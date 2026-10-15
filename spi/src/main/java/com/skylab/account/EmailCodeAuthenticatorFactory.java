package com.skylab.account;

import org.keycloak.Config;
import org.keycloak.authentication.AuthenticationFlowCallbackFactory;
import org.keycloak.authentication.Authenticator;
import org.keycloak.authentication.authenticators.browser.WebAuthnConditionalUIAuthenticator;
import org.keycloak.models.AuthenticationExecutionModel;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;
import org.keycloak.provider.ProviderConfigProperty;

import java.util.List;
import java.util.Map;

/**
 * {@code sky-email-code}: "E-postayla devam et" ({@link EmailCodeAuthenticator}). It runs only where
 * a flow names it; config/reconcile-account-center.sh puts it, with Keycloak's conditional OTP and the
 * passkey offer, into an ALTERNATIVE subflow of the realm's browser flow next to the password form
 * ({@code KEYCLOAK_EMAIL_CODE_LOGIN=on}, realm by realm) and turns that subflow off again
 * ({@code off}, the rollback). A callback factory, so the step hears when its subflow succeeded.
 *
 * <p>Settings: the YTÜ identity provider alias as the password form takes it (provider config
 * {@code --spi-authenticator-sky-email-code-ytu-idp-alias}, then {@code SKY_ACCOUNT_YTU_IDP_ALIAS},
 * then {@code OBS}); {@code SKY_EMAIL_CODE_DAILY_LIMIT} and {@code SKY_EMAIL_CODE_ALARM_GROUP}
 * ({@link EmailCodeSettings}).
 */
public final class EmailCodeAuthenticatorFactory implements AuthenticationFlowCallbackFactory {

    static final String YTU_IDP_ALIAS_CONFIG = "ytu-idp-alias";

    private static final AuthenticationExecutionModel.Requirement[] REQUIREMENT_CHOICES = {
            AuthenticationExecutionModel.Requirement.REQUIRED,
            AuthenticationExecutionModel.Requirement.ALTERNATIVE,
            AuthenticationExecutionModel.Requirement.DISABLED
    };

    private volatile EmailCodeSettings settings = EmailCodeSettings.from(null, Map.of());

    @Override
    public Authenticator create(KeycloakSession session) {
        return new EmailCodeAuthenticator(settings, new BackgroundLoginCodeMail(settings),
                new WebAuthnConditionalUIAuthenticator(session, EmailCodeAuthenticator::passkeyErrorPage));
    }

    @Override
    public void init(Config.Scope config) {
        settings = EmailCodeSettings.from(config == null ? null : config.get(YTU_IDP_ALIAS_CONFIG), System.getenv());
    }

    EmailCodeSettings settings() {
        return settings;
    }

    @Override
    public void postInit(KeycloakSessionFactory factory) {
        // no-op
    }

    @Override
    public void close() {
        // no-op
    }

    @Override
    public String getId() {
        return EmailCodeAuthenticator.PROVIDER_ID;
    }

    @Override
    public String getDisplayType() {
        return "SKY LAB E-mail Code";
    }

    @Override
    public String getReferenceCategory() {
        return null;
    }

    @Override
    public boolean isConfigurable() {
        return false;
    }

    @Override
    public AuthenticationExecutionModel.Requirement[] getRequirementChoices() {
        return REQUIREMENT_CHOICES.clone();
    }

    @Override
    public boolean isUserSetupAllowed() {
        return false;
    }

    @Override
    public String getHelpText() {
        return "Signs in with a six-digit code mailed to the account's primary e-mail (Login code, ADR-0063).";
    }

    @Override
    public List<ProviderConfigProperty> getConfigProperties() {
        return List.of();
    }
}
