package com.skylab.passkey;

import java.util.Set;
import java.util.function.LongSupplier;
import org.keycloak.Config;
import org.keycloak.authentication.InitiatedActionSupport;
import org.keycloak.authentication.RequiredActionContext;
import org.keycloak.authentication.RequiredActionFactory;
import org.keycloak.authentication.RequiredActionProvider;
import org.keycloak.common.util.Time;
import org.keycloak.events.Errors;
import org.keycloak.models.Constants;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;

/** Session-only credential choices, scheduled after an optional native link has finished. */
public final class SignUpCredentialsRequiredAction implements RequiredActionProvider, RequiredActionFactory {
    public static final String PROVIDER_ID = "sky-sign-up-credentials";
    static final String TEMPLATE = "sky-after-sign-up-credentials.ftl";
    static final String CHOICE = "sky-sign-up-credential-choice";
    private static final Set<String> TERMINAL_STATUSES = Set.of("success", "cancelled", "error");
    private final LongSupplier clock;

    public SignUpCredentialsRequiredAction() { this(Time::currentTime); }
    SignUpCredentialsRequiredAction(LongSupplier clock) { this.clock = clock; }

    @Override
    public void evaluateTriggers(RequiredActionContext context) {
        var auth = context.getAuthenticationSession();
        if (auth == null) return;
        var state = validState(context);
        if (state == null) {
            auth.removeRequiredAction(PROVIDER_ID);
            return;
        }
        if (state.stage() == AfterSignUpState.Stage.LINK_PENDING
                && auth.getClientNote(Constants.KC_ACTION) == null
                && AfterSignUpState.YTU_ALIAS.equals(auth.getClientNote(Constants.KC_ACTION_PARAMETER))) {
            String status = auth.getClientNote(Constants.KC_ACTION_STATUS);
            if (status != null && TERMINAL_STATUSES.contains(status)) {
                state = AfterSignUpState.move(context.getSession(), auth, state, AfterSignUpState.Stage.CREDENTIALS, clock);
                if (state == null) return;
                auth.removeClientNote(Constants.KC_ACTION_STATUS);
                auth.removeClientNote(Constants.KC_ACTION_PARAMETER);
            }
        }
        if (state.stage() == AfterSignUpState.Stage.CREDENTIALS) AfterSignUpState.scheduleCredentials(auth);
    }

    @Override
    public void requiredActionChallenge(RequiredActionContext context) {
        var state = validState(context);
        if (state == null || state.stage() != AfterSignUpState.Stage.CREDENTIALS
                || context.getAuthenticationSession().getClientNote(Constants.KC_ACTION) != null
                || !AfterSignUpState.supportedRelyingParty(context.getRealm(), context.getAuthenticationSession(), context.getUser())) {
            context.ignore();
            return;
        }
        context.challenge(context.form().createForm(TEMPLATE));
    }

    @Override
    public void processAction(RequiredActionContext context) {
        var auth = context.getAuthenticationSession();
        var state = validState(context);
        if (state == null || state.stage() != AfterSignUpState.Stage.CREDENTIALS
                || context.getAuthenticationSession().getClientNote(Constants.KC_ACTION) != null
                || !AfterSignUpState.supportedRelyingParty(context.getRealm(), auth, context.getUser())) {
            context.failure(Errors.INVALID_REQUEST);
            return;
        }
        String choice = SkyAfterLoginAuthenticator.choice(context.getHttpRequest().getDecodedFormParameters(), CHOICE);
        String nextAction;
        if ("passkey".equals(choice)) nextAction = "webauthn-register-passwordless";
        else if ("password".equals(choice)) nextAction = "UPDATE_PASSWORD";
        else if ("skip".equals(choice)) nextAction = null;
        else {
            context.challenge(context.form().setError("Lütfen tercihini yeniden seç.").createForm(TEMPLATE));
            return;
        }
        if (nextAction != null && !AfterSignUpState.actionEnabled(context.getRealm(), nextAction)) {
            context.failure(Errors.INVALID_REQUEST);
            return;
        }
        if (AfterSignUpState.move(context.getSession(), auth, state, AfterSignUpState.Stage.DONE, clock) == null) {
            context.failure(Errors.INVALID_REQUEST);
            return;
        }
        if (nextAction != null) auth.addRequiredAction(nextAction);
        context.success();
    }

    private AfterSignUpState.State validState(RequiredActionContext context) {
        return AfterSignUpState.enabled(context.getRealm())
                && AfterSignUpState.supportedRelyingParty(context.getRealm(), context.getAuthenticationSession(), context.getUser())
                ? AfterSignUpState.read(context.getRealm(), context.getAuthenticationSession(), context.getUser(), clock.getAsLong()) : null;
    }

    @Override public InitiatedActionSupport initiatedActionSupport() { return InitiatedActionSupport.NOT_SUPPORTED; }
    @Override public RequiredActionProvider create(KeycloakSession session) { return this; }
    @Override public String getId() { return PROVIDER_ID; }
    @Override public String getDisplayText() { return "SKY LAB sign-up credential choices"; }
    @Override public void init(Config.Scope config) { }
    @Override public void postInit(KeycloakSessionFactory factory) { }
    @Override public void close() { }
}
