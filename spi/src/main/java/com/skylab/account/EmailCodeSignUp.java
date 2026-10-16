package com.skylab.account;

import jakarta.ws.rs.core.Response;
import org.keycloak.authentication.AuthenticationFlowContext;
import org.keycloak.forms.login.LoginFormsProvider;
import org.keycloak.models.AuthenticationExecutionModel;
import org.keycloak.models.AuthenticationFlowModel;
import org.keycloak.models.AuthenticatorConfigModel;
import org.keycloak.models.RealmModel;

import java.util.List;
import java.util.Map;

/**
 * Self-registration on the "E-postayla devam et" door (eskylab-login-ux 09, ADR-0063 decision 1,
 * CONTEXT "Self-registration"): the switch, the page and the names that {@link EmailCodeAuthenticator}
 * shares with the theme. The flow itself is the authenticator's.
 *
 * <p>The switch is the {@value #CONFIG} setting of the realm's {@code sky-email-code} execution
 * (Keycloak's authenticator config, so it is per realm: sandbox first), off unless set to
 * {@code true}; the reconciler sets it ({@code KEYCLOAK_EMAIL_CODE_SIGN_UP}). Keycloak's own
 * registration page ({@code registrationAllowed}) stays off (spec S2).
 *
 * <p>The page ({@value #TEMPLATE}) is separate from the sign-in step's page. Its stages:
 * <ul>
 *   <li>{@code form}: "Hesabını oluşturalım": the proven address read-only, first and last name;
 *   <li>{@code ytu}: the proven address is on a YTÜ school domain: no account, the YTÜ (Microsoft)
 *       sign-in instead (spec S3);
 *   <li>{@code existing}: "Hesap aç" for an address that has an account: the code signed the person
 *       in, the page says so once;
 *   <li>{@code unavailable}: the proven address cannot open an account (another account holds it
 *       in a way that does not sign in with it, or Self-registration went off meanwhile).
 * </ul>
 */
public final class EmailCodeSignUp {

    /** The setting of the {@code sky-email-code} execution that turns Self-registration on. */
    static final String CONFIG = "sign-up";
    static final String TEMPLATE = "sky-email-code-sign-up.ftl";

    /** "Hesap aç": posted with Keycloak's execution switch, so the address page says so. */
    static final String INTENT_PARAM = "sky-email-code-intent";
    static final String INTENT_SIGN_UP = "sign-up";
    static final String FIRST_NAME_PARAM = "firstName";
    static final String LAST_NAME_PARAM = "lastName";
    /** The sign-up form's action; "Devam et" of the existing stage is {@link #CONTINUE}. */
    static final String SIGN_UP = "sign-up";
    static final String CONTINUE = "continue";

    // Notes of the sign-in session.
    static final String INTENT_NOTE = "sky-email-code.intent";
    /** The address the right sign-up code proved; the form opens the account for it. */
    static final String ADDRESS_NOTE = "sky-email-code.sign-up-address";
    /** When it was proven (epoch seconds); the form does not outlive {@link #PROOF_SECONDS}. */
    static final String PROVEN_AT_NOTE = "sky-email-code.sign-up-proven-at";
    /** Which stage other than the form waits: ytu, existing or unavailable. */
    static final String STAGE_NOTE = "sky-email-code.sign-up-stage";
    /** The existing stage: whom the code signs in on "Devam et", and the address it went to. */
    static final String EXISTING_USER_NOTE = "sky-email-code.existing-user";
    static final String EXISTING_ADDRESS_NOTE = "sky-email-code.existing-address";
    /**
     * Set when this sign-in opened the account; the after-sign-up questions (ticket 10) read it.
     * Public: another package's authenticator reads it.
     */
    public static final String SIGNED_UP_NOTE = "sky-email-code.signed-up";

    // Page attributes.
    static final String STAGE_ATTRIBUTE = "skySignUpStage";
    static final String ADDRESS_ATTRIBUTE = "skySignUpAddress";
    static final String ERROR_ATTRIBUTE = "skySignUpError";
    static final String FIRST_NAME_ATTRIBUTE = "skySignUpFirstName";
    static final String LAST_NAME_ATTRIBUTE = "skySignUpLastName";
    static final String YTU_ALIAS_ATTRIBUTE = "skySignUpYtuAlias";
    /** On the sign-in step's own pages and the password form: Self-registration is on in this realm. */
    public static final String ON_ATTRIBUTE = "skyEmailCodeSignUp";
    /** On the sign-in step's own pages: the person came through "Hesap aç". */
    static final String INTENT_ATTRIBUTE = "skyEmailCodeIntent";

