package com.skylab.handoff;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

class MintRequestTest {

    @Test
    void readsTheTargetClientIdAndTheRelativePath() {
        MintRequest request = MintRequest.parse("{\"target\":\"skyforms\",\"path\":\"/3f1c2e9a\"}");

        assertEquals("skyforms", request.target());
        assertEquals("/3f1c2e9a", request.path());
    }

    @Test
    void aMissingOrMalformedTargetIsInvalidTarget() {
        assertEquals("invalid_target", code("{\"path\":\"/\"}"));
        assertEquals("invalid_target", code("{\"target\":\"\",\"path\":\"/\"}"));
        assertEquals("invalid_target", code("{\"target\":42,\"path\":\"/\"}"));
        assertEquals("invalid_target", code("{\"target\":null,\"path\":\"/\"}"));
        assertEquals("invalid_target", code("{\"target\":\"" + "a".repeat(256) + "\",\"path\":\"/\"}"));
    }

    @Test
    void aMissingOrUnsafePathIsInvalidPath() {
        assertEquals("invalid_path", code("{\"target\":\"skyforms\"}"));
        assertEquals("invalid_path", code("{\"target\":\"skyforms\",\"path\":\"//evil.example\"}"));
        assertEquals("invalid_path", code("{\"target\":\"skyforms\",\"path\":\"https://evil.example\"}"));
        assertEquals("invalid_path", code("{\"target\":\"skyforms\",\"path\":\"/a/../b\"}"));
        assertEquals("invalid_path", code("{\"target\":\"skyforms\",\"path\":[\"/\"]}"));
    }

    @Test
    void anythingThatIsNotExactlyTheContractIsInvalidRequest() {
        assertEquals("invalid_request", code(null));
        assertEquals("invalid_request", code(""));
        assertEquals("invalid_request", code("not json"));
        assertEquals("invalid_request", code("[]"));
        assertEquals("invalid_request", code("{\"target\":\"skyforms\",\"path\":\"/\",\"url\":\"https://evil.example\"}"));
        assertEquals("invalid_request", code("{\"target\":\"skyforms\",\"path\":\"" + "a".repeat(5000) + "\"}"));
    }

    private static String code(String body) {
        return assertThrows(HandoffProblem.Raised.class, () -> MintRequest.parse(body)).problem().code();
    }
}
