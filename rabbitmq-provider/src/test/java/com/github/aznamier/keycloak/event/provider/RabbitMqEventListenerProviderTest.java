package com.github.aznamier.keycloak.event.provider;

import com.rabbitmq.client.AMQP;
import com.rabbitmq.client.Channel;
import org.junit.jupiter.api.Test;
import org.keycloak.events.Event;
import org.keycloak.events.EventType;
import org.keycloak.events.admin.AdminEvent;
import org.keycloak.events.admin.AuthDetails;
import org.keycloak.events.admin.OperationType;
import org.keycloak.models.KeycloakContext;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakTransaction;
import org.keycloak.models.KeycloakTransactionManager;
import org.keycloak.util.JsonSerialization;

import java.lang.reflect.Proxy;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

class RabbitMqEventListenerProviderTest {

    private static final String ADDRESS = "ayse.yilmaz@example.invalid";
    private static final String IP = "192.0.2.10";

    private final List<String> channelCalls = new ArrayList<>();
    private final List<Published> published = new ArrayList<>();
    private final AtomicInteger opened = new AtomicInteger();
    private final AtomicReference<KeycloakTransaction> afterCompletion = new AtomicReference<>();
    private boolean channelOpen = true;

    private record Published(String exchange, String routingKey, AMQP.BasicProperties properties, String body) {
    }

    @Test
    void aProviderThatIsNeverClosedHoldsNoChannel() {
        RabbitMqEventListenerProvider provider = provider();

        provider.onEvent(userAdminEvent(OperationType.CREATE), false);

        // Keycloak's admin event builder never closes its listeners: nothing may be open yet.
        assertEquals(0, opened.get());
        assertEquals(List.of(), channelCalls);
    }

    @Test
    void everyMessageGetsItsOwnChannelWhichIsClosedAfterPublishing() {
        RabbitMqEventListenerProvider provider = provider();
        provider.onEvent(userAdminEvent(OperationType.CREATE), false);
        provider.onEvent(userAdminEvent(OperationType.UPDATE), true);

        commit();

        assertEquals(2, opened.get());
        assertEquals(List.of("isOpen", "basicPublish", "close", "isOpen", "basicPublish", "close"), channelCalls);
    }

    @Test
    void aClosedChannelIsSkippedAndStillReleased() {
        channelOpen = false;
        RabbitMqEventListenerProvider provider = provider();
        provider.onEvent(userAdminEvent(OperationType.CREATE), false);

        commit();

        assertEquals(List.of("isOpen", "close"), channelCalls);
    }

    @Test
    void aRegisterEventCarriesIdentifiersOnly() throws Exception {
        RabbitMqEventListenerProvider provider = provider();
        Event event = userEvent(EventType.REGISTER);

        provider.onEvent(event);
        commit();

        assertEquals(1, published.size());
        Published message = published.get(0);
        assertEquals("keycloak.events", message.exchange());
        assertEquals("KK.EVENT.CLIENT.e-skylab.SUCCESS.accountcenter.REGISTER", message.routingKey());
        Map<?, ?> body = JsonSerialization.readValue(message.body(), Map.class);
        assertEquals(List.of("id", "type", "realmId", "clientId", "userId", "time"), List.copyOf(body.keySet()));
        assertEquals(event.getId(), body.get("id"));
        assertEquals("REGISTER", body.get("type"));
        assertEquals("realm-uuid", body.get("realmId"));
        assertEquals("account.center", body.get("clientId"));
        assertEquals("user-uuid", body.get("userId"));
        assertEquals(1_789_833_600_000L, ((Number) body.get("time")).longValue());
        assertNoPersonalData(message.body());
        assertEquals(event.getId(), message.properties().getMessageId());
        assertEquals("Keycloak", message.properties().getAppId());
        assertEquals("application/json", message.properties().getContentType());
        assertEquals(2, message.properties().getDeliveryMode());
        assertEquals(null, message.properties().getHeaders());
    }

    @Test
    void everyCatalogUserEventIsPublished() {
        RabbitMqEventListenerProvider provider = provider();
        for (EventType type : List.of(EventType.REGISTER, EventType.UPDATE_EMAIL, EventType.UPDATE_PROFILE,
                EventType.DELETE_ACCOUNT)) {
            provider.onEvent(userEvent(type));
        }

        commit();

        assertEquals(List.of(
                "KK.EVENT.CLIENT.e-skylab.SUCCESS.accountcenter.REGISTER",
                "KK.EVENT.CLIENT.e-skylab.SUCCESS.accountcenter.UPDATE_EMAIL",
                "KK.EVENT.CLIENT.e-skylab.SUCCESS.accountcenter.UPDATE_PROFILE",
                "KK.EVENT.CLIENT.e-skylab.SUCCESS.accountcenter.DELETE_ACCOUNT"), routingKeys());
        published.forEach(message -> assertNoPersonalData(message.body()));
    }

