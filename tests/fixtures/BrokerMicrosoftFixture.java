package com.skylab.broker;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import org.keycloak.Config;
import org.keycloak.broker.provider.BrokeredIdentityContext;
import org.keycloak.broker.provider.IdentityBrokerException;
import org.keycloak.http.simple.SimpleHttp;
import org.keycloak.models.IdentityProviderModel;
import org.keycloak.models.KeycloakSession;
import org.keycloak.social.microsoft.MicrosoftIdentityProvider;
import org.keycloak.social.microsoft.MicrosoftIdentityProviderConfig;
import org.keycloak.social.microsoft.MicrosoftIdentityProviderFactory;

/** Test-only Microsoft transport backed by a second local Keycloak realm, never shipped. */
public final class BrokerMicrosoftFixture extends MicrosoftIdentityProviderFactory {
    @Override public String getId() { return "sky-test-microsoft"; }
    @Override public void init(Config.Scope config) { }

    @Override public MicrosoftIdentityProvider create(KeycloakSession session, IdentityProviderModel model) {
        if (!"1".equals(System.getenv("SKY_HARNESS"))) throw new IllegalStateException("test-only provider");
        String auth = model.getConfig().get("authorizationUrl");
        String token = model.getConfig().get("tokenUrl");
        String profile = model.getConfig().get("userInfoUrl");
        return new LocalMicrosoft(session, new MicrosoftIdentityProviderConfig(model), auth, token, profile);
    }

    private static final class LocalMicrosoft extends SkyMicrosoftIdentityProvider {
        LocalMicrosoft(KeycloakSession session, MicrosoftIdentityProviderConfig config,
                       String authorization, String token, String profile) {
            super(session, config, false);
            getConfig().setAuthorizationUrl(authorization);
            getConfig().setTokenUrl(token);
            getConfig().setUserInfoUrl(profile);
            getConfig().setDefaultScope("openid profile email");
        }

        @Override protected String getDefaultScopes() { return "openid profile email"; }

        @Override protected BrokeredIdentityContext doGetFederatedIdentity(String accessToken) {
            try {
                JsonNode source = SimpleHttp.create(session).doGet(getConfig().getUserInfoUrl()).auth(accessToken).asJson();
                ObjectNode profile = source.deepCopy();
                profile.put("id", source.path("sub").asText());
                profile.put("givenName", source.path("given_name").asText());
                profile.put("surname", source.path("family_name").asText());
                profile.put("mail", source.path("preferred_username").asText());
                profile.put("userPrincipalName", source.path("upn").asText());
                BrokeredIdentityContext identity = extractIdentityFromProfile(null, profile);
                identity.setEmail(null); // MicrosoftMapper's production preprocess contract.
                return identity;
            } catch (Exception failed) {
                throw new IdentityBrokerException("The local Microsoft fixture failed");
            }
        }
    }
}
