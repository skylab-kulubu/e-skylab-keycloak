package com.skylab.handoff;

import org.keycloak.models.KeycloakSession;
import org.keycloak.services.resource.RealmResourceProvider;

final class SkyHandoffResourceProvider implements RealmResourceProvider {

    private final KeycloakSession session;
    private final AdminAccess adminAccess;

    SkyHandoffResourceProvider(KeycloakSession session, AdminAccess adminAccess) {
        this.session = session;
        this.adminAccess = adminAccess;
    }

    @Override
    public Object getResource() {
        return new SkyHandoffResource(session, adminAccess);
    }

    @Override
    public void close() {
        // no-op
    }
}
