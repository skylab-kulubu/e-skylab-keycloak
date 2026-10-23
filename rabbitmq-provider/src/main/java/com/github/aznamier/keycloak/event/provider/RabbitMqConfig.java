package com.github.aznamier.keycloak.event.provider;

import org.jboss.logging.Logger;
import org.keycloak.Config.Scope;
import org.keycloak.events.Event;
import org.keycloak.events.EventType;
import org.keycloak.events.admin.AdminEvent;
import org.keycloak.events.admin.OperationType;
import org.keycloak.models.KeycloakSession;
import org.keycloak.util.JsonSerialization;

import java.util.Collections;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.function.UnaryOperator;
import java.util.regex.Pattern;

final class RabbitMqConfig {

    static final String ROUTING_KEY_PREFIX = "KK.EVENT";

    /**
     * The user events of the event catalog (ADR-0071, RabbitMQ SPEC §5): what core wakes its user
     * sync for. No other type ever leaves Keycloak; KK_TO_RMQ_EVENT_TYPES can only narrow it.
     */
    static final Set<EventType> CATALOG_EVENT_TYPES = Collections.unmodifiableSet(new LinkedHashSet<>(List.of(
            EventType.REGISTER, EventType.UPDATE_EMAIL, EventType.UPDATE_PROFILE, EventType.DELETE_ACCOUNT)));

    /** The admin events of the catalog: these resource types (KK_TO_RMQ_ADMIN_RESOURCES narrows them)... */
    static final Set<String> CATALOG_ADMIN_RESOURCES = Set.of("USER");

    /** ...with these operations. ACTION (an action e-mail, a credential reset) is not one of them. */
    static final Set<OperationType> CATALOG_ADMIN_OPERATIONS = Collections.unmodifiableSet(new LinkedHashSet<>(List.of(
            OperationType.CREATE, OperationType.UPDATE, OperationType.DELETE)));

    private static final Logger LOG = Logger.getLogger(RabbitMqConfig.class);
    private static final Pattern SPECIAL_CHARACTERS = Pattern.compile("[^*#a-zA-Z0-9 _.-]");
    private static final Pattern SPACE = Pattern.compile(" ");
    private static final Pattern DOT = Pattern.compile("\\.");

    private String host;
    private int port;
    private String username;
    private String password;
    private String virtualHost;
    private boolean useTls;
    private String trustStore;
    private String trustStorePassword;
    private String keyStore;
    private String keyStorePassword;
    private String exchange;
    private Set<EventType> eventTypes;
    private Set<String> adminResources;

    /** The provider's settings: the SPI scope first, then the KK_TO_RMQ_* environment variables. */
    static RabbitMqConfig from(Scope scope) {
        return from(name -> {
            String configured = scope == null ? null : scope.get(name);
            return configured != null ? configured : System.getenv("KK_TO_RMQ_" + name.toUpperCase(Locale.ENGLISH));
        });
    }

    /** The same from a lookup that answers null for a setting that is not set. */
    static RabbitMqConfig from(UnaryOperator<String> lookup) {
        RabbitMqConfig config = new RabbitMqConfig();
        config.host = value(lookup, "url", "localhost");
        config.port = parsePort(value(lookup, "port", "5672"));
        config.username = value(lookup, "username", "guest");
        config.password = value(lookup, "password", "guest");
        config.virtualHost = value(lookup, "vhost", "/");
        config.useTls = Boolean.parseBoolean(value(lookup, "use_tls", "false"));
        config.trustStore = value(lookup, "trust_store", "");
        config.trustStorePassword = value(lookup, "trust_store_pass", "");
        config.keyStore = value(lookup, "key_store", "");
        config.keyStorePassword = value(lookup, "key_store_pass", "");
        config.exchange = value(lookup, "exchange", "amq.topic");
        config.eventTypes = eventTypes(lookup.apply("event_types"));
        config.adminResources = adminResources(lookup.apply("admin_resources"));
        LOG.infof("keycloak-to-rabbitmq publishes user events %s and admin events %s %s",
                config.eventTypes, config.adminResources, CATALOG_ADMIN_OPERATIONS);
        return config;
    }

    /**
     * KK_TO_RMQ_EVENT_TYPES: not set, the catalog; set, the comma-separated catalog types it names
     * (empty: none). A name outside the catalog is refused with an error line and never published.
     */
    static Set<EventType> eventTypes(String configured) {
        if (configured == null) {
            return CATALOG_EVENT_TYPES;
        }
        Set<EventType> types = new LinkedHashSet<>();
        for (String name : names(configured)) {
            EventType type = CATALOG_EVENT_TYPES.stream()
                    .filter(candidate -> candidate.name().equals(name))
                    .findFirst()
                    .orElse(null);
            if (type == null) {
                LOG.errorf("keycloak-to-rabbitmq ignores event type %s: it is not in the event catalog %s",
                        name, CATALOG_EVENT_TYPES);
            } else {
                types.add(type);
            }
        }
        return Collections.unmodifiableSet(types);
    }

