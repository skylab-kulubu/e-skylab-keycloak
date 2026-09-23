package com.skylab.mail;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.IOException;
import java.net.URI;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashMap;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class SkyMailSettingsTest {

    @TempDir
    Path secrets;

    private Map<String, String> environment(Path secretFile) {
        Map<String, String> environment = new HashMap<>();
        environment.put(SkyMailSettings.ENABLED_ENV, "true");
        environment.put(SkyMailSettings.BASE_URL_ENV, "https://mail.yildizskylab.com");
        environment.put(SkyMailSettings.CLIENT_ID_ENV, "keycloak-mailer");
        environment.put(SkyMailSettings.CLIENT_SECRET_FILE_ENV, secretFile.toString());
        return environment;
    }

    private Path secretFile(String contents) throws IOException {
        Path file = secrets.resolve("client.secret");
        Files.writeString(file, contents);
        return file;
    }

    @Test
    void isDisabledUntilAnOperatorEnablesIt() {
        SkyMailSettings settings = SkyMailSettings.fromEnvironment(Map.of());

        assertFalse(settings.enabled());
        assertEquals(SkyMailSettings.REASON_NOT_ENABLED, settings.disabledReason());
        assertFalse(SkyMailSettings.parseEnabled(null));
        assertFalse(SkyMailSettings.parseEnabled(" FALSE "));
        assertTrue(SkyMailSettings.parseEnabled(" True "));
        assertThrows(IllegalStateException.class, () -> SkyMailSettings.parseEnabled("yes"));
    }

    @Test
    void buildsTheSingleMailTaskEndpointFromTheBaseUrl() throws IOException {
        SkyMailSettings settings = SkyMailSettings.fromEnvironment(environment(secretFile("s3cr3t\n")));

        assertTrue(settings.enabled());
        assertNull(settings.disabledReason());
        assertEquals(
                URI.create("https://mail.yildizskylab.com/v1/mail_tasks/single"),
                settings.mailTaskUrl());
        assertEquals("keycloak-mailer", settings.clientId());
    }

    @Test
    void refusesABaseUrlThatIsNotACredentialFreeHttpsOrigin() {
        assertThrows(IllegalStateException.class,
                () -> SkyMailSettings.mailTaskUrl("http://mail.yildizskylab.com", false));
        assertThrows(IllegalStateException.class,
                () -> SkyMailSettings.mailTaskUrl("https://mail.yildizskylab.com/v1", false));
        assertThrows(IllegalStateException.class,
                () -> SkyMailSettings.mailTaskUrl("https://mail.yildizskylab.com?token=leak", false));
        assertThrows(IllegalStateException.class,
                () -> SkyMailSettings.mailTaskUrl("https://ops:secret@mail.yildizskylab.com", false));
        assertEquals(
                URI.create("https://mail.yildizskylab.com/v1/mail_tasks/single"),
                SkyMailSettings.mailTaskUrl("https://mail.yildizskylab.com/", false));
        // Plain HTTP exists for the integration harness only.
        assertEquals(
                URI.create("http://skymail:8080/v1/mail_tasks/single"),
                SkyMailSettings.mailTaskUrl("http://skymail:8080", true));
    }

    @Test
    void derivesTheTokenEndpointFromTheRealmIssuerUnlessItIsPinned() throws IOException {
        SkyMailSettings derived = SkyMailSettings.fromEnvironment(environment(secretFile("s3cr3t")));
        assertNull(derived.tokenUrl());
        assertEquals(
                URI.create("https://e.yildizskylab.com/realms/e-skylab/protocol/openid-connect/token"),
                derived.tokenUrlFor(URI.create("https://e.yildizskylab.com/realms/e-skylab")));

        Map<String, String> pinned = environment(secretFile("s3cr3t"));
        pinned.put(SkyMailSettings.TOKEN_URL_ENV,
                "https://e.yildizskylab.com/realms/e-skylab/protocol/openid-connect/token");
        SkyMailSettings settings = SkyMailSettings.fromEnvironment(pinned);
        assertEquals(settings.tokenUrl(), settings.tokenUrlFor(URI.create("https://other.invalid/realms/x")));

        assertThrows(IllegalStateException.class,
                () -> SkyMailSettings.tokenUrl("https://e.yildizskylab.com/realms/e-skylab", false));
        assertThrows(IllegalStateException.class,
                () -> SkyMailSettings.tokenUrl("http://keycloak:8080/realms/x/protocol/openid-connect/token", false));
    }

    @Test
    void boundsTheRequestBudgetAndKeepsTheConnectBudgetBelowIt() throws IOException {
        SkyMailSettings settings = SkyMailSettings.fromEnvironment(environment(secretFile("s3cr3t")));
        assertEquals(5_000, settings.requestTimeout().toMillis());
        assertEquals(2_000, settings.connectTimeout().toMillis());

        Map<String, String> fast = environment(secretFile("s3cr3t"));
        fast.put(SkyMailSettings.TIMEOUT_ENV, "1500");
        SkyMailSettings tightened = SkyMailSettings.fromEnvironment(fast);
        assertEquals(1_500, tightened.requestTimeout().toMillis());
        assertEquals(1_500, tightened.connectTimeout().toMillis());

        assertThrows(IllegalStateException.class, () -> SkyMailSettings.requestTimeout("999"));
        assertThrows(IllegalStateException.class, () -> SkyMailSettings.requestTimeout("15001"));
        assertThrows(IllegalStateException.class, () -> SkyMailSettings.requestTimeout("soon"));
    }

    @Test
    void readsTheSecretFromItsMountedFileWithoutItsTrailingNewline() throws Exception {
        SkyMailSettings settings = SkyMailSettings.fromEnvironment(environment(secretFile("s3cr3t\n")));

        assertEquals("s3cr3t", settings.secret().read());
        assertEquals("s3cr3t", SkyMailSecret.stripTrailingNewlines("s3cr3t\r\n\n"));
        assertEquals("SkyMailSecret[redacted]", settings.secret().toString());
        assertFalse(settings.toString().contains("s3cr3t"));
    }

    @Test
    void defaultsToTheMountedSecretPathAndFailsClosedWhenItIsMissingOrEmpty() throws IOException {
        Map<String, String> unmounted = environment(secretFile("s3cr3t"));
        unmounted.remove(SkyMailSettings.CLIENT_SECRET_FILE_ENV);
        SkyMailSettings defaulted = SkyMailSettings.fromEnvironment(unmounted);
        assertFalse(defaulted.enabled(), "the documented mount is absent in the test environment");
        assertEquals(SkyMailSettings.REASON_SECRET_FILE_MISSING, defaulted.disabledReason());
        assertEquals("/run/secrets/sky-mail/client.secret", SkyMailSettings.DEFAULT_SECRET_FILE);

        Map<String, String> missing = environment(secrets.resolve("absent.secret"));
        SkyMailSettings withoutFile = SkyMailSettings.fromEnvironment(missing);
        assertFalse(withoutFile.enabled());
        assertEquals(SkyMailSettings.REASON_SECRET_FILE_MISSING, withoutFile.disabledReason());

        SkyMailSettings empty = SkyMailSettings.fromEnvironment(environment(secretFile("\n")));
        assertFalse(empty.enabled());
        assertEquals(SkyMailSettings.REASON_SECRET_FILE_EMPTY, empty.disabledReason());
    }

    @Test
    void acceptsAnInlineSecretOnlyForTheHarness() throws Exception {
        Map<String, String> harness = environment(secrets.resolve("absent.secret"));
        harness.put(SkyMailSettings.CLIENT_SECRET_ENV, "harness-secret");
        harness.put(SkyMailSettings.HARNESS_ENV, "1");
        SkyMailSettings settings = SkyMailSettings.fromEnvironment(harness);
        assertTrue(settings.enabled());
        assertEquals("harness-secret", settings.secret().read());

        Map<String, String> production = environment(secrets.resolve("absent.secret"));
        production.put(SkyMailSettings.CLIENT_SECRET_ENV, "harness-secret");
        SkyMailSettings refused = SkyMailSettings.fromEnvironment(production);
        assertFalse(refused.enabled());
        assertEquals(SkyMailSettings.REASON_SECRET_FILE_MISSING, refused.disabledReason());
    }

    @Test
    void refusesAMissingOrImpossibleClientId() throws IOException {
        Map<String, String> withoutClientId = environment(secretFile("s3cr3t"));
        withoutClientId.remove(SkyMailSettings.CLIENT_ID_ENV);
        assertThrows(IllegalStateException.class,
                () -> SkyMailSettings.fromEnvironment(withoutClientId));

        assertEquals("keycloak-mailer", SkyMailSettings.clientId("keycloak-mailer"));
        assertThrows(IllegalStateException.class, () -> SkyMailSettings.clientId("mailer client"));
        assertThrows(IllegalStateException.class, () -> SkyMailSettings.clientId("a".repeat(65)));
    }
}
