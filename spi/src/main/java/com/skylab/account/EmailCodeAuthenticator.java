package com.skylab.account;

import jakarta.ws.rs.core.MultivaluedMap;
import jakarta.ws.rs.core.Response;
import org.jboss.logging.Logger;
import org.keycloak.WebAuthnConstants;
import org.keycloak.authentication.AuthenticationFlowCallback;
import org.keycloak.authentication.AuthenticationFlowContext;
import org.keycloak.authentication.authenticators.browser.AbstractUsernameFormAuthenticator;
import org.keycloak.authentication.authenticators.browser.WebAuthnConditionalUIAuthenticator;
import org.keycloak.authentication.authenticators.util.AuthenticatorUtils;
import org.keycloak.common.util.Base64Url;
import org.keycloak.common.util.SecretGenerator;
import org.keycloak.common.util.Time;
import org.keycloak.events.Details;
import org.keycloak.events.Errors;
import org.keycloak.events.EventBuilder;
import org.keycloak.forms.login.LoginFormsProvider;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;
import org.keycloak.models.credential.OTPCredentialModel;
import org.keycloak.protocol.oidc.OIDCLoginProtocol;
import org.keycloak.sessions.AuthenticationSessionModel;

/**
 * {@code sky-email-code}: "E-postayla devam et", sign-in with a Login code (ADR-0063 decision 2,
 * CONTEXT "Login code", eskylab-login-ux 08). The person types an e-mail address or a username and
 * asks for a code; a six-digit code goes to the account's Primary e-mail (its School e-mail when it
 * has no Primary e-mail and is a Verified YTÜ account; spec S4), whichever identifier was typed;
 * the code typed on the next page signs the person in. The realm's browser flow runs it as the first
 * step of its own ALTERNATIVE subflow, followed by Keycloak's conditional OTP (a person with TOTP is
 * still asked for it; spec S6) and the passkey offer (config/reconcile-account-center.sh,
 * {@code KEYCLOAK_EMAIL_CODE_LOGIN}).
 *
 * <p>Whom an identifier names is the password form's rule ({@link LoginIdentifiers}): the username,
 * the Primary e-mail, a Verified YTÜ account's School e-mail or a proven Personal e-mail. The page is
 * the same whatever was typed (spec §7.4): an identifier that names nobody, two people, a disabled
 * account or an account with nowhere to mail a code to gets the same code page and a code that is
 * never mailed, so the store traffic and the tries look the same too. The mail itself leaves after
 * the request, in the background ({@link LoginCodeMail}), so the answer takes the same time. Whether
 * an account exists is said only after the right code (ADR-0063, the second OWASP deviation); while
 * Self-registration is off (ticket 09) that is "no account" for a code nobody was mailed.
 *
 * <p>The code follows CONTEXT's Login code ({@link LoginCodes}): six digits, ten minutes, dead after
 * five wrong tries, single use, valid only in the sign-in session (browser and tab) that asked for
 * it, only a salted hash stored; a new code replaces the old one. A wrong code counts toward the
 * person's brute-force lock (Keycloak's protector, as a wrong password does), and a locked or
 * disabled person is not signed in by the right code. The code also stops working when the
 * person's codes would go elsewhere by now (the Primary e-mail changed in the ten minutes). Like
 * Keycloak's reset-password link, the right code marks the Primary e-mail it went to verified.
 * A person with OTP is signed in by the code only while the flow still asks for the OTP after it
 * ({@link OtpAfterCode}): an Admin Console change that drops that step makes the code refuse them
 * at once (fail closed), not only stop the next reconciliation.
 *
 * <p>Sending is limited per sign-in session, per IP class, per address (a quarter of an hour and a
 * day) and overall per day ({@link RateLimiter}, spec §7.2). Past the session or IP class budget the
 * page says so; past the address budget nothing is mailed and the page stays the same, and the new
 * code that is never mailed replaces the session's old one like any other (security review B3: a
 * kept code's tries left would link two identifiers to one account). The overall budget never stops a sign-in code: it
 * alarms the operator at its half and when it is used up. Budget keys are keyed hashes
 * ({@link BudgetKeys}); the IP itself is written nowhere.
 *
 * <p>Events: every refusal is a {@code LOGIN_ERROR} with {@code sky_method=email_code} and the
 * {@value #EVENT_DETAIL} detail saying what happened, without the IP and without the typed
 * identifier (they reach the server log through the jboss-logging listener; spec §7.5). The login
 * itself is Keycloak's {@code LOGIN} event; {@link #onParentFlowSuccess} puts
 * {@code sky_method=email_code} on it when the subflow ends in the same request as the login.
 *
 * <p>The first page also offers passkeys the way Keycloak's username form does (conditional UI,
 * {@link WebAuthnConditionalUIAuthenticator}): a passkey assertion posted to this page is
 * Keycloak's own passkey sign-in. "Parolanla gir" is the theme's switch to the password form
 * (Keycloak's {@code authenticationExecution} selection), not this step's.
 */
