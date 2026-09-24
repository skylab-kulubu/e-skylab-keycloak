package com.skylab.handoff;

import org.keycloak.Config;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;
import org.keycloak.models.utils.KeycloakModelUtils;
import org.keycloak.services.resource.RealmResourceProvider;
import org.keycloak.services.resource.RealmResourceProviderFactory;

import java.util.Map;
import java.util.regex.Pattern;

/**
 * Mounts {@code /realms/{realm}/sky-handoff}: the Web handoff that lets SkyApp open a SKY LAB
 * site in its WebView already signed in (ADR-0048). Kept apart from {@code sky-account}, which
 * serves Account Center only.
 *
 * <p>Two settings say who may change Handoff targets through {@code v1/admin/targets}: the
 * Keycloak group whose members are admins ({@code admin-group}, default {@code /ADMIN}, the group
 * superadmin and core treat as admin; membership through a subgroup counts) and the client their
 * access token must be issued to ({@code admin-client}, default {@code admin}, superadmin's own
 * client). Each is read from the provider config
 * ({@code --spi-realm-restapi-extension--sky-handoff--admin-group}, env
 * {@code KC_SPI_REALM_RESTAPI_EXTENSION__SKY_HANDOFF__ADMIN_GROUP}; likewise {@code admin-client}
 * and {@code ..._ADMIN_CLIENT}), then from the plain environment variable
 * {@code SKY_HANDOFF_ADMIN_GROUP} / {@code SKY_HANDOFF_ADMIN_CLIENT}, then the default. A group is
 * named by its path ({@code /ADMIN}, {@code /ADMIN/web}); a missing leading slash is added.
 */
public final class SkyHandoffResourceProviderFactory implements RealmResourceProviderFactory {

    public static final String PROVIDER_ID = "sky-handoff";
    static final String ADMIN_GROUP_CONFIG = "admin-group";
    static final String ADMIN_GROUP_ENV = "SKY_HANDOFF_ADMIN_GROUP";
    static final String DEFAULT_ADMIN_GROUP = "/ADMIN";
    static final String ADMIN_CLIENT_CONFIG = "admin-client";
    static final String ADMIN_CLIENT_ENV = "SKY_HANDOFF_ADMIN_CLIENT";
    static final String DEFAULT_ADMIN_CLIENT = "admin";

    private static final Pattern GROUP_PATH = Pattern.compile("^/[^\\p{Cntrl}]{1,1023}$");
    private static final Pattern CLIENT_ID = Pattern.compile("^[^\\p{Cntrl}]{1,255}$");

    private volatile AdminAccess adminAccess = new AdminAccess(DEFAULT_ADMIN_GROUP, DEFAULT_ADMIN_CLIENT);

    @Override
    public String getId() {
        return PROVIDER_ID;
    }

    @Override
    public RealmResourceProvider create(KeycloakSession session) {
        return new SkyHandoffResourceProvider(session, adminAccess);
    }

    @Override
    public void init(Config.Scope config) {
        adminAccess = new AdminAccess(
                resolveAdminGroup(config == null ? null : config.get(ADMIN_GROUP_CONFIG), System.getenv()),
                resolveAdminClient(config == null ? null : config.get(ADMIN_CLIENT_CONFIG), System.getenv()));
    }

    static String resolveAdminGroup(String configured, Map<String, String> environment) {
        String path = KeycloakModelUtils.normalizeGroupPath(
                setting(configured, environment.get(ADMIN_GROUP_ENV), DEFAULT_ADMIN_GROUP));
        if (!GROUP_PATH.matcher(path).matches()) {
            throw new IllegalStateException(
                    "sky-handoff admin group must be a group path of 1-1024 characters without control characters");
        }
        return path;
    }

    static String resolveAdminClient(String configured, Map<String, String> environment) {
        String clientId = setting(configured, environment.get(ADMIN_CLIENT_ENV), DEFAULT_ADMIN_CLIENT);
        if (!CLIENT_ID.matcher(clientId).matches()) {
            throw new IllegalStateException("sky-handoff admin client must be 1-255 characters without control characters");
        }
        return clientId;
    }

    /** The provider config, else the environment variable, else the default; trimmed. */
    private static String setting(String configured, String environment, String fallback) {
        if (configured != null && !configured.isBlank()) {
            return configured.trim();
        }
        if (environment != null && !environment.isBlank()) {
            return environment.trim();
        }
        return fallback;
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
