package com.skylab.authenticator;

import com.skylab.account.LoginIdentifiers;
import org.keycloak.Config;
import org.keycloak.authentication.Authenticator;
import org.keycloak.authentication.authenticators.browser.UsernamePasswordFormFactory;
import org.keycloak.models.KeycloakSession;

/**
 * {@code sky-username-password-form}: Keycloak's {@code auth-username-password-form} with the
 * SKY LAB lookup (K4). Everything else is inherited from Keycloak's factory, so the reference
 * category ({@code password}, which brute-force protection keys on), the passkey category, the
 * single REQUIRED requirement and the absent configuration stay exactly the stock ones.
 * {@code config/reconcile-account-center.sh} puts it in place of the stock form in the realm
 * browser flow and can put the stock form back ({@code KEYCLOAK_PASSWORD_FORM}).
 *
 * <p>The YTÜ identity provider alias follows the sky-account endpoints: provider config
 * {@code --spi-authenticator-sky-username-password-form-ytu-idp-alias}, then
 * {@code SKY_ACCOUNT_YTU_IDP_ALIAS}, then {@code OBS}.
 */
public final class SkyUsernamePasswordFormFactory extends UsernamePasswordFormFactory {

    public static final String PROVIDER_ID = "sky-username-password-form";
    static final String YTU_IDP_ALIAS_CONFIG = "ytu-idp-alias";

    private volatile String ytuIdpAlias = LoginIdentifiers.ytuIdpAlias(null);

    @Override
    public String getId() {
        return PROVIDER_ID;
    }

    @Override
    public Authenticator create(KeycloakSession session) {
        return new SkyUsernamePasswordForm(session, ytuIdpAlias);
    }

    @Override
    public void init(Config.Scope config) {
        ytuIdpAlias = LoginIdentifiers.ytuIdpAlias(config == null ? null : config.get(YTU_IDP_ALIAS_CONFIG));
    }

    @Override
    public String getDisplayType() {
        return "SKY LAB Username Password Form";
    }

    @Override
    public String getHelpText() {
        return "Validates a password for the username, the primary e-mail, or a proven school or personal e-mail.";
    }

    String ytuIdpAlias() {
        return ytuIdpAlias;
    }
}
