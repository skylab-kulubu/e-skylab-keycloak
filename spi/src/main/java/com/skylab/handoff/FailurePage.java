package com.skylab.handoff;

import jakarta.ws.rs.core.HttpHeaders;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;
import org.jboss.logging.Logger;
import org.keycloak.forms.login.LoginFormsProvider;
import org.keycloak.models.KeycloakSession;
import org.keycloak.theme.Theme;

import java.io.IOException;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * The page a failed Web handoff lands on inside the WebView ({@code v1/failed?reason=}). Its path
 * and reason codes are stable because SkyApp may watch for them. It offers no login form and no
 * link to the Keycloak login, and it only ever shows one of the fixed sentences of
 * {@link FailureReason}, never the query value.
 *
 * <p>The page is rendered by the realm's login theme ({@value #TEMPLATE}, which the SKY LAB login
 * theme draws in its LegacyFrame design, in the person's locale), with the reason code as the
 * only page attribute. When the login theme lacks that page or cannot render it, a plain built-in
 * page with the same Turkish sentences is served instead, so a failure never ends on an error.
 */
final class FailurePage {

    /** The login theme template of the page; the SKY LAB theme generates it from its React page. */
    static final String TEMPLATE = "sky-handoff-failed.ftl";
    /** The only page attribute: the reason code, one of {@link FailureReason}. */
    static final String REASON_ATTRIBUTE = "skyHandoffReason";

    /** The built-in page runs no script and loads nothing. */
    static final String FALLBACK_CONTENT_SECURITY_POLICY =
            "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";

    /**
     * Every header both pages share: never cached, never framed, no referrer, not indexed. They
     * replace Keycloak's realm browser security headers for this response (which would allow
     * same-origin framing and set a looser policy), so the caller must switch those off.
     */
    static final Map<String, String> HEADERS = Map.of(
            HttpHeaders.CACHE_CONTROL, "no-store",
            "X-Frame-Options", "DENY",
            "X-Content-Type-Options", "nosniff",
            "Referrer-Policy", "no-referrer",
            "X-Robots-Tag", "none");

    private static final Logger LOG = Logger.getLogger(FailurePage.class);
    private static final MediaType HTML = MediaType.TEXT_HTML_TYPE.withCharset("UTF-8");
    /** An inline script element: a {@code <script>} start tag without {@code src} and its text. */
    private static final Pattern INLINE_SCRIPT = Pattern.compile(
            "<script(?![^>]*\\ssrc\\s*=)[^>]*>(.*?)</script\\s*>", Pattern.CASE_INSENSITIVE | Pattern.DOTALL);

    private FailurePage() {
    }

    /** The page and every response header it is sent with. */
    record Page(String html, Map<String, String> headers) {

        Response toResponse() {
            Response.ResponseBuilder builder = Response.ok(html, HTML);
            headers.forEach(builder::header);
            return builder.build();
        }
    }

    /**
     * @param pageUrl                    this page's own absolute URL; the theme context gets it as its
     *                                action URL (the page has no form, nothing posts to it)
     * @param strictTransportSecurity the realm's {@code Strict-Transport-Security} value, kept
     *                                because Keycloak's own headers are switched off; {@code null}
     *                                or empty to send none
     */
    static Response render(KeycloakSession session, FailureReason reason, URI pageUrl, String strictTransportSecurity) {
        return page(session, reason, pageUrl, strictTransportSecurity).toResponse();
    }

    static Page page(KeycloakSession session, FailureReason reason, URI pageUrl, String strictTransportSecurity) {
        Map<String, String> headers = new LinkedHashMap<>(HEADERS);
        ThemedPage themed = themedPage(session, reason, pageUrl);
        String html;
        if (themed != null) {
            html = themed.html();
            headers.put("Content-Security-Policy", themedContentSecurityPolicy(html));
            if (themed.language() != null && !themed.language().isBlank()) {
                headers.put(HttpHeaders.CONTENT_LANGUAGE, themed.language());
            }
        } else {
            html = fallbackHtml(reason);
            headers.put("Content-Security-Policy", FALLBACK_CONTENT_SECURITY_POLICY);
        }
        if (strictTransportSecurity != null && !strictTransportSecurity.isBlank()) {
            headers.put("Strict-Transport-Security", strictTransportSecurity);
        }
        return new Page(html, Map.copyOf(headers));
    }

