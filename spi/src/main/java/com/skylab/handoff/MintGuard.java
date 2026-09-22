package com.skylab.handoff;

import org.keycloak.models.UserModel;
import org.keycloak.models.UserSessionModel;
import org.keycloak.representations.AccessToken;
import org.keycloak.services.managers.AuthenticationManager;

import java.util.Objects;

/**
 * The contract a bearer token must meet to mint a handoff code, after Keycloak's own bearer
 * verification (signature, expiry, revocation, a live online <em>or offline</em> user session,
 * enabled user): it was issued to SkyApp and names the session it belongs to.
 */
final class MintGuard {

    static final String SKYAPP_CLIENT_ID = "skyapp";

    private MintGuard() {
    }

    /**
     * @return {@code null} when the token may mint, otherwise a short reason for debug logs.
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
        if (!SKYAPP_CLIENT_ID.equals(token.getIssuedFor())) {
            return "azp is not skyapp";
        }
        if (token.getSessionId() == null || !Objects.equals(token.getSessionId(), userSession.getId())) {
            return "sid does not match the user session";
        }
        if (userSession.getUser() == null || !Objects.equals(user.getId(), userSession.getUser().getId())) {
            return "user session belongs to another user";
        }
        return null;
    }

    /**
     * When the person really authenticated in SkyApp (epoch seconds): the source session's
     * {@code AUTH_TIME} note, which is what Keycloak writes into {@code auth_time}; failing that
     * the verified token's {@code auth_time}; failing that the session start. The browser
     * session inherits it, so actions that need a fresh login still ask for one.
     */
    static long originalAuthTime(UserSessionModel userSession, AccessToken token) {
        String note = userSession.getNote(AuthenticationManager.AUTH_TIME);
        if (note != null) {
            try {
                long authTime = Long.parseLong(note);
                if (authTime > 0) {
                    return authTime;
                }
            } catch (NumberFormatException ignored) {
                // fall through to the token claim
            }
        }
        Long claim = token.getAuth_time();
        if (claim != null && claim > 0) {
            return claim;
        }
        return userSession.getStarted();
    }
}