public final class EmailCodeAuthenticator implements AuthenticationFlowCallback {

    private static final Logger LOG = Logger.getLogger(EmailCodeAuthenticator.class);

    public static final String PROVIDER_ID = "sky-email-code";
    /** The page: {@code theme-resources/templates/} of this extension, drawn by the SKY LAB theme. */
    static final String TEMPLATE = "sky-email-code.ftl";
    /**
     * The mail ({@code theme-resources/templates/{text,html}/}); public because the SkyMail provider
     * routes this mail to {@code keycloak.login-code} by exactly this name.
     */
    public static final String MAIL_TEMPLATE = "sky-login-code.ftl";

    static final String ACTION_PARAM = "sky-email-code-action";
    static final String IDENTIFIER_PARAM = "username";
    static final String CODE_PARAM = "code";
    static final String SEND = "send";
    static final String VERIFY = "verify";
    static final String RESEND = "resend";
    static final String CHANGE = "change";

    static final String STAGE_ATTRIBUTE = "skyEmailCodeStage";
    static final String IDENTIFIER_ATTRIBUTE = "skyEmailCodeIdentifier";
    static final String ERROR_ATTRIBUTE = "skyEmailCodeError";
    static final String ATTEMPTS_LEFT_ATTRIBUTE = "skyEmailCodeAttemptsLeft";
    static final String CODE_MINUTES_ATTRIBUTE = "skyEmailCodeMinutes";
    static final String RESEND_AFTER_ATTRIBUTE = "skyEmailCodeResendAfter";

    /** The handle of this session's code in {@link LoginCodes}. */
    static final String HANDLE_NOTE = "sky-email-code.handle";
    /** What the person typed, to show it again and to resend. */
    static final String IDENTIFIER_NOTE = "sky-email-code.identifier";
    /** When the last code was asked for (epoch seconds), for the resend wait. */
    static final String SENT_AT_NOTE = "sky-email-code.sent-at";
    /** Set once the code signed the person in; {@link #onParentFlowSuccess} reads it. */
    static final String METHOD_NOTE = "sky-email-code.method";

    static final String METHOD_DETAIL = "sky_method";
    static final String METHOD = "email_code";
    /** The event detail that says what happened: wrong_code, rate_limited, account_locked, … */
    static final String EVENT_DETAIL = "sky_email_code";
    static final String RATE_LIMITED_ERROR = "sky_email_code_rate_limited";
    /** The event detail of a person with OTP refused because the flow would skip it. */
    static final String OTP_UNGUARDED = "otp_unguarded";

    /** What a code is for, in the mail; only sign-in here. */
    static final String PURPOSE_LOGIN = "login";
    static final int RESEND_SECONDS = 60;
    static final int MAX_IDENTIFIER_LENGTH = 255;
    private static final int HANDLE_BYTES = 32;

    /** Which part of the page is shown. */
    enum Stage {
        IDENTIFIER("identifier"), CODE("code");

        final String value;

        Stage(String value) {
            this.value = value;
        }
    }

