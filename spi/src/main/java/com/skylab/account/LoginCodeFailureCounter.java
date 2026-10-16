package com.skylab.account;

import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;

/** The persistent, account-scoped guard around a Login code comparison (ticket 24). */
interface LoginCodeFailureCounter {
    int LIMIT = 100;

    /** Enlists the database provider before transaction preparation starts. */
    void prepare(KeycloakSession session);

    /** Holds the account's database row until commit/rollback; null for a missing local account. */
    Guard lock(KeycloakSession session, RealmModel realm, String userId);

    /** Only a completed, successful LOGIN calls this; uses the same account lock as comparisons. */
    void reset(KeycloakSession session, RealmModel realm, String userId);

    interface Guard {
        boolean blocked();

        /** Records one actually compared wrong code; true only on the transition to the limit. */
        boolean wrongCode();
    }
}
