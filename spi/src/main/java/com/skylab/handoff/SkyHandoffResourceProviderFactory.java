package com.skylab.handoff;

import org.keycloak.Config;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;
import org.keycloak.services.resource.RealmResourceProvider;
import org.keycloak.services.resource.RealmResourceProviderFactory;

/**
 * Mounts {@code /realms/{realm}/sky-handoff}: the Web handoff that lets SkyApp open a SKY LAB
 * site in its WebView already signed in (ADR-0048). Kept apart from {@code sky-account}, which
 * serves Account Center only.
 */
public final class SkyHandoffResourceProviderFactory implements RealmResourceProviderFactory {

    public static final String PROVIDER_ID = "sky-handoff";

    @Override
    public String getId() {
        return PROVIDER_ID;
    }

    @Override
    public RealmResourceProvider create(KeycloakSession session) {
        return new SkyHandoffResourceProvider(session);
    }

    @Override
    public void init(Config.Scope config) {
        // no configuration
    }

    @Override
    public void postInit(KeycloakSessionFactory factory) {
        // no-op
    }

    @Override
    public void close() {
        // no-op
    }
}
