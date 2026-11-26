package com.skylab.mail;

import com.fasterxml.jackson.databind.JsonNode;
import org.keycloak.util.JsonSerialization;

import java.io.IOException;
import java.io.InputStream;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.net.http.HttpTimeoutException;
import java.nio.charset.StandardCharsets;
import java.time.Clock;
import java.time.Duration;
import java.util.Base64;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;

/**
 * The outbound half of the {@code skynotify} sender: a client-credentials token for the
 * {@code keycloak-mailer} service account, cached in memory until shortly before it expires, and
 * one {@code POST /v1/mail_tasks/single} per mail.
 *
 * <p>Nothing here throws at the caller. Every way a mail can fail to reach SkyNotify — an
 * unobtainable token, a refused or unavailable SkyNotify, a timeout, a 201 without a task id —
 * comes back as a {@link SkyNotifyFallback} so the sender can put the mail on Keycloak's own SMTP
 * instead. Only {@code 201} counts as sent: on a {@code 404} SkyNotify has written no queue row, so
 * a mail treated as sent would vanish.</p>
 */
final class SkyNotifyClient {

    /** Refresh a cached token this long before it expires, so a send never races the expiry. */
    static final Duration TOKEN_REFRESH_MARGIN = Duration.ofSeconds(30);
    /** Used when a token response carries no usable {@code expires_in}. */
    static final long FALLBACK_TOKEN_LIFETIME_SECONDS = 60;

    private static final int MAX_MAIL_RESPONSE_BYTES = 4_096;
    private static final int MAX_TOKEN_RESPONSE_BYTES = 16_384;

    private final SkyNotifySettings settings;
    private final HttpClient httpClient;
    private final Clock clock;
    private final Map<URI, CachedToken> tokens = new ConcurrentHashMap<>();

    SkyNotifyClient(SkyNotifySettings settings, HttpClient httpClient, Clock clock) {
        this.settings = settings;
        this.httpClient = httpClient;
        this.clock = clock;
    }

    static SkyNotifyClient create(SkyNotifySettings settings) {
        HttpClient httpClient = HttpClient.newBuilder()
                .connectTimeout(settings.connectTimeout())
                .followRedirects(HttpClient.Redirect.NEVER)
                .build();
        return new SkyNotifyClient(settings, httpClient, Clock.systemUTC());
    }

    /**
     * Hands one mail to SkyNotify. Returns empty when SkyNotify accepted it with {@code 201}, and the
     * reason to fall back otherwise.
     */
    Optional<SkyNotifyFallback> send(SkyNotifyMessage message, String recipientEmail, URI realmIssuer) {
        final URI tokenUrl;
        final String body;
        try {
            tokenUrl = settings.tokenUrlFor(realmIssuer);
            body = message.toRequestBody(recipientEmail);
        } catch (IOException | RuntimeException exception) {
            return Optional.of(SkyNotifyFallback.CONFIG);
        }

        Optional<String> token = accessToken(tokenUrl);
        if (token.isEmpty()) {
            return Optional.of(SkyNotifyFallback.TOKEN);
        }

        Optional<SkyNotifyFallback> outcome = post(body, token.get());
        if (outcome.filter(SkyNotifyFallback.REFUSED::equals).isPresent()) {
            // A refused mail may be a token Keycloak rotated under us; never reuse it.
            tokens.remove(tokenUrl);
        }
        return outcome;
    }

    private Optional<SkyNotifyFallback> post(String body, String token) {
        HttpRequest request = HttpRequest.newBuilder(settings.mailTaskUrl())
                .timeout(settings.requestTimeout())
                .header("Accept", "application/json")
                .header("Content-Type", "application/json")
                .header("Authorization", "Bearer " + token)
                .POST(HttpRequest.BodyPublishers.ofString(body, StandardCharsets.UTF_8))
                .build();
        try {
            HttpResponse<InputStream> response =
                    httpClient.send(request, HttpResponse.BodyHandlers.ofInputStream());
            try (InputStream stream = response.body()) {
                byte[] bytes = stream.readNBytes(MAX_MAIL_RESPONSE_BYTES);
                return classify(response.statusCode(), bytes);
            }
        } catch (HttpTimeoutException exception) {
            return Optional.of(SkyNotifyFallback.TIMEOUT);
        } catch (IOException exception) {
            return Optional.of(SkyNotifyFallback.TRANSPORT);
        } catch (InterruptedException exception) {
            Thread.currentThread().interrupt();
            return Optional.of(SkyNotifyFallback.TRANSPORT);
        }
    }

