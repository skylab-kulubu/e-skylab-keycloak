package com.skylab.authenticator;

import com.skylab.account.LoginIdentifiers;
import org.keycloak.Config;
import org.keycloak.authentication.AuthenticationFlowContext;
import org.keycloak.authentication.authenticators.browser.AbstractUsernameFormAuthenticator;
import org.keycloak.authentication.authenticators.resetcred.ResetCredentialChooseUser;
import org.keycloak.events.Details;
import org.keycloak.events.Errors;
import org.keycloak.models.UserModel;
import org.keycloak.services.managers.AuthenticationManager;

/**
 * {@code sky-reset-credentials-choose-user}: the first step of the reset-password ("Şifremi
 * unuttum") flow, Keycloak's {@code reset-credentials-choose-user} with the lookup of the SKY LAB
 * password form (K4b). The field takes what sign-in takes: the username, the Primary e-mail, the
 * School e-mail of a Verified YTÜ account or a proven Personal e-mail, by the same rules
 * ({@link LoginIdentifiers}). Before it, Keycloak's step knew only the username and the Primary
 * e-mail, so a person who typed the other address saw "e-mail sent" and got nothing.
 *
 * <ul>
 *   <li>Input Keycloak's own lookup resolves (the username or the Primary e-mail), input that
 *       names nobody, an empty field, and every path that does not read the form (a person
 *       already known from first-broker login, an action token or an SSO cookie): Keycloak's
 *       step, untouched.</li>
 *   <li>A proven School or Personal e-mail of exactly one person: that person is chosen exactly as
 *       Keycloak chooses a person it found, a disabled one cleared exactly as Keycloak clears a
 *       disabled username.</li>
 *   <li>Input that names two different people by any route: exactly Keycloak's answer to an
 *       unknown username ({@code user_not_found}, nobody chosen), even where Keycloak's own
 *       lookup alone would pick one of them.</li>
 * </ul>
 *
 * <p>The flow always continues, so the page says "e-mail sent" whatever was typed and no answer
 * tells whether an address belongs to anyone. The attempted username stays what was typed: no
 * page echoes another identifier of the person.
 *
 * <p>Where the mail goes is not decided here: the next step, Keycloak's
 * {@code reset-credential-email}, mails the chosen person's Primary e-mail, never the address
 * typed. Its action token is bound to that address (Keycloak refuses the link once the Primary
 * e-mail changes) and following the link marks it verified, which is only true of the address the
 * link went to. The Primary e-mail is the one of School and Personal e-mail the person chose to
 * receive mail at (CONTEXT, Primary e-mail).
 *
 * <p>Unlike the password form, a person found by address alone does not have to be found again by
 * their username: this step sets the person on the flow itself and never hands a username to
 * Keycloak's lookup. Keycloak's step has no brute-force check, and none is added.
 *
 * <p>The YTÜ identity provider alias follows the password form: provider config
 * {@code --spi-authenticator-sky-reset-credentials-choose-user-ytu-idp-alias}, then
 * {@code SKY_ACCOUNT_YTU_IDP_ALIAS}, then {@code OBS}. {@code config/reconcile-account-center.sh}
 * puts this step in place of Keycloak's in the realm's reset credentials flow and can put
 * Keycloak's back ({@code KEYCLOAK_RESET_CHOOSE_USER}).
 */
public class SkyResetCredentialChooseUser extends ResetCredentialChooseUser {

    public static final String PROVIDER_ID = "sky-reset-credentials-choose-user";
    static final String YTU_IDP_ALIAS_CONFIG = "ytu-idp-alias";

    private volatile String ytuIdpAlias = LoginIdentifiers.ytuIdpAlias(null);

    @Override
    public void action(AuthenticationFlowContext context) {
        String typed = context.getHttpRequest().getDecodedFormParameters().getFirst(AuthenticationManager.FORM_USERNAME);
        if (typed == null || typed.isBlank()) {
            super.action(context);
            return;
        }
        String identifier = typed.trim();
        LoginIdentifiers.Match match = LoginIdentifiers.resolve(
                context.getSession(), context.getRealm(), ytuIdpAlias, identifier);
        if (match instanceof LoginIdentifiers.Ambiguous) {
            chooseNobody(context, identifier);
        } else if (match instanceof LoginIdentifiers.Person person && !person.byKeycloakLookup()) {
            choose(context, identifier, person.user());
        } else {
            super.action(context);
        }
    }

    /** What Keycloak's step does for a username it cannot find. */
    private static void chooseNobody(AuthenticationFlowContext context, String identifier) {
        context.getAuthenticationSession().setAuthNote(AbstractUsernameFormAuthenticator.ATTEMPTED_USERNAME, identifier);
        context.getEvent().clone()
                .detail(Details.USERNAME, identifier)
                .error(Errors.USER_NOT_FOUND);
        context.clearUser();
        context.success();
    }

    /** What Keycloak's step does for a person it found. */
    private static void choose(AuthenticationFlowContext context, String identifier, UserModel user) {
        context.getAuthenticationSession().setAuthNote(AbstractUsernameFormAuthenticator.ATTEMPTED_USERNAME, identifier);
        if (!user.isEnabled()) {
            context.getEvent().clone()
                    .detail(Details.USERNAME, identifier)
                    .user(user)
                    .error(Errors.USER_DISABLED);
            context.clearUser();
        } else {
            context.getAuthenticationSession().setAuthNote(RESET_CREDENTIAL_USER_CHOSEN, "true");
            context.setUser(user);
        }
        context.success();
    }

    @Override
    public void init(Config.Scope config) {
        ytuIdpAlias = LoginIdentifiers.ytuIdpAlias(config == null ? null : config.get(YTU_IDP_ALIAS_CONFIG));
    }

    @Override
    public String getId() {
        return PROVIDER_ID;
    }

    @Override
    public String getDisplayType() {
        return "SKY LAB Choose User";
    }

    @Override
    public String getHelpText() {
        return "Chooses the user to reset credentials for by username, primary e-mail, or a proven school or personal e-mail.";
    }
}
