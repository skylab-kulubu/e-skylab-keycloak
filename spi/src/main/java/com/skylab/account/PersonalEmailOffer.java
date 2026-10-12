package com.skylab.account;

import com.skylab.account.PendingEmailChanges.Outcome;
import com.skylab.account.PendingEmailChanges.Waiting;
import jakarta.ws.rs.core.MultivaluedMap;
import jakarta.ws.rs.core.Response;
import org.jboss.logging.Logger;
import org.keycloak.Config;
import org.keycloak.authentication.RequiredActionContext;
import org.keycloak.authentication.RequiredActionFactory;
import org.keycloak.authentication.RequiredActionProvider;
import org.keycloak.broker.provider.AbstractIdentityProvider;
import org.keycloak.common.util.Base64Url;
import org.keycloak.common.util.SecretGenerator;
import org.keycloak.common.util.Time;
import org.keycloak.crypto.Algorithm;
import org.keycloak.crypto.KeyUse;
import org.keycloak.crypto.KeyWrapper;
import org.keycloak.events.Details;
import org.keycloak.events.Errors;
import org.keycloak.events.EventBuilder;
import org.keycloak.events.EventType;
import org.keycloak.forms.login.LoginFormsProvider;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;
import org.keycloak.models.RealmModel;
import org.keycloak.models.RequiredActionProviderModel;
import org.keycloak.models.UserModel;
import org.keycloak.sessions.AuthenticationSessionModel;

import java.net.Inet4Address;
import java.net.Inet6Address;
import java.net.InetAddress;
import java.net.UnknownHostException;
import java.nio.charset.StandardCharsets;
import java.security.InvalidKeyException;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;
import java.util.List;
import java.util.regex.Pattern;
import javax.crypto.Mac;
import javax.crypto.SecretKey;
import javax.crypto.spec.SecretKeySpec;

/**
 * {@code sky-personal-email-offer}: once, at the end of a first YTÜ login that opened an account with
 * the School e-mail as its Primary e-mail, the person may add a Personal e-mail without leaving the
 * sign-in (eskylab-login-ux ticket 21, Yusuf's decision of 2026-10-11; Microsoft's "add security
 * info" and Google's recovery e-mail interstitials). The school mailbox may close after graduation,
 * and "Şifremi unuttum" and club mail reach only the Primary e-mail.
 *
 * <p>The page asks for an address ([Kod gönder]) or lets the person go on ([Şimdilik geç]). A
 * six-digit code is mailed to the address and typed on the same page; when it is right the address
 * becomes the person's proven Personal e-mail ({@code personalEmail}, {@code personalEmailVerifiedAt})
 * and the Primary e-mail stays the School e-mail. Then, or after a skip, the login continues to the
 * application. The code follows ADR-0044 and CONTEXT's Login code: six digits, ten minutes, dead after
 * five wrong tries, single use, valid only in this sign-in session (the store entry is keyed by a
 * random handle kept in an authentication note of this session), only a salted hash stored
 * ({@link PendingEmailChanges}). Who may receive a code, the mail and the proof are Account center's
 * ({@link PersonalEmailVerification}); an address on the university's domain is never a Personal
 * e-mail (it may close after graduation). Sending is limited per sign-in session, per address, per IP
 * class and overall; the IP itself is never stored, its /24 or /64 class enters a budget key only as
 * an HMAC under a sub-key of the realm's HMAC key, held in memory until the clock hour ends. Like Account
 * center, the page says when another account already uses the address, and only after the sending
 * budgets were charged.
 *
 * <p>Only {@code sky-ytu-first-login} schedules it ({@link #schedule}), on this sign-in session and
 * only when it wrote the School e-mail as the Primary e-mail of the account about to be opened and
 * the realm has the action enabled. When the page would come, it checks again that this session did
 * open the account ({@code BROKER_REGISTERED_NEW_USER}), that the account's Primary e-mail is still
 * that verified address, and that the person has no Personal e-mail and never skipped the offer
 * ({@value #SKIPPED_AT_ATTRIBUTE}); otherwise the login just continues. So it never shows for an
 * account being linked, for A6 ({@code kc_action=idp_link} never runs the first broker login flow),
 * for a login without YTÜ, or twice. It cannot be requested with {@code kc_action}. Turning the realm's
 * required action off (the reconciler's {@code KEYCLOAK_PERSONAL_EMAIL_OFFER=off}) is the rollback.
 */