    /** The proven address opens the form for this long (Keycloak's own login action lifespan). */
    static final int PROOF_SECONDS = 30 * 60;
    /** How long one address is held by the sign-up that is opening an account for it. */
    static final int LOCK_SECONDS = 60;

    enum Stage {
        FORM("form"), YTU("ytu"), EXISTING("existing"), UNAVAILABLE("unavailable");

        final String value;

        Stage(String value) {
            this.value = value;
        }

        static Stage of(String value) {
            for (Stage stage : values()) {
                if (stage.value.equals(value)) {
                    return stage;
                }
            }
            return null;
        }
    }

    /** The form's error codes; the theme turns each into one sentence. */
    enum Problem {
        FIRST_NAME_MISSING("first_name_missing"),
        FIRST_NAME_INVALID("first_name_invalid"),
        LAST_NAME_MISSING("last_name_missing"),
        LAST_NAME_INVALID("last_name_invalid"),
        TRY_AGAIN("try_again");

        final String value;

        Problem(String value) {
            this.value = value;
        }
    }

    private EmailCodeSignUp() {
    }

    /** Whether the running {@code sky-email-code} execution has Self-registration on. */
    static boolean isOn(AuthenticationFlowContext context) {
        return isOn(context.getAuthenticatorConfig());
    }

    static boolean isOn(AuthenticatorConfigModel config) {
        Map<String, String> settings = config == null ? null : config.getConfig();
        return settings != null && "true".equalsIgnoreCase(trimmed(settings.get(CONFIG)));
    }

    /**
     * Whether the realm's browser flow offers Self-registration: an enabled {@code sky-email-code}
     * execution with the setting on, under subflows none of which is disabled. For the password
     * form's page, so the theme can show "Hesabın yok mu? E-postayla hesap aç".
     */
    public static boolean isOffered(RealmModel realm) {
        AuthenticationFlowModel browser = realm == null ? null : realm.getBrowserFlow();
        return browser != null && isOfferedIn(realm, browser.getId(), 0);
    }

    private static boolean isOfferedIn(RealmModel realm, String flowId, int depth) {
        if (flowId == null || depth > 10) {
            return false;
        }
        List<AuthenticationExecutionModel> executions = realm.getAuthenticationExecutionsStream(flowId).toList();
        for (AuthenticationExecutionModel execution : executions) {
            if (execution.isDisabled()) {
                continue;
            }
            if (execution.isAuthenticatorFlow()) {
                if (isOfferedIn(realm, execution.getFlowId(), depth + 1)) {
                    return true;
                }
            } else if (EmailCodeAuthenticator.PROVIDER_ID.equals(execution.getAuthenticator())
                    && execution.getAuthenticatorConfig() != null
                    && isOn(realm.getAuthenticatorConfigById(execution.getAuthenticatorConfig()))) {
                return true;
            }
        }
        return false;
    }

    /** One stage of the page. */
    static Response page(AuthenticationFlowContext context, Stage stage, String address, Problem problem,
            String firstName, String lastName, String ytuAlias) {
        LoginFormsProvider form = context.form().setAttribute(STAGE_ATTRIBUTE, stage.value);
        if (address != null) {
            form.setAttribute(ADDRESS_ATTRIBUTE, address);
        }
        if (problem != null) {
            form.setAttribute(ERROR_ATTRIBUTE, problem.value);
        }
        if (firstName != null) {
            form.setAttribute(FIRST_NAME_ATTRIBUTE, firstName);
        }
        if (lastName != null) {
            form.setAttribute(LAST_NAME_ATTRIBUTE, lastName);
        }
        if (ytuAlias != null) {
            form.setAttribute(YTU_ALIAS_ATTRIBUTE, ytuAlias);
        }
        return form.createForm(TEMPLATE);
    }

    private static String trimmed(String value) {
        return value == null || value.isBlank() ? null : value.trim();
    }
}
