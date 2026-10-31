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
import org.keycloak.events.EventType;
import org.keycloak.forms.login.LoginFormsProvider;
import org.keycloak.models.Constants;
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
 * the request, in the background ({@link LoginCodeMail}), so the answer takes the same time. The
 * page never says that an address has no account: the right code of a code nobody was mailed (a
 * guess) gets a dead code's sentence; only the event, for the administrators, says {@code no_account}.
 * A disabled account whose Account erasure is running gets the same page and code; it is mailed,
 * after the request, that the account is being deleted ({@link AccountErasureNotice}).
 *
 * <p>Self-registration (ticket 09, ADR-0063 decision 1, CONTEXT "Self-registration"; off unless the
 * execution's {@value EmailCodeSignUp#CONFIG} setting is {@code true}, {@link EmailCodeSignUp}): an
 * e-mail address that names nobody is mailed a sign-up code instead of none, on the same page, in the
 * same budgets (the overall one stops sign-up codes when it is used up; sign-in codes go on). Only
 * the right code tells the two apart: it opens the sign-up form ({@link EmailCodeSignUp#TEMPLATE}),
 * or, for an address on a YTÜ school domain, sends the person to the YTÜ sign-in and opens nothing
 * (spec S3). The form takes a first and a last name and opens the account
 * ({@link SignUpAccounts}): the proven address as its verified Primary e-mail and Personal e-mail,
 * a username derived from it ({@link SignUpUsernames}), no password, no rights, a {@code REGISTER}
 * event; then the person is signed in. When the address got an account meanwhile (another sign-up,
 * a race), no second account is opened: the code signs the person in to it. A person who came
 * through "Hesap aç" ({@value EmailCodeSignUp#INTENT_PARAM}) and has an account is signed in by the
 * Login code and told so once.
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
 * kept code's tries left would link two identifiers to one account). The overall budget never stops
 * a sign-in code: it alarms the operator at its half and when it is used up. Wrong codes are limited
 * per account and day (security review K2, {@code SKY_EMAIL_CODE_WRONG_CODES_PER_ACCOUNT}, default
 * ten): past that ceiling the account is mailed no code until the day ends, the page stays the
 * same, and a code already mailed is no longer looked at (its tries are spent as wrong ones); the
 * first account of the day at the ceiling alarms the operator. Budget keys are keyed hashes
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
    /**
     * Set once the code signed the person in; {@link #onParentFlowSuccess} reads it, and so does
     * {@code sky-stay-signed-in}, which asks a Login code sign-in whether to stay signed in.
     */
    public static final String METHOD_NOTE = "sky-email-code.method";

    public static final String METHOD_DETAIL = "sky_method";
    public static final String METHOD = "email_code";
    /** The event detail that says what happened: wrong_code, rate_limited, account_locked, … */
    static final String EVENT_DETAIL = "sky_email_code";
    static final String RATE_LIMITED_ERROR = "sky_email_code_rate_limited";
    /** The event detail of a person with OTP refused because the flow would skip it. */
    static final String OTP_UNGUARDED = "otp_unguarded";
    /** The event detail of the right code for nobody; the page shows a dead code's sentence. */
    static final String NO_ACCOUNT = "no_account";
    /**
     * The event detail when the person's wrong codes reached the day's ceiling (security review
     * K2): a code that was not mailed, or a try spent without looking at the code.
     */
    static final String WRONG_CODE_CEILING = "wrong_code_ceiling";
    static final String CONSECUTIVE_CODE_CEILING = "consecutive_code_ceiling";
    /** Self-registration's event details (ticket 09); the events carry no IP and no address. */
    static final String SIGN_UP_PAUSED = "sign_up_paused";
    static final String SCHOOL_DOMAIN = "school_domain";
    static final String SIGN_UP_TAKEN = "sign_up_taken";
    static final String SIGN_UP_OFF = "sign_up_off";
    static final String EXISTING_ACCOUNT = "existing_account";
    static final String REGISTER_METHOD = "email_code";

    /** What a code is for, in the mail: sign-in; a sign-up code is {@link LoginCodes#SIGN_UP_PURPOSE}. */
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
    private final SignUpAccounts accounts;
    private final SignUpUsernames usernames;
    private final LoginCodeFailureCounter persistentFailures;

    EmailCodeAuthenticator(EmailCodeSettings settings, LoginCodeMail mail, WebAuthnConditionalUIAuthenticator webauthn) {
        this(settings, mail, webauthn, new ProfileSignUpAccounts(), new SignUpUsernames());
    }

    EmailCodeAuthenticator(EmailCodeSettings settings, LoginCodeMail mail, WebAuthnConditionalUIAuthenticator webauthn,
            SignUpAccounts accounts, SignUpUsernames usernames) {
        this(settings, mail, webauthn, accounts, usernames, new PersistentLoginCodeFailures());
    }

    EmailCodeAuthenticator(EmailCodeSettings settings, LoginCodeMail mail, WebAuthnConditionalUIAuthenticator webauthn,
            SignUpAccounts accounts, SignUpUsernames usernames, LoginCodeFailureCounter persistentFailures) {
        this.settings = settings;
        this.mail = mail;
        this.webauthn = webauthn;
        this.accounts = accounts;
        this.usernames = usernames;
        this.persistentFailures = persistentFailures;
    }

    @Override
    public void authenticate(AuthenticationFlowContext context) {
        rememberIntent(context);
        if (resumeSignUp(context)) {
            return;
        }
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
        if (EmailCodeSignUp.SIGN_UP.equals(action)) {
            submitSignUp(context, form.getFirst(EmailCodeSignUp.FIRST_NAME_PARAM), form.getFirst(EmailCodeSignUp.LAST_NAME_PARAM));
            return;
        }
        if (EmailCodeSignUp.CONTINUE.equals(action)) {
            continueExisting(context);
            return;
        }
        if (SEND.equals(action) || RESEND.equals(action) || VERIFY.equals(action) || CHANGE.equals(action)) {
            // The code path again: whatever a right code had opened before is closed.
            clearSignUp(context);
        }
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
     * code: mailed to that address; with Self-registration on, a sign-up code mailed to an e-mail
     * address that names nobody; or never mailed when there is nobody to mail it to or a budget is
     * spent. The page is the code page either way.
     */
    private void issue(AuthenticationFlowContext context, String identifier) {
        KeycloakSession session = context.getSession();
        RealmModel realm = context.getRealm();
        AuthenticationSessionModel authSession = context.getAuthenticationSession();
        LoginIdentifiers.Match match = LoginIdentifiers.resolve(session, realm, settings.ytuIdpAlias(), identifier);
        UserModel user = match instanceof LoginIdentifiers.Person person ? person.user() : null;
        String address = user == null ? null : destination(session, realm, user);
        String signUpAddress = match instanceof LoginIdentifiers.Nobody && EmailCodeSignUp.isOn(context)
                && PersonalEmailVerification.isValidAddress(session, identifier)
                ? PersonalEmailProof.normalise(identifier) : null;
        LoginCodes codes = new LoginCodes(session.singleUseObjects());
        String previousHandle = authSession.getAuthNote(HANDLE_NOTE);

        // Charged for nobody too, under what was typed, so the work and the answer are the same.
        String budgetAddress = PersonalEmailProof.normalise(address != null ? address : identifier);
        boolean withinBudget = claimAddressBudgets(context, budgetAddress);
        boolean mailable = user != null && address != null;
        LoginCodeFailureCounter.Guard persistent = withinBudget && mailable
                ? persistentFailures.lock(session, realm, user.getId()) : null;
        if (!withinBudget) {
            failure(context, user, "rate_limited_address", RATE_LIMITED_ERROR);
            signUpAddress = null;
        } else if (mailable && (persistent == null || persistent.blocked())) {
            failure(context, user, CONSECUTIVE_CODE_CEILING, RATE_LIMITED_ERROR);
            mailable = false;
        } else if (mailable && pastCeiling(context, accountCeilingKey(context, user.getId()))) {
            // Security review K2: no code reaches the account for the rest of the day; the page
            // and the code that is never mailed are the ones anybody else gets.
            failure(context, user, WRONG_CODE_CEILING, RATE_LIMITED_ERROR);
            mailable = false;
        } else if (signUpAddress != null && pastCeiling(context, signUpCeilingKey(context, signUpAddress))) {
            // The same ceiling for an address being signed up: no more guesses at its codes today.
            signUpFailure(context, WRONG_CODE_CEILING, RATE_LIMITED_ERROR);
            signUpAddress = null;
        } else if (signUpAddress != null && dailyBudgetSpent(context)) {
            // Spec §7.2: at the overall budget sign-up codes stop; sign-in codes go on.
            signUpFailure(context, SIGN_UP_PAUSED, RATE_LIMITED_ERROR);
            signUpAddress = null;
        }

        // A new code always replaces the old one, mailed or not: had a code already mailed kept
        // working past the address budget, its tries left would tell whether two identifiers name
        // one account (security review B3).
        codes.discard(previousHandle);
        if (withinBudget && mailable) {
            String handle = handle();
            String code = codes.issue(handle, user.getId(), address);
            authSession.setAuthNote(HANDLE_NOTE, handle);
            mail.sendCode(context, user, address, code, PURPOSE_LOGIN);
            countTowardTheDailyBudget(context);
        } else if (signUpAddress != null) {
            String handle = handle();
            String code = codes.issueSignUp(handle, signUpAddress);
            authSession.setAuthNote(HANDLE_NOTE, handle);
            mail.sendSignUpCode(context, signUpAddress, code);
            countTowardTheDailyBudget(context);
        } else {
            authSession.setAuthNote(HANDLE_NOTE, newHandle(codes, "", ""));
            if (withinBudget && user != null && !user.isEnabled()) {
                // Whether the person is being erased, and the notice, are decided after the
                // request (AccountErasureNotice): the page and its time stay those of any code
                // that is never mailed, and a person an administrator disabled still gets nothing.
                mail.sendErasureNotice(context, user);
            }
        }
        remember(authSession, identifier);
        context.challenge(codePage(context, null, null));
    }

    /** Whether today's overall budget of Login codes is used up (sign-up codes stop there). */
    private boolean dailyBudgetSpent(AuthenticationFlowContext context) {
        return new RateLimiter(context.getSession().singleUseObjects())
                .spent(RateLimiter.loginCodesPerDay(settings.dailyLimit()), context.getRealm().getId());
    }

    /**
     * One slot of the overall daily budget. It never stops a sign-in code; the claim that takes the
     * middle slot and the one that takes the last raise the operator alarm, each exactly once a day.
     */
    void countTowardTheDailyBudget(AuthenticationFlowContext context) {
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
        return mailbox(session, realm, user, settings.ytuIdpAlias());
    }

    /**
     * The address a person's mail from this step goes to, whether or not they may sign in: the
     * Primary e-mail, or the School e-mail of a Verified YTÜ account; null when there is neither.
     */
    static String mailbox(KeycloakSession session, RealmModel realm, UserModel user, String ytuIdpAlias) {
        String primary = trimmed(user.getEmail());
        if (primary != null) {
            return primary;
        }
        String school = trimmed(user.getFirstAttribute(IdentityResource.SCHOOL_EMAIL_ATTRIBUTE));
        if (school != null && session.users().getFederatedIdentity(realm, user, ytuIdpAlias) != null) {
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
        LoginCodes.Waiting waiting = handle == null ? null : codes.peek(handle);
        if (waiting == null) {
            expired(context, null);
            return;
        }
        String code = LoginCodes.codeFromInput(typed);
        if (code == null) {
            context.challenge(codePage(context, Problem.MALFORMED_CODE, null));
            return;
        }
        // Past the person's ceiling of wrong codes no code is looked at: the try is spent as a
        // wrong one, so the page is the one any wrong code gets (security review K2). A sign-up
        // code has the same ceiling, per address.
        String userId = accountAtVerification(context, waiting);
        String signUpCeiling = isBlank(waiting.signUpAddress()) ? null
                : signUpCeilingKey(context, waiting.signUpAddress());
        String ceilingKey = isBlank(userId) ? signUpCeiling : accountCeilingKey(context, userId);
        boolean pastCeiling = (ceilingKey != null && pastCeiling(context, ceilingKey))
                || (signUpCeiling != null && pastCeiling(context, signUpCeiling));
        LoginCodeFailureCounter.Guard persistent = isBlank(userId) ? null
                : persistentFailures.lock(context.getSession(), context.getRealm(), userId);
        boolean persistentBlocked = !isBlank(userId) && (persistent == null || persistent.blocked());
        boolean suppressed = pastCeiling || persistentBlocked;
        LoginCodes.Outcome outcome = suppressed ? codes.spendTry(handle) : codes.confirm(handle, code);
        if (outcome.status() == LoginCodes.Outcome.Status.WRONG_CODE && !suppressed && persistent != null
                && persistent.wrongCode()) {
            mail.consecutiveAlarm(context, LoginCodeFailureCounter.LIMIT);
        }
        switch (outcome.status()) {
            case NONE -> expired(context, null);
            case WRONG_CODE -> wrongCode(context, outcome, userId, ceilingKey, signUpCeiling, suppressed, persistentBlocked);
            case CONFIRMED -> confirmed(context, outcome.pending());
        }
    }

    /** A sign-up address can acquire an account after its code was mailed, before this try. */
    private String accountAtVerification(AuthenticationFlowContext context, LoginCodes.Waiting waiting) {
        if (!isBlank(waiting.userId())) {
            return waiting.userId();
        }
        if (!isBlank(waiting.signUpAddress()) && LoginIdentifiers.resolve(context.getSession(), context.getRealm(),
                settings.ytuIdpAlias(), waiting.signUpAddress()) instanceof LoginIdentifiers.Person person) {
            String address = destination(context.getSession(), context.getRealm(), person.user());
            if (address != null && address.equalsIgnoreCase(waiting.signUpAddress())) {
                return person.user().getId();
            }
        }
        return null;
    }

    private void wrongCode(AuthenticationFlowContext context, LoginCodes.Outcome outcome, String userId,
            String ceilingKey, String signUpCeiling, boolean pastCeiling, boolean persistentBlocked) {
        UserModel user = isBlank(userId) ? null
                : context.getSession().users().getUserById(context.getRealm(), userId);
        if (user != null) {
            recordFailedLogin(context, user);
            if (!pastCeiling) {
                countTowardTheCeiling(context, user, ceilingKey);
            }
        }
        if (signUpCeiling != null && !pastCeiling) {
            countTowardTheSignUpCeiling(context, signUpCeiling);
        }
        String reason = persistentBlocked ? CONSECUTIVE_CODE_CEILING
                : pastCeiling ? WRONG_CODE_CEILING : Problem.WRONG_CODE.value;
        failure(context, user, reason, Errors.INVALID_CODE);
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
        String identifier = identifierOf(context);
        discardCode(context);
        if (pending.signUp()) {
            signUpCodeConfirmed(context, pending.address(), identifier);
            return;
        }

        UserModel user = isBlank(pending.userId()) ? null : session.users().getUserById(realm, pending.userId());
        if (user == null) {
            // A code nobody was mailed, guessed, or the account went away in the ten minutes. The
            // page says what it says for a dead code: "no account" would tell an address apart
            // (the code page itself never does). Only the event, for the administrators, says it.
            failure(context, null, NO_ACCOUNT, Errors.USER_NOT_FOUND);
            context.challenge(identifierPage(context, identifier, Problem.CODE_EXPIRED));
            return;
        }
        if (!admitted(context, user, pending.address(), identifier)) {
            return;
        }
        if (EmailCodeSignUp.INTENT_SIGN_UP.equals(context.getAuthenticationSession().getAuthNote(EmailCodeSignUp.INTENT_NOTE))) {
            // "Hesap aç" with an address that has an account: the code signs the person in, and the
            // page says so once (spec §7.4) before the sign-in goes on.
            showExisting(context, user, pending.address());
            return;
        }
        signIn(context, user, pending.address(), identifier);
    }

    /**
     * Whether {@code user} may be signed in now by a code that went to {@code address}: enabled, not
     * locked, the address still where the person's codes go, OTP still asked when the person has it.
     * When not, the refusal is written and the page is challenged.
     */
    private boolean admitted(AuthenticationFlowContext context, UserModel user, String address, String identifier) {
        KeycloakSession session = context.getSession();
        RealmModel realm = context.getRealm();
        if (!user.isEnabled()) {
            failure(context, user, Problem.ACCOUNT_DISABLED.value, Errors.USER_DISABLED);
            context.challenge(identifierPage(context, identifier, Problem.ACCOUNT_DISABLED));
            return false;
        }
        String bruteForceError = AuthenticatorUtils.getDisabledByBruteForceEventError(context, user);
        if (bruteForceError != null) {
            failure(context, user, Problem.ACCOUNT_LOCKED.value, bruteForceError);
            context.challenge(identifierPage(context, identifier, Problem.ACCOUNT_LOCKED));
            return false;
        }
        String destination = destination(session, realm, user);
        if (destination == null || !destination.equalsIgnoreCase(address)) {
            expired(context, user);
            return false;
        }
        if (user.credentialManager().isConfiguredFor(OTPCredentialModel.TYPE)
                && !OtpAfterCode.asked(session, realm, context.getExecution())) {
            // No person, address or IP: the realm and what to do.
            LOG.errorf("sky_email_code_otp_unguarded realm=%s: the e-mail code subflow no longer asks for OTP"
                    + " after the code, so a person with OTP is refused; run the reconciler with"
                    + " KEYCLOAK_EMAIL_CODE_LOGIN=on (or off)", realm.getName());
            failure(context, user, OTP_UNGUARDED, Errors.INVALID_CONFIG);
            context.challenge(identifierPage(context, identifier, Problem.UNAVAILABLE));
            return false;
        }
        // A fixed proof shown on the existing-account sign-up page can outlive another session's
        // hundredth failure. Recheck under the same user lock before dispatching that proof too.
        LoginCodeFailureCounter.Guard persistent = persistentFailures.lock(session, realm, user.getId());
        if (persistent == null || persistent.blocked()) {
            clearSignUp(context);
            expired(context, user);
            return false;
        }
        return true;
    }

    /** The code signs {@code user} in: the flow goes on to TOTP and the rest. */
    private void signIn(AuthenticationFlowContext context, UserModel user, String address, String identifier) {
        AuthenticationSessionModel authSession = context.getAuthenticationSession();
        if (address.equalsIgnoreCase(trimmed(user.getEmail())) && !user.isEmailVerified()) {
            user.setEmailVerified(true);
            user.removeRequiredAction(UserModel.RequiredAction.VERIFY_EMAIL);
        }
        if (identifier != null) {
            // As the password form leaves it: the login event and the session name what was typed.
            authSession.setAuthNote(AbstractUsernameFormAuthenticator.ATTEMPTED_USERNAME, identifier);
        }
        clearSignUp(context);
        authSession.removeAuthNote(EmailCodeSignUp.INTENT_NOTE);
        authSession.removeAuthNote(IDENTIFIER_NOTE);
        authSession.setAuthNote(METHOD_NOTE, METHOD);
        context.getEvent().detail(METHOD_DETAIL, METHOD);
        context.setUser(user);
        context.success();
    }

    // ------------------------------------------------------------------------------- sign-up

    /**
     * "Hesap aç" ({@value EmailCodeSignUp#INTENT_PARAM}) travels with Keycloak's execution switch to
     * this step; any other switch to it is plain "E-postayla devam et". Remembered only while
     * Self-registration is on.
     */
    private static void rememberIntent(AuthenticationFlowContext context) {
        MultivaluedMap<String, String> form = context.getHttpRequest().getDecodedFormParameters();
        if (form == null || !form.containsKey(Constants.AUTHENTICATION_EXECUTION)) {
            return;
        }
        AuthenticationSessionModel authSession = context.getAuthenticationSession();
        if (EmailCodeSignUp.INTENT_SIGN_UP.equals(form.getFirst(EmailCodeSignUp.INTENT_PARAM)) && EmailCodeSignUp.isOn(context)) {
            authSession.setAuthNote(EmailCodeSignUp.INTENT_NOTE, EmailCodeSignUp.INTENT_SIGN_UP);
        } else {
            authSession.removeAuthNote(EmailCodeSignUp.INTENT_NOTE);
        }
    }

    /**
     * The right sign-up code proved {@code address}. Who has it now decides: an account whose codes
     * go there (one opened meanwhile) is signed in; one that holds it otherwise, two accounts, or
     * Self-registration turned off meanwhile open nothing; a YTÜ school address goes to the YTÜ
     * sign-in (spec S3); any other opens the form.
     */
    private void signUpCodeConfirmed(AuthenticationFlowContext context, String address, String identifier) {
        if (signedInToAnAccountThatHasIt(context, address, identifier)) {
            return;
        }
        if (PersonalEmailVerification.isSchoolDomain(address)) {
            signUpFailure(context, SCHOOL_DOMAIN, Errors.INVALID_REGISTRATION);
            showStage(context, EmailCodeSignUp.Stage.YTU, address);
            return;
        }
        if (!signUpPossible(context, address)) {
            return;
        }
        AuthenticationSessionModel authSession = context.getAuthenticationSession();
        authSession.setAuthNote(EmailCodeSignUp.ADDRESS_NOTE, address);
        authSession.setAuthNote(EmailCodeSignUp.PROVEN_AT_NOTE, Integer.toString(Time.currentTime()));
        context.challenge(EmailCodeSignUp.page(context, EmailCodeSignUp.Stage.FORM, address, null, null, null, null));
    }

    /**
     * When {@code address} now names a person whose codes go there, that person is signed in by the
     * proof (shown the existing stage first) and true is returned. Nobody is signed in by an address
     * that is not where their codes go.
     */
    private boolean signedInToAnAccountThatHasIt(AuthenticationFlowContext context, String address, String identifier) {
        KeycloakSession session = context.getSession();
        RealmModel realm = context.getRealm();
        if (!(LoginIdentifiers.resolve(session, realm, settings.ytuIdpAlias(), address)
                instanceof LoginIdentifiers.Person person)) {
            return false;
        }
        UserModel user = person.user();
        String destination = destination(session, realm, user);
        if (destination == null || !destination.equalsIgnoreCase(address)) {
            return false;
        }
        if (admitted(context, user, address, identifier)) {
            showExisting(context, user, address);
        }
        return true;
    }

    /**
     * Whether an account may be opened for {@code address} now; when not, the refusal is written and
     * the unavailable stage is challenged.
     */
    private boolean signUpPossible(AuthenticationFlowContext context, String address) {
        KeycloakSession session = context.getSession();
        RealmModel realm = context.getRealm();
        if (!EmailCodeSignUp.isOn(context)) {
            signUpFailure(context, SIGN_UP_OFF, Errors.REGISTRATION_DISABLED);
            showStage(context, EmailCodeSignUp.Stage.UNAVAILABLE, address);
            return false;
        }
        if (!(LoginIdentifiers.resolve(session, realm, settings.ytuIdpAlias(), address) instanceof LoginIdentifiers.Nobody)
                || PersonalEmailVerification.isTakenByAnother(session, realm, null, address)) {
            signUpFailure(context, SIGN_UP_TAKEN, Errors.EMAIL_IN_USE);
            showStage(context, EmailCodeSignUp.Stage.UNAVAILABLE, address);
            return false;
        }
        return true;
    }

    /** "Hesabı aç": the names, then the account, then the sign-in. */
    private void submitSignUp(AuthenticationFlowContext context, String typedFirstName, String typedLastName) {
        KeycloakSession session = context.getSession();
        AuthenticationSessionModel authSession = context.getAuthenticationSession();
        String address = provenAddress(authSession);
        if (address == null) {
            clearSignUp(context);
            authenticate(context);
            return;
        }
        String identifier = identifierOf(context);
        String firstName = IdentityResource.normalisePersonName(typedFirstName == null ? "" : typedFirstName);
        String lastName = IdentityResource.normalisePersonName(typedLastName == null ? "" : typedLastName);
        EmailCodeSignUp.Problem problem = nameProblem(firstName, true);
        if (problem == null) {
            problem = nameProblem(lastName, false);
        }
        if (problem != null) {
            context.challenge(EmailCodeSignUp.page(context, EmailCodeSignUp.Stage.FORM, address, problem, firstName,
                    lastName, null));
            return;
        }
        String lock = addressLockKey(context, address);
        if (!session.singleUseObjects().putIfAbsent(lock, EmailCodeSignUp.LOCK_SECONDS)) {
            // Another sign-up of this address is opening its account, or just opened it.
            if (!signedInToAnAccountThatHasIt(context, address, identifier)) {
                context.challenge(EmailCodeSignUp.page(context, EmailCodeSignUp.Stage.FORM, address,
                        EmailCodeSignUp.Problem.TRY_AGAIN, firstName, lastName, null));
            }
            return;
        }
        // The lock stays for its minute once an account is opened (a second sign-up of the address
        // then finds that account); it goes at once when none was.
        UserModel user = null;
        try {
            user = openAccount(context, address, identifier, firstName, lastName);
        } finally {
            if (user == null) {
                session.singleUseObjects().remove(lock);
            }
        }
        if (user != null) {
            registered(context, user, address);
            authSession.setAuthNote(EmailCodeSignUp.SIGNED_UP_NOTE, "true");
            signIn(context, user, address, identifier);
        }
    }

    /**
     * The account for {@code address}, opened under this sign-up's lock; null when none was opened
     * (the page or another stage is challenged then).
     */
    private UserModel openAccount(AuthenticationFlowContext context, String address, String identifier,
            String firstName, String lastName) {
        KeycloakSession session = context.getSession();
        RealmModel realm = context.getRealm();
        if (signedInToAnAccountThatHasIt(context, address, identifier) || !signUpPossible(context, address)) {
            return null;
        }
        UserModel user = null;
        for (int attempt = 0; attempt < 3 && user == null; attempt++) {
            String username = usernames.choose(session, realm, firstName, lastName);
            try {
                user = accounts.open(session, realm, username, address, firstName, lastName);
            } catch (SignUpAccounts.Refused refused) {
                switch (refused.reason()) {
                    case USERNAME_TAKEN -> {
                        // Taken between the choice and the write: the next name.
                    }
                    case FIRST_NAME, LAST_NAME -> {
                        context.challenge(EmailCodeSignUp.page(context, EmailCodeSignUp.Stage.FORM, address,
                                refused.reason() == SignUpAccounts.Refused.Reason.FIRST_NAME
                                        ? EmailCodeSignUp.Problem.FIRST_NAME_INVALID
                                        : EmailCodeSignUp.Problem.LAST_NAME_INVALID,
                                firstName, lastName, null));
                        return null;
                    }
                    case ADDRESS_TAKEN -> {
                        if (!signedInToAnAccountThatHasIt(context, address, identifier)) {
                            signUpFailure(context, SIGN_UP_TAKEN, Errors.EMAIL_IN_USE);
                            showStage(context, EmailCodeSignUp.Stage.UNAVAILABLE, address);
                        }
                        return null;
                    }
                    default -> {
                        context.challenge(EmailCodeSignUp.page(context, EmailCodeSignUp.Stage.FORM, address,
                                EmailCodeSignUp.Problem.TRY_AGAIN, firstName, lastName, null));
                        return null;
                    }
                }
            }
        }
        if (user == null) {
            context.challenge(EmailCodeSignUp.page(context, EmailCodeSignUp.Stage.FORM, address,
                    EmailCodeSignUp.Problem.TRY_AGAIN, firstName, lastName, null));
        }
        return user;
    }

    /** What a name may not be: empty, longer than Account center allows, or with prohibited characters. */
    private static EmailCodeSignUp.Problem nameProblem(String name, boolean first) {
        if (name.isEmpty()) {
            return first ? EmailCodeSignUp.Problem.FIRST_NAME_MISSING : EmailCodeSignUp.Problem.LAST_NAME_MISSING;
        }
        if (name.length() > IdentityResource.MAX_NAME_LENGTH || !IdentityResource.isAllowedPersonName(name)) {
            return first ? EmailCodeSignUp.Problem.FIRST_NAME_INVALID : EmailCodeSignUp.Problem.LAST_NAME_INVALID;
        }
        return null;
    }

    /** "Devam et" on the existing stage: the person the code named, checked again, is signed in. */
    private void continueExisting(AuthenticationFlowContext context) {
        AuthenticationSessionModel authSession = context.getAuthenticationSession();
        String userId = authSession.getAuthNote(EmailCodeSignUp.EXISTING_USER_NOTE);
        String address = authSession.getAuthNote(EmailCodeSignUp.EXISTING_ADDRESS_NOTE);
        if (userId == null || address == null || !proofIsFresh(authSession)) {
            clearSignUp(context);
            expired(context, null);
            return;
        }
        String identifier = identifierOf(context);
        clearSignUp(context);
        UserModel user = context.getSession().users().getUserById(context.getRealm(), userId);
        if (user == null) {
            expired(context, null);
            return;
        }
        if (admitted(context, user, address, identifier)) {
            // The login event of this request, when the sign-in ends here, says why it took a step more.
            context.getEvent().detail(EVENT_DETAIL, EXISTING_ACCOUNT);
            signIn(context, user, address, identifier);
        }
    }

    private void showExisting(AuthenticationFlowContext context, UserModel user, String address) {
        AuthenticationSessionModel authSession = context.getAuthenticationSession();
        String provenAt = authSession.getAuthNote(EmailCodeSignUp.PROVEN_AT_NOTE);
        clearSignUp(context);
        authSession.setAuthNote(EmailCodeSignUp.PROVEN_AT_NOTE,
                provenAt == null ? Integer.toString(Time.currentTime()) : provenAt);
        authSession.setAuthNote(EmailCodeSignUp.STAGE_NOTE, EmailCodeSignUp.Stage.EXISTING.value);
        authSession.setAuthNote(EmailCodeSignUp.EXISTING_USER_NOTE, user.getId());
        authSession.setAuthNote(EmailCodeSignUp.EXISTING_ADDRESS_NOTE, address);
        context.challenge(EmailCodeSignUp.page(context, EmailCodeSignUp.Stage.EXISTING, address, null, null, null, null));
    }

    /** A stage other than the form, kept for a reload of the page. */
    private void showStage(AuthenticationFlowContext context, EmailCodeSignUp.Stage stage, String address) {
        clearSignUp(context);
        AuthenticationSessionModel authSession = context.getAuthenticationSession();
        authSession.setAuthNote(EmailCodeSignUp.STAGE_NOTE, stage.value);
        authSession.setAuthNote(EmailCodeSignUp.ADDRESS_NOTE, address);
        context.challenge(stagePage(context, stage, address));
    }

    private Response stagePage(AuthenticationFlowContext context, EmailCodeSignUp.Stage stage, String address) {
        return EmailCodeSignUp.page(context, stage, address, null, null, null,
                stage == EmailCodeSignUp.Stage.YTU ? settings.ytuIdpAlias() : null);
    }

    /** A page of the sign-up waiting in this session (a reload): shown again, true; otherwise false. */
    private boolean resumeSignUp(AuthenticationFlowContext context) {
        AuthenticationSessionModel authSession = context.getAuthenticationSession();
        EmailCodeSignUp.Stage stage = EmailCodeSignUp.Stage.of(authSession.getAuthNote(EmailCodeSignUp.STAGE_NOTE));
        String address = stage == EmailCodeSignUp.Stage.EXISTING
                ? authSession.getAuthNote(EmailCodeSignUp.EXISTING_ADDRESS_NOTE)
                : stage == null ? provenAddress(authSession) : authSession.getAuthNote(EmailCodeSignUp.ADDRESS_NOTE);
        if (address == null || (stage == EmailCodeSignUp.Stage.EXISTING && !proofIsFresh(authSession))) {
            clearSignUp(context);
            return false;
        }
        context.challenge(stage == null
                ? EmailCodeSignUp.page(context, EmailCodeSignUp.Stage.FORM, address, null, null, null, null)
                : stagePage(context, stage, address));
        return true;
    }

    /** The address the sign-up form may open an account for: proven in this session, recently. */
    private static String provenAddress(AuthenticationSessionModel authSession) {
        String address = authSession.getAuthNote(EmailCodeSignUp.ADDRESS_NOTE);
        return address != null && authSession.getAuthNote(EmailCodeSignUp.STAGE_NOTE) == null && proofIsFresh(authSession)
                ? address : null;
    }

    /** Fixed lifetime from the code proof; reloading or changing stages never renews it. */
    private static boolean proofIsFresh(AuthenticationSessionModel authSession) {
        String provenAt = authSession.getAuthNote(EmailCodeSignUp.PROVEN_AT_NOTE);
        if (provenAt == null) {
            return false;
        }
        try {
            long age = (long) Time.currentTime() - Long.parseLong(provenAt);
            return age >= 0 && age <= EmailCodeSignUp.PROOF_SECONDS;
        } catch (NumberFormatException malformed) {
            return false;
        }
    }

    /** Forgets every page of the sign-up this session was on; the intent stays. */
    private static void clearSignUp(AuthenticationFlowContext context) {
        AuthenticationSessionModel authSession = context.getAuthenticationSession();
        authSession.removeAuthNote(EmailCodeSignUp.ADDRESS_NOTE);
        authSession.removeAuthNote(EmailCodeSignUp.PROVEN_AT_NOTE);
        authSession.removeAuthNote(EmailCodeSignUp.STAGE_NOTE);
        authSession.removeAuthNote(EmailCodeSignUp.EXISTING_USER_NOTE);
        authSession.removeAuthNote(EmailCodeSignUp.EXISTING_ADDRESS_NOTE);
    }

    /** One address is opened by one sign-up at a time, across nodes. */
    private static String addressLockKey(AuthenticationFlowContext context, String address) {
        return "sky-email-code:sign-up-lock:" + BudgetKeys.keyed(context.getSession(), context.getRealm(), "address:" + address);
    }

    /**
     * Keycloak's {@code REGISTER} event of the new account, as its own registration writes it (the
     * username and the address), with {@code register_method} and {@code sky_method}
     * {@value #REGISTER_METHOD}.
     */
    private static void registered(AuthenticationFlowContext context, UserModel user, String address) {
        context.getEvent().clone()
                .event(EventType.REGISTER)
                .user(user)
                .detail(Details.USERNAME, user.getUsername())
                .detail(Details.EMAIL, address)
                .detail(Details.REGISTER_METHOD, REGISTER_METHOD)
                .detail(METHOD_DETAIL, METHOD)
                .success();
    }

    /**
     * A refusal of Self-registration: a {@code REGISTER_ERROR} of its own, with what happened and
     * neither the IP nor the address (as {@link #failure}).
     */
    private static void signUpFailure(AuthenticationFlowContext context, String what, String error) {
        context.getEvent().clone()
                .event(EventType.REGISTER)
                .ipAddress(null)
                .removeDetail(Details.USERNAME)
                .detail(METHOD_DETAIL, METHOD)
                .detail(EVENT_DETAIL, what)
                .error(error);
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
    static boolean claimRequestBudgets(AuthenticationFlowContext context) {
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
    static boolean claimAddressBudgets(AuthenticationFlowContext context, String address) {
        KeycloakSession session = context.getSession();
        String key = BudgetKeys.keyed(session, context.getRealm(), "address:" + address);
        RateLimiter limiter = new RateLimiter(session.singleUseObjects());
        return limiter.claim(RateLimiter.LOGIN_CODE_ADDRESS, key) == 0
                && limiter.claim(RateLimiter.LOGIN_CODE_ADDRESS_DAY, key) == 0;
    }

    /** Whether the wrong codes under {@code key} reached today's ceiling (security review K2). */
    boolean pastCeiling(AuthenticationFlowContext context, String key) {
        return new RateLimiter(context.getSession().singleUseObjects())
                .spent(RateLimiter.loginCodeWrongPerAccount(settings.wrongCodesPerAccount()), key);
    }

    /**
     * One wrong code of the person toward today's ceiling. The one that reaches it is logged with
     * how many accounts reached it today; the first account of the day also alarms the operator.
     */
    void countTowardTheCeiling(AuthenticationFlowContext context, UserModel user, String key) {
        int ceiling = settings.wrongCodesPerAccount();
        RateLimiter limiter = new RateLimiter(context.getSession().singleUseObjects());
        if (limiter.claimSlot(RateLimiter.loginCodeWrongPerAccount(ceiling), key) != ceiling) {
            return;
        }
        int accounts = limiter.claimSlot(RateLimiter.LOGIN_CODE_CEILING_ACCOUNTS, context.getRealm().getId());
        // No person: the LOGIN_ERROR event names them for the administrators.
        LOG.warnf("sky_email_code_wrong_ceiling accounts=%s ceiling=%d realm=%s",
                accounts == 0 ? "more_than_" + RateLimiter.LOGIN_CODE_CEILING_ACCOUNTS.maxAttempts() : Integer.toString(accounts),
                ceiling, context.getRealm().getName());
        if (accounts == 1) {
            mail.ceilingAlarm(context, ceiling, accounts);
        }
    }

    /**
     * One wrong sign-up code toward the address's ceiling; the one that reaches it is logged (no
     * address). No operator alarm: no account is at stake.
     */
    private void countTowardTheSignUpCeiling(AuthenticationFlowContext context, String key) {
        int ceiling = settings.wrongCodesPerAccount();
        if (new RateLimiter(context.getSession().singleUseObjects())
                .claimSlot(RateLimiter.loginCodeWrongPerAccount(ceiling), key) == ceiling) {
            LOG.warnf("sky_email_code_sign_up_wrong_ceiling ceiling=%d realm=%s", ceiling, context.getRealm().getName());
        }
    }

    static String accountCeilingKey(AuthenticationFlowContext context, String userId) {
        return BudgetKeys.keyed(context.getSession(), context.getRealm(), "wrong-account:" + userId);
    }

    private static String signUpCeilingKey(AuthenticationFlowContext context, String address) {
        return BudgetKeys.keyed(context.getSession(), context.getRealm(), "wrong-sign-up:" + address);
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
        signUpAttributes(context, form);
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
        signUpAttributes(context, form);
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

    /**
     * Whether Self-registration is on, and whether the person came through "Hesap aç": the same for
     * every address typed, so the page still tells no account apart.
     */
    private static void signUpAttributes(AuthenticationFlowContext context, LoginFormsProvider form) {
        if (EmailCodeSignUp.isOn(context)) {
            form.setAttribute(EmailCodeSignUp.ON_ATTRIBUTE, "true");
            if (EmailCodeSignUp.INTENT_SIGN_UP.equals(context.getAuthenticationSession().getAuthNote(EmailCodeSignUp.INTENT_NOTE))) {
                form.setAttribute(EmailCodeSignUp.INTENT_ATTRIBUTE, EmailCodeSignUp.INTENT_SIGN_UP);
            }
        }
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
