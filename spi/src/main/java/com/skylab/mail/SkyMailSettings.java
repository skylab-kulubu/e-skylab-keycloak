package com.skylab.mail;

import java.net.URI;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.Map;
import java.util.regex.Pattern;

/**
 * Environment configuration of the {@code sky-mail} e-mail sender, read and validated once when
 * the factory is initialised.
 *
 * <p>Malformed values (a non-HTTPS base URL, an out-of-range timeout, an impossible client id)
 * are operator mistakes and fail the factory with {@link IllegalStateException}. A missing or
 * empty secret file fails closed instead: the provider stays disabled, the factory warns once and
 * every mail keeps going out over Keycloak's own SMTP, because a mail server that refuses to boot
 * is worse than one that falls back.</p>
 *
 * <p>{@code SKY_MAIL_ENABLED} defaults to {@code false}, so the optimized image build
 * ({@code kc.sh build}, which initialises every factory without runtime environment) validates
 * nothing and needs no secret.</p>
 */
record SkyMailSettings(
        boolean enabled,
        String disabledReason,
        URI mailTaskUrl,
        URI tokenUrl,
        String clientId,
        SkyMailSecret secret,
        Duration connectTimeout,
        Duration requestTimeout) {

    static final String ENABLED_ENV = "SKY_MAIL_ENABLED";
    static final String BASE_URL_ENV = "SKY_MAIL_BASE_URL";
    static final String CLIENT_ID_ENV = "SKY_MAIL_CLIENT_ID";
    static final String CLIENT_SECRET_FILE_ENV = "SKY_MAIL_CLIENT_SECRET_FILE";
    static final String CLIENT_SECRET_ENV = "SKY_MAIL_CLIENT_SECRET";
    static final String TIMEOUT_ENV = "SKY_MAIL_TIMEOUT_MILLISECONDS";
    static final String TOKEN_URL_ENV = "SKY_MAIL_TOKEN_URL";
    static final String HARNESS_ENV = "SKY_HARNESS";

    /** The bind mount the production host provides; see docs/keycloak-mail-via-skymail.md. */
    static final String DEFAULT_SECRET_FILE = "/run/secrets/sky-mail/client.secret";

    static final String SINGLE_MAIL_TASK_PATH = "/v1/mail_tasks/single";
    static final String TOKEN_PATH = "/protocol/openid-connect/token";

    /** Total request budget; the connect budget is the smaller of 2000 ms and this value. */
    static final long DEFAULT_TIMEOUT_MILLISECONDS = 5_000;
    static final long CONNECT_TIMEOUT_CEILING_MILLISECONDS = 2_000;
    static final long MINIMUM_TIMEOUT_MILLISECONDS = 1_000;
    static final long MAXIMUM_TIMEOUT_MILLISECONDS = 15_000;

    static final String REASON_NOT_ENABLED = "not_enabled";
    static final String REASON_SECRET_FILE_MISSING = "secret_file_missing";
    static final String REASON_SECRET_FILE_EMPTY = "secret_file_empty";

    private static final Pattern CLIENT_ID = Pattern.compile("^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$");

    static SkyMailSettings fromEnvironment(Map<String, String> environment) {
        if (!parseEnabled(environment.get(ENABLED_ENV))) {
            return disabled(REASON_NOT_ENABLED);
        }

        boolean harness = "1".equals(trimmed(environment.get(HARNESS_ENV)));
        URI mailTaskUrl = mailTaskUrl(required(environment, BASE_URL_ENV), harness);
        URI tokenUrl = tokenUrl(trimmed(environment.get(TOKEN_URL_ENV)), harness);
        String clientId = clientId(required(environment, CLIENT_ID_ENV));
        Duration requestTimeout = requestTimeout(trimmed(environment.get(TIMEOUT_ENV)));
        Duration connectTimeout = Duration.ofMillis(
                Math.min(CONNECT_TIMEOUT_CEILING_MILLISECONDS, requestTimeout.toMillis()));

        String inlineSecret = trimmed(environment.get(CLIENT_SECRET_ENV));
        if (harness && inlineSecret != null) {
            return new SkyMailSettings(true, null, mailTaskUrl, tokenUrl, clientId,
                    SkyMailSecret.ofLiteral(inlineSecret), connectTimeout, requestTimeout);
        }

        String configuredFile = trimmed(environment.get(CLIENT_SECRET_FILE_ENV));
        Path secretFile = Path.of(configuredFile == null ? DEFAULT_SECRET_FILE : configuredFile);
        if (!secretFile.isAbsolute()) {
            throw new IllegalStateException(CLIENT_SECRET_FILE_ENV + " must be an absolute path.");
        }
        if (!Files.isRegularFile(secretFile) || !Files.isReadable(secretFile)) {
            return disabled(REASON_SECRET_FILE_MISSING);
        }
        SkyMailSecret secret = SkyMailSecret.ofFile(secretFile);
        try {
            secret.read();
        } catch (Exception exception) {
            return disabled(REASON_SECRET_FILE_EMPTY);
        }
        return new SkyMailSettings(true, null, mailTaskUrl, tokenUrl, clientId, secret,
                connectTimeout, requestTimeout);
    }

    static SkyMailSettings disabled(String reason) {
        return new SkyMailSettings(false, reason, null, null, null, null, null, null);
    }

    /**
     * The realm token endpoint this realm's service account authenticates against: the configured
     * {@code SKY_MAIL_TOKEN_URL} when the operator pinned one, otherwise derived from the realm
     * issuer that Keycloak is serving.
     */
    URI tokenUrlFor(URI realmIssuer) {
        if (tokenUrl != null) {
            return tokenUrl;
        }
        String issuer = realmIssuer.toString();
        while (issuer.endsWith("/")) {
            issuer = issuer.substring(0, issuer.length() - 1);
        }
        return URI.create(issuer + TOKEN_PATH);
    }

    static boolean parseEnabled(String value) {
        String candidate = trimmed(value);
        if (candidate == null || "false".equalsIgnoreCase(candidate)) {
            return false;
        }
        if ("true".equalsIgnoreCase(candidate)) {
            return true;
        }
        throw new IllegalStateException(ENABLED_ENV + " must be true or false.");
    }

    private static final Pattern BASE_PATH_SEGMENT = Pattern.compile("^[A-Za-z0-9._~-]+$");

    static URI mailTaskUrl(String value, boolean harness) {
        URI base = credentialFreeUrl(value, BASE_URL_ENV, harness);
        // SkyMail may answer under a path on a shared API host (production:
        // https://api.yildizskylab.com/api/skymail, the same root core uses). The path must be a
        // plain root: unreserved segments only, no dot segments, no encoding, and not the /v1 the
        // task path already adds.
        String rawPath = base.getRawPath() == null ? "" : base.getRawPath();
        String root = rawPath.endsWith("/") ? rawPath.substring(0, rawPath.length() - 1) : rawPath;
        if (!root.isEmpty()) {
            for (String segment : root.substring(1).split("/", -1)) {
                if (!BASE_PATH_SEGMENT.matcher(segment).matches() || ".".equals(segment) || "..".equals(segment)) {
                    throw new IllegalStateException(BASE_URL_ENV + " must be the SkyMail API root: "
                            + "a plain path without dot segments, encoding or empty segments.");
                }
            }
            if (root.endsWith("/v1")) {
                throw new IllegalStateException(BASE_URL_ENV + " must be the SkyMail API root without /v1.");
            }
        }
        return URI.create(base.getScheme() + "://" + base.getRawAuthority() + root + SINGLE_MAIL_TASK_PATH);
    }

    static URI tokenUrl(String value, boolean harness) {
        if (value == null) {
            return null;
        }
        URI tokenUrl = credentialFreeUrl(value, TOKEN_URL_ENV, harness);
        if (!tokenUrl.getPath().endsWith(TOKEN_PATH)) {
            throw new IllegalStateException(TOKEN_URL_ENV + " must end with " + TOKEN_PATH + ".");
        }
        return tokenUrl;
    }

    private static URI credentialFreeUrl(String value, String name, boolean harness) {
        final URI url;
        try {
            url = URI.create(value);
        } catch (IllegalArgumentException exception) {
            throw new IllegalStateException(name + " must be a valid HTTPS URL.", exception);
        }
        boolean https = "https".equals(url.getScheme());
        boolean harnessHttp = harness && "http".equals(url.getScheme());
        if ((!https && !harnessHttp) || url.getHost() == null || url.getUserInfo() != null
                || url.getQuery() != null || url.getFragment() != null) {
            throw new IllegalStateException(
                    name + " must be a credential-free HTTPS URL without query or fragment.");
        }
        return url;
    }

    static String clientId(String value) {
        if (!CLIENT_ID.matcher(value).matches()) {
            throw new IllegalStateException(CLIENT_ID_ENV + " must match " + CLIENT_ID.pattern() + ".");
        }
        return value;
    }

    static Duration requestTimeout(String value) {
        if (value == null) {
            return Duration.ofMillis(DEFAULT_TIMEOUT_MILLISECONDS);
        }
        final long parsed;
        try {
            parsed = Long.parseLong(value);
        } catch (NumberFormatException exception) {
            throw new IllegalStateException(timeoutBoundsMessage());
        }
        if (parsed < MINIMUM_TIMEOUT_MILLISECONDS || parsed > MAXIMUM_TIMEOUT_MILLISECONDS) {
            throw new IllegalStateException(timeoutBoundsMessage());
        }
        return Duration.ofMillis(parsed);
    }

    private static String timeoutBoundsMessage() {
        return TIMEOUT_ENV + " must be an integer from " + MINIMUM_TIMEOUT_MILLISECONDS
                + " through " + MAXIMUM_TIMEOUT_MILLISECONDS + ".";
    }

    private static String required(Map<String, String> environment, String name) {
        String value = trimmed(environment.get(name));
        if (value == null) {
            throw new IllegalStateException("Missing required environment variable: " + name);
        }
        return value;
    }

    private static String trimmed(String value) {
        if (value == null) {
            return null;
        }
        String trimmed = value.trim();
        return trimmed.isEmpty() ? null : trimmed;
    }
}
