package com.skylab.handoff;

import org.keycloak.Config;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;
import org.keycloak.services.resource.RealmResourceProvider;
import org.keycloak.services.resource.RealmResourceProviderFactory;

import java.util.Map;
import java.util.regex.Pattern;

/**
 * Mounts {@code /realms/{realm}/sky-handoff}: the Web handoff that lets SkyApp open a SKY LAB
 * site in its WebView already signed in (ADR-0048). Kept apart from {@code sky-account}, which
 * serves Account Center only.
 *
 * <p>The only setting is the realm super-admin role that may change Handoff targets through
 * {@code v1/admin/targets}. It is read from the provider config
 * ({@code --spi-realm-restapi-extension--sky-handoff--admin-role}, env
 * {@code KC_SPI_REALM_RESTAPI_EXTENSION__SKY_HANDOFF__ADMIN_ROLE}), then from the
 * {@code SKY_HANDOFF_ADMIN_ROLE} environment variable, and defaults to Keycloak's own realm
 * administrator role {@code realm-management.realm-admin}, whose holders can already edit every
 * client attribute through the admin console. Unlike Admin REST, the role is checked on the person
 * alone (not also on the token's client scope), so a realm administrator's token of any client may
 * change the three Handoff target attributes. A realm role is named plainly
 * ({@code sky-super-admin}), a client role as {@code <clientId>.<role>}, the way Keycloak's
 * hardcoded-role mapper names roles.
 */
public final class SkyHandoffResourceProviderFactory implements RealmResourceProviderFactory {

    public static final String PROVIDER_ID = "sky-handoff";
    static final String ADMIN_ROLE_CONFIG = "admin-role";
    static final String ADMIN_ROLE_ENV = "SKY_HANDOFF_ADMIN_ROLE";
    static final String DEFAULT_ADMIN_ROLE = "realm-management.realm-admin";

    private static final Pattern ROLE_NAME = Pattern.compile("^[^\\p{Cntrl}]{1,255}$");

    private volatile String adminRole = DEFAULT_ADMIN_ROLE;

    @Override
    public String getId() {
        return PROVIDER_ID;
    }

    @Override
    public RealmResourceProvider create(KeycloakSession session) {
        return new SkyHandoffResourceProvider(session, adminRole);
    }

    @Override
    public void init(Config.Scope config) {
        adminRole = resolveAdminRole(config == null ? null : config.get(ADMIN_ROLE_CONFIG), System.getenv());
    }

    static String resolveAdminRole(String configured, Map<String, String> environment) {
        String candidate = configured;
        if (candidate == null || candidate.isBlank()) {
            candidate = environment.get(ADMIN_ROLE_ENV);
        }
        if (candidate == null || candidate.isBlank()) {
            return DEFAULT_ADMIN_ROLE;
        }
        String role = candidate.trim();
        if (!ROLE_NAME.matcher(role).matches()) {
            throw new IllegalStateException("sky-handoff admin role must be 1-255 characters without control characters");
        }
        return role;
    }

    @Override
    public void postInit(KeycloakSessionFactory factory) {
        // no-op
    }

    @Override
    public void close() {
        // no-op
    }
}
