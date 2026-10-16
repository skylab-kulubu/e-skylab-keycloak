package com.skylab.account;

import jakarta.ws.rs.core.UriInfo;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.keycloak.authentication.AuthenticationFlowContext;
import org.keycloak.executors.ExecutorsProvider;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;
import org.keycloak.models.KeycloakTransaction;
import org.keycloak.models.KeycloakTransactionManager;
import org.keycloak.models.RealmModel;

import java.net.URI;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.atomic.AtomicReference;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class BackgroundConsecutiveAlarmTest {
    final AuthenticationFlowContext context = mock(AuthenticationFlowContext.class);
    final KeycloakSession session = mock(KeycloakSession.class);
    final KeycloakTransactionManager manager = mock(KeycloakTransactionManager.class);
    final ExecutorsProvider executors = mock(ExecutorsProvider.class);
    final List<Runnable> queue = new ArrayList<>();
    final ExecutorService executor = mock(ExecutorService.class);
    final AtomicReference<KeycloakTransaction> after = new AtomicReference<>();
    final BackgroundLoginCodeMail mail = new BackgroundLoginCodeMail(new EmailCodeSettings("OBS", 500, "/ADMIN", 10));

    @BeforeEach
    void setUp() {
        when(context.getSession()).thenReturn(session);
        RealmModel realm = mock(RealmModel.class);
        when(context.getRealm()).thenReturn(realm);
        when(realm.getId()).thenReturn("realm-a");
        when(realm.getName()).thenReturn("fixture");
        UriInfo uri = mock(UriInfo.class);
        when(uri.getBaseUri()).thenReturn(URI.create("https://auth.example.invalid/"));
        when(context.getUriInfo()).thenReturn(uri);
        when(session.getKeycloakSessionFactory()).thenReturn(mock(KeycloakSessionFactory.class));
        when(session.getProvider(ExecutorsProvider.class)).thenReturn(executors);
        when(executors.getExecutor(BackgroundLoginCodeMail.EXECUTOR)).thenReturn(executor);
        doAnswer(call -> { queue.add(call.getArgument(0)); return null; }).when(executor).execute(any());
        when(session.getTransactionManager()).thenReturn(manager);
        doAnswer(call -> { after.set(call.getArgument(0)); after.get().begin(); return null; })
                .when(manager).enlistAfterCompletion(any());
    }

    @Test
    void commitQueuesTheImmutableNoticeWithoutReadingTheClosedRequest() {
        mail.consecutiveAlarm(context, 100);
        assertTrue(queue.isEmpty());
        clearInvocations(context, session);
        after.get().commit();
        assertEquals(1, queue.size());
        assertDoesNotThrow(queue.getFirst()::run); // A missing background session is safely logged.
        verifyNoInteractions(context, session);
    }

    @Test
    void rollbackNeverQueuesAnAlarm() {
        mail.consecutiveAlarm(context, 100);
        after.get().rollback();
        assertTrue(queue.isEmpty());
    }

    @Test
    void aRejectedExecutorCannotFailAnAlreadyCommittedLoginRequest() {
        doThrow(new RejectedExecutionException("fixture")).when(executor).execute(any());
        mail.consecutiveAlarm(context, 100);
        assertDoesNotThrow(() -> after.get().commit());
    }

    @Test
    void theConsecutiveNoticeDoesNotDescribeADailyCeilingOrCarryAPerson() {
        String text = BackgroundLoginCodeMail.consecutiveText("fixture", 100);
        assertTrue(text.contains("100 ardışık"));
        assertTrue(text.contains("Gün dönümü veya yeniden başlatma sınırı kaldırmaz"));
        assertFalse(text.contains("@"));
        assertFalse(text.contains("günlük"));
        assertEquals("skyLoginCodeAlarmConsecutiveSubject", BackgroundLoginCodeMail.ALARM_CONSECUTIVE_SUBJECT_KEY);
    }
}
