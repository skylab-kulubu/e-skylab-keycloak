package com.skylab.account;

import com.fasterxml.jackson.databind.JsonNode;
import org.keycloak.util.JsonSerialization;

import java.io.IOException;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.List;
import java.util.Set;

/**
 * Strict JSON request parsing: an object with exactly the declared fields and types. Parsing
 * failures never echo the body (it may contain a password) and map to {@code invalid_request}.
 */
final class RequestBody {

    static final int MAX_BYTES = 8 * 1024;

    private final JsonNode root;
    private final String prefix;

    private RequestBody(JsonNode root, String prefix) {
        this.root = root;
        this.prefix = prefix;
    }

    static RequestBody parse(String body, Set<String> allowedFields) {
        return parse(body, allowedFields, MAX_BYTES);
    }

    static RequestBody parse(String body, Set<String> allowedFields, int maxBytes) {
        if (body == null || body.isBlank() || body.length() > maxBytes) {
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
        RequestBody parsed = new RequestBody(root, "");
        parsed.requireOnly(allowedFields);
        return parsed;
    }

    String requireString(String field, int minLength, int maxLength) {
        JsonNode node = root.get(field);
        if (node == null || !node.isTextual()) {
            throw invalid(field);
        }
        String value = node.textValue();
        if (value.length() < minLength || value.length() > maxLength) {
            throw invalid(field);
        }
        return value;
    }

    String requireTrimmedString(String field, int minLength, int maxLength) {
        String value = requireString(field, 0, maxLength).trim();
        if (value.length() < minLength) {
            throw invalid(field);
        }
        return value;
    }

    /** A string field that may be absent or {@code null}; when present it must fit the bounds. */
    String optionalString(String field, int minLength, int maxLength) {
        JsonNode node = root.get(field);
        if (node == null || node.isNull()) {
            return null;
        }
        return requireString(field, minLength, maxLength);
    }

    /** Whether the field is present with a non-null value. */
    boolean has(String field) {
        JsonNode node = root.get(field);
        return node != null && !node.isNull();
    }

    boolean requireBoolean(String field) {
        JsonNode node = root.get(field);
        if (node == null || !node.isBoolean()) {
            throw invalid(field);
        }
        return node.booleanValue();
    }

    /** A nested object with exactly the declared fields; its own field errors carry the dotted path. */
    RequestBody requireObject(String field, Set<String> allowedFields) {
        JsonNode node = root.get(field);
        if (node == null || !node.isObject()) {
            throw invalid(field);
        }
        RequestBody nested = new RequestBody(node, prefix + field + ".");
        nested.requireOnly(allowedFields);
        return nested;
    }

    /**
     * An array of strings that may be absent or {@code null}: every element must be a non-empty
     * string within the bounds and the array must not exceed {@code maxItems}.
     */
    List<String> optionalStringList(String field, int maxItems, int maxLength) {
        JsonNode node = root.get(field);
        if (node == null || node.isNull()) {
            return List.of();
        }
        if (!node.isArray() || node.size() > maxItems) {
            throw invalid(field);
        }
        List<String> values = new ArrayList<>(node.size());
        for (JsonNode element : node) {
            if (!element.isTextual() || element.textValue().isEmpty() || element.textValue().length() > maxLength) {
                throw invalid(field);
            }
            values.add(element.textValue());
        }
        return values;
    }

    private void requireOnly(Set<String> allowedFields) {
        for (Iterator<String> names = root.fieldNames(); names.hasNext(); ) {
            String name = names.next();
            if (!allowedFields.contains(name)) {
                throw invalid(name);
            }
        }
    }

    /** The {@code invalid_request} problem for a field of this (possibly nested) object. */
    ProblemException invalid(String field) {
        return Problems.invalidRequest(prefix + field).exception();
    }
}
