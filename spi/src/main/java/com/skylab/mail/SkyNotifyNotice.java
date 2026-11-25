package com.skylab.mail;

import org.keycloak.email.EmailException;
import org.keycloak.email.EmailSenderProvider;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;

/**
 * A mail to an operator: no Keycloak template.
 * SkyNotify renders its system template; when SkyNotify is off or refuses, Keycloak's own SMTP sends
 * the plain text given here instead (the same fallback as every other mail of this provider).
 *
 * <p>The operator notice has no FreeMarker template of its own (its text is built in code), so it
 * goes to the realm's e-mail sender directly with the SkyNotify message recorded on the session,
 * exactly as {@link SkyNotifyEmailTemplateProvider} records it.
 */
public final class SkyNotifyNotice {

    private SkyNotifyNotice() {
    }

    /**
     * The Login code's overall daily budget reached half or all of it (eskylab-login-ux 08):
     * SkyNotify's {@value SkyNotifyTemplates#LOGIN_CODE_ALARM}, which tells the two apart by
     * {@code subjectKey}.
     */
    public static void sendLoginCodeAlarm(KeycloakSession session, RealmModel realm, String subjectKey,
            UserModel recipient, String subject, String text) throws EmailException {
        session.setAttribute(SkyNotifyMessage.SESSION_ATTRIBUTE,
                SkyNotifyMessage.of(SkyNotifyTemplates.LOGIN_CODE_ALARM, subjectKey, "", "", recipient, realm));
        try {
            session.getProvider(EmailSenderProvider.class)
                    .send(realm.getSmtpConfig(), recipient.getEmail(), subject, text, null);
        } finally {
            // A sender that never took the message must not hand it to the next mail of the session.
            session.removeAttribute(SkyNotifyMessage.SESSION_ATTRIBUTE);
        }
    }
}