    /** The page's error codes; the theme turns each into one sentence. */
    enum Problem {
        INVALID_IDENTIFIER("invalid_identifier"),
        RATE_LIMITED("rate_limited"),
        RESEND_TOO_SOON("resend_too_soon"),
        MALFORMED_CODE("malformed_code"),
        WRONG_CODE("wrong_code"),
        CODE_EXPIRED("code_expired"),
        TOO_MANY_TRIES("too_many_tries"),
        NO_ACCOUNT("no_account"),
        ACCOUNT_DISABLED("account_disabled"),
        ACCOUNT_LOCKED("account_locked"),
        /** The flow no longer asks a person with OTP for it after the code (security review K1). */
        UNAVAILABLE("unavailable");

        final String value;

        Problem(String value) {
            this.value = value;
        }
    }

    private final EmailCodeSettings settings;
    private final LoginCodeMail mail;
    private final WebAuthnConditionalUIAuthenticator webauthn;

    EmailCodeAuthenticator(EmailCodeSettings settings, LoginCodeMail mail, WebAuthnConditionalUIAuthenticator webauthn) {
        this.settings = settings;
        this.mail = mail;
        this.webauthn = webauthn;
    }

    @Override
    public void authenticate(AuthenticationFlowContext context) {
        if (waiting(context) != null) {
            context.challenge(codePage(context, null, null));
            return;
        }
        String identifier = context.getAuthenticationSession().getAuthNote(IDENTIFIER_NOTE);
        if (identifier == null) {
            identifier = context.getAuthenticationSession().getClientNote(OIDCLoginProtocol.LOGIN_HINT_PARAM);
        }
        context.challenge(identifierPage(context, identifier, null));
    }

    @Override
    public void action(AuthenticationFlowContext context) {
        MultivaluedMap<String, String> form = context.getHttpRequest().getDecodedFormParameters();
        if (passkeysEnabled()
                && (form.containsKey(WebAuthnConstants.AUTHENTICATOR_DATA) || form.containsKey(WebAuthnConstants.ERROR))) {
            webauthn.action(context);
            return;
        }
        String action = form.getFirst(ACTION_PARAM);
        if (SEND.equals(action)) {
            send(context, form.getFirst(IDENTIFIER_PARAM));
        } else if (RESEND.equals(action)) {
            resend(context);
        } else if (VERIFY.equals(action)) {
            verify(context, form.getFirst(CODE_PARAM));
        } else if (CHANGE.equals(action)) {
            discardCode(context);
            context.challenge(identifierPage(context, context.getAuthenticationSession().getAuthNote(IDENTIFIER_NOTE), null));
        } else {
            authenticate(context);
        }
    }

    /**
     * The subflow this step opens ended: when the code signed the person in, the login event of this
     * request says so. Keycloak calls it in the request that finishes the subflow (after the TOTP
     * page or the passkey offer, if they came), which is the request of the {@code LOGIN} event
     * unless a required action shows a page after it.
     */
    @Override
    public void onParentFlowSuccess(AuthenticationFlowContext context) {
        if (METHOD.equals(context.getAuthenticationSession().getAuthNote(METHOD_NOTE))) {
            context.getEvent().detail(METHOD_DETAIL, METHOD);
        }
    }

    // ------------------------------------------------------------------------------- sending

    /** "Kod gönder": the session and IP class budgets, then a code (mailed or not). */
    private void send(AuthenticationFlowContext context, String typed) {
        String identifier = typed == null ? "" : typed.strip();
        if (identifier.isEmpty() || identifier.length() > MAX_IDENTIFIER_LENGTH) {
            context.challenge(identifierPage(context, null, Problem.INVALID_IDENTIFIER));
            return;
        }
        if (!claimRequestBudgets(context)) {
            failure(context, null, Problem.RATE_LIMITED.value, RATE_LIMITED_ERROR);
            context.challenge(identifierPage(context, identifier, Problem.RATE_LIMITED));
            return;
        }
        issue(context, identifier);
    }

