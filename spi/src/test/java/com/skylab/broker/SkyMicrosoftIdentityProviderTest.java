package com.skylab.broker;

import jakarta.ws.rs.core.UriBuilder;
import jakarta.ws.rs.ext.RuntimeDelegate;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.keycloak.broker.provider.AuthenticationRequest;
import org.keycloak.broker.provider.util.IdentityBrokerState;
import org.keycloak.models.KeycloakSession;
import org.keycloak.services.managers.AuthenticationManager;
import org.keycloak.sessions.AuthenticationSessionModel;
import org.keycloak.social.microsoft.MicrosoftIdentityProviderConfig;
import org.keycloak.social.microsoft.MicrosoftIdentityProviderFactory;

import java.net.URI;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.ServiceLoader;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class SkyMicrosoftIdentityProviderTest {

    /** The SPI's tests run without a JAX-RS runtime; Keycloak's code only needs these UriBuilder calls. */
    @BeforeAll
    static void recordingUriBuilder() {
        RuntimeDelegate delegate = mock(RuntimeDelegate.class);
        when(delegate.createUriBuilder()).thenAnswer(call -> recordingBuilder());
        RuntimeDelegate.setInstance(delegate);
    }

    private static UriBuilder recordingBuilder() {
        StringBuilder base = new StringBuilder();
        StringBuilder query = new StringBuilder();
        UriBuilder[] self = new UriBuilder[1];
        self[0] = mock(UriBuilder.class, call -> switch (call.getMethod().getName()) {
            case "uri" -> {
                base.setLength(0);
                base.append(call.<Object>getArgument(0));
                yield self[0];
            }
            case "queryParam" -> {
                for (Object value : (Object[]) call.getRawArguments()[1]) {
                    if (!query.isEmpty()) {
                        query.append('&');
                    }
                    query.append(encode(call.getArgument(0))).append('=').append(encode(String.valueOf(value)));
                }
                yield self[0];
            }
            case "replaceQuery" -> {
                query.setLength(0);
                query.append(call.<String>getArgument(0));
                yield self[0];
            }
            case "build" -> URI.create(base + (query.isEmpty() ? "" : "?" + query));
            default -> throw new UnsupportedOperationException(call.getMethod().getName());
        });
        return self[0];
    }

    private static String encode(String value) {
        return URLEncoder.encode(value, StandardCharsets.UTF_8);
    }

    @Test
    void forcedReauthenticationAsksMicrosoftForCredentials() {
        Map<String, String> authNotes = Map.of(AuthenticationManager.FORCED_REAUTHENTICATION, "true");

        assertEquals(List.of("login"), prompts(authorizationUrl(true, null, Map.of(), authNotes)));
    }

    @Test
    void anOrdinaryLoginSendsNoPrompt() {
        assertEquals(List.of(), prompts(authorizationUrl(true, null, Map.of(), Map.of())));
    }

    @Test
    void theClientsOwnPromptIsForwardedOnceAndUnchanged() {
        Map<String, String> authNotes = Map.of(AuthenticationManager.FORCED_REAUTHENTICATION, "true");

        assertEquals(List.of("login"), prompts(authorizationUrl(true, null, Map.of("prompt", "login"), authNotes)));
        assertEquals(List.of("select_account"),
                prompts(authorizationUrl(true, null, Map.of("prompt", "select_account"), authNotes)));
    }

    @Test
    void thePromptConfiguredOnTheIdentityProviderWins() {
        Map<String, String> authNotes = Map.of(AuthenticationManager.FORCED_REAUTHENTICATION, "true");

        assertEquals(List.of("consent"), prompts(authorizationUrl(true, "consent", Map.of(), authNotes)));
    }

    @Test
    void switchedOffItBehavesLikeKeycloaksOwnProvider() {
        Map<String, String> authNotes = Map.of(AuthenticationManager.FORCED_REAUTHENTICATION, "true");

        assertEquals(List.of(), prompts(authorizationUrl(false, null, Map.of(), authNotes)));
    }

    @Test
    void theRestOfTheRequestIsKeycloaksOwn() {
        Map<String, String> authNotes = Map.of(AuthenticationManager.FORCED_REAUTHENTICATION, "true");
        URI uri = authorizationUrl(true, null, Map.of(), authNotes);

        assertEquals("login.microsoftonline.com", uri.getHost());
        assertEquals("/ytu-tenant/oauth2/v2.0/authorize", uri.getPath());
        Map<String, List<String>> query = query(uri);
        assertEquals(List.of("app-id"), query.get("client_id"));
        assertEquals(List.of("code"), query.get("response_type"));
        assertEquals(List.of("https://e.example/realms/e-skylab/broker/OBS/endpoint"), query.get("redirect_uri"));
    }

    @Test
    void theSwitchIsOnUnlessSetToFalse() {
        assertTrue(SkyMicrosoftIdentityProviderFactory.resolveForwardReauthentication(null, Map.of()));
        assertTrue(SkyMicrosoftIdentityProviderFactory.resolveForwardReauthentication(" ", Map.of()));
        assertTrue(SkyMicrosoftIdentityProviderFactory.resolveForwardReauthentication(null,
                Map.of(SkyMicrosoftIdentityProviderFactory.FORWARD_REAUTHENTICATION_ENV, "TRUE")));
        assertFalse(SkyMicrosoftIdentityProviderFactory.resolveForwardReauthentication(null,
                Map.of(SkyMicrosoftIdentityProviderFactory.FORWARD_REAUTHENTICATION_ENV, "false")));
        assertFalse(SkyMicrosoftIdentityProviderFactory.resolveForwardReauthentication("false",
                Map.of(SkyMicrosoftIdentityProviderFactory.FORWARD_REAUTHENTICATION_ENV, "true")));
        assertThrows(IllegalStateException.class, () -> SkyMicrosoftIdentityProviderFactory
                .resolveForwardReauthentication(null,
                        Map.of(SkyMicrosoftIdentityProviderFactory.FORWARD_REAUTHENTICATION_ENV, "off")));
    }

    @Test
    void itReplacesKeycloaksMicrosoftProvider() {
        SkyMicrosoftIdentityProviderFactory factory = ServiceLoader
                .load(org.keycloak.broker.social.SocialIdentityProviderFactory.class).stream()
                .map(ServiceLoader.Provider::get)
                .filter(SkyMicrosoftIdentityProviderFactory.class::isInstance)
                .map(SkyMicrosoftIdentityProviderFactory.class::cast)
                .findFirst()
                .orElseThrow();

        assertEquals(MicrosoftIdentityProviderFactory.PROVIDER_ID, factory.getId());
        assertEquals("Microsoft", factory.getName());
        assertInstanceOf(MicrosoftIdentityProviderConfig.class, factory.createConfig());
    }

    private static URI authorizationUrl(boolean forward, String configuredPrompt, Map<String, String> clientNotes,
                                        Map<String, String> authNotes) {
        MicrosoftIdentityProviderConfig config = new MicrosoftIdentityProviderConfig();
        config.setAlias("OBS");
        config.setClientId("app-id");
        config.setTenantId("ytu-tenant");
        if (configuredPrompt != null) {
            config.getConfig().put("prompt", configuredPrompt);
        }
        SkyMicrosoftIdentityProvider provider =
                new SkyMicrosoftIdentityProvider(mock(KeycloakSession.class), config, forward);

        AuthenticationSessionModel authSession = mock(AuthenticationSessionModel.class);
        when(authSession.getClientNote(anyString())).thenAnswer(call -> clientNotes.get(call.<String>getArgument(0)));
        when(authSession.getAuthNote(anyString())).thenAnswer(call -> authNotes.get(call.<String>getArgument(0)));
        AuthenticationRequest request = new AuthenticationRequest(null, null, authSession, null, null,
                IdentityBrokerState.decoded("state", "client-uuid", "panel", "tab", null),
                "https://e.example/realms/e-skylab/broker/OBS/endpoint");

        return provider.createAuthorizationUrl(request).build();
    }

    private static List<String> prompts(URI uri) {
        return query(uri).getOrDefault("prompt", List.of());
    }

    private static Map<String, List<String>> query(URI uri) {
        Map<String, List<String>> query = new HashMap<>();
        for (String pair : uri.getRawQuery().split("&")) {
            String[] parts = pair.split("=", 2);
            query.computeIfAbsent(decode(parts[0]), key -> new ArrayList<>()).add(decode(parts.length > 1 ? parts[1] : ""));
        }
        return query;
    }

    private static String decode(String value) {
        return java.net.URLDecoder.decode(value, StandardCharsets.UTF_8);
    }
}