public final class PersonalEmailOffer implements RequiredActionProvider, RequiredActionFactory {

    public static final String PROVIDER_ID = "sky-personal-email-offer";
    /** Set when the person chose "Şimdilik geç"; the page never comes again (ISO-8601 UTC). */
    public static final String SKIPPED_AT_ATTRIBUTE = "personalEmailOfferSkippedAt";
    static final String TEMPLATE = "sky-personal-email-offer.ftl";

    /** The School e-mail {@code sky-ytu-first-login} wrote as the new account's Primary e-mail. */
    static final String SCHEDULED_NOTE = "sky-personal-email-offer.primary";
    /** The handle of this session's code in {@link PendingEmailChanges#forLoginSessions}. */
    static final String HANDLE_NOTE = "sky-personal-email-offer.handle";
    /** Present once the "shown" event was written for this session. */
    static final String SHOWN_NOTE = "sky-personal-email-offer.shown";

    /** The event detail that counts the offer (spec §11): shown, code_sent, added, skip. */
    static final String EVENT_DETAIL = "sky_personal_email_offer";

    static final String ACTION_PARAM = "sky-offer-action";
    static final String ADDRESS_PARAM = "address";
    static final String CODE_PARAM = "code";
    static final String SEND = "send";
    static final String VERIFY = "verify";
    static final String CHANGE = "change";
    static final String SKIP = "skip";

    static final String STAGE_ATTRIBUTE = "skyOfferStage";
    static final String ADDRESS_ATTRIBUTE = "skyOfferAddress";
    static final String ERROR_ATTRIBUTE = "skyOfferError";
    static final String ATTEMPTS_LEFT_ATTRIBUTE = "skyOfferAttemptsLeft";
    static final String CODE_MINUTES_ATTRIBUTE = "skyOfferCodeMinutes";

    /** Which part of the page is shown. */
    enum Stage {
        ADDRESS("address"), CODE("code");

        final String value;

        Stage(String value) {
            this.value = value;
        }
    }

    /** The page's error codes; the theme turns each into one sentence. */
    enum Problem {
        INVALID_ADDRESS("invalid_address"),
        OWN_ADDRESS("own_address"),
        SCHOOL_DOMAIN("email_school_domain"),
        TAKEN("email_taken"),
        RATE_LIMITED("rate_limited"),
        NOT_SENT("email_not_sent"),
        MALFORMED_CODE("malformed_code"),
        WRONG_CODE("wrong_code"),
        CODE_EXPIRED("code_expired"),
        TOO_MANY_TRIES("too_many_tries");

        final String value;

        Problem(String value) {
            this.value = value;
        }
    }

    private static final Logger LOG = Logger.getLogger(PersonalEmailOffer.class);
    private static final int HANDLE_BYTES = 32;
    private static final Pattern IPV4 = Pattern.compile("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$");
    private static final Pattern IPV6 = Pattern.compile("^[0-9a-fA-F:.]+$");

    /**
     * Called by {@code sky-ytu-first-login} when it writes {@code schoolAddress} as the Primary e-mail
     * of the account the first broker login is about to open: puts the offer on this sign-in session
     * when the realm has the action enabled. Nothing is written to the user.
     */
    public static void schedule(RealmModel realm, AuthenticationSessionModel authSession, String schoolAddress) {
        RequiredActionProviderModel model = realm.getRequiredActionProviderByAlias(PROVIDER_ID);
        if (model == null || !model.isEnabled() || schoolAddress == null || schoolAddress.isBlank()) {
            return;
        }
        authSession.setAuthNote(SCHEDULED_NOTE, schoolAddress);
        authSession.addRequiredAction(PROVIDER_ID);
    }

