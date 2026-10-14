package com.skylab.mail;

import org.keycloak.email.EmailException;
import org.keycloak.email.EmailSenderProvider;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;

/**
 * A mail to an operator rather than to a person of the realm: no user, no Keycloak template.
 * SkyMail renders its system template; when SkyMail is off or refuses, Keycloak's own SMTP sends
 * the plain text given here instead (the same fallback as every other mail of this provider).
 *
 * <p>Keycloak's FreeMarker template provider needs a user to render a mail, and an operator
 * address is not one, so this goes to the realm's e-mail sender directly with the SkyMail message
 * recorded on the session, exactly as {@link SkyMailEmailTemplateProvider} records it.
 */
public final class SkyMailNotice {

    private SkyMailNotice() {
    }

    /**
     * The Login code's overall daily budget reached half or all of it (eskylab-login-ux 08):
     * SkyMail's {@value SkyMailTemplates#LOGIN_CODE_ALARM}, which tells the two apart by
     * {@code subjectKey}.
     */
    public static void sendLoginCodeAlarm(KeycloakSession session, RealmModel realm, String subjectKey,
            String recipient, String subject, String text) throws EmailException {
        session.setAttribute(SkyMailMessage.SESSION_ATTRIBUTE,
                SkyMailMessage.of(SkyMailTemplates.LOGIN_CODE_ALARM, subjectKey, "", "", null, realm));
        try {
            session.getProvider(EmailSenderProvider.class).send(realm.getSmtpConfig(), recipient, subject, text, null);
        } finally {
            // A sender that never took the message must not hand it to the next mail of the session.
            session.removeAttribute(SkyMailMessage.SESSION_ATTRIBUTE);
        }
    }
}