    @Test
    void userEventsOutsideTheCatalogAndErrorsOpenNoChannel() {
        RabbitMqEventListenerProvider provider = provider();
        provider.onEvent(userEvent(EventType.LOGIN));
        provider.onEvent(userEvent(EventType.LOGIN_ERROR));
        provider.onEvent(userEvent(EventType.CODE_TO_TOKEN));
        Event registerError = userEvent(EventType.REGISTER_ERROR);
        registerError.setError("invalid_registration");
        provider.onEvent(registerError);
        Event failedRegister = userEvent(EventType.REGISTER);
        failedRegister.setError("email_in_use");
        provider.onEvent(failedRegister);

        commit();

        assertEquals(0, opened.get());
        assertEquals(List.of(), published);
    }

    @Test
    void theTypeListNarrowsTheCatalog() {
        RabbitMqEventListenerProvider provider = provider(Map.of("event_types", "REGISTER"));
        provider.onEvent(userEvent(EventType.REGISTER));
        provider.onEvent(userEvent(EventType.UPDATE_EMAIL));

        commit();

        assertEquals(List.of("KK.EVENT.CLIENT.e-skylab.SUCCESS.accountcenter.REGISTER"), routingKeys());
    }

    @Test
    void anEmptyTypeListPublishesNoUserEvent() {
        RabbitMqEventListenerProvider provider = provider(Map.of("event_types", ""));
        provider.onEvent(userEvent(EventType.REGISTER));
        provider.onEvent(userAdminEvent(OperationType.CREATE), true);

        commit();

        assertEquals(List.of("KK.EVENT.ADMIN.e-skylab.SUCCESS.USER.CREATE"), routingKeys());
    }

    @Test
    void anAdminEventCarriesNeitherTheRepresentationNorItsAuthor() throws Exception {
        RabbitMqEventListenerProvider provider = provider();
        AdminEvent event = userAdminEvent(OperationType.CREATE);

        provider.onEvent(event, true);
        commit();

        assertEquals(1, published.size());
        Published message = published.get(0);
        assertEquals("KK.EVENT.ADMIN.e-skylab.SUCCESS.USER.CREATE", message.routingKey());
        Map<?, ?> body = JsonSerialization.readValue(message.body(), Map.class);
        assertEquals(List.of("id", "realmId", "resourceType", "operationType", "resourcePath", "time"),
                List.copyOf(body.keySet()));
        assertEquals(event.getId(), body.get("id"));
        assertEquals("realm-uuid", body.get("realmId"));
        assertEquals("USER", body.get("resourceType"));
        assertEquals("CREATE", body.get("operationType"));
        assertEquals("users/user-uuid", body.get("resourcePath"));
        assertNoPersonalData(message.body());
        assertFalse(message.body().contains("admin-uuid"), "the author of the change");
        assertEquals(event.getId(), message.properties().getMessageId());
        // Keycloak hands the same event to its store and every listener: it is not changed here.
        assertNotNull(event.getRepresentation());
    }

    @Test
    void adminEventsOutsideTheCatalogAndErrorsOpenNoChannel() {
        RabbitMqEventListenerProvider provider = provider();
        provider.onEvent(userAdminEvent(OperationType.ACTION), true);
        AdminEvent realm = userAdminEvent(OperationType.UPDATE);
        realm.setResourceTypeAsString("REALM");
        realm.setResourcePath("realms/e-skylab");
        provider.onEvent(realm, true);
        AdminEvent membership = userAdminEvent(OperationType.CREATE);
        membership.setResourceTypeAsString("GROUP_MEMBERSHIP");
        provider.onEvent(membership, true);
        AdminEvent failed = userAdminEvent(OperationType.DELETE);
        failed.setError("unknown_error");
        provider.onEvent(failed, true);

        commit();

        assertEquals(0, opened.get());
        assertEquals(List.of(), published);
    }

    @Test
    void anEmptyAdminResourceListPublishesNoAdminEvent() {
        RabbitMqEventListenerProvider provider = provider(Map.of("admin_resources", ""));
        provider.onEvent(userAdminEvent(OperationType.DELETE), true);
        provider.onEvent(userEvent(EventType.DELETE_ACCOUNT));

        commit();

        assertEquals(List.of("KK.EVENT.CLIENT.e-skylab.SUCCESS.accountcenter.DELETE_ACCOUNT"), routingKeys());
    }

    @Test
    void anEventWithoutAnIdGetsOneForItsBodyAndItsMessageId() throws Exception {
        RabbitMqEventListenerProvider provider = provider();
        Event event = userEvent(EventType.UPDATE_PROFILE);
        event.setId(null);

        provider.onEvent(event);
        commit();

        Published message = published.get(0);
        String id = (String) JsonSerialization.readValue(message.body(), Map.class).get("id");
        assertEquals(id, UUID.fromString(id).toString());
        assertEquals(id, message.properties().getMessageId());
    }

