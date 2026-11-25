package com.skylab.mail;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.keycloak.email.EmailException;
import org.keycloak.email.EmailSenderProvider;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.UserModel;

import java.net.URI;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.function.Supplier;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class SkyNotifyEmailSenderProviderTest {

    private static final Map<String, String> SMTP_CONFIG = Map.of("host", "smtp.yildizskylab.com");
    private static final String SUBJECT = "E-posta adresinizi doğrulayın";
    private static final String TEXT_BODY = "Doğrulamak için bağlantıya gidin.";
    private static final String HTML_BODY = "<p>Doğrulamak için bağlantıya gidin.</p>";

    private final Map<String, Object> attributes = new HashMap<>();
    private final RecordingSender smtp = new RecordingSender();

    private KeycloakSession session;
    private SkyNotifyClient client;
    private SkyNotifySettings enabled;

    @BeforeEach
    void setUp() {
        session = SkyNotifyEmailTemplateProviderTest.sessionWithAttributes(attributes);
        client = mock(SkyNotifyClient.class);
        enabled = new SkyNotifySettings(true, null,
                URI.create("https://api.yildizskylab.com/v1/mail_tasks/single"),
                URI.create("https://e.yildizskylab.com/realms/e-skylab/protocol/openid-connect/token"),
                "keycloak-mailer", SkyNotifySecret.ofLiteral("s3cr3t"),
                java.time.Duration.ofMillis(2_000), java.time.Duration.ofMillis(5_000));
    }

    private SkyNotifyEmailSenderProvider provider(SkyNotifySettings settings, SkyNotifyClient client) {
        return provider(settings, client, () -> URI.create("https://e.yildizskylab.com/realms/e-skylab"));
    }

    private SkyNotifyEmailSenderProvider provider(
            SkyNotifySettings settings, SkyNotifyClient client, Supplier<URI> realmIssuer) {
        return new SkyNotifyEmailSenderProvider(session, settings, client, () -> smtp, realmIssuer);
    }

    private SkyNotifyMessage record() {
        SkyNotifyMessage message = SkyNotifyMessage.of(
                SkyNotifyTemplates.VERIFY_EMAIL, SkyNotifyTemplates.VERIFY_EMAIL_SUBJECT_KEY,
                "https://e.yildizskylab.com/verify?key=abc", "60",
                SkyNotifyMessageTest.user("Ada", "Yıldız", "ada", "ada@yildizskylab.com"),
                SkyNotifyMessageTest.realm("e-skylab", "SKY LAB"));
        attributes.put(SkyNotifyMessage.SESSION_ATTRIBUTE, message);
        return message;
    }

    @Test
    void leavesSmtpAloneWhenSkyNotifyAcceptsTheMail() throws EmailException {
        SkyNotifyMessage message = record();
        when(client.send(any(), any(), any())).thenReturn(Optional.empty());

        provider(enabled, client).send(SMTP_CONFIG, "ada@yildizskylab.com", SUBJECT, TEXT_BODY, HTML_BODY);

        verify(client).send(eq(message), eq("ada@yildizskylab.com"), any());
        assertTrue(smtp.sent.isEmpty(), "an accepted mail must not be sent twice");
        assertNull(attributes.get(SkyNotifyMessage.SESSION_ATTRIBUTE));
    }

    @Test
    void fallsBackToKeycloaksOwnSenderWithTheStockRenderingWhenSkyNotifyFails() throws EmailException {
        record();
        when(client.send(any(), any(), any())).thenReturn(Optional.of(SkyNotifyFallback.UNAVAILABLE));

        provider(enabled, client).send(SMTP_CONFIG, "ada@yildizskylab.com", SUBJECT, TEXT_BODY, HTML_BODY);

        assertEquals(
                List.of(SMTP_CONFIG + "|ada@yildizskylab.com|" + SUBJECT + "|" + TEXT_BODY + "|" + HTML_BODY),
                smtp.sent);
    }

    @Test
    void fallsBackForEveryReasonSkyNotifyCanFailWith() throws EmailException {
        for (SkyNotifyFallback fallback : List.of(SkyNotifyFallback.TEMPLATE_MISSING,
                SkyNotifyFallback.UNAVAILABLE, SkyNotifyFallback.REFUSED, SkyNotifyFallback.TIMEOUT,
                SkyNotifyFallback.TRANSPORT, SkyNotifyFallback.TOKEN, SkyNotifyFallback.RESPONSE)) {
            smtp.sent.clear();
            record();
            when(client.send(any(), any(), any())).thenReturn(Optional.of(fallback));

            provider(enabled, client)
                    .send(SMTP_CONFIG, "ada@yildizskylab.com", SUBJECT, TEXT_BODY, HTML_BODY);

            assertEquals(1, smtp.sent.size(), fallback.reason() + " must still deliver the mail");
        }
    }

    @Test
    void fallsBackWithoutCallingSkyNotifyWhenTheProviderIsDisabled() throws EmailException {
        record();
        SkyNotifySettings disabled =
                SkyNotifySettings.disabled(SkyNotifySettings.REASON_SECRET_FILE_MISSING);

        provider(disabled, null).send(SMTP_CONFIG, "ada@yildizskylab.com", SUBJECT, TEXT_BODY, HTML_BODY);

        assertEquals(1, smtp.sent.size());
        verify(client, never()).send(any(), any(), any());
    }

    @Test
    void fallsBackWhenKeycloakSendsAMailThisProviderDoesNotTemplate() throws EmailException {
        provider(enabled, client).send(SMTP_CONFIG, "ops@yildizskylab.com", SUBJECT, TEXT_BODY, HTML_BODY);

        assertEquals(1, smtp.sent.size());
        verify(client, never()).send(any(), any(), any());
    }

    @Test
    void usesEachRecordedMailExactlyOnce() throws EmailException {
        record();
        when(client.send(any(), any(), any())).thenReturn(Optional.empty());
        SkyNotifyEmailSenderProvider provider = provider(enabled, client);

        provider.send(SMTP_CONFIG, "ada@yildizskylab.com", SUBJECT, TEXT_BODY, HTML_BODY);
        provider.send(SMTP_CONFIG, "ops@yildizskylab.com", SUBJECT, TEXT_BODY, HTML_BODY);

        verify(client).send(any(), eq("ada@yildizskylab.com"), any());
        assertEquals(1, smtp.sent.size(), "the second mail had no template and must use SMTP");
    }

    @Test
    void sendsToTheAddressKeycloakResolvedForThisMail() throws EmailException {
        record();
        when(client.send(any(), any(), any())).thenReturn(Optional.empty());
        UserModel user = SkyNotifyMessageTest.user("Ada", "Yıldız", "ada", "ada@yildizskylab.com");

        provider(enabled, client).send(SMTP_CONFIG, user, SUBJECT, TEXT_BODY, HTML_BODY);

        verify(client).send(any(), eq("ada@yildizskylab.com"), any());
    }

    @Test
    void fallsBackWhenTheRealmIssuerCannotBeResolvedAndNoTokenUrlIsPinned() throws EmailException {
        record();
        SkyNotifySettings derived = new SkyNotifySettings(true, null,
                URI.create("https://api.yildizskylab.com/v1/mail_tasks/single"), null,
                "keycloak-mailer", SkyNotifySecret.ofLiteral("s3cr3t"),
                java.time.Duration.ofMillis(2_000), java.time.Duration.ofMillis(5_000));

        provider(derived, client, () -> null)
                .send(SMTP_CONFIG, "ada@yildizskylab.com", SUBJECT, TEXT_BODY, HTML_BODY);

        assertEquals(1, smtp.sent.size());
        verify(client, never()).send(any(), any(), any());
    }

    @Test
    void derivesTheRealmIssuerKeycloakIsServing() {
        assertEquals(
                URI.create("https://e.yildizskylab.com/realms/e-skylab"),
                SkyNotifyEmailSenderProvider.realmIssuer(
                        URI.create("https://e.yildizskylab.com/"), "e-skylab"));
        assertEquals(
                URI.create("http://localhost:18080/realms/e-skylab-test"),
                SkyNotifyEmailSenderProvider.realmIssuer(
                        URI.create("http://localhost:18080"), "e-skylab-test"));
        assertNull(SkyNotifyEmailSenderProvider.realmIssuer(null, "e-skylab"));
        assertNull(SkyNotifyEmailSenderProvider.realmIssuer(URI.create("https://e.invalid/"), " "));
    }

    @Test
    void reportsWhenKeycloaksOwnSenderIsUnavailable() {
        SkyNotifyEmailSenderProvider provider = new SkyNotifyEmailSenderProvider(
                session, SkyNotifySettings.disabled(SkyNotifySettings.REASON_NOT_ENABLED), null,
                () -> null, () -> null);

        assertThrows(EmailException.class,
                () -> provider.send(SMTP_CONFIG, "ada@yildizskylab.com", SUBJECT, TEXT_BODY, HTML_BODY));
        assertThrows(EmailException.class, () -> provider.validate(SMTP_CONFIG));
    }

    @Test
    void leavesSmtpValidationToKeycloaksOwnSender() throws EmailException {
        provider(enabled, client).validate(SMTP_CONFIG);

        assertEquals(List.of(SMTP_CONFIG.toString()), smtp.validated);
    }

    static final class RecordingSender implements EmailSenderProvider {

        final List<String> sent = new ArrayList<>();
        final List<String> validated = new ArrayList<>();

        @Override
        public void send(Map<String, String> config, String address, String subject, String textBody,
                String htmlBody) {
            sent.add(config + "|" + address + "|" + subject + "|" + textBody + "|" + htmlBody);
        }

        @Override
        public void validate(Map<String, String> config) {
            validated.add(config.toString());
        }

        @Override
        public void close() {
        }
    }
}
