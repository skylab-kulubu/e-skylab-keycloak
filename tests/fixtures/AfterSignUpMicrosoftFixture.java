package com.skylab.broker;

import org.keycloak.Config;
import org.keycloak.models.IdentityProviderModel;
import org.keycloak.models.KeycloakSession;
import org.keycloak.social.microsoft.MicrosoftIdentityProvider;
import org.keycloak.social.microsoft.MicrosoftIdentityProviderFactory;

/** B10-only transport: keep the real microsoft ID and protected provider type for the native gate. */
public final class AfterSignUpMicrosoftFixture extends MicrosoftIdentityProviderFactory {
    @Override public String getId() { return "microsoft"; }
    @Override public int order() { return 1000; }
    @Override public void init(Config.Scope config) { }
    @Override public MicrosoftIdentityProvider create(KeycloakSession session, IdentityProviderModel model) {
        return new BrokerMicrosoftFixture().create(session, model);
    }
}
