package com.skylab.handoff;

import org.junit.jupiter.api.Test;

import java.util.Optional;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class HandoffRulesTest {

    @Test
    void anHttpsRootUrlOnYildizskylabComOrASubdomainIsAnAllowedOrigin() {
        assertEquals(Optional.of("https://my.yildizskylab.com"), HandoffRules.origin("https://my.yildizskylab.com"));
        assertEquals(Optional.of("https://forms.yildizskylab.com"), HandoffRules.origin("https://forms.yildizskylab.com/"));
        assertEquals(Optional.of("https://yildizskylab.com"), HandoffRules.origin("https://yildizskylab.com"));
        assertEquals(Optional.of("https://arge.site.yildizskylab.com"),
                HandoffRules.origin("https://arge.site.yildizskylab.com"));
        assertEquals(Optional.of("https://my.yildizskylab.com"), HandoffRules.origin("https://MY.YildizSkylab.com"),
                "host names are case-insensitive and normalised");
    }

    @Test
    void refusesEveryOtherRootUrl() {
        for (String rootUrl : new String[] {
                null,
                "",
                "   ",
                "http://my.yildizskylab.com",
                "HTTPS://my.yildizskylab.com",
                "https://my.yildizskylab.com:443",
                "https://my.yildizskylab.com:8443",
                "https://user@my.yildizskylab.com",
                "https://user:pw@my.yildizskylab.com",
                "https://my.yildizskylab.com?x=1",
                "https://my.yildizskylab.com/#x",
                "https://my.yildizskylab.com/app",
                "https://evilyildizskylab.com",
                "https://yildizskylab.com.evil.com",
                "https://my.yildizskylab.com.",
                "https://-my.yildizskylab.com",
                "https://my..yildizskylab.com",
                "https://my.yıldızskylab.com",
                "https://example.com",
                "${authBaseUrl}",
                "//my.yildizskylab.com",
                "https:my.yildizskylab.com",
                "https://my.yildizskylab.com\\@evil.com",
                " https://my.yildizskylab.com",
        }) {
            assertEquals(Optional.empty(), HandoffRules.origin(rootUrl), "must refuse " + rootUrl);
        }
    }

    @Test
    void aSignInPathIsAPlainAbsolutePathWithoutQueryOrFragment() {
        assertTrue(HandoffRules.isSignInPath("/auth/signin"));
        assertTrue(HandoffRules.isSignInPath("/api/auth/login"));
        assertTrue(HandoffRules.isSignInPath("/"));
        assertTrue(HandoffRules.isSignInPath("/login/"));

        for (String path : new String[] {
                null, "", "auth/signin", "//auth", "/auth//signin", "/auth\\signin", "/../admin", "/auth/..",
                "/auth/./signin", "/auth?x=1", "/auth#x", "/auth signin", "/auth%2Fsignin", "/giriş",
                "/" + "a".repeat(128),
        }) {
            assertFalse(HandoffRules.isSignInPath(path), "must refuse sign-in path " + path);
        }
    }

    @Test
    void aReturnParamIsAShortIdentifier() {
        assertTrue(HandoffRules.isReturnParam("returnTo"));
        assertTrue(HandoffRules.isReturnParam("callbackUrl"));
        assertTrue(HandoffRules.isReturnParam("next_url"));
        assertTrue(HandoffRules.isReturnParam("a" + "b".repeat(31)));

        for (String name : new String[] {null, "", "1next", "_next", "return-to", "return to", "a" + "b".repeat(32), "retürn"}) {
            assertFalse(HandoffRules.isReturnParam(name), "must refuse return parameter " + name);
        }
    }

    @Test
    void aRequestedPathIsRelativeToTheTarget() {
        for (String path : new String[] {
                "/",
                "/3f1c2e9a-8a3c-4c8e-9c4e-0a3b1f2e7d6c",
                "/forms/abc?step=2&lang=tr",
                "/profile#security",
                "/search?q=sky%20lab",
                "/" + "a".repeat(511),
        }) {
            assertTrue(HandoffRules.isRelativePath(path), "must accept " + path);
        }
    }

    @Test
    void refusesPathsThatCouldLeaveTheTargetOrSmuggleSomething() {
        for (String path : new String[] {
                null,
                "",
                "forms/abc",
                "https://evil.example/",
                "javascript:alert(1)",
                "//evil.example",
                "/\\evil.example",
                "/a//b",
                "/../admin",
                "/a/..",
                "/a/../b",
                "/%2F%2Fevil.example",
                "/%2fevil",
                "/%5Cevil",
                "/%2e%2e/admin",
                "/a%0d%0aSet-Cookie:x",
                "/a%7F",
                "/a b",
                "/a\tb",
                "/a\nb",
                "/ş",
                "/" + "a".repeat(512),
        }) {
            assertFalse(HandoffRules.isRelativePath(path), "must refuse " + path);
        }
    }
}
