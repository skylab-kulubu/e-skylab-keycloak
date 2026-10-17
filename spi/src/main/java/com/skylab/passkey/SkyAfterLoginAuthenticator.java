package com.skylab.passkey;

import com.skylab.account.EmailCodeSignUp;
import jakarta.ws.rs.core.MultivaluedMap;
import java.util.function.LongSupplier;
import org.keycloak.authentication.AuthenticationFlowContext;
import org.keycloak.authentication.AuthenticationFlowError;
import org.keycloak.authentication.Authenticator;
import org.keycloak.common.util.Time;
import org.keycloak.models.Constants;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;
import org.keycloak.sessions.AuthenticationSessionModel;

/** Registration-only questions; every ordinary login delegates to the unchanged passkey offer. */
public final class SkyAfterLoginAuthenticator implements Authenticator {
    static final String TEMPLATE = "sky-after-sign-up-school.ftl";
    static final String CHOICE = "sky-sign-up-school-choice";
    static final String LINK_AVAILABLE = "skyYtuLinkAvailable";
    static final String LINK_DEFERRED = "skyYtuLinkDeferredMessage";
    private static final String DEFERRED_COPY = "Okul hesabını daha sonra Hesap Merkezi’nden bağlayabilirsin.";
    private final PasskeyOfferAuthenticator loginOffer = new PasskeyOfferAuthenticator();
    private final LongSupplier clock;

    public SkyAfterLoginAuthenticator() { this(Time::currentTime); }
    SkyAfterLoginAuthenticator(LongSupplier clock) { this.clock = clock; }

    @Override
    public void authenticate(AuthenticationFlowContext context) {
        if (ordinaryLogin(context)) {
            loginOffer.authenticate(context);
            return;
        }
        var auth = context.getAuthenticationSession();
        if (!AfterSignUpState.supportedRelyingParty(context.getRealm(), auth, context.getUser())) {
            reject(context);
            return;
        }
        var state = state(context);
        if (state == null) {
            if (auth != null && !AfterSignUpState.present(auth)
                    && "true".equals(auth.getAuthNote(EmailCodeSignUp.SIGNED_UP_NOTE))
                    && noActionInProgress(auth)) {
                state = AfterSignUpState.begin(context.getSession(), context.getRealm(), auth, context.getUser(), clock);
            }
            if (state == null) { reject(context); return; }
        }
        switch (state.stage()) {
            case SCHOOL -> schoolPage(context, false);
            case CREDENTIALS -> {
                AfterSignUpState.scheduleCredentials(auth);
                context.success();
            }
            case LINK_PENDING -> {
                if (!"idp_link".equals(auth.getClientNote(Constants.KC_ACTION))
                        || !AfterSignUpState.YTU_ALIAS.equals(auth.getClientNote(Constants.KC_ACTION_PARAMETER))) {
                    reject(context);
                } else context.success();
            }
            case DONE -> context.success();
        }
    }

    @Override
    public void action(AuthenticationFlowContext context) {
        if (ordinaryLogin(context)) {
            loginOffer.action(context);
            return;
        }
        var auth = context.getAuthenticationSession();
        if (!AfterSignUpState.supportedRelyingParty(context.getRealm(), auth, context.getUser())) {
            reject(context);
            return;
        }
        var state = state(context);
        if (state == null || state.stage() != AfterSignUpState.Stage.SCHOOL || !noActionInProgress(auth)) {
            reject(context);
            return;
        }
        String choice = choice(context.getHttpRequest().getDecodedFormParameters(), CHOICE);
        if ("link".equals(choice)) {
            if (!AfterSignUpState.nativeLinkSupported(context.getSession(), context.getRealm(), auth, context.getUser())) {
                schoolPage(context, true);
                return;
            }
            if (AfterSignUpState.move(context.getSession(), auth, state, AfterSignUpState.Stage.LINK_PENDING, clock) == null) {
                reject(context);
                return;
            }
            auth.setClientNote(Constants.KC_ACTION, "idp_link");
            auth.setClientNote(Constants.KC_ACTION_PARAMETER, AfterSignUpState.YTU_ALIAS);
            // Do not add idp_link to requiredActions: that enforces an otherwise optional native action.
            context.success();
        } else if ("skip".equals(choice)) {
            if (AfterSignUpState.move(context.getSession(), auth, state, AfterSignUpState.Stage.CREDENTIALS, clock) == null) {
                reject(context);
                return;
            }
            AfterSignUpState.scheduleCredentials(auth);
            context.success();
        } else {
            schoolPage(context, true);
        }
    }

    private static void schoolPage(AuthenticationFlowContext context, boolean error) {
        boolean available = AfterSignUpState.nativeLinkSupported(context.getSession(), context.getRealm(),
                context.getAuthenticationSession(), context.getUser());
        var form = context.form().setAttribute(LINK_AVAILABLE, available)
                .setAttribute(LINK_DEFERRED, available ? "" : DEFERRED_COPY);
        if (error) form.setError(available ? "afterSignUpChooseAgain" : "afterSignUpSchoolDeferred");
        context.challenge(form.createForm(TEMPLATE));
    }

    private boolean ordinaryLogin(AuthenticationFlowContext context) {
        var auth = context.getAuthenticationSession();
        return !AfterSignUpState.enabled(context.getRealm()) || (auth != null
                && !AfterSignUpState.present(auth) && auth.getAuthNote(EmailCodeSignUp.SIGNED_UP_NOTE) == null);
    }

    private AfterSignUpState.State state(AuthenticationFlowContext context) {
        return AfterSignUpState.read(context.getRealm(), context.getAuthenticationSession(), context.getUser(), clock.getAsLong());
    }

    private static boolean noActionInProgress(AuthenticationSessionModel auth) {
        return auth.getClientNote(Constants.KC_ACTION) == null
                && auth.getClientNote(Constants.KC_ACTION_EXECUTING) == null
                && auth.getClientNote(Constants.KC_ACTION_ENFORCED) == null;
    }

    static String choice(MultivaluedMap<String, String> form, String name) {
        return form != null && form.get(name) != null && form.get(name).size() == 1 ? form.getFirst(name) : null;
    }

    private static void reject(AuthenticationFlowContext context) {
        context.failure(AuthenticationFlowError.GENERIC_AUTHENTICATION_ERROR);
    }

    @Override public boolean requiresUser() { return true; }
    @Override public boolean configuredFor(KeycloakSession session, RealmModel realm, UserModel user) { return true; }
    @Override public void setRequiredActions(KeycloakSession session, RealmModel realm, UserModel user) { }
    @Override public void close() { }
}
