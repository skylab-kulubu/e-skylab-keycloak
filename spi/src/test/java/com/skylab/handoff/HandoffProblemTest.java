package com.skylab.handoff;

import com.fasterxml.jackson.databind.JsonNode;
import org.junit.jupiter.api.Test;
import org.keycloak.util.JsonSerialization;

import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class HandoffProblemTest {

    @Test
    void aProblemIsAnRfc7807DocumentWithAStableCodeAndATurkishDetail() throws Exception {
        HandoffProblem problem = HandoffProblem.invalidTarget();
        JsonNode body = JsonSerialization.mapper.readTree(problem.body());

        assertEquals(400, problem.status());
        assertEquals("tag:yildizskylab.com,2026:sky-handoff:invalid_target", body.get("type").textValue());
        assertEquals("invalid_target", body.get("code").textValue());
        assertEquals(400, body.get("status").intValue());
        assertEquals("Bu siteye uygulamadan geçiş açık değil.", body.get("detail").textValue());
        assertEquals(5, body.size(), "nothing else leaks into the document");
    }

    @Test
    void theMintContractCodesAreStable() {
        assertEquals("invalid_path", HandoffProblem.invalidPath().code());
        assertEquals("invalid_request", HandoffProblem.invalidRequest().code());

        HandoffProblem unauthorized = HandoffProblem.invalidToken("e-skylab");
        assertEquals(401, unauthorized.status());
        assertEquals("invalid_token", unauthorized.code());
        assertEquals("Bearer realm=\"e-skylab\", error=\"invalid_token\"", unauthorized.headers().get("WWW-Authenticate"));

        HandoffProblem limited = HandoffProblem.rateLimited(42);
        assertEquals(429, limited.status());
        assertEquals("rate_limited", limited.code());
        assertEquals("42", limited.headers().get("Retry-After"));
    }

    @Test
    void everyCatalogueEntryHasACodeATitleAndATurkishDetail() {
        for (HandoffProblem problem : List.of(
                HandoffProblem.invalidToken("r"), HandoffProblem.invalidRequest(), HandoffProblem.invalidTarget(),
                HandoffProblem.invalidPath(), HandoffProblem.rateLimited(1), HandoffProblem.internalError())) {
            assertTrue(problem.code().matches("^[a-z_]+$"), problem.code());
            assertFalse(problem.title().isBlank(), problem.code());
            assertFalse(problem.detail().isBlank(), problem.code());
            assertTrue(problem.status() >= 400 && problem.status() <= 599, problem.code());
        }
    }
}
