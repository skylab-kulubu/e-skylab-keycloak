package com.skylab.handoff;

import org.keycloak.models.RoleModel;
import org.keycloak.models.UserModel;
import org.keycloak.models.UserSessionModel;
import org.keycloak.representations.AccessToken;

import java.util.Objects;

/**
 * Who may change Handoff targets: after Keycloak's own bearer verification, a person holding
 * the configured super-admin role, with the token bound to a live online session. The role is
 * checked on the person's effective role mappings (direct, group, composite), not on the token's
 * claims, so the superadmin panel's ordinary token works and any client is accepted.
 */
final class AdminGuard {

    private AdminGuard() {
    }

    /**
     * @return {@code null} when the caller is a super admin, otherwise a short reason for debug logs
     */
    static String rejectionReason(AccessToken token, UserModel user, UserSessionModel userSession, RoleModel adminRole) {
        if (token == null || user == null) {
            return "no verified token";
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
        if (adminRole == null) {
            return "super-admin role not found in the realm";
        }
        if (!user.hasRole(adminRole)) {
            return "not a super admin";
        }
        return null;
    }
}
