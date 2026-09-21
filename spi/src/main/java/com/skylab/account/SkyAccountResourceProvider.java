package com.skylab.account;

import org.keycloak.models.KeycloakSession;
import org.keycloak.services.resource.RealmResourceProvider;

final class SkyAccountResourceProvider implements RealmResourceProvider {

    private final KeycloakSession session;
    private final String ytuIdpAlias;

    SkyAccountResourceProvider(KeycloakSession session, String ytuIdpAlias) {
        this.session = session;
        this.ytuIdpAlias = ytuIdpAlias;
    }

    @Override
    public Object getResource() {
        return new SkyAccountResource(session, ytuIdpAlias);
    }

    @Override
    public void close() {
        // no-op
    }
}
