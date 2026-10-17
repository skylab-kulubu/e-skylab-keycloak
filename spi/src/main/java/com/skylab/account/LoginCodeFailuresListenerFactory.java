package com.skylab.account;

import org.keycloak.Config;
import org.keycloak.events.EventListenerProvider;
import org.keycloak.events.EventListenerProviderFactory;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;

/** Global so disabling event storage or changing realm listener settings cannot disable the reset. */
public final class LoginCodeFailuresListenerFactory implements EventListenerProviderFactory {
    @Override
    public EventListenerProvider create(KeycloakSession session) {
        return new LoginCodeFailuresListener(session, new PersistentLoginCodeFailures());
    }
    @Override
    public boolean isGlobal() { return true; }
    @Override
    public String getId() { return "sky-email-code-failures"; }
    @Override
    public void init(Config.Scope config) { }
    @Override
    public void postInit(KeycloakSessionFactory factory) { }
    @Override
    public void close() { }
}
