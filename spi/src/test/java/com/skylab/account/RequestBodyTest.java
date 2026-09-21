package com.skylab.account;

import org.junit.jupiter.api.Test;

import java.util.Set;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
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

    private static String invalidField(String json, Set<String> fields, java.util.function.Consumer<RequestBody> read) {
        ProblemException exception = assertThrows(ProblemException.class,
                () -> read.accept(RequestBody.parse(json, fields)));
        assertEquals("invalid_request", exception.problem().code());
        return (String) exception.problem().extensions().get("field");
    }
}