    /**
     * Whether the page is due: this sign-in session opened the account with the scheduled School
     * e-mail as its verified Primary e-mail, and the person has neither a Personal e-mail nor a skip.
     */
    static boolean due(AuthenticationSessionModel authSession, UserModel user) {
        String scheduled = authSession.getAuthNote(SCHEDULED_NOTE);
        return scheduled != null && user != null
                && Boolean.parseBoolean(authSession.getAuthNote(AbstractIdentityProvider.BROKER_REGISTERED_NEW_USER))
                && scheduled.equalsIgnoreCase(user.getEmail())
                && user.isEmailVerified()
                && isBlank(user.getFirstAttribute(PersonalEmailProof.ADDRESS_ATTRIBUTE))
                && isBlank(user.getFirstAttribute(SKIPPED_AT_ATTRIBUTE));
    }

    @Override
    public void evaluateTriggers(RequiredActionContext context) {
        // Only sky-ytu-first-login schedules the offer, on the sign-in session.
    }

    @Override
    public void requiredActionChallenge(RequiredActionContext context) {
        AuthenticationSessionModel authSession = context.getAuthenticationSession();
        if (!due(authSession, context.getUser())) {
            forget(context);
            context.success();
            return;
        }
        if (authSession.getAuthNote(SHOWN_NOTE) == null) {
            authSession.setAuthNote(SHOWN_NOTE, Boolean.TRUE.toString());
            event(context, "shown").success();
        }
        Waiting waiting = waiting(context);
        context.challenge(waiting == null
                ? page(context, Stage.ADDRESS, null, null, null)
                : page(context, Stage.CODE, waiting.address(), null, null));
    }

    @Override
    public void processAction(RequiredActionContext context) {
        if (!due(context.getAuthenticationSession(), context.getUser())) {
            forget(context);
            context.success();
            return;
        }
        MultivaluedMap<String, String> form = context.getHttpRequest().getDecodedFormParameters();
        String action = form.getFirst(ACTION_PARAM);
        if (SKIP.equals(action)) {
            skip(context);
        } else if (SEND.equals(action)) {
            send(context, form.getFirst(ADDRESS_PARAM));
        } else if (VERIFY.equals(action)) {
            verify(context, form.getFirst(CODE_PARAM));
        } else if (CHANGE.equals(action)) {
            discardCode(context);
            context.challenge(page(context, Stage.ADDRESS, null, null, null));
        } else {
            requiredActionChallenge(context);
        }
    }

    /** "Şimdilik geç": the page never comes again, and the login goes on. */
    private void skip(RequiredActionContext context) {
        context.getUser().setSingleAttribute(SKIPPED_AT_ATTRIBUTE, PersonalEmailProof.verifiedAt(Time.currentTime()));
        forget(context);
        context.getEvent().detail(EVENT_DETAIL, SKIP);
        context.success();
    }

