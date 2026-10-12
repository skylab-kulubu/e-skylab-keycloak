package com.skylab.broker;

import org.keycloak.Config;
import org.keycloak.models.IdentityProviderModel;
import org.keycloak.models.KeycloakSession;
import org.keycloak.social.microsoft.MicrosoftIdentityProvider;
import org.keycloak.social.microsoft.MicrosoftIdentityProviderConfig;
import org.keycloak.social.microsoft.MicrosoftIdentityProviderFactory;

import java.util.Locale;
import java.util.Map;

/**
 * Replaces Keycloak's built-in {@code microsoft} identity provider factory with
 * {@link SkyMicrosoftIdentityProvider}. Same provider ID, name, configuration and admin fields:
 * Keycloak keeps a custom factory over an internal one with the same ID
 * ({@code ProviderManager.compareFactories}), so identity providers of type {@code microsoft}
 * (YTÜ's OBS) need no change.
 *
 * <p>{@code SKY_FORWARD_REAUTHENTICATION} (or the SPI option
 * {@code spi-social--microsoft--forward-reauthentication}) is {@code true} by default; {@code false}
 * gives back exactly Keycloak's own behaviour (the rollback, after a restart). Anything else stops
 * the server at start.
 */
public class SkyMicrosoftIdentityProviderFactory extends MicrosoftIdentityProviderFactory {

    static final String FORWARD_REAUTHENTICATION_CONFIG = "forward-reauthentication";
    static final String FORWARD_REAUTHENTICATION_ENV = "SKY_FORWARD_REAUTHENTICATION";

    private volatile boolean forwardReauthentication = true;

    @Override
    public MicrosoftIdentityProvider create(KeycloakSession session, IdentityProviderModel model) {
        return new SkyMicrosoftIdentityProvider(session, new MicrosoftIdentityProviderConfig(model),
                forwardReauthentication);
    }

    @Override
    public void init(Config.Scope config) {
        super.init(config);
        forwardReauthentication = resolveForwardReauthentication(
                config == null ? null : config.get(FORWARD_REAUTHENTICATION_CONFIG), System.getenv());
    }

    static boolean resolveForwardReauthentication(String configured, Map<String, String> environment) {
        String candidate = configured;
        if (candidate == null || candidate.isBlank()) {
            candidate = environment.get(FORWARD_REAUTHENTICATION_ENV);
        }
        if (candidate == null || candidate.isBlank()) {
            return true;
        }
        return switch (candidate.trim().toLowerCase(Locale.ROOT)) {
            case "true" -> true;
            case "false" -> false;
            default -> throw new IllegalStateException(FORWARD_REAUTHENTICATION_ENV + " must be true or false.");
        };
    }
}
