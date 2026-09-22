package com.skylab.mail;

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
        assertEquals("keycloak.personal-email-confirm",
                SkyMailTemplates.forBodyTemplate("personal-email-confirm.ftl"));
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
