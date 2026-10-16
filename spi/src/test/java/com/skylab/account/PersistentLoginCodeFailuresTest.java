package com.skylab.account;

import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import jakarta.persistence.Query;
import jakarta.persistence.TypedQuery;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.keycloak.connections.jpa.JpaConnectionProvider;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakTransactionManager;
import org.keycloak.models.RealmModel;
import org.keycloak.models.jpa.entities.UserEntity;
import org.hibernate.Session;

import java.sql.Connection;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class PersistentLoginCodeFailuresTest {
    final KeycloakSession session = mock(KeycloakSession.class);
    final RealmModel realm = mock(RealmModel.class);
    final EntityManager em = mock(EntityManager.class);
    final KeycloakTransactionManager tx = mock(KeycloakTransactionManager.class);
    final TypedQuery<UserEntity> lock = mock(TypedQuery.class, RETURNS_SELF);
    final TypedQuery<Object[]> read = mock(TypedQuery.class, RETURNS_SELF);
    final Session hibernate = mock(Session.class);
    final Query update = mock(Query.class, RETURNS_SELF);
    final UserEntity user = new UserEntity();
    final PersistentLoginCodeFailures counter = new PersistentLoginCodeFailures();

    @BeforeEach
    void setUp() {
        JpaConnectionProvider jpa = mock(JpaConnectionProvider.class);
        when(session.getProvider(JpaConnectionProvider.class)).thenReturn(jpa);
        when(jpa.getEntityManager()).thenReturn(em);
        when(session.getTransactionManager()).thenReturn(tx);
        when(realm.getId()).thenReturn("realm-a");
        user.setId("user-a");
        when(em.createQuery(PersistentLoginCodeFailures.LOCK_QUERY, UserEntity.class)).thenReturn(lock);
        when(lock.getResultList()).thenReturn(List.of(user));
        when(em.createQuery(PersistentLoginCodeFailures.READ_QUERY, Object[].class)).thenReturn(read);
        when(read.getResultList()).thenReturn(List.<Object[]>of(new Object[]{"attribute-a", "99"}));
        when(em.unwrap(Session.class)).thenReturn(hibernate);
        when(hibernate.doReturningWork(any())).thenReturn(Connection.TRANSACTION_READ_COMMITTED);
        when(em.createQuery(startsWith("update UserAttributeEntity"))).thenReturn(update);
        when(update.executeUpdate()).thenReturn(1);
    }

    @Test
    void aFreshScalarReadAfterTheUserLockCounts99To100Once() {
        LoginCodeFailureCounter.Guard guard = counter.lock(session, realm, "user-a");
        assertFalse(guard.blocked());
        assertTrue(guard.wrongCode());
        assertTrue(guard.blocked());
        assertFalse(guard.wrongCode());
        var order = inOrder(lock, read, update);
        order.verify(lock).getResultList();
        order.verify(read).getResultList();
        order.verify(update).executeUpdate();
        verify(lock).setLockMode(LockModeType.PESSIMISTIC_WRITE);
        verify(lock).setParameter("realm", "realm-a");
        verify(lock).setParameter("user", "user-a");
        verify(update).setParameter("value", "100");
        verify(update, times(1)).executeUpdate();
        verify(session, never()).users();
    }

    @Test
    void missingLocalUsersDoNotAcquireAnAttributeOrCounter() {
        when(lock.getResultList()).thenReturn(List.of());
        assertNull(counter.lock(session, realm, "missing"));
        verify(read, never()).getResultList();
        verify(em, never()).persist(any());
    }

    @Test
    void corruptedDuplicatedOrOutOfRangeStoredCountersFailClosed() {
        assertEquals(0, PersistentLoginCodeFailures.countOf(List.of()));
        assertEquals(99, PersistentLoginCodeFailures.countOf(List.<Object[]>of(new Object[]{"a", "99"})));
        for (String value : new String[]{"100", "999", "1000", "-1", "", "broken"}) {
            assertEquals(100, PersistentLoginCodeFailures.countOf(List.<Object[]>of(new Object[]{"a", value})));
        }
        assertEquals(100, PersistentLoginCodeFailures.countOf(List.<Object[]>of(new Object[]{"a", null})));
        assertEquals(100, PersistentLoginCodeFailures.countOf(List.of(new Object[]{"a", "1"}, new Object[]{"b", "2"})));
    }

    @Test
    void aSnapshotIsolationSettingCannotSilentlyReuseAnOldCounter() {
        when(hibernate.doReturningWork(any())).thenReturn(Connection.TRANSACTION_REPEATABLE_READ);
        assertThrows(IllegalStateException.class, () -> counter.lock(session, realm, "user-a"));
        verify(tx).setRollbackOnly();
    }

    @Test
    void failedCounterWritesMarkTheWholeRequestForRollback() {
        when(update.executeUpdate()).thenThrow(new IllegalStateException("fixture"));
        var guard = counter.lock(session, realm, "user-a");
        assertThrows(IllegalStateException.class, guard::wrongCode);
        verify(tx).setRollbackOnly();
    }
}
