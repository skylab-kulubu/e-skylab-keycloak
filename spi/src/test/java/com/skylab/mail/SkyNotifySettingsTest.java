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

class SkyNotifySettingsTest {

    @TempDir
    Path secrets;

    private Map<String, String> environment(Path secretFile) {
        Map<String, String> environment = new HashMap<>();
        environment.put(SkyNotifySettings.ENABLED_ENV, "true");
        environment.put(SkyNotifySettings.BASE_URL_ENV, "https://mail.yildizskylab.com");
        environment.put(SkyNotifySettings.CLIENT_ID_ENV, "keycloak-mailer");
        environment.put(SkyNotifySettings.CLIENT_SECRET_FILE_ENV, secretFile.toString());
        return environment;
    }

    private Path secretFile(String contents) throws IOException {
        Path file = secrets.resolve("client.secret");
        Files.writeString(file, contents);
        return file;
    }

    @Test
    void isDisabledUntilAnOperatorEnablesIt() {
        SkyNotifySettings settings = SkyNotifySettings.fromEnvironment(Map.of());

        assertFalse(settings.enabled());
        assertEquals(SkyNotifySettings.REASON_NOT_ENABLED, settings.disabledReason());
        assertFalse(SkyNotifySettings.parseEnabled(null));
        assertFalse(SkyNotifySettings.parseEnabled(" FALSE "));
        assertTrue(SkyNotifySettings.parseEnabled(" True "));
        assertThrows(IllegalStateException.class, () -> SkyNotifySettings.parseEnabled("yes"));
    }

