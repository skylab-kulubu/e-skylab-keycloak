package com.skylab.handoff;

import org.keycloak.models.KeycloakSession;
import org.keycloak.services.resource.RealmResourceProvider;

final class SkyHandoffResourceProvider implements RealmResourceProvider {

    private final KeycloakSession session;
    private final String adminRole;

    SkyHandoffResourceProvider(KeycloakSession session, String adminRole) {
        this.session = session;
        this.adminRole = adminRole;
    }

    @Override
    public Object getResource() {
        return new SkyHandoffResource(session, adminRole);
    }

    @Override
    public void close() {
        // no-op
    }
}