    /** "Kodu yeniden gönder": the same identifier, at most once a minute, within the same budgets. */
    private void resend(AuthenticationFlowContext context) {
        String identifier = context.getAuthenticationSession().getAuthNote(IDENTIFIER_NOTE);
        if (identifier == null) {
            context.challenge(identifierPage(context, null, null));
            return;
        }
        if (secondsUntilResend(context) > 0) {
            context.challenge(codePage(context, Problem.RESEND_TOO_SOON, null));
            return;
        }
        if (!claimRequestBudgets(context)) {
            failure(context, null, Problem.RATE_LIMITED.value, RATE_LIMITED_ERROR);
            context.challenge(codePage(context, Problem.RATE_LIMITED, null));
            return;
        }
        issue(context, identifier);
    }

    /**
     * Whom the identifier names, where their codes go, the address budgets, then this session's new
     * code: mailed to that address, or never mailed when there is nobody to mail it to or the
     * address budget is spent. The page is the code page either way.
     */
    private void issue(AuthenticationFlowContext context, String identifier) {
        KeycloakSession session = context.getSession();
        RealmModel realm = context.getRealm();
        AuthenticationSessionModel authSession = context.getAuthenticationSession();
        LoginIdentifiers.Match match = LoginIdentifiers.resolve(session, realm, settings.ytuIdpAlias(), identifier);
        UserModel user = match instanceof LoginIdentifiers.Person person ? person.user() : null;
        String address = user == null ? null : destination(session, realm, user);
        LoginCodes codes = new LoginCodes(session.singleUseObjects());
        String previousHandle = authSession.getAuthNote(HANDLE_NOTE);

        // Charged for nobody too, under what was typed, so the work and the answer are the same.
        String budgetAddress = PersonalEmailProof.normalise(address != null ? address : identifier);
        boolean withinBudget = claimAddressBudgets(context, budgetAddress);
        if (!withinBudget) {
            failure(context, user, "rate_limited_address", RATE_LIMITED_ERROR);
        }

        // A new code always replaces the old one, mailed or not: had a code already mailed kept
        // working past the address budget, its tries left would tell whether two identifiers name
        // one account (security review B3).
        codes.discard(previousHandle);
        if (withinBudget && user != null && address != null) {
            String handle = handle();
            String code = codes.issue(handle, user.getId(), address);
            authSession.setAuthNote(HANDLE_NOTE, handle);
            mail.sendCode(context, user, address, code, PURPOSE_LOGIN);
            countTowardTheDailyBudget(context);
        } else {
            authSession.setAuthNote(HANDLE_NOTE, newHandle(codes, "", ""));
        }
        remember(authSession, identifier);
        context.challenge(codePage(context, null, null));
    }

    /**
     * One slot of the overall daily budget. It never stops a sign-in code; the claim that takes the
     * middle slot and the one that takes the last raise the operator alarm, each exactly once a day.
     */
    private void countTowardTheDailyBudget(AuthenticationFlowContext context) {
        int dailyLimit = settings.dailyLimit();
        int slot = new RateLimiter(context.getSession().singleUseObjects())
                .claimSlot(RateLimiter.loginCodesPerDay(dailyLimit), context.getRealm().getId());
        if (dailyLimit >= 2 && slot == dailyLimit / 2) {
            mail.alarm(context, LoginCodeMail.HALF, dailyLimit);
        } else if (slot == dailyLimit) {
            mail.alarm(context, LoginCodeMail.FULL, dailyLimit);
        }
    }

    /**
     * Where a person's Login codes go (spec S4): the Primary e-mail; without one, the School e-mail
     * of a Verified YTÜ account; nowhere for a disabled account or a service account.
     */
    String destination(KeycloakSession session, RealmModel realm, UserModel user) {
        if (!user.isEnabled() || user.getServiceAccountClientLink() != null) {
            return null;
        }
        String primary = trimmed(user.getEmail());
        if (primary != null) {
            return primary;
        }
        String school = trimmed(user.getFirstAttribute(IdentityResource.SCHOOL_EMAIL_ATTRIBUTE));
        if (school != null && session.users().getFederatedIdentity(realm, user, settings.ytuIdpAlias()) != null) {
            return school;
        }
        return null;
    }

    // ------------------------------------------------------------------------------- the code

