package com.skylab.authenticator;

import com.skylab.account.EmailCodeAuthenticator;
import jakarta.ws.rs.core.MultivaluedMap;
import org.keycloak.Config;
import org.keycloak.authentication.AuthenticationProcessor;
import org.keycloak.authentication.RequiredActionContext;
import org.keycloak.authentication.RequiredActionFactory;
import org.keycloak.authentication.RequiredActionProvider;
import org.keycloak.events.Details;
import org.keycloak.models.ClientModel;
import org.keycloak.models.Constants;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserSessionModel;
import org.keycloak.models.utils.RealmExpiration;
import org.keycloak.services.managers.AuthenticationManager;
import org.keycloak.sessions.AuthenticationSessionModel;

/**
 * {@code sky-stay-signed-in}: "Bu cihazda oturumum açık kalsın mı?" once at the end of every YTÜ
 * login, the counterpart of Microsoft's "Stay signed in?" after a federated sign-in (Yusuf's
 * decision of 2026-10-12), and since eskylab-login-ux 08 at the end of every Login code sign-in
 * ("E-postayla devam et", {@link EmailCodeAuthenticator}), whose pages have no "Beni hatırla" box
 * either (Microsoft asks after an e-mail code too). "Evet, açık kalsın" makes the new Keycloak session a remember-me session
 * (the realm's remember-me idle time and lifespan, a persistent cookie); "Hayır" leaves it an
 * ordinary one: a session cookie, and a server session that ends after the realm's idle time. The
 * page asks people on a shared computer to choose "Hayır" and sign out when done. The password and passkey sign-in keeps its own "Beni hatırla" box; this page never
 * shows there.
 *
 * <p>The YTÜ button is a link to the identity provider, so Keycloak never sees the box and no
 * authenticator of the browser flow runs for a person who signs in with YTÜ again: a linked account
 * goes from the identity provider straight to the end of the login. Only the realm's required
 * actions run on every login, so this is one: {@link #evaluateTriggers} puts it on the sign-in
 * session (never on the user) when the login came through the identity provider {@value #YTU_IDP_ALIAS}
 * or the e-mail code step signed the person in (its authentication note).
 * The answer is the {@link Details#REMEMBER_ME} authentication note, which Keycloak reads when it
 * creates the user session after the required actions
 * ({@code AuthenticationProcessor.attachSession}), as the password form's box does
 * ({@code AuthenticatorUtils.processRememberMe}).
 *
 * <p>It does not ask when the answer could not count or must not be asked:
 * <ul>
 *   <li>the realm has remember-me off (Keycloak would refuse such a session);</li>
 *   <li>SkyApp ({@value #SKYAPP_CLIENT_ID}): its sign-in browser only hands the app its own tokens,
 *       as Microsoft shows no "Stay signed in?" in a native app's sign-in (Yusuf, 2026-10-12);</li>
 *   <li>a passive login ({@code prompt=none} forwarded to the identity provider): Keycloak fails a
 *       passive login that meets a required action with {@code interaction_required};</li>
 *   <li>an application-initiated action ({@code kc_action});</li>
 *   <li>a re-authentication inside a live session ({@code prompt=login}, {@code max_age}): Keycloak
 *       keeps that session as it is, whatever the answer;</li>
 *   <li>a second time in the same sign-in.</li>
 * </ul>
 * It cannot be requested with {@code kc_action}. {@code config/reconcile-account-center.sh}
 * registers it last among the realm's required actions ({@code KEYCLOAK_STAY_SIGNED_IN}); turning
 * the realm's required action off is the rollback.
 */
public final class SkyStaySignedIn implements RequiredActionProvider, RequiredActionFactory {

    public static final String PROVIDER_ID = "sky-stay-signed-in";
    /** The alias of YTÜ's identity provider (Microsoft, OBS), as the reconciler names it. */
    static final String YTU_IDP_ALIAS = "OBS";
    static final String TEMPLATE = "sky-stay-signed-in.ftl";
    /** SkyApp's public client, as config/reconcile-account-center.sh names it (SKYAPP_CLIENT_ID). */
    static final String SKYAPP_CLIENT_ID = "skyapp";

    /** Present once the person answered in this sign-in session. */
    static final String ANSWERED_NOTE = "sky-stay-signed-in.answered";
    static final String CHOICE_PARAM = "sky-stay-signed-in";
    static final String YES = "yes";
    static final String NO = "no";
    /** The event detail of the answer: yes or no. */
    static final String EVENT_DETAIL = "sky_stay_signed_in";

    static final String IDLE_DAYS_ATTRIBUTE = "skyStaySignedInIdleDays";
    static final String MAX_DAYS_ATTRIBUTE = "skyStaySignedInMaxDays";

    private static final int DAY_SECONDS = 24 * 60 * 60;

