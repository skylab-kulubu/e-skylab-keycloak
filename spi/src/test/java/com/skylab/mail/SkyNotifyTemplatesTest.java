package com.skylab.mail;

import com.skylab.account.AccountErasureNotice;
import com.skylab.account.EmailCodeAuthenticator;
import com.skylab.account.EmailResource;
import org.junit.jupiter.api.Test;
import org.keycloak.events.EventType;

import static org.junit.jupiter.api.Assertions.assertEquals;

class SkyNotifyTemplatesTest {

    @Test
    void mapsEveryKeycloakBodyTemplateSkyNotifyTemplates() {
        assertEquals("keycloak.verify-email", SkyNotifyTemplates.forBodyTemplate("email-verification.ftl"));
        assertEquals("keycloak.reset-password", SkyNotifyTemplates.forBodyTemplate("password-reset.ftl"));
        assertEquals("keycloak.update-email",
                SkyNotifyTemplates.forBodyTemplate("email-update-confirmation.ftl"));
        assertEquals("keycloak.idp-link", SkyNotifyTemplates.forBodyTemplate("identity-provider-link.ftl"));
    }

    // K3c sends this mail through the generic overload under EmailResource.TEMPLATE. Naming the
    // file by hand here once drifted from the real name, and the mail fell through to the generic
    // template without its code; reading the constant keeps the two from drifting again.
    @Test
    void routesTheSkyAccountPersonalEmailCodeMailByTheNameItIsSentWith() {
        assertEquals("keycloak.personal-email-confirm", SkyNotifyTemplates.forBodyTemplate(EmailResource.TEMPLATE));
        assertEquals("keycloak.personal-email-confirm",
                SkyNotifyTemplates.forBodyTemplate("text/" + EmailResource.TEMPLATE));
        assertEquals("keycloak.personal-email-confirm",
                SkyNotifyTemplates.forBodyTemplate("html/" + EmailResource.TEMPLATE));
    }

    // eskylab-login-ux 08: the Login code goes through the generic overload under the name the
    // authenticator sends it with.
    @Test
    void routesTheLoginCodeMailByTheNameItIsSentWith() {
        assertEquals("keycloak.login-code", SkyNotifyTemplates.forBodyTemplate(EmailCodeAuthenticator.MAIL_TEMPLATE));
        assertEquals("keycloak.login-code",
                SkyNotifyTemplates.forBodyTemplate("html/" + EmailCodeAuthenticator.MAIL_TEMPLATE));
    }

    // The notice to a person whose Account erasure runs: SkyNotify's key named as its other account
    // deletion mails are (account.deletion-requested, account.deletion-completed).
    @Test
    void routesTheAccountErasureNoticeByTheNameItIsSentWith() {
        assertEquals("account.deletion-in-progress", SkyNotifyTemplates.forBodyTemplate(AccountErasureNotice.MAIL_TEMPLATE));
        assertEquals("account.deletion-in-progress",
                SkyNotifyTemplates.forBodyTemplate("text/" + AccountErasureNotice.MAIL_TEMPLATE));
    }

    @Test
    void namesTheTemplateThroughThemeDirectoriesSuffixAndCase() {
        assertEquals("keycloak.verify-email", SkyNotifyTemplates.forBodyTemplate("html/email-verification.ftl"));
        assertEquals("keycloak.verify-email", SkyNotifyTemplates.forBodyTemplate("text/email-verification.ftl"));
        assertEquals("keycloak.verify-email", SkyNotifyTemplates.forBodyTemplate("Email-Verification"));
        assertEquals("keycloak.verify-email", SkyNotifyTemplates.forBodyTemplate("  email-verification.ftl  "));
    }

    @Test
    void sendsAnythingElseAsTheGenericTemplate() {
        assertEquals("keycloak.generic", SkyNotifyTemplates.forBodyTemplate("executeActions.ftl"));
        assertEquals("keycloak.generic", SkyNotifyTemplates.forBodyTemplate("event-login_error.ftl"));
        assertEquals("keycloak.generic", SkyNotifyTemplates.forBodyTemplate(null));
        assertEquals("keycloak.generic", SkyNotifyTemplates.forBodyTemplate("  "));
    }

    @Test
    void reportsTheKeycloakSubjectKeyOfAnEventMail() {
        assertEquals("eventUpdatePasswordSubject", SkyNotifyTemplates.eventSubjectKey(EventType.UPDATE_PASSWORD));
        assertEquals("eventLoginErrorSubject", SkyNotifyTemplates.eventSubjectKey(EventType.LOGIN_ERROR));
    }
    @org.junit.jupiter.api.Test
    void sudoCodeUsesTheMaskedCodeTemplateWithItsOwnPurpose() {
        org.junit.jupiter.api.Assertions.assertEquals(SkyNotifyTemplates.LOGIN_CODE,
                SkyNotifyTemplates.forBodyTemplate(com.skylab.account.SudoResource.MAIL_TEMPLATE));
    }

}
