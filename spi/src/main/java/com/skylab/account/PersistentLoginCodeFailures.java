package com.skylab.account;

import jakarta.persistence.EntityManager;
import jakarta.persistence.FlushModeType;
import jakarta.persistence.LockModeType;
import org.keycloak.connections.jpa.JpaConnectionProvider;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;
import org.keycloak.models.cache.UserCache;
import org.keycloak.models.jpa.entities.UserAttributeEntity;
import org.keycloak.models.jpa.entities.UserEntity;
import org.hibernate.Session;

import java.sql.Connection;
import java.util.List;
import java.util.UUID;

/**
 * PostgreSQL READ COMMITTED, Keycloak 26.7.4. A user row lock serializes comparisons, increments,
 * successful LOGIN resets and the maintenance SQL reset, across nodes and restarts. The attribute
 * is unmanaged/read-only under the realm's ADMIN_VIEW policy; no UserModel attribute read/write is
 * used for security decisions. Scalar queries bypass both the user cache and JPA's identity map.
 * JPQL/persist preserve Keycloak's configured database schema. No new entity or migration.
 */
final class PersistentLoginCodeFailures implements LoginCodeFailureCounter {
    static final String ATTRIBUTE = "skyEmailCodeConsecutiveFailures";
    static final String LOCK_QUERY = "select u from UserEntity u where u.id = :user and u.realmId = :realm";
    static final String READ_QUERY = "select a.id, a.value from UserAttributeEntity a"
            + " where a.user.id = :user and a.name = :name";
    private static final int LOCK_TIMEOUT_MILLISECONDS = 5_000;

    @Override
    public void prepare(KeycloakSession session) {
        entityManager(session);
    }

    @Override
    public Guard lock(KeycloakSession session, RealmModel realm, String userId) {
        try {
            EntityManager em = entityManager(session);
            List<UserEntity> users = em.createQuery(LOCK_QUERY, UserEntity.class)
                    .setParameter("user", userId).setParameter("realm", realm.getId())
                    .setFlushMode(FlushModeType.COMMIT).setLockMode(LockModeType.PESSIMISTIC_WRITE)
                    .setHint("jakarta.persistence.lock.timeout", LOCK_TIMEOUT_MILLISECONDS)
                    .setHint("org.hibernate.cacheable", false).getResultList();
            if (users.isEmpty()) return null;
            // READ COMMITTED refreshes this separate statement after a lock wait. A stronger
            // snapshot could otherwise retain an old attribute while only the parent row is locked.
            int isolation = em.unwrap(Session.class).doReturningWork(Connection::getTransactionIsolation);
            if (isolation != Connection.TRANSACTION_READ_COMMITTED) {
                throw new IllegalStateException("Login code counter requires READ COMMITTED");
            }
            List<Object[]> rows = em.createQuery(READ_QUERY, Object[].class)
                    .setParameter("user", userId).setParameter("name", ATTRIBUTE)
                    .setFlushMode(FlushModeType.COMMIT).setHint("org.hibernate.cacheable", false)
                    .setMaxResults(2).getResultList();
            return new Locked(session, realm, em, users.getFirst(), rows);
        } catch (RuntimeException failed) {
            session.getTransactionManager().setRollbackOnly();
            throw new IllegalStateException("Login code counter is unavailable", failed);
        }
    }

    @Override
    public void reset(KeycloakSession session, RealmModel realm, String userId) {
        Guard guard = lock(session, realm, userId);
        if (guard == null) return; // Deleted or non-local users cannot have this local counter.
        Locked locked = (Locked) guard;
        try {
            locked.em.createQuery("delete from UserAttributeEntity a where a.user.id = :user and a.name = :name")
                    .setParameter("user", userId).setParameter("name", ATTRIBUTE)
                    .setFlushMode(FlushModeType.COMMIT).executeUpdate();
            // Reset is SQL-only in prepare. Cached attributes never decide whether a code may be tried.
        } catch (RuntimeException failed) {
            session.getTransactionManager().setRollbackOnly();
            throw new IllegalStateException("Login code counter could not be reset", failed);
        }
    }

    static int countOf(List<Object[]> rows) {
        if (rows.isEmpty()) return 0;
        if (rows.size() != 1 || !(rows.getFirst()[1] instanceof String value) || !value.matches("[0-9]{1,3}")) return LIMIT;
        return Math.min(Integer.parseInt(value), LIMIT);
    }

    private static EntityManager entityManager(KeycloakSession session) {
        JpaConnectionProvider jpa = session.getProvider(JpaConnectionProvider.class);
        if (jpa == null) throw new IllegalStateException("Login code counter requires JPA");
        return jpa.getEntityManager();
    }

    private static void invalidate(KeycloakSession session, RealmModel realm, String userId) {
        UserCache cache = session.getProvider(UserCache.class);
        if (cache == null) return;
        UserModel user = session.users().getUserById(realm, userId);
        if (user != null) cache.evict(realm, user); // Cluster invalidation after completion; decisions remain SQL-only.
    }

    private static final class Locked implements Guard {
        private final KeycloakSession session;
        private final RealmModel realm;
        private final EntityManager em;
        private final UserEntity user;
        private String attributeId;
        private int count;

        Locked(KeycloakSession session, RealmModel realm, EntityManager em, UserEntity user, List<Object[]> rows) {
            this.session = session;
            this.realm = realm;
            this.em = em;
            this.user = user;
            this.attributeId = rows.isEmpty() ? null : (String) rows.getFirst()[0];
            this.count = countOf(rows);
        }

        @Override
        public boolean blocked() { return count >= LIMIT; }

        @Override
        public boolean wrongCode() {
            if (blocked()) return false;
            try {
                count++;
                if (attributeId == null) {
                    UserAttributeEntity attribute = new UserAttributeEntity();
                    attributeId = UUID.randomUUID().toString();
                    attribute.setId(attributeId);
                    attribute.setUser(user);
                    attribute.setName(ATTRIBUTE);
                    attribute.setValue(Integer.toString(count));
                    em.persist(attribute);
                    em.flush();
                } else {
                    int updated = em.createQuery("update UserAttributeEntity a set a.value = :value where a.id = :id and a.user.id = :user")
                            .setParameter("value", Integer.toString(count)).setParameter("id", attributeId)
                            .setParameter("user", user.getId()).setFlushMode(FlushModeType.COMMIT).executeUpdate();
                    if (updated != 1) throw new IllegalStateException("Login code counter changed outside its lock");
                }
                invalidate(session, realm, user.getId());
                return count == LIMIT;
            } catch (RuntimeException failed) {
                session.getTransactionManager().setRollbackOnly();
                throw new IllegalStateException("Login code counter could not be recorded", failed);
            }
        }
    }
}
