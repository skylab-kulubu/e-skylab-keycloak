package com.skylab.account;

import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import jakarta.persistence.LockTimeoutException;
import jakarta.persistence.TypedQuery;
import org.junit.jupiter.api.Test;
import org.keycloak.connections.jpa.JpaConnectionProvider;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakTransactionManager;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;
import org.keycloak.models.UserProvider;
import org.keycloak.models.jpa.entities.RealmEntity;

import java.util.List;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.anyMap;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.RETURNS_SELF;
import static org.mockito.Mockito.inOrder;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.when;

class EmailAddressOwnershipTest {

    /** The offer's existing unit fixture uses a free DB; the runtime harness proves real transactions. */
    static EntityManager mockDatabase(KeycloakSession session, RealmModel realm) {
        JpaConnectionProvider jpa = mock(JpaConnectionProvider.class);
        EntityManager em = mock(EntityManager.class);
        when(session.getProvider(JpaConnectionProvider.class)).thenReturn(jpa);
        when(jpa.getEntityManager()).thenReturn(em);
        String realmId = realm.getId();
        when(em.find(eq(RealmEntity.class), eq(realmId), eq(LockModeType.PESSIMISTIC_WRITE), anyMap()))
                .thenReturn(new RealmEntity());
        @SuppressWarnings("unchecked")
        TypedQuery<String> query = mock(TypedQuery.class, RETURNS_SELF);
        when(em.createQuery(anyString(), eq(String.class))).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of());
        return em;
    }

    @Test
    void theDatabaseLockPrecedesTheFreshScalarQueryAndProviderCheck() {
        KeycloakSession session = mock(KeycloakSession.class);
        RealmModel realm = mock(RealmModel.class);
        when(realm.getId()).thenReturn("realm-id");
        UserProvider users = mock(UserProvider.class);
        when(session.users()).thenReturn(users);
        EntityManager em = mockDatabase(session, realm);

        assertFalse(EmailAddressOwnership.isTakenAfterLock(session, realm, null, "Private@Example.COM"));

        var order = inOrder(em, users);
        order.verify(em).find(eq(RealmEntity.class), eq("realm-id"), eq(LockModeType.PESSIMISTIC_WRITE), anyMap());
        order.verify(em).createQuery(EmailAddressOwnership.OWNERS_QUERY, String.class);
        order.verify(users).getUserByEmail(realm, "private@example.com");
        TypedQuery<String> query = em.createQuery(EmailAddressOwnership.OWNERS_QUERY, String.class);
        verify(query).setParameter("address", "private@example.com");
        verify(query).setParameter("exclude", "");
        verify(query).setMaxResults(1);
    }

    @Test
    void aFreshDatabaseHolderWinsOverStaleNegativeProviderLookups() {
        KeycloakSession session = mock(KeycloakSession.class);
        RealmModel realm = mock(RealmModel.class);
        when(realm.getId()).thenReturn("realm-id");
        EntityManager em = mockDatabase(session, realm);
        when(em.createQuery(EmailAddressOwnership.OWNERS_QUERY, String.class).getResultList()).thenReturn(List.of("new-holder"));
        UserModel own = mock(UserModel.class);
        when(own.getId()).thenReturn("own-id");

        assertTrue(EmailAddressOwnership.isTakenAfterLock(session, realm, own, "private@example.com"));
        verify(em.createQuery(EmailAddressOwnership.OWNERS_QUERY, String.class)).setParameter("exclude", "own-id");
    }

    @Test
    void everyCallLocksEvenWhenTheSessionIsReusedForAnotherTransaction() {
        KeycloakSession session = mock(KeycloakSession.class);
        RealmModel realm = mock(RealmModel.class);
        when(realm.getId()).thenReturn("realm-id");
        when(session.users()).thenReturn(mock(UserProvider.class));
        EntityManager em = mockDatabase(session, realm);

        assertFalse(EmailAddressOwnership.isTakenAfterLock(session, realm, null, "first@example.com"));
        assertFalse(EmailAddressOwnership.isTakenAfterLock(session, realm, null, "second@example.com"));

        verify(em, times(2)).find(eq(RealmEntity.class), eq("realm-id"), eq(LockModeType.PESSIMISTIC_WRITE), anyMap());
    }

    @Test
    void missingJpaAndLockTimeoutFailClosedAndMarkRollback() {
        KeycloakSession session = mock(KeycloakSession.class);
        RealmModel realm = mock(RealmModel.class);
        when(realm.getId()).thenReturn("realm-id");
        KeycloakTransactionManager transaction = mock(KeycloakTransactionManager.class);
        when(session.getTransactionManager()).thenReturn(transaction);
        assertThrows(IllegalStateException.class,
                () -> EmailAddressOwnership.isTakenAfterLock(session, realm, null, "private@example.com"));
        verify(transaction).setRollbackOnly();

        KeycloakSession timedOut = mock(KeycloakSession.class);
        when(timedOut.getTransactionManager()).thenReturn(mock(KeycloakTransactionManager.class));
        EntityManager em = mockDatabase(timedOut, realm);
        when(em.find(eq(RealmEntity.class), eq("realm-id"), eq(LockModeType.PESSIMISTIC_WRITE), anyMap()))
                .thenThrow(new LockTimeoutException());
        assertThrows(IllegalStateException.class,
                () -> EmailAddressOwnership.isTakenAfterLock(timedOut, realm, null, "private@example.com"));
        verify(timedOut.getTransactionManager()).setRollbackOnly();
    }
}
