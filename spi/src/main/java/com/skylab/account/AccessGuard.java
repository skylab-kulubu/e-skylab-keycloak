package com.skylab.account;

import jakarta.ws.rs.NotAuthorizedException;
import org.jboss.logging.Logger;
import org.keycloak.models.AccountRoles;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;
import org.keycloak.models.UserSessionModel;
import org.keycloak.representations.AccessToken;
import org.keycloak.services.managers.AppAuthManager;
import org.keycloak.services.managers.AuthenticationManager;

import java.util.Objects;
import java.util.Set;

/**
 * Admits only a live Account Center user token: Keycloak's own bearer verification (signature,
 * expiry, revocation, active user session, enabled user) followed by the sky-account
 * contract checks. Every failure is the same 401 problem so the response leaks nothing.
 */
final class AccessGuard {

    static final String ACCOUNT_CENTER_CLIENT_ID = "account-center";
    static final String ACCOUNT_CLIENT_ID = "account";

    private static final Logger LOG = Logger.getLogger(AccessGuard.class);

    private AccessGuard() {
    }

    static Caller authenticate(KeycloakSession session) {
        RealmModel realm = session.getContext().getRealm();
        final AuthenticationManager.AuthResult result;
        try {
            result = new AppAuthManager.BearerTokenAuthenticator(session).authenticate();
        } catch (NotAuthorizedException exception) {
            throw Problems.unauthorized(realm.getName()).exception();
        }
        if (result == null) {
            throw Problems.unauthorized(realm.getName()).exception();
        }
        String rejection = rejectionReason(result.token(), result.user(), result.session());
        if (rejection != null) {
            LOG.debugf("sky-account rejected a bearer token: %s", rejection);
            throw Problems.unauthorized(realm.getName()).exception();
        }
        return new Caller(result.user(), result.session(), result.token(), result.client());
    }

    /**
     * @return {@code null} when the token satisfies the contract, otherwise a short reason for logs.
     */
    static String rejectionReason(AccessToken token, UserModel user, UserSessionModel userSession) {
        if (token == null || user == null) {
            return "no verified token";
        }
        if (userSession == null) {
            return "no active user session";
        }
        if (!user.isEnabled()) {
            return "user disabled";
        }
        if (!ACCOUNT_CENTER_CLIENT_ID.equals(token.getIssuedFor())) {
            return "azp is not account-center";
        }
        if (!token.hasAudience(ACCOUNT_CLIENT_ID)) {
            return "aud lacks account";
        }
        AccessToken.Access accountAccess = token.getResourceAccess(ACCOUNT_CLIENT_ID);
        Set<String> roles = accountAccess == null ? null : accountAccess.getRoles();
        if (roles == null || !roles.contains(AccountRoles.MANAGE_ACCOUNT)) {
            return "manage-account role missing";
        }
        if (token.getSessionId() == null || !Objects.equals(token.getSessionId(), userSession.getId())) {
            return "sid does not match the user session";
        }
        if (!Objects.equals(user.getId(), userSession.getUser().getId())) {
            return "user session belongs to another user";
        }
        return null;
    }
}
