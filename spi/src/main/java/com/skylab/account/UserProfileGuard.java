package com.skylab.account;

import org.jboss.logging.Logger;
import org.keycloak.models.KeycloakSession;
import org.keycloak.representations.userprofile.config.UPConfig;
import org.keycloak.userprofile.UserProfileProvider;

/**
 * Fails closed when the realm's User Profile lets people edit unmanaged attributes: with
 * {@code unmanagedAttributePolicy=ENABLED} the person could rewrite {@code usernameChangedAt},
 * {@code schoolEmail} or {@code personalEmail} through Account REST and defeat the rules this
 * extension enforces. Reads stay available; mutations answer 503 until reconcile fixes the realm.
 */
final class UserProfileGuard {

    private static final Logger LOG = Logger.getLogger(UserProfileGuard.class);

    private UserProfileGuard() {
    }

    static void requireManagedAttributes(KeycloakSession session) {
        UserProfileProvider profiles = session.getProvider(UserProfileProvider.class);
        UPConfig config = profiles == null ? null : profiles.getConfiguration();
        if (config == null) {
            LOG.warn("sky-account refused a mutation: the User Profile configuration is unavailable");
            throw Problems.unmanagedAttributesEnabled().exception();
        }
        if (config.getUnmanagedAttributePolicy() == UPConfig.UnmanagedAttributePolicy.ENABLED) {
            LOG.warn("sky-account refused a mutation: unmanagedAttributePolicy=ENABLED lets people edit "
                    + "usernameChangedAt, schoolEmail and personalEmail through Account REST");
            throw Problems.unmanagedAttributesEnabled().exception();
        }
    }
}