    @Test
    void nothingIsPublishedWhenTheTransactionRollsBack() {
        RabbitMqEventListenerProvider provider = provider();
        provider.onEvent(userEvent(EventType.REGISTER));
        provider.onEvent(userAdminEvent(OperationType.CREATE), true);

        KeycloakTransaction transaction = afterCompletion.get();
        transaction.begin();
        transaction.rollback();

        assertEquals(0, opened.get());
    }

    private static void assertNoPersonalData(String body) {
        assertFalse(body.contains(ADDRESS), "the e-mail address");
        assertFalse(body.contains("ayse.yilmaz"), "the username");
        assertFalse(body.contains(IP), "the IP address");
        assertFalse(body.contains("session-uuid"), "the session");
        assertFalse(body.contains("details"), "the details");
        assertFalse(body.contains("representation"), "the representation");
        assertFalse(body.contains("authDetails"), "the author");
        assertFalse(body.contains("@class"), "a Java type");
        assertTrue(body.length() < 64 * 1024);
    }

    private List<String> routingKeys() {
        return published.stream().map(Published::routingKey).toList();
    }

    private RabbitMqEventListenerProvider provider() {
        return provider(Map.of());
    }

    private RabbitMqEventListenerProvider provider(Map<String, String> settings) {
        Channel channel = proxy(Channel.class, (method, args) -> {
            channelCalls.add(method);
            if ("basicPublish".equals(method)) {
                published.add(new Published((String) args[0], (String) args[1], (AMQP.BasicProperties) args[2],
                        new String((byte[]) args[3], StandardCharsets.UTF_8)));
            }
            return "isOpen".equals(method) ? channelOpen : null;
        });
        KeycloakTransactionManager transactions = proxy(KeycloakTransactionManager.class, (method, args) -> {
            if ("enlistAfterCompletion".equals(method)) {
                afterCompletion.set((KeycloakTransaction) args[0]);
            }
            return null;
        });
        KeycloakContext context = proxy(KeycloakContext.class, (method, args) -> null);
        KeycloakSession session = proxy(KeycloakSession.class, (method, args) -> switch (method) {
            case "getTransactionManager" -> transactions;
            case "getContext" -> context;
            default -> null;
        });
        Map<String, String> config = new java.util.HashMap<>(settings);
        config.putIfAbsent("exchange", "keycloak.events");
        return new RabbitMqEventListenerProvider(() -> {
            opened.incrementAndGet();
            return channel;
        }, session, RabbitMqConfig.from(config::get));
    }

    private void commit() {
        KeycloakTransaction transaction = afterCompletion.get();
        assertNotNull(transaction, "the provider must publish after the Keycloak transaction");
        transaction.begin();
        transaction.commit();
    }

    /** A user event as Keycloak's EventBuilder sends it: with the IP, the session and details. */
    private static Event userEvent(EventType type) {
        Event event = new Event();
        event.setId(UUID.randomUUID().toString());
        event.setType(type);
        event.setRealmId("realm-uuid");
        event.setRealmName("e-skylab");
        event.setClientId("account.center");
        event.setUserId("user-uuid");
        event.setSessionId("session-uuid");
        event.setIpAddress(IP);
        event.setTime(1_789_833_600_000L);
        event.setDetails(Map.of(
                "username", "ayse.yilmaz",
                "email", ADDRESS,
                "previous_email", "old." + ADDRESS,
                "register_method", "email_code"));
        return event;
    }

    /** A user admin event as AdminEventBuilder sends it with admin event details on. */
    private static AdminEvent userAdminEvent(OperationType operation) {
        AdminEvent event = new AdminEvent();
        event.setId(UUID.randomUUID().toString());
        event.setRealmId("realm-uuid");
        event.setRealmName("e-skylab");
        event.setOperationType(operation);
        event.setResourceTypeAsString("USER");
        event.setResourcePath("users/user-uuid");
        event.setTime(1_789_833_600_000L);
        event.setRepresentation("{\"username\":\"ayse.yilmaz\",\"email\":\"" + ADDRESS + "\"}");
        event.setDetails(Map.of("email", ADDRESS));
        AuthDetails author = new AuthDetails();
        author.setRealmId("master-uuid");
        author.setClientId("admin-cli");
        author.setUserId("admin-uuid");
        author.setIpAddress(IP);
        event.setAuthDetails(author);
        return event;
    }

    @FunctionalInterface
    private interface Answer {
        Object answer(String method, Object[] args);
    }

    private static <T> T proxy(Class<T> type, Answer answer) {
        return type.cast(Proxy.newProxyInstance(
                RabbitMqEventListenerProviderTest.class.getClassLoader(),
                new Class<?>[] {type},
                (target, method, args) -> {
                    if (method.getDeclaringClass() == Object.class) {
                        return switch (method.getName()) {
                            case "hashCode" -> System.identityHashCode(target);
                            case "equals" -> target == args[0];
                            default -> type.getSimpleName();
                        };
                    }
                    Object result = answer.answer(method.getName(), args);
                    if (result == null && method.getReturnType() == boolean.class) {
                        return false;
                    }
                    return result;
                }));
    }
}
