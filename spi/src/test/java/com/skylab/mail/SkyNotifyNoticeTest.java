package com.skylab.mail;

import org.junit.jupiter.api.Test;
import org.keycloak.email.EmailException;
import org.keycloak.email.EmailSenderProvider;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;

import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.atomic.AtomicReference;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.ArgumentMatchers.isNull;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class SkyNotifyNoticeTest {

    private final Map<String, Object> attributes = new HashMap<>();
    private final KeycloakSession session = SkyNotifyEmailTemplateProviderTest.sessionWithAttributes(attributes);
    private final EmailSenderProvider sender = mock(EmailSenderProvider.class);
    private final RealmModel realm = SkyNotifyMessageTest.realm("e-skylab", "SKY LAB");
    private final UserModel admin = SkyNotifyMessageTest.user("Ada", "Yönetici", "ada", "ops@example.org");

    // The sender takes the recorded message off the session while sending; it routes the alarm to
    // SkyNotify's template, or falls back to SMTP with the plain text handed over here.
    @Test
    void sendsTheLoginCodeAlarmAsSkyNotifysTemplateWithAPlainTextFallback() throws EmailException {
        when(session.getProvider(EmailSenderProvider.class)).thenReturn(sender);
        when(realm.getSmtpConfig()).thenReturn(Map.of("host", "smtp.example.invalid"));
        AtomicReference<SkyNotifyMessage> seen = new AtomicReference<>();
        doAnswer(call -> {
            seen.set((SkyNotifyMessage) attributes.get(SkyNotifyMessage.SESSION_ATTRIBUTE));
            return null;
        }).when(sender).send(any(), anyString(), anyString(), anyString(), isNull());

        SkyNotifyNotice.sendLoginCodeAlarm(session, realm, "skyLoginCodeAlarmHalfSubject",
                admin, "konu", "metin");

        verify(sender).send(eq(Map.of("host", "smtp.example.invalid")), eq("ops@example.org"), eq("konu"), eq("metin"), isNull());
        assertEquals(SkyNotifyTemplates.LOGIN_CODE_ALARM, seen.get().templateKey());
        assertEquals("skyLoginCodeAlarmHalfSubject", seen.get().variables().get(SkyNotifyMessage.SUBJECT_KEY));
        assertEquals("SKY LAB", seen.get().variables().get(SkyNotifyMessage.REALM_DISPLAY_NAME));
        assertEquals("Ada Yönetici", seen.get().recipientFullName());
        assertFalse(attributes.containsKey(SkyNotifyMessage.SESSION_ATTRIBUTE), "nothing is left for the next mail");
    }

    @Test
    void leavesNothingOnTheSessionWhenTheSenderFails() throws EmailException {
        when(session.getProvider(EmailSenderProvider.class)).thenReturn(sender);
        doThrow(new EmailException("down")).when(sender).send(any(), anyString(), anyString(), anyString(), isNull());

        assertThrows(EmailException.class, () -> SkyNotifyNotice.sendLoginCodeAlarm(session, realm,
                "skyLoginCodeAlarmFullSubject", admin, "konu", "metin"));
        assertFalse(attributes.containsKey(SkyNotifyMessage.SESSION_ATTRIBUTE));
    }
}
