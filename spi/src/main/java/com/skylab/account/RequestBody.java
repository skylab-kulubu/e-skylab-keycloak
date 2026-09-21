package com.skylab.account;

import com.fasterxml.jackson.databind.JsonNode;
import org.keycloak.util.JsonSerialization;

import java.io.IOException;
import java.util.Iterator;
import java.util.Set;

/**
 * Strict JSON request parsing: an object with exactly the declared fields and types. Parsing
 * failures never echo the body (it may contain a password) and map to {@code invalid_request}.
 */
final class RequestBody {

    static final int MAX_BYTES = 8 * 1024;

    private final JsonNode root;

    private RequestBody(JsonNode root) {
        this.root = root;
    }

    static RequestBody parse(String body, Set<String> allowedFields) {
        if (body == null || body.isBlank() || body.length() > MAX_BYTES) {
            throw Problems.invalidRequest(null).exception();
        }
        final JsonNode root;
        try {
            root = JsonSerialization.mapper.readTree(body);
        } catch (IOException | RuntimeException exception) {
            throw Problems.invalidRequest(null).exception();
        }
        if (root == null || !root.isObject()) {
            throw Problems.invalidRequest(null).exception();
        }
        for (Iterator<String> names = root.fieldNames(); names.hasNext(); ) {
            String name = names.next();
            if (!allowedFields.contains(name)) {
                throw Problems.invalidRequest(name).exception();
            }
        }
        return new RequestBody(root);
    }

    String requireString(String field, int minLength, int maxLength) {
        JsonNode node = root.get(field);
        if (node == null || !node.isTextual()) {
            throw Problems.invalidRequest(field).exception();
        }
        String value = node.textValue();
        if (value.length() < minLength || value.length() > maxLength) {
            throw Problems.invalidRequest(field).exception();
        }
        return value;
    }

    String requireTrimmedString(String field, int minLength, int maxLength) {
        String value = requireString(field, 0, maxLength).trim();
        if (value.length() < minLength) {
            throw Problems.invalidRequest(field).exception();
        }
        return value;
    }

    boolean requireBoolean(String field) {
        JsonNode node = root.get(field);
        if (node == null || !node.isBoolean()) {
            throw Problems.invalidRequest(field).exception();
        }
        return node.booleanValue();
    }
}
