package com.skylab.handoff;

import org.junit.jupiter.api.Test;
import org.keycloak.models.ClientModel;

import java.util.HashMap;
import java.util.Map;
import java.util.Optional;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class HandoffTargetTest {

    @Test
    void anEnabledClientLandsOnItsSignInEntryWithThePathAsTheReturnParameter() {
        ClientModel accountCenter = client("account-center", "https://my.yildizskylab.com",
                Map.of("sky.handoff.enabled", "true",
                        "sky.handoff.signInPath", "/api/auth/login",
                        "sky.handoff.returnParam", "returnTo"));
        ClientModel forms = client("skyforms", "https://forms.yildizskylab.com/",
                Map.of("sky.handoff.enabled", "true",
                        "sky.handoff.signInPath", "/auth/signin",
                        "sky.handoff.returnParam", "callbackUrl"));

        assertEquals("https://my.yildizskylab.com/api/auth/login?returnTo=%2F",
                HandoffTarget.of(accountCenter).orElseThrow().entry("/"));
        assertEquals("https://forms.yildizskylab.com/auth/signin?callbackUrl=%2F3f1c2e9a-8a3c",
                HandoffTarget.of(forms).orElseThrow().entry("/3f1c2e9a-8a3c"));
        assertEquals("https://forms.yildizskylab.com/auth/signin?callbackUrl=%2Fa%3Fstep%3D2%26lang%3Dtr%23top",
                HandoffTarget.of(forms).orElseThrow().entry("/a?step=2&lang=tr#top"),
                "the whole path, query and fragment included, is one encoded parameter value");
        assertEquals("skyforms", HandoffTarget.of(forms).orElseThrow().clientId());
    }

    @Test
    void aClientIsNotATargetUnlessEnabledIsExactlyTrue() {
        for (String enabled : new String[] {null, "", "false", "TRUE", "yes", "1"}) {
            Map<String, String> attributes = new HashMap<>(Map.of(
                    "sky.handoff.signInPath", "/api/auth/login",
                    "sky.handoff.returnParam", "returnTo"));
            if (enabled != null) {
                attributes.put("sky.handoff.enabled", enabled);
            }
            assertEquals(Optional.empty(),
                    HandoffTarget.of(client("account-center", "https://my.yildizskylab.com", attributes)),
                    "enabled=" + enabled + " must not make a target");
        }
    }

    @Test
    void aDisabledClientOrAnInvalidAttributeOrOriginIsNotATarget() {
        Map<String, String> valid = Map.of(
                "sky.handoff.enabled", "true",
                "sky.handoff.signInPath", "/api/auth/login",
                "sky.handoff.returnParam", "returnTo");

        ClientModel disabledClient = client("account-center", "https://my.yildizskylab.com", valid);
        when(disabledClient.isEnabled()).thenReturn(false);
        assertTrue(HandoffTarget.of(disabledClient).isEmpty(), "a disabled Keycloak client");

        assertTrue(HandoffTarget.of(client("outside", "https://example.com", valid)).isEmpty(), "foreign origin");
        assertTrue(HandoffTarget.of(client("plain", "http://my.yildizskylab.com", valid)).isEmpty(), "http origin");
        assertTrue(HandoffTarget.of(client("none", null, valid)).isEmpty(), "no root URL");

        Map<String, String> badPath = new HashMap<>(valid);
        badPath.put("sky.handoff.signInPath", "//evil.example/login");
        assertTrue(HandoffTarget.of(client("account-center", "https://my.yildizskylab.com", badPath)).isEmpty(),
                "a sign-in path that leaves the origin");

        Map<String, String> missingParam = new HashMap<>(valid);
        missingParam.remove("sky.handoff.returnParam");
        assertTrue(HandoffTarget.of(client("account-center", "https://my.yildizskylab.com", missingParam)).isEmpty(),
                "no return parameter");

        Map<String, String> badParam = new HashMap<>(valid);
        badParam.put("sky.handoff.returnParam", "return to");
        assertTrue(HandoffTarget.of(client("account-center", "https://my.yildizskylab.com", badParam)).isEmpty(),
                "a return parameter that is not an identifier");

        assertTrue(HandoffTarget.of(null).isEmpty(), "no client");
    }

    static ClientModel client(String clientId, String rootUrl, Map<String, String> attributes) {
        ClientModel client = mock(ClientModel.class);
        when(client.getClientId()).thenReturn(clientId);
        when(client.getRootUrl()).thenReturn(rootUrl);
        when(client.isEnabled()).thenReturn(true);
        when(client.getAttribute(anyString())).thenAnswer(invocation -> attributes.get(invocation.<String>getArgument(0)));
        when(client.getAttributes()).thenReturn(attributes);
        return client;
    }
}