    /** "Kod gönder": the same address rule as Account center, the budgets, then the code by mail. */
    private void send(RequiredActionContext context, String typed) {
        KeycloakSession session = context.getSession();
        RealmModel realm = context.getRealm();
        UserModel user = context.getUser();
        if (typed == null || typed.isBlank() || typed.length() > 2 * PersonalEmailVerification.MAX_ADDRESS_LENGTH) {
            context.challenge(page(context, Stage.ADDRESS, null, Problem.INVALID_ADDRESS, null));
            return;
        }
        String address = PersonalEmailProof.normalise(typed);
        if (address.length() > PersonalEmailVerification.MAX_ADDRESS_LENGTH
                || !PersonalEmailVerification.isValidAddress(session, address)) {
            context.challenge(page(context, Stage.ADDRESS, address, Problem.INVALID_ADDRESS, null));
            return;
        }
        if (address.equalsIgnoreCase(user.getEmail()) || PersonalEmailVerification.isOwnAddress(user, address)) {
            context.challenge(page(context, Stage.ADDRESS, address, Problem.OWN_ADDRESS, null));
            return;
        }
        // Before the budgets: it says nothing about other accounts.
        if (PersonalEmailVerification.isSchoolDomain(address)) {
            context.challenge(page(context, Stage.ADDRESS, address, Problem.SCHOOL_DOMAIN, null));
            return;
        }
        // Charged before the address is looked up, as Account center charges its budget before
        // saying that another account uses it: every probe costs a mail's worth.
        if (!claimBudgets(context, address)) {
            context.challenge(page(context, Stage.ADDRESS, address, Problem.RATE_LIMITED, null));
            return;
        }
        if (PersonalEmailVerification.isTakenByAnother(session, realm, user, address)) {
            event(context, "address_taken").error(Errors.EMAIL_IN_USE);
            context.challenge(page(context, Stage.ADDRESS, address, Problem.TAKEN, null));
            return;
        }

        PendingEmailChanges pending = PendingEmailChanges.forLoginSessions(session.singleUseObjects());
        discardCode(context);
        String handle = Base64Url.encode(SecretGenerator.getInstance().randomBytes(HANDLE_BYTES));
        String code = pending.issue(handle, address, false);
        try {
            PersonalEmailVerification.send(session, realm, user, address, code);
        } catch (Exception exception) {
            pending.discard(handle);
            // Neither the address nor the code may reach the log; the SMTP diagnostics (which quote
            // the recipient) stay at DEBUG.
            LOG.errorf("The first-login personal e-mail offer could not send a code for user %s", user.getId());
            LOG.debug("first-login personal e-mail offer send failure", exception);
            event(context, "send_failed").error(Errors.EMAIL_SEND_FAILED);
            context.challenge(page(context, Stage.ADDRESS, address, Problem.NOT_SENT, null));
            return;
        }
        context.getAuthenticationSession().setAuthNote(HANDLE_NOTE, handle);
        event(context, "code_sent").success();
        context.challenge(page(context, Stage.CODE, address, null, null));
    }

    /** The code from the mail: right once, wrong at most five times, dead after ten minutes. */
    private void verify(RequiredActionContext context, String typed) {
        AuthenticationSessionModel authSession = context.getAuthenticationSession();
        String handle = authSession.getAuthNote(HANDLE_NOTE);
        PendingEmailChanges pending = PendingEmailChanges.forLoginSessions(context.getSession().singleUseObjects());
        Waiting waiting = handle == null ? null : pending.peek(handle);
        if (waiting == null) {
            discardCode(context);
            context.challenge(page(context, Stage.ADDRESS, null, Problem.CODE_EXPIRED, null));
            return;
        }
        String code = PersonalEmailVerification.codeFromInput(typed);
        if (code == null) {
            context.challenge(page(context, Stage.CODE, waiting.address(), Problem.MALFORMED_CODE, null));
            return;
        }
        Outcome outcome = pending.confirm(handle, code);
        switch (outcome.status()) {
            case NONE -> {
                discardCode(context);
                context.challenge(page(context, Stage.ADDRESS, waiting.address(), Problem.CODE_EXPIRED, null));
            }
            case WRONG_CODE -> {
                event(context, "wrong_code").error(Errors.INVALID_CODE);
                if (outcome.attemptsLeft() > 0) {
                    context.challenge(page(context, Stage.CODE, waiting.address(), Problem.WRONG_CODE,
                            outcome.attemptsLeft()));
                } else {
                    discardCode(context);
                    context.challenge(page(context, Stage.ADDRESS, waiting.address(), Problem.TOO_MANY_TRIES, null));
                }
            }
            case CONFIRMED -> confirmed(context, outcome.change().address());
        }
    }

    private void confirmed(RequiredActionContext context, String address) {
        UserModel user = context.getUser();
        if (PersonalEmailVerification.isSchoolDomain(address)) {
            discardCode(context);
            context.challenge(page(context, Stage.ADDRESS, address, Problem.SCHOOL_DOMAIN, null));
            return;
        }
        // Ten minutes passed: somebody else may have taken the address meanwhile (Account center
        // checks again at this point too).
        if (PersonalEmailVerification.isTakenByAnother(context.getSession(), context.getRealm(), user, address)) {
            discardCode(context);
            event(context, "address_taken").error(Errors.EMAIL_IN_USE);
            context.challenge(page(context, Stage.ADDRESS, address, Problem.TAKEN, null));
            return;
        }
        PersonalEmailVerification.prove(user, address, Time.currentTime());
        forget(context);
        context.getEvent().detail(EVENT_DETAIL, "added");
        context.success();
    }