    static Optional<SkyNotifyFallback> classify(int statusCode, byte[] responseBytes) {
        if (statusCode == 201) {
            return hasMailTaskId(responseBytes)
                    ? Optional.empty()
                    : Optional.of(SkyNotifyFallback.RESPONSE);
        }
        if (statusCode == 404) {
            return Optional.of(SkyNotifyFallback.TEMPLATE_MISSING);
        }
        if (statusCode >= 500) {
            return Optional.of(SkyNotifyFallback.UNAVAILABLE);
        }
        return Optional.of(SkyNotifyFallback.REFUSED);
    }

    private static boolean hasMailTaskId(byte[] responseBytes) {
        try {
            JsonNode root = JsonSerialization.mapper.readTree(
                    new String(responseBytes, StandardCharsets.UTF_8));
            JsonNode id = root == null ? null : root.get("id");
            return id != null && id.isTextual() && !id.textValue().isBlank();
        } catch (IOException | RuntimeException exception) {
            return false;
        }
    }

    private Optional<String> accessToken(URI tokenUrl) {
        long now = clock.instant().getEpochSecond();
        CachedToken cached = tokens.get(tokenUrl);
        if (cached != null && cached.isUsableAt(now)) {
            return Optional.of(cached.accessToken());
        }
        Optional<CachedToken> fetched = fetchToken(tokenUrl, now);
        fetched.ifPresent(token -> tokens.put(tokenUrl, token));
        if (fetched.isEmpty()) {
            tokens.remove(tokenUrl);
        }
        return fetched.map(CachedToken::accessToken);
    }

    private Optional<CachedToken> fetchToken(URI tokenUrl, long now) {
        final String credentials;
        try {
            credentials = Base64.getEncoder().encodeToString(
                    (settings.clientId() + ":" + settings.secret().read())
                            .getBytes(StandardCharsets.UTF_8));
        } catch (IOException | RuntimeException exception) {
            return Optional.empty();
        }
        HttpRequest request = HttpRequest.newBuilder(tokenUrl)
                .timeout(settings.requestTimeout())
                .header("Accept", "application/json")
                .header("Content-Type", "application/x-www-form-urlencoded")
                .header("Authorization", "Basic " + credentials)
                // SkyNotify authenticates each call through Keycloak's userinfo endpoint, which
                // refuses a token without the openid scope.
                .POST(HttpRequest.BodyPublishers.ofString(
                        "grant_type=client_credentials&scope=openid", StandardCharsets.UTF_8))
                .build();
        try {
            HttpResponse<InputStream> response =
                    httpClient.send(request, HttpResponse.BodyHandlers.ofInputStream());
            try (InputStream stream = response.body()) {
                byte[] bytes = stream.readNBytes(MAX_TOKEN_RESPONSE_BYTES);
                if (response.statusCode() != 200) {
                    return Optional.empty();
                }
                return parseToken(new String(bytes, StandardCharsets.UTF_8), now);
            }
        } catch (IOException exception) {
            return Optional.empty();
        } catch (InterruptedException exception) {
            Thread.currentThread().interrupt();
            return Optional.empty();
        }
    }

    static Optional<CachedToken> parseToken(String responseBody, long now) {
        try {
            JsonNode root = JsonSerialization.mapper.readTree(responseBody);
            JsonNode accessToken = root == null ? null : root.get("access_token");
            if (accessToken == null || !accessToken.isTextual() || accessToken.textValue().isBlank()) {
                return Optional.empty();
            }
            JsonNode expiresIn = root.get("expires_in");
            long lifetime = expiresIn != null && expiresIn.isIntegralNumber() && expiresIn.longValue() > 0
                    ? expiresIn.longValue()
                    : FALLBACK_TOKEN_LIFETIME_SECONDS;
            return Optional.of(new CachedToken(accessToken.textValue(), now + lifetime));
        } catch (IOException | RuntimeException exception) {
            return Optional.empty();
        }
    }

    /** Visible for tests: how many token endpoints currently hold a cached token. */
    int cachedTokenCount() {
        return tokens.size();
    }

    record CachedToken(String accessToken, long expiresAtEpochSecond) {

        boolean isUsableAt(long nowEpochSecond) {
            return nowEpochSecond < expiresAtEpochSecond - TOKEN_REFRESH_MARGIN.toSeconds();
        }

        @Override
        public String toString() {
            return "CachedToken[redacted, expiresAtEpochSecond=" + expiresAtEpochSecond + "]";
        }
    }
}
