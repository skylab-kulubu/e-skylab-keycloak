package com.skylab.account;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.keycloak.events.Event;
import org.keycloak.events.EventType;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakTransaction;
import org.keycloak.models.KeycloakTransactionManager;
import org.keycloak.models.RealmModel;
import org.keycloak.models.RealmProvider;

import java.util.concurrent.atomic.AtomicReference;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class LoginCodeFailuresListenerTest {
    final KeycloakSession session = mock(KeycloakSession.class);
    final KeycloakTransactionManager tx = mock(KeycloakTransactionManager.class);
    final LoginCodeFailureCounter counter = mock(LoginCodeFailureCounter.class);
    final RealmModel realm = mock(RealmModel.class);
    final AtomicReference<KeycloakTransaction> prepare = new AtomicReference<>();
    LoginCodeFailuresListener listener;

    @BeforeEach
    void setUp() {
        when(session.getTransactionManager()).thenReturn(tx);
        org.keycloak.models.KeycloakContext context = mock(org.keycloak.models.KeycloakContext.class);
        when(session.getContext()).thenReturn(context);
        when(context.getRealm()).thenReturn(realm);
        when(realm.getId()).thenReturn("realm-a");
        doAnswer(call -> { prepare.set(call.getArgument(0)); prepare.get().begin(); return null; })
                .when(tx).enlistPrepare(any());
        listener = new LoginCodeFailuresListener(session, counter);
    }

    private Event event(EventType type) {
        Event event = new Event();
        event.setType(type);
        event.setRealmId("realm-a");
        event.setUserId("user-a");
        return event;
    }

    @Test
    void onlyACompletedLoginResetsAtPrepareAndTheHookIsGlobal() {
        listener.onEvent(event(EventType.LOGIN));
        listener.onEvent(event(EventType.LOGIN));
        verify(counter).prepare(session);
        verify(counter, never()).reset(any(), any(), any());
        prepare.get().commit();
        verify(counter, times(1)).reset(session, realm, "user-a");
        assertTrue(new LoginCodeFailuresListenerFactory().isGlobal());
    }

    @Test
    void errorsRefreshesAndPartialProofEventsDoNotReset() {
        for (EventType type : new EventType[]{EventType.LOGIN_ERROR, EventType.REFRESH_TOKEN, EventType.REGISTER,
                EventType.CODE_TO_TOKEN, EventType.IDENTITY_PROVIDER_LINK_ACCOUNT}) listener.onEvent(event(type));
        Event failed = event(EventType.LOGIN);
        failed.setError("fixture");
        listener.onEvent(failed);
        prepare.get().commit();
        verify(counter, never()).reset(any(), any(), any());
    }

    @Test
    void rollbackDoesNotResetAndResetErrorsEscapeOutsideTheEventCallback() {
        listener.onEvent(event(EventType.LOGIN));
        doThrow(new IllegalStateException("fixture")).when(counter).reset(session, realm, "user-a");
        assertThrows(IllegalStateException.class, () -> prepare.get().commit());
    }

    @Test
    void eventCallbacksReadNoRequestOrProviderStateAfterConstruction() {
        clearInvocations(session, counter, realm);
        listener.onEvent(event(EventType.LOGIN));
        verifyNoInteractions(session, counter, realm);
    }
}