    /**
     * The policy of the themed page: the theme's own resources, its one inline script (the
     * Keycloakify page context, allowed by hash and nothing else inline), inline styles for the
     * animated logo, no framing, no form target.
     */
    static String themedContentSecurityPolicy(String html) {
        StringBuilder scripts = new StringBuilder("'self'");
        for (String hash : inlineScriptHashes(html)) {
            scripts.append(" 'sha256-").append(hash).append('\'');
        }
        return "default-src 'none'; script-src " + scripts
                + "; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'"
                + "; base-uri 'self'; form-action 'none'; frame-ancestors 'none'; object-src 'none'";
    }

    /**
     * SHA-256 (base64) of every inline script, over the text the browser hashes: the element's
     * content with line breaks normalised to {@code \n}, as the HTML parser does before it runs.
     */
    static List<String> inlineScriptHashes(String html) {
        List<String> hashes = new ArrayList<>();
        Matcher matcher = INLINE_SCRIPT.matcher(html);
        while (matcher.find()) {
            String script = matcher.group(1).replace("\r\n", "\n").replace('\r', '\n');
            hashes.add(Base64.getEncoder().encodeToString(sha256(script.getBytes(StandardCharsets.UTF_8))));
        }
        return hashes;
    }

    /** The page as the login theme rendered it, with the locale it chose. */
    private record ThemedPage(String html, String language) {
    }

    /** The page from the realm's login theme, or {@code null} when the theme cannot provide it. */
    private static ThemedPage themedPage(KeycloakSession session, FailureReason reason, URI pageUrl) {
        try {
            Theme theme = session.theme().getTheme(Theme.Type.LOGIN);
            if (theme == null || theme.getTemplate(TEMPLATE) == null) {
                LOG.debugf("sky-handoff: the login theme has no %s; serving the built-in failure page", TEMPLATE);
                return null;
            }
            Response rendered = session.getProvider(LoginFormsProvider.class)
                    .setActionUri(pageUrl)
                    .setAttribute(REASON_ATTRIBUTE, reason.code())
                    .createForm(TEMPLATE);
            if (rendered != null && rendered.getStatus() == 200
                    && rendered.getEntity() instanceof String html && !html.isBlank()) {
                return new ThemedPage(html, rendered.getHeaderString(HttpHeaders.CONTENT_LANGUAGE));
            }
            LOG.warnf("sky-handoff: the login theme could not render %s (HTTP %s); serving the built-in failure page",
                    TEMPLATE, rendered == null ? "none" : rendered.getStatus());
        } catch (IOException | RuntimeException exception) {
            LOG.warn("sky-handoff: the login theme failed on the failure page; serving the built-in one", exception);
        }
        return null;
    }

    /**
     * The built-in page for a realm whose login theme lacks the themed one: the LegacyFrame tokens
     * (background, card, ink, muted text, accent) without the theme's resources.
     */
    static String fallbackHtml(FailureReason reason) {
        return """
                <!doctype html>
                <html lang="tr">
                <head>
                <meta charset="utf-8">
                <meta name="viewport" content="width=device-width, initial-scale=1">
                <meta name="robots" content="noindex">
                <meta name="color-scheme" content="dark">
                <title>SKY LAB</title>
                <style>
                html{color-scheme:dark;background:#08070b}
                body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;\
                font-family:Inter,ui-sans-serif,system-ui,-apple-system,"Segoe UI",sans-serif;background:#08070b;color:#fff}
                main{box-sizing:border-box;width:min(100%% - 2rem,28rem);padding:2rem 1.5rem;text-align:center;\
                border:1px solid rgba(255,255,255,.1);border-radius:1.5rem;background:rgba(24,24,27,.6)}
                p.brand{margin:0 0 1.25rem;font-weight:700;letter-spacing:.24em;color:#e0c8e5}
                h1{font-size:1.5rem;line-height:1.3;font-weight:700;margin:0}
                p{margin:.5rem 0 0;font-size:.875rem;line-height:1.625;color:#a1a1aa}
                </style>
                </head>
                <body>
                <main data-reason="%s">
                <p class="brand">SKY LAB</p>
                <h1>%s</h1>
                <p>%s</p>
                </main>
                </body>
                </html>
                """.formatted(reason.code(), reason.message(), FailureReason.RETRY_HINT);
    }

    private static byte[] sha256(byte[] value) {
        try {
            return MessageDigest.getInstance("SHA-256").digest(value);
        } catch (NoSuchAlgorithmException exception) {
            throw new IllegalStateException("SHA-256 is unavailable", exception);
        }
    }
}
