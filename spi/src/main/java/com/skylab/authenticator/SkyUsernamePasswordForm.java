package com.skylab.authenticator;

import com.skylab.account.LoginIdentifiers;
import jakarta.ws.rs.core.MultivaluedHashMap;
import jakarta.ws.rs.core.MultivaluedMap;
import org.keycloak.authentication.AuthenticationFlowContext;
import org.keycloak.authentication.AuthenticationFlowError;
import org.keycloak.authentication.FlowStatus;
import org.keycloak.authentication.authenticators.browser.UsernamePasswordForm;
import org.keycloak.events.Details;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;
import org.keycloak.models.utils.KeycloakModelUtils;
import org.keycloak.services.managers.AuthenticationManager;
import org.keycloak.services.managers.BruteForceProtector;

import java.util.Set;

/**
 * Keycloak's username/password form that also takes the School or Personal e-mail as the
 * username (K4). Only the lookup changes; the password check, brute-force protection, the
 * disabled-user and required-action handling, the error messages and the passkey (conditional
 * UI) path are Keycloak's own, reached through {@link UsernamePasswordForm#validateForm}.
 *
 * <ul>
 *   <li>Input Keycloak's own lookup resolves (the username or the Primary e-mail), input that
 *       names nobody, and a user set before this form: the stock form, untouched.</li>
 *   <li>Input that names two different people by any route: exactly Keycloak's answer to an
 *       unknown username ({@link #testInvalidUser}: the constant-time dummy hash, the
 *       {@code user_not_found} event, the generic "invalid username or password").</li>
 *   <li>A proven School or Personal e-mail of exactly one person: the stock form runs with that
 *       person's username in the field. Afterwards the attempted username is set back to what
 *       was typed: the login and reset-password pages show it again, and an address must never
 *       reveal whose username it is. Keycloak finds the person for brute-force accounting from
 *       that note, which no longer resolves, so a wrong password is counted here instead, with
 *       exactly the call Keycloak's flow makes, once.</li>
 * </ul>
 */
public class SkyUsernamePasswordForm extends UsernamePasswordForm {

    private final String ytuIdpAlias;

    public SkyUsernamePasswordForm(KeycloakSession session, String ytuIdpAlias) {
        super(session);
        this.ytuIdpAlias = ytuIdpAlias;
    }

    /** Without the passkey (conditional UI) helper, for tests. */
    SkyUsernamePasswordForm(String ytuIdpAlias) {
        super();
        this.ytuIdpAlias = ytuIdpAlias;
    }

    @Override
    protected boolean validateForm(AuthenticationFlowContext context, MultivaluedMap<String, String> formData) {
        String typed = formData.getFirst(AuthenticationManager.FORM_USERNAME);
        if (isUserAlreadySetBeforeUsernamePasswordAuth(context) || typed == null || typed.isBlank()) {
            return keycloakForm(context, formData);
        }
        String identifier = typed.trim();
        LoginIdentifiers.Match match = resolve(context, identifier);
        if (match instanceof LoginIdentifiers.Ambiguous) {
            return refuseAsUnknown(context, identifier);
        }
        if (match instanceof LoginIdentifiers.Person person && !person.byKeycloakLookup()) {
            // Found by a School or Personal e-mail alone. A username that Keycloak resolves to
            // somebody else (a legacy username equal to another person's e-mail) cannot stand in
            // for the address, so that person is refused like a typo.
            return usernameFindsTheSamePerson(context, person.user())
                    ? signInByAddress(context, formData, identifier, person.user())
                    : refuseAsUnknown(context, identifier);
        }
        return keycloakForm(context, formData);
    }

    LoginIdentifiers.Match resolve(AuthenticationFlowContext context, String identifier) {
        return LoginIdentifiers.resolve(context.getSession(), context.getRealm(), ytuIdpAlias, identifier);
    }

    /** Keycloak's own form with the given form data; a seam for tests. */
    boolean keycloakForm(AuthenticationFlowContext context, MultivaluedMap<String, String> formData) {
        return super.validateForm(context, formData);
    }

    boolean usernameFindsTheSamePerson(AuthenticationFlowContext context, UserModel user) {
        UserModel found = KeycloakModelUtils.findUserByNameOrEmail(
                context.getSession(), context.getRealm(), user.getUsername());
        return found != null && found.getId().equals(user.getId());
    }

    /**
     * Keycloak's unknown-username answer. The three notes are what Keycloak records before its
     * own lookup, so the page, the event and the brute-force note look like a typo's.
     */
    boolean refuseAsUnknown(AuthenticationFlowContext context, String identifier) {
        context.clearUser();
        context.getEvent().detail(Details.USERNAME, identifier);
        context.getAuthenticationSession().setAuthNote(ATTEMPTED_USERNAME, identifier);
        testInvalidUser(context, null);
        return false;
    }

    private boolean signInByAddress(AuthenticationFlowContext context, MultivaluedMap<String, String> formData,
                                    String identifier, UserModel user) {
        MultivaluedMap<String, String> byUsername = new MultivaluedHashMap<>(formData);
        byUsername.putSingle(AuthenticationManager.FORM_USERNAME, user.getUsername());
        boolean signedIn;
        try {
            signedIn = keycloakForm(context, byUsername);
        } finally {
            context.getAuthenticationSession().setAuthNote(ATTEMPTED_USERNAME, identifier);
            context.getEvent().detail(Details.USERNAME, identifier);
        }
        if (!signedIn
                && context.getStatus() == FlowStatus.FAILURE_CHALLENGE
                && context.getError() == AuthenticationFlowError.INVALID_CREDENTIALS
                && KeycloakModelUtils.findUserByNameOrEmail(context.getSession(), context.getRealm(), identifier) == null) {
            recordFailedLogin(context, user);
        }
        return signedIn;
    }

    /**
     * What {@code AuthenticationProcessor.logFailure} does for the person it finds from the
     * attempted username: Keycloak's brute-force protector, with this execution's category.
     */
    void recordFailedLogin(AuthenticationFlowContext context, UserModel user) {
        RealmModel realm = context.getRealm();
        if (!realm.isBruteForceProtected()) {
            return;
        }
        KeycloakSession session = context.getSession();
        String category = AuthenticationManager.getAuthenticationCategory(
                session, context.getExecution().getAuthenticator());
        session.getProvider(BruteForceProtector.class).failedLogin(
                realm,
                user,
                context.getConnection(),
                session.getContext().getHttpRequest().getUri(),
                category == null ? null : Set.of(category));
    }
}
