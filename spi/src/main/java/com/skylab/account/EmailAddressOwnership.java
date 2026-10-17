package com.skylab.account;

import jakarta.persistence.EntityManager;
import jakarta.persistence.FlushModeType;
import jakarta.persistence.LockModeType;
import org.keycloak.connections.jpa.JpaConnectionProvider;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;
import org.keycloak.models.jpa.entities.RealmEntity;

import java.util.Locale;
import java.util.Map;

/**
 * Serializes the product's e-mail ownership writes, including personalEmail-only confirmations.
 * The database's unique email constraint cannot protect a user attribute. Before the first user
 * write, hold the realm row with PESSIMISTIC_WRITE until the transaction commits or rolls back;
 * no expiring cache lease and no manual unlock. Every participating path uses realm -> user lock
 * order and performs no mail or other network request while holding it.
 *
 * <p>The scalar query after the lock bypasses Keycloak's user cache and JPA's managed entities:
 * a holder committed while this request waited must not disappear behind a cached negative lookup.
 * The provider check is retained for non-local users. Admin REST/imports and operator maintenance
 * do not use this guard; those writes require a maintenance window when they change ownership.
 */
final class EmailAddressOwnership {

    private static final int LOCK_TIMEOUT_MILLISECONDS = 5_000;
    static final String OWNERS_QUERY = "select u.id from UserEntity u where u.realmId = :realm and u.id <> :exclude"
            + " and (lower(u.email) = :address or lower(u.username) = :address or exists"
            + " (select a.id from UserAttributeEntity a where a.user = u and a.name in (:personal, :school)"
            + " and lower(a.value) = :address))";

    private EmailAddressOwnership() {
    }

    /** Acquires the transaction lock, then checks all local ownership slots and the user provider. */
    static boolean isTakenAfterLock(KeycloakSession session, RealmModel realm, UserModel user, String address) {
        try {
            JpaConnectionProvider jpa = session.getProvider(JpaConnectionProvider.class);
            if (jpa == null) {
                throw new IllegalStateException("e-mail ownership requires JPA");
            }
            EntityManager em = jpa.getEntityManager();
            RealmEntity locked = em.find(RealmEntity.class, realm.getId(), LockModeType.PESSIMISTIC_WRITE,
                    Map.of("jakarta.persistence.lock.timeout", LOCK_TIMEOUT_MILLISECONDS));
            if (locked == null) {
                throw new IllegalStateException("e-mail ownership realm is unavailable");
            }
            String normalised = address.trim().toLowerCase(Locale.ROOT);
            boolean taken = !em.createQuery(OWNERS_QUERY, String.class)
                    .setFlushMode(FlushModeType.COMMIT)
                    .setHint("org.hibernate.cacheable", false)
                    .setParameter("realm", realm.getId())
                    .setParameter("exclude", user == null ? "" : user.getId())
                    .setParameter("address", normalised)
                    .setParameter("personal", IdentityResource.PERSONAL_EMAIL_ATTRIBUTE)
                    .setParameter("school", IdentityResource.SCHOOL_EMAIL_ATTRIBUTE)
                    .setMaxResults(1)
                    .getResultList().isEmpty();
            return taken || PersonalEmailVerification.isTakenByAnother(session, realm, user, normalised);
        } catch (RuntimeException failed) {
            session.getTransactionManager().setRollbackOnly();
            throw new IllegalStateException("e-mail ownership could not be checked", failed);
        }
    }
}
