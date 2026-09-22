package com.skylab.handoff;

import org.keycloak.models.KeycloakSession;
import org.keycloak.services.resource.RealmResourceProvider;

final class SkyHandoffResourceProvider implements RealmResourceProvider {

    private final KeycloakSession session;

    SkyHandoffResourceProvider(KeycloakSession session) {
        this.session = session;
    }

    @Override
    public Object getResource() {
        return new SkyHandoffResource(session);
    }

    @Override
    public void close() {
        // no-op
    }
}