    /**
     * One slot of each budget, in order, stopping at the first that is spent: this sign-in session,
     * the IP class, everybody, then the address. The IP class and address budgets are per realm (the
     * sandbox realm shares the server with production). Every key is a keyed hash ({@link #keyed}) or
     * an id, never the address or the IP itself; a key lives in memory until its hour ends.
     */
    private static boolean claimBudgets(RequiredActionContext context, String address) {
        RateLimiter limiter = new RateLimiter(context.getSession().singleUseObjects());
        for (Budget budget : budgets(context, address)) {
            if (limiter.claim(budget.limit(), budget.key()) > 0) {
                return false;
            }
        }
        return true;
    }

    /** A sending budget and the key this request spends it under. */
    record Budget(RateLimiter.Limit limit, String key) {
    }

    static List<Budget> budgets(RequiredActionContext context, String address) {
        AuthenticationSessionModel authSession = context.getAuthenticationSession();
        String remote = context.getConnection() == null ? null : context.getConnection().getRemoteAddr();
        KeycloakSession session = context.getSession();
        RealmModel realm = context.getRealm();
        return List.of(
                new Budget(RateLimiter.OFFER_SESSION,
                        keyed(session, realm, "session:" + authSession.getParentSession().getId() + "/" + authSession.getTabId())),
                new Budget(RateLimiter.OFFER_IP_CLASS, keyed(session, realm, "ip-class:" + ipClass(remote))),
                new Budget(RateLimiter.OFFER_ALL, realm.getId()),
                new Budget(RateLimiter.OFFER_ADDRESS, keyed(session, realm, "address:" + address)));
    }

    /**
     * The network an address belongs to, as a budget key: an IPv4 address's /24, an IPv6 address's
     * /64 (one subscriber), or {@code unknown} for anything that is not an address literal (no
     * name is ever resolved).
     */
    static String ipClass(String remote) {
        if (remote == null || remote.isBlank()) {
            return "unknown";
        }
        String literal = remote.strip();
        if (IPV4.matcher(literal).matches()) {
            String[] octets = literal.split("\\.");
            for (String octet : octets) {
                if (Integer.parseInt(octet) > 255) {
                    return "unknown";
                }
            }
            return "v4:" + Integer.parseInt(octets[0]) + "." + Integer.parseInt(octets[1]) + "." + Integer.parseInt(octets[2]);
        }
        try {
            // A string with a colon is only ever parsed as an IPv6 literal: no name is resolved.
            if (literal.indexOf(':') >= 0 && IPV6.matcher(literal).matches()) {
                InetAddress parsed = InetAddress.getByName(literal);
                byte[] bytes = parsed.getAddress();
                if (parsed instanceof Inet4Address) {
                    return "v4:" + (bytes[0] & 0xff) + "." + (bytes[1] & 0xff) + "." + (bytes[2] & 0xff);
                }
                if (parsed instanceof Inet6Address) {
                    return "v6:" + HexFormat.of().formatHex(bytes, 0, 8);
                }
            }
        } catch (UnknownHostException malformed) {
            return "unknown";
        }
        return "unknown";
    }

    /** What the budget sub-key is derived for, so the realm's signing key is never used as is. */
    static final String BUDGET_KEY_LABEL = "sky-personal-email-limits";

