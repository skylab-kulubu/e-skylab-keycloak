package com.skylab.mail;

import com.fasterxml.jackson.databind.JsonNode;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.keycloak.util.JsonSerialization;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.URI;
import java.net.http.HttpClient;
import java.nio.charset.StandardCharsets;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneId;
import java.time.ZoneOffset;
import java.util.Base64;
import java.util.List;
import java.util.Optional;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicInteger;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class SkyMailClientTest {

    private static final String SECRET = "mailer-client-secret";
    private static final String TOKEN_PATH = "/realms/e-skylab-test/protocol/openid-connect/token";
    private static final String MAIL_PATH = "/v1/mail_tasks/single";
    private static final URI REALM_ISSUER = URI.create("https://e.yildizskylab.com/realms/e-skylab");

    private HttpServer server;
    private URI base;
    private MutableClock clock;

    private final AtomicInteger tokenRequests = new AtomicInteger();
    private final List<String> mailBodies = new CopyOnWriteArrayList<>();
    private final List<String> mailAuthorizations = new CopyOnWriteArrayList<>();
    private final List<String> tokenAuthorizations = new CopyOnWriteArrayList<>();
    private final List<String> tokenBodies = new CopyOnWriteArrayList<>();

    private volatile int mailStatus = 201;
    private volatile String mailResponse = "{\"id\":\"8f1c0d3e-0000-4000-8000-000000000001\"}";
    private volatile long mailDelayMillis;
    private volatile int tokenStatus = 200;
    private volatile long tokenLifetimeSeconds = 300;

    @BeforeEach
    void startStubSkyMail() throws IOException {
        server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.setExecutor(Executors.newFixedThreadPool(2));
        server.createContext(TOKEN_PATH, exchange -> {
            tokenBodies.add(new String(drain(exchange), StandardCharsets.UTF_8));
            tokenRequests.incrementAndGet();
            tokenAuthorizations.add(String.valueOf(exchange.getRequestHeaders().getFirst("Authorization")));
            String body = tokenStatus == 200
                    ? "{\"access_token\":\"access-" + tokenRequests.get() + "\",\"expires_in\":"
                            + tokenLifetimeSeconds + ",\"token_type\":\"Bearer\"}"
                    : "{\"error\":\"invalid_client\"}";
            respond(exchange, tokenStatus, body);
        });
        server.createContext(MAIL_PATH, exchange -> {
            mailBodies.add(new String(drain(exchange), StandardCharsets.UTF_8));
            mailAuthorizations.add(String.valueOf(exchange.getRequestHeaders().getFirst("Authorization")));
            if (mailDelayMillis > 0) {
                try {
                    Thread.sleep(mailDelayMillis);
                } catch (InterruptedException interrupted) {
                    Thread.currentThread().interrupt();
                }
            }
            respond(exchange, mailStatus, mailResponse);
        });
        server.start();
        base = URI.create("http://127.0.0.1:" + server.getAddress().getPort());
        clock = new MutableClock(Instant.parse("2026-09-22T09:00:00Z"));
    }

    @AfterEach
    void stopStubSkyMail() {
        server.stop(0);
    }

    private static byte[] drain(HttpExchange exchange) throws IOException {
        try (InputStream body = exchange.getRequestBody()) {
            return body.readAllBytes();
        }
    }

    private static void respond(HttpExchange exchange, int status, String body) throws IOException {
        byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
        exchange.getResponseHeaders().add("Content-Type", "application/json");
        exchange.sendResponseHeaders(status, bytes.length);
        try (OutputStream response = exchange.getResponseBody()) {
            response.write(bytes);
        }
    }

    private SkyMailSettings settings(long timeoutMillis, URI tokenUrl) {
        return new SkyMailSettings(
                true,
                null,
                base.resolve(MAIL_PATH),
                tokenUrl,
                "keycloak-mailer",
                SkyMailSecret.ofLiteral(SECRET),
                Duration.ofMillis(Math.min(2_000, timeoutMillis)),
                Duration.ofMillis(timeoutMillis));
    }

    private SkyMailClient client() {
        return client(settings(2_000, base.resolve(TOKEN_PATH)));
    }

    private SkyMailClient client(SkyMailSettings settings) {
        return new SkyMailClient(
                settings,
                HttpClient.newBuilder().connectTimeout(settings.connectTimeout()).build(),
                clock);
    }

    private static SkyMailMessage message() {
        return SkyMailMessage.of(
                SkyMailTemplates.VERIFY_EMAIL,
                SkyMailTemplates.VERIFY_EMAIL_SUBJECT_KEY,
                "https://e.yildizskylab.com/verify?key=abc",
                "60",
                SkyMailMessageTest.user("Ada", "Yıldız", "ada", "ada@yildizskylab.com"),
                SkyMailMessageTest.realm("e-skylab", "SKY LAB"));
    }

    @Test
    void sendsOneSingleMailTaskAndCountsOnly201AsSent() throws Exception {
        Optional<SkyMailFallback> outcome =
                client().send(message(), "ada@yildizskylab.com", REALM_ISSUER);

        assertEquals(Optional.empty(), outcome);
        assertEquals(1, mailBodies.size());
        JsonNode body = JsonSerialization.mapper.readTree(mailBodies.getFirst());
        assertEquals("keycloak.verify-email", body.get("template_key").textValue());
        assertEquals("ada@yildizskylab.com", body.get("recipient_email").textValue());
        assertEquals("Ada Yıldız", body.get("recipient_full_name").textValue());
        assertEquals(SkyMailMessage.VARIABLE_NAMES.size(), body.get("body_variables").size());
        assertEquals("access-1", mailAuthorizations.getFirst().replace("Bearer ", ""));
    }

    @Test
    void sendsTheClientSecretOnlyToTheRealmTokenEndpoint() {
        client().send(message(), "ada@yildizskylab.com", REALM_ISSUER);

        String credentials = tokenAuthorizations.getFirst().replace("Basic ", "");
        assertEquals("keycloak-mailer:" + SECRET,
                new String(Base64.getDecoder().decode(credentials), StandardCharsets.UTF_8));
        assertFalse(mailAuthorizations.getFirst().contains(SECRET));
        assertFalse(mailBodies.getFirst().contains(SECRET));
    }

    // SkyMail authenticates every call through Keycloak's userinfo endpoint, and Keycloak answers
    // a token without the openid scope there with 403, which SkyMail turns into 401. Production
    // K5 fell back with reason=refused on 2026-09-24 for exactly that; core asks for openid too.
    @Test
    void asksForTheOpenidScopeSoSkyMailCanReadUserinfo() {
        client().send(message(), "ada@yildizskylab.com", REALM_ISSUER);

        assertEquals(List.of("grant_type=client_credentials&scope=openid"), tokenBodies);
    }

    @Test
    void fallsBackWhenSkyMailDoesNotKnowTheTemplateKey() {
        mailStatus = 404;
        mailResponse = "{\"detail\":\"template not found\"}";

        assertEquals(Optional.of(SkyMailFallback.TEMPLATE_MISSING),
                client().send(message(), "ada@yildizskylab.com", REALM_ISSUER));
    }

    @Test
    void fallsBackWhenSkyMailIsUnavailable() {
        mailStatus = 500;
        mailResponse = "{\"detail\":\"boom\"}";

        assertEquals(Optional.of(SkyMailFallback.UNAVAILABLE),
                client().send(message(), "ada@yildizskylab.com", REALM_ISSUER));
    }

    @Test
    void fallsBackWhenSkyMailRefusesTheRequest() {
        mailStatus = 400;

        assertEquals(Optional.of(SkyMailFallback.REFUSED),
                client().send(message(), "ada@yildizskylab.com", REALM_ISSUER));
    }

    @Test
    void classifiesEveryStatusSkyMailCanAnswerWith() {
        byte[] accepted = "{\"id\":\"8f1c0d3e-0000-4000-8000-000000000001\"}".getBytes(StandardCharsets.UTF_8);
        assertEquals(Optional.empty(), SkyMailClient.classify(201, accepted));
        assertEquals(Optional.of(SkyMailFallback.REFUSED), SkyMailClient.classify(200, accepted));
        assertEquals(Optional.of(SkyMailFallback.REFUSED), SkyMailClient.classify(202, accepted));
        assertEquals(Optional.of(SkyMailFallback.REFUSED), SkyMailClient.classify(401, accepted));
        assertEquals(Optional.of(SkyMailFallback.REFUSED), SkyMailClient.classify(403, accepted));
        assertEquals(Optional.of(SkyMailFallback.TEMPLATE_MISSING), SkyMailClient.classify(404, accepted));
        assertEquals(Optional.of(SkyMailFallback.UNAVAILABLE), SkyMailClient.classify(500, accepted));
        assertEquals(Optional.of(SkyMailFallback.UNAVAILABLE), SkyMailClient.classify(503, accepted));
    }

    @Test
    void fallsBackWhenSkyMailAcceptsTheMailWithoutAMailTaskId() {
        mailResponse = "{\"detail\":\"queued\"}";

        assertEquals(Optional.of(SkyMailFallback.RESPONSE),
                client().send(message(), "ada@yildizskylab.com", REALM_ISSUER));
    }

    @Test
    void fallsBackWhenSkyMailDoesNotAnswerInsideTheRequestBudget() {
        mailDelayMillis = 1_500;

        assertEquals(Optional.of(SkyMailFallback.TIMEOUT),
                client(settings(300, base.resolve(TOKEN_PATH)))
                        .send(message(), "ada@yildizskylab.com", REALM_ISSUER));
    }

    @Test
    void fallsBackWhenSkyMailCannotBeReached() throws IOException {
        HttpServer closed = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        closed.start();
        int deadPort = closed.getAddress().getPort();
        closed.stop(0);
        SkyMailSettings unreachable = new SkyMailSettings(
                true, null, URI.create("http://127.0.0.1:" + deadPort + MAIL_PATH),
                base.resolve(TOKEN_PATH), "keycloak-mailer", SkyMailSecret.ofLiteral(SECRET),
                Duration.ofMillis(500), Duration.ofMillis(500));

        Optional<SkyMailFallback> outcome =
                client(unreachable).send(message(), "ada@yildizskylab.com", REALM_ISSUER);

        assertTrue(outcome.isPresent());
        assertTrue(List.of(SkyMailFallback.TRANSPORT, SkyMailFallback.TIMEOUT).contains(outcome.get()),
                "an unreachable SkyMail must fall back, not throw: " + outcome.get());
    }

    @Test
    void fallsBackWhenTheServiceAccountTokenCannotBeObtained() {
        tokenStatus = 401;

        assertEquals(Optional.of(SkyMailFallback.TOKEN),
                client().send(message(), "ada@yildizskylab.com", REALM_ISSUER));
        assertTrue(mailBodies.isEmpty(), "no mail may be posted without a token");
    }

    @Test
    void fallsBackWhenThereIsNoTokenEndpointToCall() {
        SkyMailSettings derived = settings(2_000, null);

        assertEquals(Optional.of(SkyMailFallback.CONFIG),
                client(derived).send(message(), "ada@yildizskylab.com", null));
        assertEquals(0, tokenRequests.get());
    }

    @Test
    void cachesTheTokenAndFetchesAFreshOneShortlyBeforeItExpires() {
        tokenLifetimeSeconds = 300;
        SkyMailClient client = client();

        client.send(message(), "ada@yildizskylab.com", REALM_ISSUER);
        client.send(message(), "ada@yildizskylab.com", REALM_ISSUER);
        assertEquals(1, tokenRequests.get(), "the cached token must be reused");
        assertEquals(1, client.cachedTokenCount());

        clock.advance(Duration.ofSeconds(260));
        client.send(message(), "ada@yildizskylab.com", REALM_ISSUER);
        assertEquals(1, tokenRequests.get(), "a token well inside its lifetime is still cached");

        // 30 s before the expiry the cached token is refreshed instead of risking a rejection.
        clock.advance(Duration.ofSeconds(20));
        client.send(message(), "ada@yildizskylab.com", REALM_ISSUER);
        assertEquals(2, tokenRequests.get());
        assertEquals("Bearer access-2", mailAuthorizations.getLast());
    }

    @Test
    void forgetsACachedTokenSkyMailRefused() {
        SkyMailClient client = client();
        client.send(message(), "ada@yildizskylab.com", REALM_ISSUER);
        assertEquals(1, tokenRequests.get());

        mailStatus = 401;
        assertEquals(Optional.of(SkyMailFallback.REFUSED),
                client.send(message(), "ada@yildizskylab.com", REALM_ISSUER));
        assertEquals(0, client.cachedTokenCount());

        mailStatus = 201;
        client.send(message(), "ada@yildizskylab.com", REALM_ISSUER);
        assertEquals(2, tokenRequests.get(), "the next mail must authenticate again");
    }

    @Test
    void readsATokenResponseOnlyWhenItCarriesAUsableAccessToken() {
        assertEquals(Optional.empty(), SkyMailClient.parseToken("{\"expires_in\":300}", 1_000));
        assertEquals(Optional.empty(), SkyMailClient.parseToken("{\"access_token\":\"\"}", 1_000));
        assertEquals(Optional.empty(), SkyMailClient.parseToken("not json", 1_000));

        SkyMailClient.CachedToken token = SkyMailClient
                .parseToken("{\"access_token\":\"abc\",\"expires_in\":300}", 1_000)
                .orElseThrow();
        assertEquals(1_300, token.expiresAtEpochSecond());
        assertTrue(token.isUsableAt(1_269));
        assertFalse(token.isUsableAt(1_270));
        assertFalse(token.toString().contains("abc"), "a cached token must never be printed");

        SkyMailClient.CachedToken withoutLifetime = SkyMailClient
                .parseToken("{\"access_token\":\"abc\"}", 1_000)
                .orElseThrow();
        assertEquals(1_000 + SkyMailClient.FALLBACK_TOKEN_LIFETIME_SECONDS,
                withoutLifetime.expiresAtEpochSecond());
    }

    @Test
    void neverPutsTheAddressLinkOrSecretInWhatTheSenderLogs() {
        SkyMailMessage message = message();
        List<String> lines = new java.util.ArrayList<>();
        lines.add(SkyMailEmailSenderProvider.sentLine(message));
        for (SkyMailFallback fallback : SkyMailFallback.values()) {
            lines.add(SkyMailEmailSenderProvider.fallbackLine(fallback, message));
            lines.add(SkyMailEmailSenderProvider.fallbackLine(fallback, null));
        }

        for (String line : lines) {
            assertFalse(line.contains("ada@yildizskylab.com"), line);
            assertFalse(line.contains("verify?key=abc"), line);
            assertFalse(line.contains(SECRET), line);
            assertFalse(line.contains("Ada"), line);
        }
        assertEquals("sky_mail_fallback reason=template_missing template=keycloak.verify-email",
                SkyMailEmailSenderProvider.fallbackLine(SkyMailFallback.TEMPLATE_MISSING, message));
        assertEquals("sky_mail_fallback reason=disabled template=none",
                SkyMailEmailSenderProvider.fallbackLine(SkyMailFallback.DISABLED, null));
    }

    @Test
    void reportsEveryFallbackReasonWithAFixedWord() {
        assertEquals(
                List.of("disabled", "not_mapped", "config", "token", "template_missing", "refused",
                        "unavailable", "timeout", "transport", "response"),
                java.util.Arrays.stream(SkyMailFallback.values()).map(SkyMailFallback::reason).toList());
        assertFalse(SkyMailFallback.DISABLED.isFailure());
        assertFalse(SkyMailFallback.NOT_MAPPED.isFailure());
        assertTrue(SkyMailFallback.TEMPLATE_MISSING.isFailure());
        assertTrue(SkyMailFallback.TIMEOUT.isFailure());
    }

    static final class MutableClock extends Clock {

        private Instant instant;

        MutableClock(Instant instant) {
            this.instant = instant;
        }

        void advance(Duration duration) {
            instant = instant.plus(duration);
        }

        @Override
        public ZoneId getZone() {
            return ZoneOffset.UTC;
        }

        @Override
        public Clock withZone(ZoneId zone) {
            return this;
        }

        @Override
        public Instant instant() {
            return instant;
        }
    }
}
