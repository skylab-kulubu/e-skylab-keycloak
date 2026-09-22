package com.skylab.account;

import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.keycloak.common.util.Time;
import org.keycloak.connections.jpa.JpaConnectionProvider;
import org.keycloak.events.EventBuilder;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakTransactionManager;
import org.keycloak.models.ModelDuplicateException;
import org.keycloak.models.UserModel;

import java.time.Instant;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.RETURNS_SELF;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class IdentityResourceTest {

    @AfterEach
    void resetClock() {
        Time.setOffset(0);
    }

    @Test
    void primaryEmailIsWhicheverAddressKeycloakEmailMatches() {
        assertEquals("school", IdentityResource.primaryOf("Ada@std.yildiz.edu.tr", "ada@std.yildiz.edu.tr", "ada@example.com"));
        assertEquals("personal", IdentityResource.primaryOf("ada@example.com", "ada@std.yildiz.edu.tr", "ada@example.com"));
        assertEquals("none", IdentityResource.primaryOf("legacy@example.com", null, null));
        assertEquals("none", IdentityResource.primaryOf(null, "ada@std.yildiz.edu.tr", null));
    }

    @Test
    void usernameCooldownLastsFourteenDaysFromTheRecordedChange() {
        UserModel user = mock(UserModel.class);
        assertNull(IdentityResource.usernameChangeAvailableAt(user));

        long changedAt = Time.currentTime() - 24 * 60 * 60;
        when(user.getFirstAttribute(IdentityResource.USERNAME_CHANGED_AT_ATTRIBUTE))
                .thenReturn(Instant.ofEpochSecond(changedAt).toString());
        assertEquals(changedAt + IdentityResource.USERNAME_COOLDOWN_SECONDS,
                IdentityResource.usernameChangeAvailableAt(user));

        Time.setOffset(14 * 24 * 60 * 60);
        assertNull(IdentityResource.usernameChangeAvailableAt(user));
    }

    @Test
    void anUnreadableCooldownAttributeNeverBlocksThePerson() {
        UserModel user = mock(UserModel.class);
        when(user.getId()).thenReturn("user-a");
        when(user.getFirstAttribute(IdentityResource.USERNAME_CHANGED_AT_ATTRIBUTE)).thenReturn("yesterday");

        assertNull(IdentityResource.usernameChangeAvailableAt(user));
    }

    @Test
    void personNamesFollowKeycloaksProhibitedCharacterRule() {
        assertTrue(IdentityResource.isAllowedPersonName("Ayşe Nur"));
        assertTrue(IdentityResource.isAllowedPersonName("O'Brien-Çelik"));
        assertFalse(IdentityResource.isAllowedPersonName("<script>"));
        assertFalse(IdentityResource.isAllowedPersonName("Ada;Lovelace"));
        assertFalse(IdentityResource.isAllowedPersonName("Ada\tLovelace"));
    }

    @Test
    void personNamesMadeOfInvisibleCharactersNormaliseToNothing() {
        assertEquals("", IdentityResource.normalisePersonName("​‌‍﻿"));
        assertEquals("", IdentityResource.normalisePersonName("     "));
        assertEquals("", IdentityResource.normalisePersonName("   \t "));
        assertEquals("Ada Lovelace", IdentityResource.normalisePersonName(" Ada  Lovelace​ "));
        assertEquals("Ayşe Nur", IdentityResource.normalisePersonName("Ayşe Nur"));
    }

    @Test
    void usernamesAreLowercaseAsciiBetweenThreeAndThirtyCharacters() {
        assertTrue(IdentityResource.USERNAME.matcher("ada.lovelace_1").matches());
        assertFalse(IdentityResource.USERNAME.matcher("ab").matches());
        assertFalse(IdentityResource.USERNAME.matcher("Ada").matches());
        assertFalse(IdentityResource.USERNAME.matcher("ada@example.com").matches());
        assertFalse(IdentityResource.USERNAME.matcher("a".repeat(31)).matches());
    }

    @Test
    void aUsernameTakenBetweenCheckAndWriteBecomesA409AndRollsBack() {
        KeycloakSession session = mock(KeycloakSession.class);
        KeycloakTransactionManager transactions = mock(KeycloakTransactionManager.class);
        JpaConnectionProvider jpa = mock(JpaConnectionProvider.class);
        EntityManager entityManager = mock(EntityManager.class);
        UserModel user = mock(UserModel.class);
        EventBuilder event = mock(EventBuilder.class, RETURNS_SELF);
        when(session.getTransactionManager()).thenReturn(transactions);
        when(session.getProvider(JpaConnectionProvider.class)).thenReturn(jpa);
        when(jpa.getEntityManager()).thenReturn(entityManager);
        doThrow(new ModelDuplicateException("duplicate username")).when(entityManager).flush();

        ProblemException exception = assertThrows(ProblemException.class,
                () -> IdentityResource.applyUsername(session, user, "ada.lovelace", event));

        assertEquals(409, exception.problem().status());
        assertEquals("username_taken", exception.problem().code());
        verify(user).setUsername("ada.lovelace");
        verify(transactions).setRollbackOnly();
        verify(event).error("username_in_use");
    }

    @Test
    void aFreeUsernameIsWrittenAndFlushedWithinTheRequest() {
        KeycloakSession session = mock(KeycloakSession.class);
        KeycloakTransactionManager transactions = mock(KeycloakTransactionManager.class);
        JpaConnectionProvider jpa = mock(JpaConnectionProvider.class);
        EntityManager entityManager = mock(EntityManager.class);
        UserModel user = mock(UserModel.class);
        when(session.getTransactionManager()).thenReturn(transactions);
        when(session.getProvider(JpaConnectionProvider.class)).thenReturn(jpa);
        when(jpa.getEntityManager()).thenReturn(entityManager);

        IdentityResource.applyUsername(session, user, "ada.lovelace", null);

        verify(user).setUsername("ada.lovelace");
        verify(entityManager).flush();
        verify(transactions, never()).setRollbackOnly();
    }
}
