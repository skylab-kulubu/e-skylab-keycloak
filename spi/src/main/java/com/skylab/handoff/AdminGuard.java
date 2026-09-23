package com.skylab.handoff;

import org.keycloak.models.GroupModel;
import org.keycloak.models.UserModel;
import org.keycloak.models.UserSessionModel;
import org.keycloak.representations.AccessToken;

import java.util.Objects;

/**
 * Who may change Handoff targets: after Keycloak's own bearer verification, a token issued to the
 * admin client (its {@code azp}) for an enabled member of the admin group, bound to a live online
 * session. Membership is read from the person's group mappings, not from the token's claims, and
 * {@link UserModel#isMemberOf} also counts membership through any subgroup of the admin group.
 */
final class AdminGuard {

    private AdminGuard() {
    }

    /**
     * @param adminGroup the realm's admin group, {@code null} when it does not exist (everyone is refused)
     * @return {@code null} when the caller is an admin, otherwise a short reason for debug logs
     */
    static String rejectionReason(AccessToken token, UserModel user, UserSessionModel userSession,
                                  GroupModel adminGroup, String adminClientId) {
        if (token == null || user == null) {
            return "no verified token";
        }
        if (adminClientId == null || !adminClientId.equals(token.getIssuedFor())) {
            return "token not issued to the admin client";
        }
        if (userSession == null) {
            return "no active user session";
        }
        if (userSession.isOffline()) {
            return "offline session";
        }
        if (!user.isEnabled()) {
            return "user disabled";
        }
        if (token.getSessionId() == null || !Objects.equals(token.getSessionId(), userSession.getId())) {
            return "sid does not match the user session";
        }
        if (userSession.getUser() == null || !Objects.equals(user.getId(), userSession.getUser().getId())) {
            return "user session belongs to another user";
        }
        if (adminGroup == null) {
            return "admin group not found in the realm";
        }
        if (!user.isMemberOf(adminGroup)) {
            return "not a member of the admin group";
        }
        return null;
    }
}
