package com.skylab.account;

import org.junit.jupiter.api.Test;

import java.util.Set;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;

class RequestBodyTest {

    private static final Set<String> FIELDS = Set.of("newPassword", "logoutOtherSessions");

    @Test
    void readsDeclaredFieldsWithTheirTypes() {
        RequestBody body = RequestBody.parse(
                "{\"newPassword\":\"correct horse\",\"logoutOtherSessions\":false}", FIELDS);

        assertEquals("correct horse", body.requireString("newPassword", 1, 1024));
        assertFalse(body.requireBoolean("logoutOtherSessions"));
    }

    @Test
    void rejectsUnknownFieldsMissingFieldsAndWrongTypes() {
        assertEquals("logoutOtherSession", invalidField(
                "{\"newPassword\":\"x\",\"logoutOtherSession\":true}", FIELDS, body -> { }));
        assertEquals("logoutOtherSessions", invalidField(
                "{\"newPassword\":\"x\"}", FIELDS, body -> body.requireBoolean("logoutOtherSessions")));
        assertEquals("logoutOtherSessions", invalidField(
                "{\"newPassword\":\"x\",\"logoutOtherSessions\":\"true\"}", FIELDS,
                body -> body.requireBoolean("logoutOtherSessions")));
        assertEquals("newPassword", invalidField(
                "{\"newPassword\":42,\"logoutOtherSessions\":true}", FIELDS,
                body -> body.requireString("newPassword", 1, 1024)));
        assertEquals("newPassword", invalidField(
                "{\"newPassword\":\"\",\"logoutOtherSessions\":true}", FIELDS,
                body -> body.requireString("newPassword", 1, 1024)));
    }

    @Test
    void rejectsNonObjectsMalformedJsonAndOversizedBodies() {
        assertThrows(ProblemException.class, () -> RequestBody.parse(null, FIELDS));
        assertThrows(ProblemException.class, () -> RequestBody.parse("", FIELDS));
        assertThrows(ProblemException.class, () -> RequestBody.parse("[]", FIELDS));
        assertThrows(ProblemException.class, () -> RequestBody.parse("\"text\"", FIELDS));
        assertThrows(ProblemException.class, () -> RequestBody.parse("{\"newPassword\":", FIELDS));
        String oversized = "{\"newPassword\":\"" + "x".repeat(RequestBody.MAX_BYTES) + "\"}";
        assertThrows(ProblemException.class, () -> RequestBody.parse(oversized, FIELDS));
    }

    @Test
    void trimsWhereAskedAndKeepsPasswordsVerbatim() {
        RequestBody body = RequestBody.parse("{\"code\":\" 123456 \",\"label\":\"  \"}", Set.of("code", "label"));

        assertEquals("123456", body.requireTrimmedString("code", 1, 16));
        assertEquals(" 123456 ", body.requireString("code", 1, 16));
        assertThrows(ProblemException.class, () -> body.requireTrimmedString("label", 1, 64));
    }

    @Test
    void readsNestedObjectsOptionalFieldsAndStringLists() {
        RequestBody body = RequestBody.parse(
                "{\"response\":{\"clientDataJSON\":\"e30\",\"transports\":[\"internal\"],\"userHandle\":null},\"label\":null}",
                Set.of("response", "label"));

        RequestBody response = body.requireObject("response", Set.of("clientDataJSON", "transports", "userHandle"));
        assertEquals("e30", response.requireString("clientDataJSON", 1, 16));
        assertEquals(java.util.List.of("internal"), response.optionalStringList("transports", 8, 32));
        assertEquals(java.util.List.of(), response.optionalStringList("missing", 8, 32));
        assertFalse(response.has("userHandle"));
        assertNull(response.optionalString("userHandle", 1, 16));
        assertNull(body.optionalString("label", 1, 16));
        assertFalse(body.has("label"));

        assertEquals("response.extra", invalidField("{\"response\":{\"extra\":1}}", Set.of("response"),
                parsed -> parsed.requireObject("response", Set.of("clientDataJSON"))));
        assertEquals("response.transports", invalidField("{\"response\":{\"transports\":[1]}}", Set.of("response"),
                parsed -> parsed.requireObject("response", Set.of("transports")).optionalStringList("transports", 8, 32)));
        assertEquals("response.transports", invalidField("{\"response\":{\"transports\":[\"a\",\"b\",\"c\"]}}", Set.of("response"),
                parsed -> parsed.requireObject("response", Set.of("transports")).optionalStringList("transports", 2, 32)));
        assertEquals("response", invalidField("{\"response\":\"text\"}", Set.of("response"),
                parsed -> parsed.requireObject("response", Set.of())));
    }

    @Test
    void honoursALargerSizeLimitWhenAnEndpointAllowsOne() {
        String large = "{\"blob\":\"" + "x".repeat(RequestBody.MAX_BYTES) + "\"}";

        assertThrows(ProblemException.class, () -> RequestBody.parse(large, Set.of("blob")));
        assertEquals(RequestBody.MAX_BYTES,
                RequestBody.parse(large, Set.of("blob"), 64 * 1024).requireString("blob", 1, 64 * 1024).length());
    }

    private static String invalidField(String json, Set<String> fields, java.util.function.Consumer<RequestBody> read) {
        ProblemException exception = assertThrows(ProblemException.class,
                () -> read.accept(RequestBody.parse(json, fields)));
        assertEquals("invalid_request", exception.problem().code());
        return (String) exception.problem().extensions().get("field");
    }
}
