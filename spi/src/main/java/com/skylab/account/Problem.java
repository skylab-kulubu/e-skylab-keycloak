package com.skylab.account;

import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import jakarta.ws.rs.core.HttpHeaders;
import jakarta.ws.rs.core.Response;
import org.keycloak.util.JsonSerialization;

import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * An RFC 7807 problem: a stable English {@code code} for the Account Center BFF and a
 * Turkish {@code detail} for the person. The response never carries secrets.
 */
final class Problem {

    static final String MEDIA_TYPE = "application/problem+json";
    static final String TYPE_PREFIX = "tag:yildizskylab.com,2026:sky-account:";

    private final int status;
    private final String code;
    private final String title;
    private final String detail;
    private final Map<String, Object> extensions;
    private final Map<String, String> headers;

    Problem(int status, String code, String title, String detail) {
        this(status, code, title, detail, Map.of(), Map.of());
    }

    private Problem(
            int status,
            String code,
            String title,
            String detail,
            Map<String, Object> extensions,
            Map<String, String> headers) {
        this.status = status;
        this.code = code;
        this.title = title;
        this.detail = detail;
        this.extensions = Collections.unmodifiableMap(new LinkedHashMap<>(extensions));
        this.headers = Collections.unmodifiableMap(new LinkedHashMap<>(headers));
    }

    Problem withExtension(String name, Object value) {
        Map<String, Object> next = new LinkedHashMap<>(extensions);
        next.put(name, value);
        return new Problem(status, code, title, detail, next, headers);
    }

    Problem withHeader(String name, String value) {
        Map<String, String> next = new LinkedHashMap<>(headers);
        next.put(name, value);
        return new Problem(status, code, title, detail, extensions, next);
    }

    int status() {
        return status;
    }

    String code() {
        return code;
    }

    String detail() {
        return detail;
    }

    Map<String, Object> extensions() {
        return extensions;
    }

    Map<String, String> headers() {
        return headers;
    }

    ProblemException exception() {
        return new ProblemException(this);
    }

    /** The {@code application/problem+json} document. */
    String body() {
        ObjectNode body = JsonSerialization.mapper.createObjectNode();
        body.put("type", TYPE_PREFIX + code);
        body.put("title", title);
        body.put("status", status);
        body.put("detail", detail);
        body.put("code", code);
        extensions.forEach((name, value) -> putValue(body, name, value));
        return body.toString();
    }

    Response toResponse() {
        Response.ResponseBuilder builder = Response.status(status)
                .type(MEDIA_TYPE)
                .header(HttpHeaders.CACHE_CONTROL, "no-store")
                .entity(body());
        headers.forEach(builder::header);
        return builder.build();
    }

    private static void putValue(ObjectNode node, String name, Object value) {
        if (value == null) {
            node.putNull(name);
        } else if (value instanceof Integer integer) {
            node.put(name, integer);
        } else if (value instanceof Long longValue) {
            node.put(name, longValue);
        } else if (value instanceof Boolean bool) {
            node.put(name, bool);
        } else if (value instanceof List<?> list) {
            ArrayNode array = node.putArray(name);
            for (Object item : list) {
                if (item instanceof Integer integer) {
                    array.add(integer);
                } else if (item instanceof Long longValue) {
                    array.add(longValue);
                } else {
                    array.add(String.valueOf(item));
                }
            }
        } else {
            node.put(name, String.valueOf(value));
        }
    }
}
