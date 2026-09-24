package com.skylab.handoff;

import java.util.Objects;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Who the admin endpoints admit, resolved once at startup: members of one Keycloak group (by
 * path; {@code /ADMIN}, the group superadmin and core treat as admin, by default) calling with an
 * access token issued to one client ({@code admin}, superadmin's own client, by default).
 */
final class AdminAccess {

    private final String groupPath;
    private final String clientId;
    /** Realms whose missing admin group was already logged and has not been found since. */
    private final Set<String> realmsWithoutGroup = ConcurrentHashMap.newKeySet();

    AdminAccess(String groupPath, String clientId) {
        this.groupPath = Objects.requireNonNull(groupPath, "groupPath");
        this.clientId = Objects.requireNonNull(clientId, "clientId");
    }

    String groupPath() {
        return groupPath;
    }

    String clientId() {
        return clientId;
    }

    /**
     * Notes one lookup of the admin group in a realm.
     *
     * @return {@code true} only for the first lookup that misses the group, so a missing group is
     *         logged once rather than on every refused request; once the group is found again, a
     *         later disappearance is logged again
     */
    boolean warnOfMissingGroup(String realmId, boolean groupExists) {
        if (groupExists) {
            realmsWithoutGroup.remove(realmId);
            return false;
        }
        return realmsWithoutGroup.add(realmId);
    }
}
