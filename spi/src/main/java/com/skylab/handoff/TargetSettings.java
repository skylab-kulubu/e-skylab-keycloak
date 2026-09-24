package com.skylab.handoff;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import org.keycloak.models.ClientModel;
import org.keycloak.util.JsonSerialization;

import java.io.IOException;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;

/**
 * The three Handoff target settings of one client as superadmin edits them
 * ({@code PUT v1/admin/targets/{clientId}}): on/off, sign-in entry path, return parameter.
 * They are the only client data this provider ever writes; "off" is an absent
 * {@code sky.handoff.enabled} attribute and a {@code null} field removes its attribute.
 */
record TargetSettings(boolean enabled, String signInPath, String returnParam) {

    static final int MAX_BYTES = 2 * 1024;
    private static final Set<String> FIELDS = Set.of("enabled", "signInPath", "returnParam");

    /** The current settings of a client. */
    static TargetSettings of(ClientModel client) {
        return new TargetSettings(
                "true".equals(client.getAttribute(HandoffTarget.ENABLED_ATTRIBUTE)),
                client.getAttribute(HandoffTarget.SIGN_IN_PATH_ATTRIBUTE),
                client.getAttribute(HandoffTarget.RETURN_PARAM_ATTRIBUTE));
    }

    /**
     * Exactly {@code {"enabled": bool, "signInPath": string|null, "returnParam": string|null}};
     * both entry fields are required to switch a target on, and a value that is present must be
     * valid either way.
     */
    static TargetSettings parse(String body) {
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
        JsonNode enabled = root.get("enabled");
        if (enabled == null || !enabled.isBoolean()) {
            throw HandoffProblem.invalidRequest().exception();
        }
        String signInPath = optionalText(root.get("signInPath"), HandoffProblem.invalidSignInPath());
        if ((signInPath == null && enabled.booleanValue()) || (signInPath != null && !HandoffRules.isSignInPath(signInPath))) {
            throw HandoffProblem.invalidSignInPath().exception();
        }
        String returnParam = optionalText(root.get("returnParam"), HandoffProblem.invalidReturnParam());
        if ((returnParam == null && enabled.booleanValue()) || (returnParam != null && !HandoffRules.isReturnParam(returnParam))) {
            throw HandoffProblem.invalidReturnParam().exception();
        }
        return new TargetSettings(enabled.booleanValue(), signInPath, returnParam);
    }

    /** Only a client whose root URL satisfies the origin rule may be switched on. */
    void requireAllowedFor(ClientModel client) {
        if (enabled && HandoffRules.origin(client.getRootUrl()).isEmpty()) {
            throw HandoffProblem.originNotAllowed().exception();
        }
    }

    /** Writes the three attributes and nothing else. */
    void writeTo(ClientModel client) {
        write(client, HandoffTarget.ENABLED_ATTRIBUTE, enabled ? "true" : null);
        write(client, HandoffTarget.SIGN_IN_PATH_ATTRIBUTE, signInPath);
        write(client, HandoffTarget.RETURN_PARAM_ATTRIBUTE, returnParam);
    }

    /** The settings as the admin event representation. */
    Map<String, Object> toMap() {
        Map<String, Object> map = new LinkedHashMap<>();
        map.put("enabled", enabled);
        map.put("signInPath", signInPath);
        map.put("returnParam", returnParam);
        return map;
    }

    /** The compact JSON of the settings, for the audit event details. */
    String toJson() {
        ObjectNode node = JsonSerialization.mapper.createObjectNode();
        node.put("enabled", enabled);
        node.put("signInPath", signInPath);
        node.put("returnParam", returnParam);
        return node.toString();
    }

    /**
     * One row of {@code GET v1/admin/targets}: the client's identity, its root URL and whether it
     * satisfies the origin rule, whether the Keycloak client is enabled, and the three settings.
     */
    static ObjectNode describe(ClientModel client) {
        TargetSettings settings = of(client);
        ObjectNode node = JsonSerialization.mapper.createObjectNode();
        node.put("clientId", client.getClientId());
        node.put("name", client.getName());
        node.put("rootUrl", client.getRootUrl());
        node.put("originAllowed", HandoffRules.origin(client.getRootUrl()).isPresent());
        node.put("clientEnabled", client.isEnabled());
        node.put("enabled", settings.enabled());
        node.put("signInPath", settings.signInPath());
        node.put("returnParam", settings.returnParam());
        return node;
    }

    private static String optionalText(JsonNode node, HandoffProblem problem) {
        if (node == null || node.isNull()) {
            return null;
        }
        if (!node.isTextual()) {
            throw problem.exception();
        }
        return node.textValue();
    }

    private static void write(ClientModel client, String attribute, String value) {
        if (value == null) {
            client.removeAttribute(attribute);
        } else {
            client.setAttribute(attribute, value);
        }
    }
}
