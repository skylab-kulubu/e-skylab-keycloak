package com.skylab.handoff;

import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Locale;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class FailurePageTest {

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
            String html = FailurePage.html(reason);
            assertTrue(html.contains(sentence), code + " must say: " + sentence);
            assertTrue(html.contains("Uygulamaya dönüp tekrar dene."), code + " must tell the person to go back");
        }
        assertEquals(expected.size(), FailureReason.values().length, "the reason list is closed");
    }

    @Test
    void anUnknownReasonIsTheGenericOneAndIsNeverEchoed() {
        String hostile = "<script>alert(1)</script>";
        assertEquals(FailureReason.UNAVAILABLE, FailureReason.fromCode(hostile));
        assertEquals(FailureReason.UNAVAILABLE, FailureReason.fromCode(null));
        assertEquals(FailureReason.UNAVAILABLE, FailureReason.fromCode("EXPIRED"));
        String html = FailurePage.html(FailureReason.fromCode(hostile));
        assertTrue(html.contains("Geçici bir sorun oluştu."));
        assertFalse(html.contains("<script"));
    }

    @Test
    void thePageOffersNoLoginAndCannotBeFramedCachedOrLeakAReferrer() {
        for (FailureReason reason : FailureReason.values()) {
            String html = FailurePage.html(reason).toLowerCase(Locale.ROOT);
            assertFalse(html.contains("<form"), "no login form");
            assertFalse(html.contains("<a "), "no link to the e. login");
            assertFalse(html.contains("<script"), "no script");
            assertTrue(html.contains("lang=\"tr\""));
        }
        assertEquals("no-store", FailurePage.HEADERS.get("Cache-Control"));
        assertEquals("DENY", FailurePage.HEADERS.get("X-Frame-Options"));
        assertEquals("no-referrer", FailurePage.HEADERS.get("Referrer-Policy"));
        assertEquals("nosniff", FailurePage.HEADERS.get("X-Content-Type-Options"));
        assertEquals("none", FailurePage.HEADERS.get("X-Robots-Tag"));
        String policy = FailurePage.HEADERS.get("Content-Security-Policy");
        assertTrue(policy.contains("default-src 'none'"));
        assertTrue(policy.contains("frame-ancestors 'none'"));
        assertTrue(policy.contains("form-action 'none'"));
    }
}
