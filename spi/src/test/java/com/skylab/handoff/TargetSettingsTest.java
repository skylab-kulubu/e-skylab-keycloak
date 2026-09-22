package com.skylab.handoff;

import com.fasterxml.jackson.databind.JsonNode;
import org.junit.jupiter.api.Test;
import org.keycloak.models.ClientModel;
import org.mockito.ArgumentCaptor;

import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.atLeast;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class TargetSettingsTest {

    private static final Set<String> HANDOFF_ATTRIBUTES =
            Set.of("sky.handoff.enabled", "sky.handoff.signInPath", "sky.handoff.returnParam");

    @Test
    void readsTheThreeSettingsOnly() {
        TargetSettings settings = TargetSettings.parse(
                "{\"enabled\":true,\"signInPath\":\"/auth/signin\",\"returnParam\":\"callbackUrl\"}");
        assertEquals(new TargetSettings(true, "/auth/signin", "callbackUrl"), settings);

        assertEquals(new TargetSettings(false, null, null), TargetSettings.parse("{\"enabled\":false}"));
        assertEquals(new TargetSettings(false, null, null),
                TargetSettings.parse("{\"enabled\":false,\"signInPath\":null,\"returnParam\":null}"));
    }

    @Test
    void anythingOutsideTheContractIsInvalidRequest() {
        for (String body : new String[] {
                null, "", "[]", "not json", "{}", "{\"enabled\":\"true\"}",
                "{\"enabled\":true,\"signInPath\":\"/a\",\"returnParam\":\"x\",\"redirectUris\":[\"https://evil\"]}",
                "{\"enabled\":false,\"rootUrl\":\"https://evil.example\"}",
        }) {
            assertEquals("invalid_request", code(() -> TargetSettings.parse(body)), "must refuse " + body);
        }
    }

    @Test
    void theEntryFieldsMustBeValidAndPresentForAnEnabledTarget() {
        assertEquals("invalid_sign_in_path", code(() -> TargetSettings.parse(
                "{\"enabled\":true,\"signInPath\":\"//evil.example/login\",\"returnParam\":\"callbackUrl\"}")));
        assertEquals("invalid_sign_in_path", code(() -> TargetSettings.parse(
                "{\"enabled\":true,\"signInPath\":\"/auth/signin?next=/\",\"returnParam\":\"callbackUrl\"}")));
        assertEquals("invalid_sign_in_path", code(() -> TargetSettings.parse(
                "{\"enabled\":true,\"returnParam\":\"callbackUrl\"}")));
        assertEquals("invalid_sign_in_path", code(() -> TargetSettings.parse(
                "{\"enabled\":false,\"signInPath\":\"/a/../b\"}")), "a stored value must be valid even when off");
        assertEquals("invalid_return_param", code(() -> TargetSettings.parse(
                "{\"enabled\":true,\"signInPath\":\"/auth/signin\",\"returnParam\":\"call back\"}")));
        assertEquals("invalid_return_param", code(() -> TargetSettings.parse(
                "{\"enabled\":true,\"signInPath\":\"/auth/signin\"}")));
        assertEquals("invalid_sign_in_path", code(() -> TargetSettings.parse(
                "{\"enabled\":true,\"signInPath\":42,\"returnParam\":\"callbackUrl\"}")));
    }

    @Test
    void enablingRequiresTheOriginRuleAndDisablingDoesNot() {
        TargetSettings on = new TargetSettings(true, "/auth/signin", "callbackUrl");
        TargetSettings off = new TargetSettings(false, "/auth/signin", "callbackUrl");

        on.requireAllowedFor(client("skyforms", "https://forms.yildizskylab.com", Map.of()));
        assertEquals("origin_not_allowed",
                code(() -> on.requireAllowedFor(client("outside", "https://example.com", Map.of()))));
        assertEquals("origin_not_allowed",
                code(() -> on.requireAllowedFor(client("no-root", null, Map.of()))));
        off.requireAllowedFor(client("outside", "https://example.com", Map.of()));
    }

    @Test
    void writesOnlyTheThreeHandoffAttributes() {
        Map<String, String> attributes = new HashMap<>(Map.of(
                "pkce.code.challenge.method", "S256",
                "sky.handoff.signInPath", "/old"));
        ClientModel client = client("skyforms", "https://forms.yildizskylab.com", attributes);

        new TargetSettings(true, "/auth/signin", "callbackUrl").writeTo(client);
        assertEquals("true", attributes.get("sky.handoff.enabled"));
        assertEquals("/auth/signin", attributes.get("sky.handoff.signInPath"));
        assertEquals("callbackUrl", attributes.get("sky.handoff.returnParam"));

        new TargetSettings(false, "/auth/signin", null).writeTo(client);
        assertFalse(attributes.containsKey("sky.handoff.enabled"), "off is an absent attribute");
        assertFalse(attributes.containsKey("sky.handoff.returnParam"), "null removes the attribute");
        assertEquals("/auth/signin", attributes.get("sky.handoff.signInPath"));
        assertEquals("S256", attributes.get("pkce.code.challenge.method"), "other attributes are untouched");

        ArgumentCaptor<String> written = ArgumentCaptor.forClass(String.class);
        verify(client, atLeast(1)).setAttribute(written.capture(), anyString());
        ArgumentCaptor<String> removed = ArgumentCaptor.forClass(String.class);
        verify(client, atLeast(1)).removeAttribute(removed.capture());
        assertTrue(HANDOFF_ATTRIBUTES.containsAll(written.getAllValues()));
        assertTrue(HANDOFF_ATTRIBUTES.containsAll(removed.getAllValues()));
        verify(client, never()).setRedirectUris(org.mockito.ArgumentMatchers.any());
        verify(client, never()).setRootUrl(anyString());
        verify(client, never()).setSecret(anyString());
    }

    @Test
    void describesAClientForTheSuperadminPage() {
        ClientModel forms = client("skyforms", "https://forms.yildizskylab.com", Map.of(
                "sky.handoff.enabled", "true",
                "sky.handoff.signInPath", "/auth/signin",
                "sky.handoff.returnParam", "callbackUrl",
                "client.secret.rotation", "never shown"));
        when(forms.getName()).thenReturn("SKY LAB Forms");
        JsonNode view = TargetSettings.describe(forms);

        assertEquals("skyforms", view.get("clientId").textValue());
        assertEquals("SKY LAB Forms", view.get("name").textValue());
        assertEquals("https://forms.yildizskylab.com", view.get("rootUrl").textValue());
        assertTrue(view.get("originAllowed").booleanValue());
        assertTrue(view.get("clientEnabled").booleanValue());
        assertTrue(view.get("enabled").booleanValue());
        assertEquals("/auth/signin", view.get("signInPath").textValue());
        assertEquals("callbackUrl", view.get("returnParam").textValue());
        assertEquals(List.of("clientEnabled", "clientId", "enabled", "name", "originAllowed", "returnParam",
                "rootUrl", "signInPath"), sortedNames(view));

        JsonNode outside = TargetSettings.describe(client("outside", "https://example.com", Map.of()));
        assertFalse(outside.get("originAllowed").booleanValue());
        assertFalse(outside.get("enabled").booleanValue());
        assertTrue(outside.get("signInPath").isNull());
    }

    @Test
    void auditValuesNameEveryField() {
        assertEquals("{\"enabled\":true,\"signInPath\":\"/auth/signin\",\"returnParam\":\"callbackUrl\"}",
                new TargetSettings(true, "/auth/signin", "callbackUrl").toJson());
        assertEquals("{\"enabled\":false,\"signInPath\":null,\"returnParam\":null}",
                new TargetSettings(false, null, null).toJson());
    }

    private static List<String> sortedNames(JsonNode node) {
        java.util.ArrayList<String> names = new java.util.ArrayList<>();
        node.fieldNames().forEachRemaining(names::add);
        names.sort(null);
        return names;
    }

    private static String code(Runnable action) {
        return assertThrows(HandoffProblem.Raised.class, action::run).problem().code();
    }

    private static ClientModel client(String clientId, String rootUrl, Map<String, String> initial) {
        Map<String, String> attributes = initial instanceof HashMap<String, String> mutable ? mutable : new HashMap<>(initial);
        ClientModel client = mock(ClientModel.class);
        when(client.getClientId()).thenReturn(clientId);
        when(client.getRootUrl()).thenReturn(rootUrl);
        when(client.isEnabled()).thenReturn(true);
        when(client.getAttribute(anyString())).thenAnswer(invocation -> attributes.get(invocation.<String>getArgument(0)));
        doAnswer(invocation -> attributes.put(invocation.getArgument(0), invocation.getArgument(1)))
                .when(client).setAttribute(anyString(), anyString());
        doAnswer(invocation -> attributes.remove(invocation.<String>getArgument(0)))
                .when(client).removeAttribute(anyString());
        return client;
    }
}
