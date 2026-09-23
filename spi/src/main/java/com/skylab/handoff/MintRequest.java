package com.skylab.handoff;

import com.fasterxml.jackson.databind.JsonNode;
import org.keycloak.util.JsonSerialization;

import java.io.IOException;
import java.util.Iterator;
import java.util.Set;

/**
 * The body of {@code POST v1/handoffs}: exactly {@code {"target": <client_id>, "path": <relative path>}}.
 * Parsing never echoes the body.
 */
record MintRequest(String target, String path) {

    static final int MAX_BYTES = 4 * 1024;
    static final int MAX_TARGET_LENGTH = 255;
    private static final Set<String> FIELDS = Set.of("target", "path");

    static MintRequest parse(String body) {
        if (body == null || body.isBlank() || body.length() > MAX_BYTES) {
            throw HandoffProblem.invalidRequest().exception();
        }
        final JsonNode root;
        try {
            root = JsonSerialization.mapper.readTree(body);
        } catch (IOException | RuntimeException exception) {
            throw HandoffProblem.invalidRequest().exception();
        }
        if (root == null || !root.isObject()) {
            throw HandoffProblem.invalidRequest().exception();
        }
        for (Iterator<String> names = root.fieldNames(); names.hasNext(); ) {
            if (!FIELDS.contains(names.next())) {
                throw HandoffProblem.invalidRequest().exception();
            }
        }
        JsonNode target = root.get("target");
        if (target == null || !target.isTextual() || target.textValue().isEmpty()
                || target.textValue().length() > MAX_TARGET_LENGTH) {
            throw HandoffProblem.invalidTarget().exception();
        }
        JsonNode path = root.get("path");
        if (path == null || !path.isTextual() || !HandoffRules.isRelativePath(path.textValue())) {
            throw HandoffProblem.invalidPath().exception();
        }
        return new MintRequest(target.textValue(), path.textValue());
    }
}
