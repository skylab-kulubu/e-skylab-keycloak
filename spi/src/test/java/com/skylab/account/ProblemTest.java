package com.skylab.account;

import com.fasterxml.jackson.databind.JsonNode;
import org.junit.jupiter.api.Test;
import org.keycloak.util.JsonSerialization;

import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class ProblemTest {

    @Test
    void rendersRfc7807JsonWithTurkishDetailAndEnglishCode() throws Exception {
        Problem problem = Problems.unauthorized("e-skylab");
        JsonNode body = JsonSerialization.mapper.readTree(problem.body());

        assertEquals(401, problem.status());
        assertEquals("Bearer realm=\"e-skylab\", error=\"invalid_token\"", problem.headers().get("WWW-Authenticate"));
        assertEquals("tag:yildizskylab.com,2026:sky-account:unauthorized", body.get("type").textValue());
        assertEquals("Unauthorized", body.get("title").textValue());
        assertEquals(401, body.get("status").intValue());
        assertEquals("unauthorized", body.get("code").textValue());
        assertEquals("Bu istek için geçerli bir Hesap Merkezi oturumu gerekiyor.", body.get("detail").textValue());
        assertEquals(5, body.size(), "no extension leaks into the base document");
    }

    @Test
    void carriesRetryAfterAsHeaderAndExtension() throws Exception {
        Problem problem = Problems.rateLimited(42);
        JsonNode body = JsonSerialization.mapper.readTree(problem.body());

        assertEquals(429, problem.status());
        assertEquals("42", problem.headers().get("Retry-After"));
        assertEquals(42, body.get("retryAfter").intValue());
        assertEquals("rate_limited", body.get("code").textValue());
    }

    @Test
    void carriesPasswordPolicyKeyAndParameters() throws Exception {
        Problem problem = Problems.passwordPolicy(
                "invalidPasswordMinLengthMessage", List.of(12), "Geçersiz parola: en az 12 karakter olmalı.");
        JsonNode body = JsonSerialization.mapper.readTree(problem.body());

        assertEquals(400, problem.status());
        assertEquals("password_policy", body.get("code").textValue());
        assertEquals("invalidPasswordMinLengthMessage", body.get("policy").textValue());
        assertEquals(12, body.get("params").get(0).intValue());
        assertEquals("Geçersiz parola: en az 12 karakter olmalı.", body.get("detail").textValue());
    }

    @Test
    void everyCatalogueEntryHasACodeATitleAndATurkishDetail() {
        List<Problem> catalogue = List.of(
                Problems.sudoRequired(), Problems.sudoExpired(), Problems.invalidPassword(), Problems.invalidTotp(),
                Problems.temporarilyLocked(), Problems.permanentlyLocked(), Problems.invalidRequest("x"),
                Problems.passwordNotConfigured(), Problems.totpNotConfigured(), Problems.passwordRejected("Ret."),
                Problems.totpSetupExpired(), Problems.invalidTotpSetupCode(), Problems.duplicateLabel(),
                Problems.credentialNotFound(), Problems.invalidName("firstName"), Problems.nameLocked(),
                Problems.invalidUsername(), Problems.usernameTaken(),
                Problems.usernameCooldown(10, "2026-09-21T00:00:00Z"), Problems.unmanagedAttributesEnabled(),
                Problems.internalError());
        for (Problem problem : catalogue) {
            assertTrue(problem.code().matches("^[a-z_]+$"), problem.code());
            assertFalse(problem.detail().isBlank(), problem.code());
            assertTrue(problem.status() >= 400 && problem.status() <= 599, problem.code());
            assertTrue(problem.body().contains("\"code\":\"" + problem.code() + "\""), problem.code());
        }
    }

    @Test
    void theProblemCatalogueOfTheEmailEndpointsIsStable() {
        assertEquals(409, Problems.emailTaken().status());
        assertEquals("email_taken", Problems.emailTaken().code());
        assertEquals(409, Problems.emailNotVerified().status());
        assertEquals("email_not_verified", Problems.emailNotVerified().code());
        assertEquals(400, Problems.invalidEmailCode(3).status());
        assertEquals("invalid_email_code", Problems.invalidEmailCode(3).code());
        assertEquals(3, Problems.invalidEmailCode(3).extensions().get("attemptsLeft"));
        assertTrue(Problems.invalidEmailCode(3).detail().contains("3 deneme"), "the person must see how many tries are left");
        assertTrue(Problems.invalidEmailCode(0).detail().contains("Yeni bir kod iste"), "the last wrong try must say what to do next");
        assertTrue(Problems.emailNotVerified().detail().contains("kod"),
                "the personal address is proven with a code, not a link");
        assertTrue(!Problems.emailNotVerified().detail().contains("bağlantıyla"));
        assertTrue(Problems.emailNotVerified().detail().contains("YTÜ"),
                "a school address is proven by the YTÜ link");
        assertTrue(Problems.noFallbackEmail().detail().contains("YTÜ"),
                "the fallback also needs the YTÜ link, not only a school address");
        assertEquals(404, Problems.noPendingEmailChange().status());
        assertEquals("no_pending_email_change", Problems.noPendingEmailChange().code());
        assertEquals(409, Problems.noFallbackEmail().status());
        assertEquals("no_fallback_email", Problems.noFallbackEmail().code());
        assertEquals(503, Problems.emailNotSent().status());
        assertEquals("email_not_sent", Problems.emailNotSent().code());
    }
}
