package com.skylab.account;

import org.jboss.logging.Logger;
import org.keycloak.Config;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;
import org.keycloak.models.RealmModel;
import org.keycloak.models.utils.KeycloakModelUtils;
import org.keycloak.services.resource.RealmResourceProvider;
import org.keycloak.services.resource.RealmResourceProviderFactory;

import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.regex.Pattern;

/**
 * Mounts {@code /realms/{realm}/sky-account}. The only setting is the alias of the YTÜ
 * Microsoft identity provider whose link makes an account a Verified YTÜ account. It is read
 * from the provider config ({@code --spi-realm-restapi-extension-sky-account-ytu-idp-alias},
 * env {@code KC_SPI_REALM_RESTAPI_EXTENSION_SKY_ACCOUNT_YTU_IDP_ALIAS}), then from the
 * {@code SKY_ACCOUNT_YTU_IDP_ALIAS} environment variable, and defaults to {@code OBS}.
 */
public final class SkyAccountResourceProviderFactory implements RealmResourceProviderFactory {

    public static final String PROVIDER_ID = "sky-account";
    static final String YTU_IDP_ALIAS_CONFIG = "ytu-idp-alias";
    static final String YTU_IDP_ALIAS_ENV = "SKY_ACCOUNT_YTU_IDP_ALIAS";
    static final String DEFAULT_YTU_IDP_ALIAS = "OBS";

    private static final Logger LOG = Logger.getLogger(SkyAccountResourceProviderFactory.class);
    private static final Pattern IDP_ALIAS = Pattern.compile("^[A-Za-z0-9._-]{1,64}$");
    private static final Set<String> BRUTE_FORCE_WARNED_REALMS = ConcurrentHashMap.newKeySet();

    private volatile String ytuIdpAlias = DEFAULT_YTU_IDP_ALIAS;

    @Override
    public String getId() {
        return PROVIDER_ID;
    }

    @Override
    public RealmResourceProvider create(KeycloakSession session) {
        return new SkyAccountResourceProvider(session, ytuIdpAlias);
    }

    @Override
    public void init(Config.Scope config) {
        ytuIdpAlias = resolveYtuIdpAlias(config == null ? null : config.get(YTU_IDP_ALIAS_CONFIG), System.getenv());
    }

    static String resolveYtuIdpAlias(String configured, Map<String, String> environment) {
        String candidate = configured;
        if (candidate == null || candidate.isBlank()) {
            candidate = environment.get(YTU_IDP_ALIAS_ENV);
        }
        if (candidate == null || candidate.isBlank()) {
            return DEFAULT_YTU_IDP_ALIAS;
        }
        String alias = candidate.trim();
        if (!IDP_ALIAS.matcher(alias).matches()) {
            throw new IllegalStateException(
                    "sky-account YTÜ identity provider alias must match " + IDP_ALIAS.pattern());
        }
        return alias;
    }

    /**
     * Warns once at startup for every realm that serves Account Center without brute-force
     * protection: until reconcile enables it, sudo guessing is bounded only by the SPI rate
     * limiter. Realms imported later get the same single warning on their first sudo attempt.
     */
    @Override
    public void postInit(KeycloakSessionFactory factory) {
        try {
            KeycloakModelUtils.runJobInTransaction(factory, session -> {
                List<String> unprotected = session.realms().getRealmsStream()
                        .filter(realm -> realm.getClientByClientId(AccessGuard.ACCOUNT_CENTER_CLIENT_ID) != null)
                        .filter(realm -> !realm.isBruteForceProtected())
                        .filter(realm -> BRUTE_FORCE_WARNED_REALMS.add(realm.getId()))
                        .map(RealmModel::getName)
                        .toList();
                if (!unprotected.isEmpty()) {
                    LOG.warnf("sky-account: brute-force protection is disabled in realm(s) %s; sudo password and "
                            + "TOTP guessing is bounded only by the SPI rate limiter until reconcile enables it",
                            unprotected);
                }
            });
        } catch (RuntimeException exception) {
            LOG.debug("sky-account could not inspect brute-force protection at startup", exception);
        }
    }

    static void warnOnceIfUnprotected(RealmModel realm) {
        if (!realm.isBruteForceProtected() && BRUTE_FORCE_WARNED_REALMS.add(realm.getId())) {
            LOG.warnf("sky-account: brute-force protection is disabled in realm %s; sudo password and TOTP "
                    + "guessing is bounded only by the SPI rate limiter until reconcile enables it", realm.getName());
        }
    }

    @Override
    public void close() {
        // no-op
    }
}
