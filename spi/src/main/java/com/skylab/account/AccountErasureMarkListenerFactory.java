package com.skylab.account;

import org.keycloak.Config;
import org.keycloak.events.EventListenerProvider;
import org.keycloak.events.EventListenerProviderFactory;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;

/** Global, so no realm setting of event listeners or event storage can switch the mark off. */
public final class AccountErasureMarkListenerFactory implements EventListenerProviderFactory {

    @Override
    public EventListenerProvider create(KeycloakSession session) {
        return new AccountErasureMarkListener(session);
    }

    @Override
    public boolean isGlobal() {
        return true;
    }

    @Override
    public String getId() {
        return "sky-account-erasure-mark";
    }

    @Override
    public void init(Config.Scope config) {
    }

    @Override
    public void postInit(KeycloakSessionFactory factory) {
    }

    @Override
    public void close() {
    }
}
