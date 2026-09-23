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

class SkyMailEmailSenderProviderTest {

    private static final Map<String, String> SMTP_CONFIG = Map.of("host", "smtp.yildizskylab.com");
    private static final String SUBJECT = "E-posta adresinizi doğrulayın";
    private static final String TEXT_BODY = "Doğrulamak için bağlantıya gidin.";
    private static final String HTML_BODY = "<p>Doğrulamak için bağlantıya gidin.</p>";

    private final Map<String, Object> attributes = new HashMap<>();
    private final RecordingSender smtp = new RecordingSender();

    private KeycloakSession session;
    private SkyMailClient client;
    private SkyMailSettings enabled;

    @BeforeEach
    void setUp() {
        session = SkyMailEmailTemplateProviderTest.sessionWithAttributes(attributes);
        client = mock(SkyMailClient.class);
        enabled = new SkyMailSettings(true, null,
                URI.create("https://mail.yildizskylab.com/v1/mail_tasks/single"),
                URI.create("https://e.yildizskylab.com/realms/e-skylab/protocol/openid-connect/token"),
                "keycloak-mailer", SkyMailSecret.ofLiteral("s3cr3t"),
                java.time.Duration.ofMillis(2_000), java.time.Duration.ofMillis(5_000));
    }

    private SkyMailEmailSenderProvider provider(SkyMailSettings settings, SkyMailClient client) {
        return provider(settings, client, () -> URI.create("https://e.yildizskylab.com/realms/e-skylab"));
    }

    private SkyMailEmailSenderProvider provider(
            SkyMailSettings settings, SkyMailClient client, Supplier<URI> realmIssuer) {
        return new SkyMailEmailSenderProvider(session, settings, client, () -> smtp, realmIssuer);
    }

    private SkyMailMessage record() {
        SkyMailMessage message = SkyMailMessage.of(
                SkyMailTemplates.VERIFY_EMAIL, SkyMailTemplates.VERIFY_EMAIL_SUBJECT_KEY,
                "https://e.yildizskylab.com/verify?key=abc", "60",
                SkyMailMessageTest.user("Ada", "Yıldız", "ada", "ada@yildizskylab.com"),
                SkyMailMessageTest.realm("e-skylab", "SKY LAB"));
        attributes.put(SkyMailMessage.SESSION_ATTRIBUTE, message);
        return message;
    }

    @Test
    void leavesSmtpAloneWhenSkyMailAcceptsTheMail() throws EmailException {
        SkyMailMessage message = record();
        when(client.send(any(), any(), any())).thenReturn(Optional.empty());

        provider(enabled, client).send(SMTP_CONFIG, "ada@yildizskylab.com", SUBJECT, TEXT_BODY, HTML_BODY);

        verify(client).send(eq(message), eq("ada@yildizskylab.com"), any());
        assertTrue(smtp.sent.isEmpty(), "an accepted mail must not be sent twice");
        assertNull(attributes.get(SkyMailMessage.SESSION_ATTRIBUTE));
    }

    @Test
    void fallsBackToKeycloaksOwnSenderWithTheStockRenderingWhenSkyMailFails() throws EmailException {
        record();
        when(client.send(any(), any(), any())).thenReturn(Optional.of(SkyMailFallback.UNAVAILABLE));

        provider(enabled, client).send(SMTP_CONFIG, "ada@yildizskylab.com", SUBJECT, TEXT_BODY, HTML_BODY);

        assertEquals(
                List.of(SMTP_CONFIG + "|ada@yildizskylab.com|" + SUBJECT + "|" + TEXT_BODY + "|" + HTML_BODY),
                smtp.sent);
    }

    @Test
    void fallsBackForEveryReasonSkyMailCanFailWith() throws EmailException {
        for (SkyMailFallback fallback : List.of(SkyMailFallback.TEMPLATE_MISSING,
                SkyMailFallback.UNAVAILABLE, SkyMailFallback.REFUSED, SkyMailFallback.TIMEOUT,
                SkyMailFallback.TRANSPORT, SkyMailFallback.TOKEN, SkyMailFallback.RESPONSE)) {
            smtp.sent.clear();
            record();
            when(client.send(any(), any(), any())).thenReturn(Optional.of(fallback));

            provider(enabled, client)
                    .send(SMTP_CONFIG, "ada@yildizskylab.com", SUBJECT, TEXT_BODY, HTML_BODY);

            assertEquals(1, smtp.sent.size(), fallback.reason() + " must still deliver the mail");
        }
    }

    @Test
    void fallsBackWithoutCallingSkyMailWhenTheProviderIsDisabled() throws EmailException {
        record();
        SkyMailSettings disabled =
                SkyMailSettings.disabled(SkyMailSettings.REASON_SECRET_FILE_MISSING);

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
        SkyMailEmailSenderProvider provider = provider(enabled, client);

        provider.send(SMTP_CONFIG, "ada@yildizskylab.com", SUBJECT, TEXT_BODY, HTML_BODY);
        provider.send(SMTP_CONFIG, "ops@yildizskylab.com", SUBJECT, TEXT_BODY, HTML_BODY);

        verify(client).send(any(), eq("ada@yildizskylab.com"), any());
        assertEquals(1, smtp.sent.size(), "the second mail had no template and must use SMTP");
    }

    @Test
    void sendsToTheAddressKeycloakResolvedForThisMail() throws EmailException {
        record();
        when(client.send(any(), any(), any())).thenReturn(Optional.empty());
        UserModel user = SkyMailMessageTest.user("Ada", "Yıldız", "ada", "ada@yildizskylab.com");

        provider(enabled, client).send(SMTP_CONFIG, user, SUBJECT, TEXT_BODY, HTML_BODY);

        verify(client).send(any(), eq("ada@yildizskylab.com"), any());
    }

    @Test
    void fallsBackWhenTheRealmIssuerCannotBeResolvedAndNoTokenUrlIsPinned() throws EmailException {
        record();
        SkyMailSettings derived = new SkyMailSettings(true, null,
                URI.create("https://mail.yildizskylab.com/v1/mail_tasks/single"), null,
                "keycloak-mailer", SkyMailSecret.ofLiteral("s3cr3t"),
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
                SkyMailEmailSenderProvider.realmIssuer(
                        URI.create("https://e.yildizskylab.com/"), "e-skylab"));
        assertEquals(
                URI.create("http://localhost:18080/realms/e-skylab-test"),
                SkyMailEmailSenderProvider.realmIssuer(
                        URI.create("http://localhost:18080"), "e-skylab-test"));
        assertNull(SkyMailEmailSenderProvider.realmIssuer(null, "e-skylab"));
        assertNull(SkyMailEmailSenderProvider.realmIssuer(URI.create("https://e.invalid/"), " "));
    }

    @Test
    void reportsWhenKeycloaksOwnSenderIsUnavailable() {
        SkyMailEmailSenderProvider provider = new SkyMailEmailSenderProvider(
                session, SkyMailSettings.disabled(SkyMailSettings.REASON_NOT_ENABLED), null,
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
