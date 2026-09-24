package com.skylab.handoff;

import jakarta.ws.rs.core.HttpHeaders;
import jakarta.ws.rs.core.Response;
import org.junit.jupiter.api.Test;
import org.keycloak.forms.login.LoginFormsProvider;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.ThemeManager;
import org.keycloak.theme.Theme;

import java.io.IOException;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Base64;
import java.util.List;
import java.util.Locale;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.RETURNS_SELF;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class FailurePageTest {

    private static final URI SELF = URI.create("https://e.yildizskylab.com/realms/e-skylab/sky-handoff/v1/failed");
    private static final String HSTS = "max-age=31536000; includeSubDomains";
    private static final String THEMED_HTML = """
            <!DOCTYPE html><html lang="en"><head><script>
            const kcContext = { "skyHandoffReason": "used" };
            window.kcContext = kcContext;
            </script>
            <base href="/resources/abc/login/e-skylab-theme/dist/">
                <script type="module" crossorigin="" src="/resources/abc/login/e-skylab-theme/dist/assets/index.js"></script>
              </head>
              <body><div id="root"></div></body></html>
            """;

    @Test
    void everyReasonHasItsOwnTurkishSentenceAndTheRetryHint() {
        List<String> expected = List.of(
                "expired=Bağlantının süresi doldu.",
                "used=Bu bağlantı zaten kullanıldı.",
                "invalid=Bağlantı geçersiz.",
                "target_disabled=Bu siteye uygulamadan geçiş şu an kapalı.",
                "account_unavailable=Hesabın şu an kullanılamıyor.",
                "unavailable=Geçici bir sorun oluştu.");
        for (String pair : expected) {
            String code = pair.substring(0, pair.indexOf('='));
            String sentence = pair.substring(pair.indexOf('=') + 1);
            FailureReason reason = FailureReason.fromCode(code);
            assertEquals(code, reason.code());
            assertEquals(sentence, reason.message());
            String html = FailurePage.fallbackHtml(reason);
            assertTrue(html.contains(sentence), code + " must say: " + sentence);
            assertTrue(html.contains("Uygulamaya dönüp tekrar dene."), code + " must tell the person to go back");
            assertTrue(html.contains("data-reason=\"" + code + "\""), code + " must name its reason for the app");
        }
        assertEquals(expected.size(), FailureReason.values().length, "the reason list is closed");
    }

    @Test
    void anUnknownReasonIsTheGenericOneAndIsNeverEchoed() {
        String hostile = "<script>alert(1)</script>";
        assertEquals(FailureReason.UNAVAILABLE, FailureReason.fromCode(hostile));
        assertEquals(FailureReason.UNAVAILABLE, FailureReason.fromCode(null));
        assertEquals(FailureReason.UNAVAILABLE, FailureReason.fromCode("EXPIRED"));
        String html = FailurePage.fallbackHtml(FailureReason.fromCode(hostile));
        assertTrue(html.contains("Geçici bir sorun oluştu."));
        assertFalse(html.contains("<script"));
    }

    @Test
    void rendersTheReasonThroughTheRealmLoginThemeWhenTheThemeHasThePage() {
        Fixture fixture = Fixture.themed();
        Response themed = rendered(200, THEMED_HTML);
        when(themed.getHeaderString(HttpHeaders.CONTENT_LANGUAGE)).thenReturn("tr");
        when(fixture.forms.createForm(FailurePage.TEMPLATE)).thenReturn(themed);

        FailurePage.Page page = FailurePage.page(fixture.session, FailureReason.USED, SELF, HSTS);

        assertEquals(THEMED_HTML, page.html());
        assertEquals("tr", page.headers().get(HttpHeaders.CONTENT_LANGUAGE));
        verify(fixture.forms).setAttribute(FailurePage.REASON_ATTRIBUTE, "used");
        // The page has no form; the action URI is itself only so the theme's context is complete.
        verify(fixture.forms).setActionUri(SELF);
    }

    @Test
    void theThemedPageRunsOnlyItsOwnInlineScriptAndCannotBeFramedCachedOrLeakAReferrer() throws Exception {
        Fixture fixture = Fixture.themed();
        Response themed = rendered(200, THEMED_HTML);
        when(fixture.forms.createForm(FailurePage.TEMPLATE)).thenReturn(themed);

        FailurePage.Page page = FailurePage.page(fixture.session, FailureReason.EXPIRED, SELF, HSTS);

        assertSecurityHeaders(page);
        String policy = page.headers().get("Content-Security-Policy");
        String inlineScript = THEMED_HTML.substring(
                THEMED_HTML.indexOf("<script>") + "<script>".length(), THEMED_HTML.indexOf("</script>"));
        assertTrue(policy.contains("script-src 'self' 'sha256-" + sha256(inlineScript) + "'"), policy);
        assertFalse(directive(policy, "script-src").contains("unsafe-inline"), "no arbitrary inline script");
        assertFalse(directive(policy, "script-src").contains("unsafe-eval"));
        assertTrue(policy.contains("default-src 'none'"));
        assertTrue(policy.contains("frame-ancestors 'none'"));
        assertTrue(policy.contains("form-action 'none'"));
        assertTrue(policy.contains("object-src 'none'"));
        // Keycloakify points <base> at the theme resources; nothing else may.
        assertTrue(policy.contains("base-uri 'self'"));
    }

    @Test
    void fallsBackToTheBuiltInPageWhenTheLoginThemeLacksThePage() throws Exception {
        Fixture fixture = Fixture.themed();
        when(fixture.theme.getTemplate(FailurePage.TEMPLATE)).thenReturn(null);

        FailurePage.Page page = FailurePage.page(fixture.session, FailureReason.TARGET_DISABLED, SELF, HSTS);

        assertFallback(page, FailureReason.TARGET_DISABLED);
        verify(fixture.forms, never()).createForm(any());
    }

    @Test
    void fallsBackToTheBuiltInPageWhenTheThemeCannotRenderIt() throws Exception {
        Fixture failed = Fixture.themed();
        Response serverError = rendered(500, "");
        when(failed.forms.createForm(FailurePage.TEMPLATE)).thenReturn(serverError);
        assertFallback(FailurePage.page(failed.session, FailureReason.INVALID, SELF, HSTS), FailureReason.INVALID);

        Fixture thrown = Fixture.themed();
        when(thrown.forms.createForm(FailurePage.TEMPLATE)).thenThrow(new IllegalStateException("template error"));
        assertFallback(FailurePage.page(thrown.session, FailureReason.INVALID, SELF, HSTS), FailureReason.INVALID);

        Fixture blank = Fixture.themed();
        Response empty = rendered(200, "  ");
        when(blank.forms.createForm(FailurePage.TEMPLATE)).thenReturn(empty);
        assertFallback(FailurePage.page(blank.session, FailureReason.INVALID, SELF, HSTS), FailureReason.INVALID);

        Fixture unreadable = Fixture.themed();
        when(unreadable.themes.getTheme(Theme.Type.LOGIN)).thenThrow(new IOException("theme missing"));
        assertFallback(FailurePage.page(unreadable.session, FailureReason.INVALID, SELF, HSTS), FailureReason.INVALID);
    }

    @Test
    void theBuiltInPageOffersNoLoginAndRunsNoScript() {
        for (FailureReason reason : FailureReason.values()) {
            String html = FailurePage.fallbackHtml(reason).toLowerCase(Locale.ROOT);
            assertFalse(html.contains("<form"), "no login form");
            assertFalse(html.contains("<a "), "no link to the e. login");
            assertFalse(html.contains("<script"), "no script");
            assertTrue(html.contains("lang=\"tr\""));
        }
    }

    @Test
    void hashesEveryInlineScriptTheWayTheBrowserReadsIt() throws Exception {
        String html = "<script>alert(1)</script><SCRIPT type=\"text/javascript\">b()</SCRIPT>"
                + "<script type=\"module\" src=\"/x.js\"></script><script src='/y.js'></script>"
                + "<script>line1\r\nline2\rline3</script>";

        assertEquals(List.of(sha256("alert(1)"), sha256("b()"), sha256("line1\nline2\nline3")),
                FailurePage.inlineScriptHashes(html));
        assertEquals(List.of(), FailurePage.inlineScriptHashes("<p>no script</p>"));

        // The Keycloakify page context is tens of kilobytes of script with Turkish text in it.
        String context = "const kcContext = {\"message\": \"Bağlantı geçersiz\"};\n".repeat(5_000);
        assertEquals(List.of(sha256(context)), FailurePage.inlineScriptHashes("<head><script>" + context + "</script>"));
    }

    @Test
    void sendsNoStrictTransportSecurityWhenTheRealmHasNone() {
        Fixture fixture = Fixture.themed();
        Response themed = rendered(200, THEMED_HTML);
        when(fixture.forms.createForm(FailurePage.TEMPLATE)).thenReturn(themed);
        assertNull(FailurePage.page(fixture.session, FailureReason.USED, SELF, "").headers().get("Strict-Transport-Security"));
        assertNull(FailurePage.page(fixture.session, FailureReason.USED, SELF, null).headers().get("Strict-Transport-Security"));
    }

    private static void assertFallback(FailurePage.Page page, FailureReason reason) {
        String html = page.html();
        assertTrue(html.contains("data-reason=\"" + reason.code() + "\""));
        assertTrue(html.contains(reason.message()));
        assertSecurityHeaders(page);
        String policy = page.headers().get("Content-Security-Policy");
        assertTrue(policy.contains("default-src 'none'"));
        assertFalse(policy.contains("script-src"), "the built-in page runs no script at all");
        assertTrue(policy.contains("base-uri 'none'"));
        assertTrue(policy.contains("frame-ancestors 'none'"));
        assertTrue(policy.contains("form-action 'none'"));
    }

    private static void assertSecurityHeaders(FailurePage.Page page) {
        assertEquals("no-store", page.headers().get("Cache-Control"));
        assertEquals("DENY", page.headers().get("X-Frame-Options"));
        assertEquals("no-referrer", page.headers().get("Referrer-Policy"));
        assertEquals("nosniff", page.headers().get("X-Content-Type-Options"));
        assertEquals("none", page.headers().get("X-Robots-Tag"));
        assertEquals(HSTS, page.headers().get("Strict-Transport-Security"));
    }

    /** What the login forms provider answered; mocked because the tests run without a JAX-RS runtime. */
    private static Response rendered(int status, String html) {
        Response response = mock(Response.class);
        when(response.getStatus()).thenReturn(status);
        when(response.getEntity()).thenReturn(html);
        return response;
    }

    private static String directive(String policy, String name) {
        for (String directive : policy.split(";")) {
            if (directive.trim().startsWith(name + " ")) {
                return directive.trim();
            }
        }
        return "";
    }

    private static String sha256(String script) throws NoSuchAlgorithmException {
        return Base64.getEncoder().encodeToString(
                MessageDigest.getInstance("SHA-256").digest(script.getBytes(StandardCharsets.UTF_8)));
    }

    private record Fixture(KeycloakSession session, ThemeManager themes, Theme theme, LoginFormsProvider forms) {

        static Fixture themed() {
            KeycloakSession session = mock(KeycloakSession.class);
            ThemeManager themes = mock(ThemeManager.class);
            Theme theme = mock(Theme.class);
            LoginFormsProvider forms = mock(LoginFormsProvider.class, RETURNS_SELF);
            when(session.theme()).thenReturn(themes);
            when(session.getProvider(LoginFormsProvider.class)).thenReturn(forms);
            try {
                when(themes.getTheme(Theme.Type.LOGIN)).thenReturn(theme);
                when(theme.getTemplate(FailurePage.TEMPLATE))
                        .thenReturn(URI.create("file:/themes/e-skylab-theme/login/" + FailurePage.TEMPLATE).toURL());
            } catch (IOException exception) {
                throw new IllegalStateException(exception);
            }
            return new Fixture(session, themes, theme, forms);
        }
    }
}