    @Test
    void buildsTheSingleMailTaskEndpointFromTheBaseUrl() throws IOException {
        SkyNotifySettings settings = SkyNotifySettings.fromEnvironment(environment(secretFile("s3cr3t\n")));

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
                () -> SkyNotifySettings.mailTaskUrl("http://mail.yildizskylab.com", false));
        assertThrows(IllegalStateException.class,
                () -> SkyNotifySettings.mailTaskUrl("https://mail.yildizskylab.com/v1", false));
        assertThrows(IllegalStateException.class,
                () -> SkyNotifySettings.mailTaskUrl("https://mail.yildizskylab.com?token=leak", false));
        assertThrows(IllegalStateException.class,
                () -> SkyNotifySettings.mailTaskUrl("https://ops:secret@mail.yildizskylab.com", false));
        assertEquals(
                URI.create("https://mail.yildizskylab.com/v1/mail_tasks/single"),
                SkyNotifySettings.mailTaskUrl("https://mail.yildizskylab.com/", false));
        // Plain HTTP exists for the integration harness only.
        assertEquals(
                URI.create("http://skynotify:8080/v1/mail_tasks/single"),
                SkyNotifySettings.mailTaskUrl("http://skynotify:8080", true));
    }

    // Production SkyNotify answers under a path on the shared API host, the same root core uses
    // (SKYNOTIFY_URL=https://api.yildizskylab.com/api/skynotify). An origin-only rule made Keycloak
    // refuse to start with that value on 2026-09-23.
    @Test
    void acceptsTheApiRootUnderAPathOnTheSharedApiHost() {
        assertEquals(
                URI.create("https://api.yildizskylab.com/api/skynotify/v1/mail_tasks/single"),
                SkyNotifySettings.mailTaskUrl("https://api.yildizskylab.com/api/skynotify", false));
        assertEquals(
                URI.create("https://api.yildizskylab.com/api/skynotify/v1/mail_tasks/single"),
                SkyNotifySettings.mailTaskUrl("https://api.yildizskylab.com/api/skynotify/", false));
    }

    @Test
    void refusesABasePathThatIsNotAPlainRoot() {
        for (String refused : new String[] {
                "https://api.yildizskylab.com/api/skynotify/v1",
                "https://api.yildizskylab.com/api/skynotify/v1/",
                "https://api.yildizskylab.com/api/../admin",
                "https://api.yildizskylab.com/api/./skynotify",
                "https://api.yildizskylab.com/api//skynotify",
                "https://api.yildizskylab.com/api/%2e%2e/admin",
                "https://api.yildizskylab.com/api/sky notify"}) {
            assertThrows(IllegalStateException.class, () -> SkyNotifySettings.mailTaskUrl(refused, false), refused);
        }
    }

    @Test
    void derivesTheTokenEndpointFromTheRealmIssuerUnlessItIsPinned() throws IOException {
        SkyNotifySettings derived = SkyNotifySettings.fromEnvironment(environment(secretFile("s3cr3t")));
        assertNull(derived.tokenUrl());
        assertEquals(
                URI.create("https://e.yildizskylab.com/realms/e-skylab/protocol/openid-connect/token"),
                derived.tokenUrlFor(URI.create("https://e.yildizskylab.com/realms/e-skylab")));

        Map<String, String> pinned = environment(secretFile("s3cr3t"));
        pinned.put(SkyNotifySettings.TOKEN_URL_ENV,
                "https://e.yildizskylab.com/realms/e-skylab/protocol/openid-connect/token");
        SkyNotifySettings settings = SkyNotifySettings.fromEnvironment(pinned);
        assertEquals(settings.tokenUrl(), settings.tokenUrlFor(URI.create("https://other.invalid/realms/x")));

        assertThrows(IllegalStateException.class,
                () -> SkyNotifySettings.tokenUrl("https://e.yildizskylab.com/realms/e-skylab", false));
        assertThrows(IllegalStateException.class,
                () -> SkyNotifySettings.tokenUrl("http://keycloak:8080/realms/x/protocol/openid-connect/token", false));
    }

    @Test
    void boundsTheRequestBudgetAndKeepsTheConnectBudgetBelowIt() throws IOException {
        SkyNotifySettings settings = SkyNotifySettings.fromEnvironment(environment(secretFile("s3cr3t")));
        assertEquals(5_000, settings.requestTimeout().toMillis());
        assertEquals(2_000, settings.connectTimeout().toMillis());

        Map<String, String> fast = environment(secretFile("s3cr3t"));
        fast.put(SkyNotifySettings.TIMEOUT_ENV, "1500");
        SkyNotifySettings tightened = SkyNotifySettings.fromEnvironment(fast);
        assertEquals(1_500, tightened.requestTimeout().toMillis());
        assertEquals(1_500, tightened.connectTimeout().toMillis());

        assertThrows(IllegalStateException.class, () -> SkyNotifySettings.requestTimeout("999"));
        assertThrows(IllegalStateException.class, () -> SkyNotifySettings.requestTimeout("15001"));
        assertThrows(IllegalStateException.class, () -> SkyNotifySettings.requestTimeout("soon"));
    }

    @Test
    void readsTheSecretFromItsMountedFileWithoutItsTrailingNewline() throws Exception {
        SkyNotifySettings settings = SkyNotifySettings.fromEnvironment(environment(secretFile("s3cr3t\n")));

        assertEquals("s3cr3t", settings.secret().read());
        assertEquals("s3cr3t", SkyNotifySecret.stripTrailingNewlines("s3cr3t\r\n\n"));
        assertEquals("SkyNotifySecret[redacted]", settings.secret().toString());
        assertFalse(settings.toString().contains("s3cr3t"));
    }

    @Test
    void defaultsToTheMountedSecretPathAndFailsClosedWhenItIsMissingOrEmpty() throws IOException {
        Map<String, String> unmounted = environment(secretFile("s3cr3t"));
        unmounted.remove(SkyNotifySettings.CLIENT_SECRET_FILE_ENV);
        SkyNotifySettings defaulted = SkyNotifySettings.fromEnvironment(unmounted);
        assertFalse(defaulted.enabled(), "the documented mount is absent in the test environment");
        assertEquals(SkyNotifySettings.REASON_SECRET_FILE_MISSING, defaulted.disabledReason());
        assertEquals("/run/secrets/skynotify/client.secret", SkyNotifySettings.DEFAULT_SECRET_FILE);

        Map<String, String> missing = environment(secrets.resolve("absent.secret"));
        SkyNotifySettings withoutFile = SkyNotifySettings.fromEnvironment(missing);
        assertFalse(withoutFile.enabled());
        assertEquals(SkyNotifySettings.REASON_SECRET_FILE_MISSING, withoutFile.disabledReason());

        SkyNotifySettings empty = SkyNotifySettings.fromEnvironment(environment(secretFile("\n")));
        assertFalse(empty.enabled());
        assertEquals(SkyNotifySettings.REASON_SECRET_FILE_EMPTY, empty.disabledReason());
    }

    @Test
    void acceptsAnInlineSecretOnlyForTheHarness() throws Exception {
        Map<String, String> harness = environment(secrets.resolve("absent.secret"));
        harness.put(SkyNotifySettings.CLIENT_SECRET_ENV, "harness-secret");
        harness.put(SkyNotifySettings.HARNESS_ENV, "1");
        SkyNotifySettings settings = SkyNotifySettings.fromEnvironment(harness);
        assertTrue(settings.enabled());
        assertEquals("harness-secret", settings.secret().read());

        Map<String, String> production = environment(secrets.resolve("absent.secret"));
        production.put(SkyNotifySettings.CLIENT_SECRET_ENV, "harness-secret");
        SkyNotifySettings refused = SkyNotifySettings.fromEnvironment(production);
        assertFalse(refused.enabled());
        assertEquals(SkyNotifySettings.REASON_SECRET_FILE_MISSING, refused.disabledReason());
    }

    @Test
    void refusesAMissingOrImpossibleClientId() throws IOException {
        Map<String, String> withoutClientId = environment(secretFile("s3cr3t"));
        withoutClientId.remove(SkyNotifySettings.CLIENT_ID_ENV);
        assertThrows(IllegalStateException.class,
                () -> SkyNotifySettings.fromEnvironment(withoutClientId));

        assertEquals("keycloak-mailer", SkyNotifySettings.clientId("keycloak-mailer"));
        assertThrows(IllegalStateException.class, () -> SkyNotifySettings.clientId("mailer client"));
        assertThrows(IllegalStateException.class, () -> SkyNotifySettings.clientId("a".repeat(65)));
    }
}
