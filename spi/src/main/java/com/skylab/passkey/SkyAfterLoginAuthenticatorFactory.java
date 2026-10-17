package com.skylab.passkey;

import java.util.List;
import org.keycloak.Config;
import org.keycloak.authentication.Authenticator;
import org.keycloak.authentication.AuthenticatorFactory;
import org.keycloak.models.AuthenticationExecutionModel;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;
import org.keycloak.provider.ProviderConfigProperty;

public final class SkyAfterLoginAuthenticatorFactory implements AuthenticatorFactory {
    public static final String PROVIDER_ID = "sky-after-login";
    @Override public String getId() { return PROVIDER_ID; }
    @Override public String getDisplayType() { return "SKY LAB after login"; }
    @Override public String getHelpText() { return "Preserves the login passkey offer; registration questions require the disabled-by-default realm feature."; }
    @Override public String getReferenceCategory() { return "passkey"; }
    @Override public boolean isConfigurable() { return false; }
    @Override public boolean isUserSetupAllowed() { return false; }
    @Override public AuthenticationExecutionModel.Requirement[] getRequirementChoices() {
        return new AuthenticationExecutionModel.Requirement[] {
                AuthenticationExecutionModel.Requirement.REQUIRED,
                AuthenticationExecutionModel.Requirement.DISABLED
        };
    }
    @Override public List<ProviderConfigProperty> getConfigProperties() { return List.of(); }
    @Override public Authenticator create(KeycloakSession session) { return new SkyAfterLoginAuthenticator(); }
    @Override public void init(Config.Scope config) { }
    @Override public void postInit(KeycloakSessionFactory factory) { }
    @Override public void close() { }
}
