package com.skylab.mail;

import com.skylab.account.EmailResource;
import org.junit.jupiter.api.Test;
import org.keycloak.events.EventType;

import static org.junit.jupiter.api.Assertions.assertEquals;

class SkyMailTemplatesTest {

    @Test
    void mapsEveryKeycloakBodyTemplateSkyMailTemplates() {
        assertEquals("keycloak.verify-email", SkyMailTemplates.forBodyTemplate("email-verification.ftl"));
        assertEquals("keycloak.reset-password", SkyMailTemplates.forBodyTemplate("password-reset.ftl"));
        assertEquals("keycloak.update-email",
                SkyMailTemplates.forBodyTemplate("email-update-confirmation.ftl"));
        assertEquals("keycloak.idp-link", SkyMailTemplates.forBodyTemplate("identity-provider-link.ftl"));
    }

    // K3c sends this mail through the generic overload under EmailResource.TEMPLATE. Naming the
    // file by hand here once drifted from the real name, and the mail fell through to the generic
    // template without its code; reading the constant keeps the two from drifting again.
    @Test
    void routesTheSkyAccountPersonalEmailCodeMailByTheNameItIsSentWith() {
        assertEquals("keycloak.personal-email-confirm", SkyMailTemplates.forBodyTemplate(EmailResource.TEMPLATE));
        assertEquals("keycloak.personal-email-confirm",
                SkyMailTemplates.forBodyTemplate("text/" + EmailResource.TEMPLATE));
        assertEquals("keycloak.personal-email-confirm",
                SkyMailTemplates.forBodyTemplate("html/" + EmailResource.TEMPLATE));
    }

    @Test
    void namesTheTemplateThroughThemeDirectoriesSuffixAndCase() {
        assertEquals("keycloak.verify-email", SkyMailTemplates.forBodyTemplate("html/email-verification.ftl"));
        assertEquals("keycloak.verify-email", SkyMailTemplates.forBodyTemplate("text/email-verification.ftl"));
        assertEquals("keycloak.verify-email", SkyMailTemplates.forBodyTemplate("Email-Verification"));
        assertEquals("keycloak.verify-email", SkyMailTemplates.forBodyTemplate("  email-verification.ftl  "));
    }

    @Test
    void sendsAnythingElseAsTheGenericTemplate() {
        assertEquals("keycloak.generic", SkyMailTemplates.forBodyTemplate("executeActions.ftl"));
        assertEquals("keycloak.generic", SkyMailTemplates.forBodyTemplate("event-login_error.ftl"));
        assertEquals("keycloak.generic", SkyMailTemplates.forBodyTemplate(null));
        assertEquals("keycloak.generic", SkyMailTemplates.forBodyTemplate("  "));
    }

    @Test
    void reportsTheKeycloakSubjectKeyOfAnEventMail() {
        assertEquals("eventUpdatePasswordSubject", SkyMailTemplates.eventSubjectKey(EventType.UPDATE_PASSWORD));
        assertEquals("eventLoginErrorSubject", SkyMailTemplates.eventSubjectKey(EventType.LOGIN_ERROR));
    }
}