    @Override
    public void evaluateTriggers(RequiredActionContext context) {
        AuthenticationSessionModel authSession = context.getAuthenticationSession();
        if (authSession != null && authSession.getAuthNote(ANSWERED_NOTE) == null
                && due(context.getSession(), context.getRealm(), authSession)) {
            authSession.addRequiredAction(PROVIDER_ID);
        }
    }

    /**
     * Whether this sign-in should ask: it came through YTÜ or a Login code, the realm has remember-me on, it is not
     * SkyApp's, not passive, not an application-initiated action, and it will open a new user session.
     */
    static boolean due(KeycloakSession session, RealmModel realm, AuthenticationSessionModel authSession) {
        if (realm == null || !realm.isRememberMe()
                || !(cameThroughYtu(authSession) || signedInWithLoginCode(authSession))
                || isSkyApp(authSession.getClient())
                || Boolean.parseBoolean(authSession.getAuthNote(AuthenticationProcessor.FORWARDED_PASSIVE_LOGIN))
                || !isBlank(authSession.getClientNote(Constants.KC_ACTION))) {
            return false;
        }
        return !keepsLiveSession(session, realm, authSession);
    }

    private static boolean cameThroughYtu(AuthenticationSessionModel authSession) {
        return YTU_IDP_ALIAS.equals(authSession.getUserSessionNotes().get(Details.IDENTITY_PROVIDER));
    }

    /** The code step of "E-postayla devam et" signed the person in (eskylab-login-ux 08). */
    private static boolean signedInWithLoginCode(AuthenticationSessionModel authSession) {
        return EmailCodeAuthenticator.METHOD.equals(authSession.getAuthNote(EmailCodeAuthenticator.METHOD_NOTE));
    }

    /**
     * The same test {@code AuthenticationProcessor.attachSession} makes: a valid user session under
     * this sign-in's id is kept as it is, so the answer would change nothing.
     */
    static boolean keepsLiveSession(KeycloakSession session, RealmModel realm, AuthenticationSessionModel authSession) {
        if (session == null || session.sessions() == null || authSession.getParentSession() == null) {
            return false;
        }
        UserSessionModel existing = session.sessions().getUserSession(realm, authSession.getParentSession().getId());
        return existing != null && existing.getUser() != null && AuthenticationManager.isSessionValid(realm, existing);
    }

    @Override
    public void requiredActionChallenge(RequiredActionContext context) {
        AuthenticationSessionModel authSession = context.getAuthenticationSession();
        if (!due(context.getSession(), context.getRealm(), authSession)) {
            // Put on a user by hand, or the sign-in changed: nothing to ask.
            authSession.setAuthNote(ANSWERED_NOTE, Boolean.TRUE.toString());
            context.success();
            return;
        }
        RealmExpiration expiration = RealmExpiration.fromRealm(context.getRealm());
        context.challenge(context.form()
                .setAttribute(IDLE_DAYS_ATTRIBUTE, days(expiration.getMaxIdle(true)))
                .setAttribute(MAX_DAYS_ATTRIBUTE, days(expiration.getLifespan(true)))
                .createForm(TEMPLATE));
    }

    @Override
    public void processAction(RequiredActionContext context) {
        AuthenticationSessionModel authSession = context.getAuthenticationSession();
        MultivaluedMap<String, String> form = context.getHttpRequest().getDecodedFormParameters();
        String choice = form == null ? null : form.getFirst(CHOICE_PARAM);
        if (YES.equals(choice) && context.getRealm().isRememberMe()) {
            authSession.setAuthNote(Details.REMEMBER_ME, Boolean.TRUE.toString());
        } else if (YES.equals(choice) || NO.equals(choice)) {
            authSession.removeAuthNote(Details.REMEMBER_ME);
        } else {
            requiredActionChallenge(context);
            return;
        }
        authSession.setAuthNote(ANSWERED_NOTE, Boolean.TRUE.toString());
        context.getEvent().detail(EVENT_DETAIL, choice);
        if (signedInWithLoginCode(authSession)) {
            // This page is the last one, so the LOGIN event is written in this request; the code
            // step marked an earlier request's event.
            context.getEvent().detail(EmailCodeAuthenticator.METHOD_DETAIL, EmailCodeAuthenticator.METHOD);
        }
        context.success();
    }

    /** Whole days, at least one, as the page words them. */
    static String days(int seconds) {
        return Integer.toString(Math.max(1, seconds / DAY_SECONDS));
    }

    private static boolean isSkyApp(ClientModel client) {
        return client != null && SKYAPP_CLIENT_ID.equals(client.getClientId());
    }

    private static boolean isBlank(String value) {
        return value == null || value.isBlank();
    }

    @Override
    public String getDisplayText() {
        return "SKY LAB stay signed in (after a YTÜ login)";
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