    /**
     * A budget key for {@code value} in this realm: HMAC-SHA256 under a sub-key derived from the
     * realm's active HS512 key (HMAC-SHA256 of {@value #BUDGET_KEY_LABEL} under it), a server secret
     * Keycloak keeps in its database, the same on every node, so a stored key cannot be turned back
     * into a /24 or an address by trying them all. Keycloak creates an HS512 key for a realm that has
     * none ({@code fallback-HS512}); only without a key manager (unit tests) is the key a SHA-256 of
     * the realm id and the value. Rotating the realm key only starts the budgets afresh.
     */
    static String keyed(KeycloakSession session, RealmModel realm, String value) {
        byte[] input = (realm.getId() + "/" + value).getBytes(StandardCharsets.UTF_8);
        SecretKey realmKey = realmHmacKey(session, realm);
        try {
            if (realmKey != null) {
                byte[] subKey = hmac(realmKey.getEncoded(), BUDGET_KEY_LABEL.getBytes(StandardCharsets.UTF_8));
                return "h" + HexFormat.of().formatHex(hmac(subKey, input));
            }
            return "s" + HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(input));
        } catch (NoSuchAlgorithmException | InvalidKeyException exception) {
            throw new IllegalStateException("HMAC-SHA256 or SHA-256 is unavailable", exception);
        }
    }

    private static byte[] hmac(byte[] key, byte[] input) throws NoSuchAlgorithmException, InvalidKeyException {
        Mac mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec(key, "HmacSHA256"));
        return mac.doFinal(input);
    }

    private static SecretKey realmHmacKey(KeycloakSession session, RealmModel realm) {
        if (session.keys() == null) {
            return null;
        }
        KeyWrapper key = session.keys().getActiveKey(realm, KeyUse.SIG, Algorithm.HS512);
        return key == null || key.getSecretKey() == null || key.getSecretKey().getEncoded() == null
                ? null : key.getSecretKey();
    }

    /** This session's code, if one is waiting. */
    private static Waiting waiting(RequiredActionContext context) {
        String handle = context.getAuthenticationSession().getAuthNote(HANDLE_NOTE);
        return handle == null ? null
                : PendingEmailChanges.forLoginSessions(context.getSession().singleUseObjects()).peek(handle);
    }

    /** Drops this session's code, if any, so it never works again. */
    private static void discardCode(RequiredActionContext context) {
        AuthenticationSessionModel authSession = context.getAuthenticationSession();
        String handle = authSession.getAuthNote(HANDLE_NOTE);
        if (handle != null) {
            PendingEmailChanges.forLoginSessions(context.getSession().singleUseObjects()).discard(handle);
            authSession.removeAuthNote(HANDLE_NOTE);
        }
    }

    /** Everything the offer kept on this sign-in session, so it cannot come back in it. */
    private static void forget(RequiredActionContext context) {
        discardCode(context);
        AuthenticationSessionModel authSession = context.getAuthenticationSession();
        authSession.removeAuthNote(SCHEDULED_NOTE);
        authSession.removeAuthNote(SHOWN_NOTE);
    }

    /** A separate event of the offer, so the login's own event keeps only the final outcome. */
    private static EventBuilder event(RequiredActionContext context, String what) {
        return context.getEvent().clone()
                .event(EventType.CUSTOM_REQUIRED_ACTION)
                .detail(Details.CUSTOM_REQUIRED_ACTION, PROVIDER_ID)
                .detail(EVENT_DETAIL, what);
    }

    private static Response page(RequiredActionContext context, Stage stage, String address, Problem problem,
            Integer attemptsLeft) {
        LoginFormsProvider form = context.form()
                .setAttribute(STAGE_ATTRIBUTE, stage.value)
                .setAttribute(CODE_MINUTES_ATTRIBUTE, Integer.toString(PendingEmailChanges.TTL_SECONDS / 60));
        if (address != null) {
            form.setAttribute(ADDRESS_ATTRIBUTE, address);
        }
        if (problem != null) {
            form.setAttribute(ERROR_ATTRIBUTE, problem.value);
        }
        if (attemptsLeft != null) {
            form.setAttribute(ATTEMPTS_LEFT_ATTRIBUTE, Integer.toString(attemptsLeft));
        }
        return form.createForm(TEMPLATE);
    }

    private static boolean isBlank(String value) {
        return value == null || value.isBlank();
    }

    @Override
    public String getDisplayText() {
        return "SKY LAB personal e-mail offer (first YTÜ login)";
    }

    @Override
    public RequiredActionProvider create(KeycloakSession session) {
        return this;
    }

    @Override
    public String getId() {
        return PROVIDER_ID;
    }

    @Override
    public void init(Config.Scope config) {
        // no-op
    }

    @Override
    public void postInit(KeycloakSessionFactory factory) {
        // no-op
    }

    @Override
    public void close() {
        // no-op
    }
}