    /** The code from the mail: right once, wrong at most five times, dead after ten minutes. */
    private void verify(AuthenticationFlowContext context, String typed) {
        AuthenticationSessionModel authSession = context.getAuthenticationSession();
        String handle = authSession.getAuthNote(HANDLE_NOTE);
        LoginCodes codes = new LoginCodes(context.getSession().singleUseObjects());
        if (handle == null || codes.peek(handle) == null) {
            expired(context, null);
            return;
        }
        String code = PersonalEmailVerification.codeFromInput(typed);
        if (code == null) {
            context.challenge(codePage(context, Problem.MALFORMED_CODE, null));
            return;
        }
        LoginCodes.Outcome outcome = codes.confirm(handle, code);
        switch (outcome.status()) {
            case NONE -> expired(context, null);
            case WRONG_CODE -> wrongCode(context, outcome);
            case CONFIRMED -> confirmed(context, outcome.pending());
        }
    }

    private void wrongCode(AuthenticationFlowContext context, LoginCodes.Outcome outcome) {
        UserModel user = isBlank(outcome.userId()) ? null
                : context.getSession().users().getUserById(context.getRealm(), outcome.userId());
        if (user != null) {
            recordFailedLogin(context, user);
        }
        failure(context, user, Problem.WRONG_CODE.value, Errors.INVALID_CODE);
        if (outcome.attemptsLeft() > 0) {
            context.challenge(codePage(context, Problem.WRONG_CODE, outcome.attemptsLeft()));
        } else {
            discardCode(context);
            context.challenge(identifierPage(context, identifierOf(context), Problem.TOO_MANY_TRIES));
        }
    }

    private void expired(AuthenticationFlowContext context, UserModel user) {
        discardCode(context);
        failure(context, user, Problem.CODE_EXPIRED.value, Errors.EXPIRED_CODE);
        context.challenge(identifierPage(context, identifierOf(context), Problem.CODE_EXPIRED));
    }

    /** The right code: the person, if there is one who may sign in now, goes on to TOTP and the rest. */
    private void confirmed(AuthenticationFlowContext context, LoginCodes.Pending pending) {
        KeycloakSession session = context.getSession();
        RealmModel realm = context.getRealm();
        AuthenticationSessionModel authSession = context.getAuthenticationSession();
        String identifier = identifierOf(context);
        discardCode(context);

        UserModel user = isBlank(pending.userId()) ? null : session.users().getUserById(realm, pending.userId());
        if (user == null) {
            failure(context, null, Problem.NO_ACCOUNT.value, Errors.USER_NOT_FOUND);
            context.challenge(identifierPage(context, identifier, Problem.NO_ACCOUNT));
            return;
        }
        if (!user.isEnabled()) {
            failure(context, user, Problem.ACCOUNT_DISABLED.value, Errors.USER_DISABLED);
            context.challenge(identifierPage(context, identifier, Problem.ACCOUNT_DISABLED));
            return;
        }
        String bruteForceError = AuthenticatorUtils.getDisabledByBruteForceEventError(context, user);
        if (bruteForceError != null) {
            failure(context, user, Problem.ACCOUNT_LOCKED.value, bruteForceError);
            context.challenge(identifierPage(context, identifier, Problem.ACCOUNT_LOCKED));
            return;
        }
        String destination = destination(session, realm, user);
        if (destination == null || !destination.equalsIgnoreCase(pending.address())) {
            expired(context, user);
            return;
        }
        if (user.credentialManager().isConfiguredFor(OTPCredentialModel.TYPE)
                && !OtpAfterCode.asked(session, realm, context.getExecution())) {
            // No person, address or IP: the realm and what to do.
            LOG.errorf("sky_email_code_otp_unguarded realm=%s: the e-mail code subflow no longer asks for OTP"
                    + " after the code, so a person with OTP is refused; run the reconciler with"
                    + " KEYCLOAK_EMAIL_CODE_LOGIN=on (or off)", realm.getName());
            failure(context, user, OTP_UNGUARDED, Errors.INVALID_CONFIG);
            context.challenge(identifierPage(context, identifier, Problem.UNAVAILABLE));
            return;
        }
        if (destination.equalsIgnoreCase(trimmed(user.getEmail())) && !user.isEmailVerified()) {
            user.setEmailVerified(true);
            user.removeRequiredAction(UserModel.RequiredAction.VERIFY_EMAIL);
        }
        if (identifier != null) {
            // As the password form leaves it: the login event and the session name what was typed.
            authSession.setAuthNote(AbstractUsernameFormAuthenticator.ATTEMPTED_USERNAME, identifier);
        }
        authSession.removeAuthNote(IDENTIFIER_NOTE);
        authSession.setAuthNote(METHOD_NOTE, METHOD);
        context.getEvent().detail(METHOD_DETAIL, METHOD);
        context.setUser(user);
        context.success();
    }