    /** KK_TO_RMQ_ADMIN_RESOURCES, as {@link #eventTypes} for the catalog's admin resource types. */
    static Set<String> adminResources(String configured) {
        if (configured == null) {
            return CATALOG_ADMIN_RESOURCES;
        }
        Set<String> resources = new LinkedHashSet<>();
        for (String name : names(configured)) {
            if (CATALOG_ADMIN_RESOURCES.contains(name)) {
                resources.add(name);
            } else {
                LOG.errorf("keycloak-to-rabbitmq ignores admin resource type %s: it is not in the event catalog %s",
                        name, CATALOG_ADMIN_RESOURCES);
            }
        }
        return Collections.unmodifiableSet(resources);
    }

    private static Set<String> names(String configured) {
        Set<String> names = new LinkedHashSet<>();
        for (String part : configured.split(",")) {
            String name = part.trim().toUpperCase(Locale.ROOT);
            if (!name.isEmpty()) {
                names.add(name);
            }
        }
        return names;
    }

    /** A successful user event of a selected type. An error has its own type (REGISTER_ERROR). */
    boolean publishes(Event event) {
        return event.getType() != null && event.getError() == null && eventTypes.contains(event.getType());
    }

    /** A successful admin event of a selected resource type with a catalog operation. */
    boolean publishes(AdminEvent event) {
        return event.getError() == null
                && event.getResourceTypeAsString() != null
                && adminResources.contains(event.getResourceTypeAsString())
                && CATALOG_ADMIN_OPERATIONS.contains(event.getOperationType());
    }

    static String routingKey(AdminEvent event, KeycloakSession session) {
        String realm = event.getRealmName();
        if (realm == null) {
            realm = session.getContext().getRealm() == null
                    ? event.getRealmId()
                    : session.getContext().getRealm().getName();
        }
        return normalize(ROUTING_KEY_PREFIX
                + ".ADMIN."
                + withoutDots(realm)
                + "."
                + (event.getError() == null ? "SUCCESS" : "ERROR")
                + "."
                + event.getResourceTypeAsString()
                + "."
                + event.getOperationType());
    }

    static String routingKey(Event event, KeycloakSession session) {
        String realmName = event.getRealmName() != null
                ? event.getRealmName()
                : session.realms().getRealm(event.getRealmId()).getName();
        return normalize(ROUTING_KEY_PREFIX
                + ".CLIENT."
                + withoutDots(realmName)
                + "."
                + (event.getError() == null ? "SUCCESS" : "ERROR")
                + "."
                + withoutDots(event.getClientId())
                + "."
                + event.getType());
    }

    static String normalize(CharSequence value) {
        return SPACE.matcher(SPECIAL_CHARACTERS.matcher(value).replaceAll(""))
                .replaceAll("_");
    }

    static String withoutDots(String value) {
        return value == null ? "UNKNOWN" : DOT.matcher(value).replaceAll("");
    }

    static String json(Object value) {
        try {
            return JsonSerialization.writeValueAsString(value);
        } catch (Exception exception) {
            LOG.error("Could not serialize Keycloak event", exception);
            return "{\"error\":\"unparseable\"}";
        }
    }

    private static String value(UnaryOperator<String> lookup, String name, String fallback) {
        String configured = lookup.apply(name);
        String result = configured == null ? fallback : configured;
        if (!name.contains("password") && !name.endsWith("_pass")) {
            LOG.infof("keycloak-to-rabbitmq configuration: %s=%s", name, result);
        }
        return result;
    }

    private static int parsePort(String value) {
        int port = Integer.parseInt(value);
        if (port < 1 || port > 65535) {
            throw new IllegalArgumentException("RabbitMQ port is outside 1-65535");
        }
        return port;
    }

    String host() {
        return host;
    }

    int port() {
        return port;
    }

    String username() {
        return username;
    }

    String password() {
        return password;
    }

    String virtualHost() {
        return virtualHost;
    }

    boolean useTls() {
        return useTls;
    }

    String trustStore() {
        return trustStore;
    }

    String trustStorePassword() {
        return trustStorePassword;
    }

    String keyStore() {
        return keyStore;
    }

    String keyStorePassword() {
        return keyStorePassword;
    }

    String exchange() {
        return exchange;
    }

    Set<EventType> eventTypes() {
        return eventTypes;
    }

    Set<String> adminResources() {
        return adminResources;
    }
}
