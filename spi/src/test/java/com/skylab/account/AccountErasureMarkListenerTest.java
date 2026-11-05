package com.skylab.account;

import jakarta.ws.rs.core.HttpHeaders;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.keycloak.events.admin.AdminEvent;
import org.keycloak.events.admin.OperationType;
import org.keycloak.events.admin.ResourceType;
import org.keycloak.http.HttpRequest;
import org.keycloak.models.KeycloakContext;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.RealmProvider;
import org.keycloak.models.UserModel;
import org.keycloak.models.UserProvider;

import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * The Account erasure mark: core's disable_identity PUT with the erasure header marks the person;
 * nothing else does, and an update that leaves the person enabled removes the mark.
 */
class AccountErasureMarkListenerTest {

    private static final String ID = "6f1c0d2e-1b2a-4c3d-8e4f-0a1b2c3d4e5f";

    private final KeycloakSession session = mock(KeycloakSession.class);
    private final RealmModel realm = mock(RealmModel.class);
    private final UserProvider users = mock(UserProvider.class);
    private final HttpHeaders headers = mock(HttpHeaders.class);
    private final UserModel user = mock(UserModel.class);
    private final Map<String, String> attributes = new HashMap<>();
    private final AccountErasureMarkListener listener = new AccountErasureMarkListener(session);
    private boolean enabled;

    @BeforeEach
    void setUp() {
        RealmProvider realms = mock(RealmProvider.class);
        when(session.realms()).thenReturn(realms);
        when(realms.getRealm("realm-id")).thenReturn(realm);
        when(session.users()).thenReturn(users);
        when(users.getUserById(eq(realm), eq(ID))).thenReturn(user);
        KeycloakContext context = mock(KeycloakContext.class);
        when(session.getContext()).thenReturn(context);
        HttpRequest request = mock(HttpRequest.class);
        when(context.getHttpRequest()).thenReturn(request);
        when(request.getHttpHeaders()).thenReturn(headers);
        when(user.getId()).thenReturn(ID);
        when(user.isEnabled()).thenAnswer(call -> enabled);
        when(user.getFirstAttribute(anyString())).thenAnswer(call -> attributes.get(call.<String>getArgument(0)));
        doAnswer(call -> attributes.put(call.getArgument(0), call.getArgument(1)))
                .when(user).setSingleAttribute(anyString(), anyString());
        doAnswer(call -> attributes.remove(call.<String>getArgument(0))).when(user).removeAttribute(anyString());
    }

    private static AdminEvent update(String path) {
        AdminEvent event = new AdminEvent();
        event.setRealmId("realm-id");
        event.setResourceType(ResourceType.USER);
        event.setOperationType(OperationType.UPDATE);
        event.setResourcePath(path);
        return event;
    }

    private void coreHeader() {
        when(headers.getHeaderString(AccountErasureMarkListener.HEADER)).thenReturn(AccountErasureMarkListener.HEADER_VALUE);
    }

    private String mark() {
        return attributes.get(AccountErasureMarkListener.ATTRIBUTE);
    }

    @Test
    void coresDisableWithTheErasureHeaderMarksThePerson() {
        coreHeader();

        listener.onEvent(update("users/" + ID), true);

        assertNotNull(mark());
        assertTrue(mark().matches("^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z$"), mark());
        assertTrue(AccountErasureMarkListener.erasureInProgress(user));
    }

    @Test
    void aDisableWithoutTheHeaderMarksNothing() {
        listener.onEvent(update("users/" + ID), true);

        assertNull(mark(), "an administrator's disable (Admin Console, kcadm) is not an erasure");
        assertFalse(AccountErasureMarkListener.erasureInProgress(user));
    }

    @Test
    void aHeaderWithAnotherValueMarksNothing() {
        when(headers.getHeaderString(AccountErasureMarkListener.HEADER)).thenReturn("1");

        listener.onEvent(update("users/" + ID), true);

        assertNull(mark());
    }

    @Test
    void theHeaderOnAnUpdateThatLeavesThePersonEnabledMarksNothing() {
        coreHeader();
        enabled = true;

        listener.onEvent(update("users/" + ID), true);

        assertNull(mark());
    }

    @Test
    void aRepeatedDisableKeepsTheTimeTheIdentityWasFirstClosed() {
        coreHeader();
        attributes.put(AccountErasureMarkListener.ATTRIBUTE, "2026-10-31T20:00:00Z");

        listener.onEvent(update("users/" + ID), true);

        assertEquals("2026-10-31T20:00:00Z", mark());
        verify(user, never()).setSingleAttribute(anyString(), anyString());
    }

    @Test
    void anUpdateThatEnablesThePersonAgainRemovesTheMark() {
        attributes.put(AccountErasureMarkListener.ATTRIBUTE, "2026-10-31T20:00:00Z");
        enabled = true;

        listener.onEvent(update("users/" + ID), true);

        assertNull(mark());
    }

    @Test
    void anotherDisabledPersonsUpdateLeavesTheMarkAlone() {
        attributes.put(AccountErasureMarkListener.ATTRIBUTE, "2026-10-31T20:00:00Z");

        listener.onEvent(update("users/" + ID), true);

        assertEquals("2026-10-31T20:00:00Z", mark(), "a whole-representation PUT by an administrator keeps it");
    }

    @Test
    void otherEventsAreNotLookedAt() {
        coreHeader();
        AdminEvent subResource = update("users/" + ID + "/groups/0a1b2c3d-1b2a-4c3d-8e4f-6f1c0d2e4e5f");
        AdminEvent action = update("users/" + ID);
        action.setOperationType(OperationType.ACTION);
        AdminEvent group = update("users/" + ID);
        group.setResourceType(ResourceType.GROUP_MEMBERSHIP);
        AdminEvent failed = update("users/" + ID);
        failed.setError("unknown_error");
        AdminEvent noPath = update(null);

        for (AdminEvent event : new AdminEvent[] {subResource, action, group, failed, noPath}) {
            listener.onEvent(event, true);
        }

        assertNull(mark());
        verify(users, never()).getUserById(eq(realm), anyString());
    }

    @Test
    void aMarkThatCannotBeWrittenNeverFailsTheDisable() {
        coreHeader();
        doThrow(new IllegalStateException("fixture")).when(user).setSingleAttribute(anyString(), anyString());

        assertDoesNotThrow(() -> listener.onEvent(update("users/" + ID), true));
    }

    @Test
    void aPersonOrRealmGoneByNowIsLeftAlone() {
        coreHeader();
        when(users.getUserById(eq(realm), eq(ID))).thenReturn(null);
        AdminEvent otherRealm = update("users/" + ID);
        otherRealm.setRealmId("gone");

        assertDoesNotThrow(() -> listener.onEvent(update("users/" + ID), true));
        assertDoesNotThrow(() -> listener.onEvent(otherRealm, true));
        assertNull(mark());
    }

    @Test
    void theListenerIsGlobalAndRegistered() throws IOException {
        AccountErasureMarkListenerFactory factory = new AccountErasureMarkListenerFactory();
        assertTrue(factory.isGlobal(), "no realm listener setting may switch the mark off");
        try (InputStream in = getClass().getResourceAsStream(
                "/META-INF/services/org.keycloak.events.EventListenerProviderFactory")) {
            assertNotNull(in);
            String services = new String(in.readAllBytes(), StandardCharsets.UTF_8);
            assertTrue(services.lines().anyMatch(AccountErasureMarkListenerFactory.class.getName()::equals), services);
        }
    }
}