    /**
     * What {@code AuthenticationProcessor.logFailure} does for a wrong password: Keycloak's
     * brute-force protector counts a failure for the person. No authentication category: Keycloak
     * counts a failure without one, and a Login code is none of password, OTP or recovery code.
     */
    private static void recordFailedLogin(AuthenticationFlowContext context, UserModel user) {
        if (context.getRealm().isBruteForceProtected()) {
            context.getProtector().failedLogin(context.getRealm(), user, context.getConnection(),
                    context.getUriInfo(), null);
        }
    }

    // ------------------------------------------------------------------------------- budgets

    /** The budgets every request for a code spends: this sign-in session's and its IP class's. */
    private static boolean claimRequestBudgets(AuthenticationFlowContext context) {
        KeycloakSession session = context.getSession();
        RealmModel realm = context.getRealm();
        AuthenticationSessionModel authSession = context.getAuthenticationSession();
        String remote = context.getConnection() == null ? null : context.getConnection().getRemoteAddr();
        RateLimiter limiter = new RateLimiter(session.singleUseObjects());
        return limiter.claim(RateLimiter.LOGIN_CODE_SESSION, BudgetKeys.keyed(session, realm,
                        "session:" + authSession.getParentSession().getId() + "/" + authSession.getTabId())) == 0
                && limiter.claim(RateLimiter.LOGIN_CODE_IP_CLASS,
                        BudgetKeys.keyed(session, realm, "ip-class:" + BudgetKeys.ipClass(remote))) == 0;
    }

    /** At most three codes a quarter of an hour and ten a day to one address. */
    private static boolean claimAddressBudgets(AuthenticationFlowContext context, String address) {
        KeycloakSession session = context.getSession();
        String key = BudgetKeys.keyed(session, context.getRealm(), "address:" + address);
        RateLimiter limiter = new RateLimiter(session.singleUseObjects());
        return limiter.claim(RateLimiter.LOGIN_CODE_ADDRESS, key) == 0
                && limiter.claim(RateLimiter.LOGIN_CODE_ADDRESS_DAY, key) == 0;
    }

    // ------------------------------------------------------------------------------- the page

    private Response identifierPage(AuthenticationFlowContext context, String identifier, Problem problem) {
        if (passkeysEnabled()) {
            webauthn.fillContextForm(context);
        }
        return identifierForm(context, identifier, problem);
    }

    /**
     * The first page after a failed passkey: Keycloak's passkey authenticator has put its error and
     * a new challenge on the form already ({@code WebAuthnConditionalUIAuthenticator}).
     */
    static Response passkeyErrorPage(AuthenticationFlowContext context) {
        return identifierForm(context, identifierOf(context), null);
    }

    private static Response identifierForm(AuthenticationFlowContext context, String identifier, Problem problem) {
        LoginFormsProvider form = context.form()
                .setAttribute(STAGE_ATTRIBUTE, Stage.IDENTIFIER.value)
                .setAttribute(CODE_MINUTES_ATTRIBUTE, Integer.toString(LoginCodes.TTL_SECONDS / 60));
        if (identifier != null) {
            form.setAttribute(IDENTIFIER_ATTRIBUTE, identifier);
        }
        if (problem != null) {
            form.setAttribute(ERROR_ATTRIBUTE, problem.value);
        }
        return form.createForm(TEMPLATE);
    }

