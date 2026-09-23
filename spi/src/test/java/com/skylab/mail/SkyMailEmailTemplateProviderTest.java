package com.skylab.mail;

import com.skylab.account.EmailResource;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.keycloak.email.EmailException;
import org.keycloak.events.Event;
import org.keycloak.events.EventType;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;

import java.util.HashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class SkyMailEmailTemplateProviderTest {

    private final Map<String, Object> attributes = new HashMap<>();
    private final FakeEmailTemplateProvider delegate = new FakeEmailTemplateProvider();
    private final UserModel user =
            SkyMailMessageTest.user("Ada", "Yıldız", "ada", "ada@yildizskylab.com");
    private final RealmModel realm = SkyMailMessageTest.realm("e-skylab", "SKY LAB");

    private KeycloakSession session;
    private SkyMailEmailTemplateProvider provider;

    static KeycloakSession sessionWithAttributes(Map<String, Object> attributes) {
        KeycloakSession session = mock(KeycloakSession.class);
        when(session.getAttribute(anyString()))
                .thenAnswer(invocation -> attributes.get(invocation.<String>getArgument(0)));
        when(session.removeAttribute(anyString()))
                .thenAnswer(invocation -> attributes.remove(invocation.<String>getArgument(0)));
        doAnswer(invocation -> attributes.put(invocation.getArgument(0), invocation.getArgument(1)))
                .when(session).setAttribute(anyString(), any());
        return session;
    }

    @BeforeEach
    void setUp() {
        session = sessionWithAttributes(attributes);
        provider = new SkyMailEmailTemplateProvider(session, delegate);
        provider.setRealm(realm).setUser(user);
    }

    private SkyMailMessage recorded() {
        Object pending = attributes.get(SkyMailMessage.SESSION_ATTRIBUTE);
        assertNotNull(pending, "the template provider must record the mail on the session");
        return (SkyMailMessage) pending;
    }

    @Test
    void keepsTheDecoratorInTheChainAndDelegatesTheRendering() throws EmailException {
        assertSame(provider, provider.setRealm(realm));
        assertSame(provider, provider.setUser(user));
        assertSame(provider, provider.setAttribute("realmName", "SKY LAB"));
        assertSame(provider, provider.setAuthenticationSession(null));
        assertSame(realm, delegate.realm);
        assertSame(user, delegate.user);

        provider.sendVerifyEmail("https://e.yildizskylab.com/verify?key=abc", 60);
        provider.close();

        assertTrue(delegate.calls.contains("sendVerifyEmail:https://e.yildizskylab.com/verify?key=abc:60"));
        assertTrue(delegate.closed);
    }

    @Test
    void mapsTheVerifyEmailMail() throws EmailException {
        provider.sendVerifyEmail("https://e.yildizskylab.com/verify?key=abc", 60);

        SkyMailMessage message = recorded();
        assertEquals(SkyMailTemplates.VERIFY_EMAIL, message.templateKey());
        assertEquals("emailVerificationSubject", message.variables().get(SkyMailMessage.SUBJECT_KEY));
        assertEquals("https://e.yildizskylab.com/verify?key=abc",
                message.variables().get(SkyMailMessage.LINK));
        assertEquals("60", message.variables().get(SkyMailMessage.LINK_EXPIRATION_MINUTES));
        assertEquals("Ada Yıldız", message.recipientFullName());
    }

    @Test
    void mapsThePasswordResetMail() throws EmailException {
        provider.sendPasswordReset("https://e.yildizskylab.com/reset?key=abc", 30);

        assertEquals(SkyMailTemplates.RESET_PASSWORD, recorded().templateKey());
        assertEquals("passwordResetSubject", recorded().variables().get(SkyMailMessage.SUBJECT_KEY));
    }

    @Test
    void mapsTheEmailUpdateConfirmationMail() throws EmailException {
        provider.sendEmailUpdateConfirmation("https://e.yildizskylab.com/update?key=abc", 15,
                "new@yildizskylab.com");

        assertEquals(SkyMailTemplates.UPDATE_EMAIL, recorded().templateKey());
        assertEquals("emailUpdateConfirmationSubject",
                recorded().variables().get(SkyMailMessage.SUBJECT_KEY));
        assertTrue(delegate.calls.contains(
                "sendEmailUpdateConfirmation:https://e.yildizskylab.com/update?key=abc:15:new@yildizskylab.com"));
    }

    @Test
    void mapsTheIdentityProviderLinkMail() throws EmailException {
        provider.sendConfirmIdentityBrokerLink("https://e.yildizskylab.com/link?key=abc", 20);

        assertEquals(SkyMailTemplates.IDP_LINK, recorded().templateKey());
        assertEquals("identityProviderLinkSubject",
                recorded().variables().get(SkyMailMessage.SUBJECT_KEY));
    }

    @Test
    void carriesTheCodeOfTheSkyAccountPersonalEmailMail() throws EmailException {
        // Exactly what EmailResource hands Keycloak's template provider.
        Map<String, Object> bodyAttributes = new HashMap<>();
        bodyAttributes.put("code", "048213");
        bodyAttributes.put("codeExpiration", 10);
        bodyAttributes.put("newEmail", "kisisel@example.com");

        provider.send("skyPersonalEmailConfirmSubject", List.of(), EmailResource.TEMPLATE,
                bodyAttributes, "kisisel@example.com");

        SkyMailMessage message = recorded();
        assertEquals(SkyMailTemplates.PERSONAL_EMAIL_CONFIRM, message.templateKey());
        assertEquals("048213", message.variables().get(SkyMailMessage.CODE));
        assertEquals("10", message.variables().get(SkyMailMessage.CODE_EXPIRATION_MINUTES));
        assertEquals("", message.variables().get(SkyMailMessage.LINK), "the code mail carries no link");
        assertEquals("skyPersonalEmailConfirmSubject", message.variables().get(SkyMailMessage.SUBJECT_KEY));
    }

    @Test
    void fallsBackToTheGenericTemplateCarryingTheKeycloakSubjectKey() throws EmailException {
        provider.sendExecuteActions("https://e.yildizskylab.com/actions?key=abc", 10);
        assertEquals(SkyMailTemplates.GENERIC, recorded().templateKey());
        assertEquals("executeActionsSubject", recorded().variables().get(SkyMailMessage.SUBJECT_KEY));

        provider.send("orgInviteSubject", "org-invite.ftl", Map.of());
        assertEquals(SkyMailTemplates.GENERIC, recorded().templateKey());
        assertEquals("orgInviteSubject", recorded().variables().get(SkyMailMessage.SUBJECT_KEY));
        assertEquals("", recorded().variables().get(SkyMailMessage.LINK));

        Event event = new Event();
        event.setType(EventType.UPDATE_PASSWORD);
        provider.sendEvent(event);
        assertEquals(SkyMailTemplates.GENERIC, recorded().templateKey());
        assertEquals("eventUpdatePasswordSubject", recorded().variables().get(SkyMailMessage.SUBJECT_KEY));
    }

    @Test
    void leavesTheSmtpTestMailToKeycloaksOwnSender() throws EmailException {
        provider.sendVerifyEmail("https://e.yildizskylab.com/verify?key=abc", 60);
        assertNotNull(attributes.get(SkyMailMessage.SESSION_ATTRIBUTE));

        provider.sendSmtpTestEmail(Map.of("host", "smtp.invalid"), user);

        assertNull(attributes.get(SkyMailMessage.SESSION_ATTRIBUTE),
                "the SMTP test mail must prove the realm's own SMTP settings");
        assertTrue(delegate.calls.contains("sendSmtpTestEmail"));
    }
}