    private Response codePage(AuthenticationFlowContext context, Problem problem, Integer attemptsLeft) {
        LoginFormsProvider form = context.form()
                .setAttribute(STAGE_ATTRIBUTE, Stage.CODE.value)
                .setAttribute(CODE_MINUTES_ATTRIBUTE, Integer.toString(LoginCodes.TTL_SECONDS / 60))
                .setAttribute(RESEND_AFTER_ATTRIBUTE, Integer.toString(secondsUntilResend(context)));
        String identifier = identifierOf(context);
        if (identifier != null) {
            form.setAttribute(IDENTIFIER_ATTRIBUTE, identifier);
        }
        if (problem != null) {
            form.setAttribute(ERROR_ATTRIBUTE, problem.value);
        }
        if (attemptsLeft != null) {
            form.setAttribute(ATTEMPTS_LEFT_ATTRIBUTE, Integer.toString(attemptsLeft));
        }
        return form.createForm(TEMPLATE);
    }

    // ------------------------------------------------------------------------------- session state

    private static LoginCodes.Waiting waiting(AuthenticationFlowContext context) {
        String handle = context.getAuthenticationSession().getAuthNote(HANDLE_NOTE);
        return handle == null ? null : new LoginCodes(context.getSession().singleUseObjects()).peek(handle);
    }

    private static void remember(AuthenticationSessionModel authSession, String identifier) {
        authSession.setAuthNote(IDENTIFIER_NOTE, identifier);
        authSession.setAuthNote(SENT_AT_NOTE, Integer.toString(Time.currentTime()));
    }

    /** Drops this session's code, so it never works again; what was typed stays for the page. */
    private static void discardCode(AuthenticationFlowContext context) {
        AuthenticationSessionModel authSession = context.getAuthenticationSession();
        new LoginCodes(context.getSession().singleUseObjects()).discard(authSession.getAuthNote(HANDLE_NOTE));
        authSession.removeAuthNote(HANDLE_NOTE);
        authSession.removeAuthNote(SENT_AT_NOTE);
    }

    private static String identifierOf(AuthenticationFlowContext context) {
        return context.getAuthenticationSession().getAuthNote(IDENTIFIER_NOTE);
    }

    private static int secondsUntilResend(AuthenticationFlowContext context) {
        String sentAt = context.getAuthenticationSession().getAuthNote(SENT_AT_NOTE);
        if (sentAt == null) {
            return 0;
        }
        try {
            return Math.max(0, Integer.parseInt(sentAt) + RESEND_SECONDS - Time.currentTime());
        } catch (NumberFormatException malformed) {
            return 0;
        }
    }

    private static String handle() {
        return Base64Url.encode(SecretGenerator.getInstance().randomBytes(HANDLE_BYTES));
    }

    /** A new handle with a code that is never mailed (for nobody), returned for the session note. */
    private static String newHandle(LoginCodes codes, String userId, String address) {
        String handle = handle();
        codes.issue(handle, userId, address);
        return handle;
    }

    /**
     * A refusal of this step: a {@code LOGIN_ERROR} of its own (the flow's event stays as it is),
     * with the method and what happened, the person when known, and neither the IP nor what was
     * typed (spec §7.5; the jboss-logging listener writes events to the server log).
     */
    private static void failure(AuthenticationFlowContext context, UserModel user, String what, String error) {
        EventBuilder event = context.getEvent().clone()
                .ipAddress(null)
                .removeDetail(Details.USERNAME)
                .detail(METHOD_DETAIL, METHOD)
                .detail(EVENT_DETAIL, what);
        if (user != null) {
            event.user(user);
        }
        event.error(error);
    }

    private boolean passkeysEnabled() {
        return webauthn != null && webauthn.isPasskeysEnabled();
    }

    private static String trimmed(String value) {
        return value == null || value.isBlank() ? null : value.trim();
    }

    private static boolean isBlank(String value) {
        return value == null || value.isBlank();
    }

    @Override
    public boolean requiresUser() {
        return false;
    }

    @Override
    public boolean configuredFor(KeycloakSession session, RealmModel realm, UserModel user) {
        return true;
    }

    @Override
    public void setRequiredActions(KeycloakSession session, RealmModel realm, UserModel user) {
        // no-op
    }

    @Override
    public void close() {
        // no-op
    }
}
