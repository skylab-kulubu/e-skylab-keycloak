package com.skylab.authenticator;

import com.skylab.account.PersonalEmailOffer;
import jakarta.ws.rs.core.MultivaluedHashMap;
import jakarta.ws.rs.core.Response;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.keycloak.authentication.AuthenticationProcessor;
import org.keycloak.authentication.InitiatedActionSupport;
import org.keycloak.authentication.RequiredActionContext;
import org.keycloak.authentication.RequiredActionFactory;
import org.keycloak.common.Profile;
import org.keycloak.common.util.Time;
import org.keycloak.events.Details;
import org.keycloak.events.EventBuilder;
import org.keycloak.forms.login.LoginFormsProvider;
import org.keycloak.http.HttpRequest;
import org.keycloak.models.ClientModel;
import org.keycloak.models.Constants;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;
import org.keycloak.models.UserSessionModel;
import org.keycloak.models.UserSessionProvider;
import org.keycloak.sessions.AuthenticationSessionModel;
import org.keycloak.sessions.RootAuthenticationSessionModel;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.ServiceLoader;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.RETURNS_SELF;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * "Bu cihazda oturumum açık kalsın mı?" after a YTÜ login against mocked Keycloak models: when the
 * sign-in session gets the action, what the page is handed, and what each answer leaves for
 * Keycloak's {@code attachSession} (the {@link Details#REMEMBER_ME} authentication note).
 */
class SkyStaySignedInTest {

    private static final int SEVEN_DAYS = 7 * 24 * 60 * 60;
    private static final int THIRTY_DAYS = 30 * 24 * 60 * 60;
    private static final String SIGN_IN = "root-auth-session";

    private static boolean profileWasSet;

    private final SkyStaySignedIn action = new SkyStaySignedIn();
    private final RequiredActionContext context = mock(RequiredActionContext.class);
    private final KeycloakSession session = mock(KeycloakSession.class);
    private final UserSessionProvider sessions = mock(UserSessionProvider.class);
    private final RealmModel realm = mock(RealmModel.class);
    private final AuthenticationSessionModel authSession = mock(AuthenticationSessionModel.class);
    private final EventBuilder event = mock(EventBuilder.class, RETURNS_SELF);
    private final LoginFormsProvider form = mock(LoginFormsProvider.class, RETURNS_SELF);
    private final Response page = mock(Response.class);
    private final Map<String, String> notes = new HashMap<>();
    private final Map<String, String> clientNotes = new HashMap<>();
    private final Map<String, String> userSessionNotes = new HashMap<>();
    private final List<String> requiredActions = new ArrayList<>();
    private final Map<String, Object> pageAttributes = new HashMap<>();
    private final MultivaluedHashMap<String, String> posted = new MultivaluedHashMap<>();

    @BeforeAll
    static void keycloakProfile() {
        // AuthenticationManager.isSessionValid reads the feature profile.
        profileWasSet = Profile.getInstance() != null;
        if (!profileWasSet) {
            Profile.defaults();
        }
    }

    @AfterAll
    static void resetProfile() {
        if (!profileWasSet) {
            Profile.reset();
        }
    }

    @BeforeEach
    void setUp() {
        when(context.getSession()).thenReturn(session);
        when(context.getRealm()).thenReturn(realm);
        when(context.getAuthenticationSession()).thenReturn(authSession);
        when(context.getEvent()).thenReturn(event);
        when(context.form()).thenReturn(form);
        when(form.setAttribute(anyString(), any())).thenAnswer(call -> {
            pageAttributes.put(call.getArgument(0), call.getArgument(1));
            return form;
        });
        when(form.createForm(SkyStaySignedIn.TEMPLATE)).thenReturn(page);
        HttpRequest request = mock(HttpRequest.class);
        when(context.getHttpRequest()).thenReturn(request);
        when(request.getDecodedFormParameters()).thenReturn(posted);
        when(session.sessions()).thenReturn(sessions);

        // The realm as config/account-center-realm.json sets it.
        when(realm.isRememberMe()).thenReturn(true);
        when(realm.getSsoSessionIdleTimeout()).thenReturn(7200);
        when(realm.getSsoSessionMaxLifespan()).thenReturn(28800);
        when(realm.getSsoSessionIdleTimeoutRememberMe()).thenReturn(SEVEN_DAYS);
        when(realm.getSsoSessionMaxLifespanRememberMe()).thenReturn(THIRTY_DAYS);

        RootAuthenticationSessionModel root = mock(RootAuthenticationSessionModel.class);
        when(root.getId()).thenReturn(SIGN_IN);
        when(authSession.getParentSession()).thenReturn(root);
        when(authSession.getAuthNote(anyString())).thenAnswer(call -> notes.get(call.<String>getArgument(0)));
        doAnswer(call -> notes.put(call.getArgument(0), call.getArgument(1)))
                .when(authSession).setAuthNote(anyString(), anyString());
        doAnswer(call -> notes.remove(call.<String>getArgument(0)))
                .when(authSession).removeAuthNote(anyString());
        when(authSession.getClientNote(anyString())).thenAnswer(call -> clientNotes.get(call.<String>getArgument(0)));
        when(authSession.getUserSessionNotes()).thenReturn(userSessionNotes);
        doAnswer(call -> requiredActions.add(call.getArgument(0)))
                .when(authSession).addRequiredAction(anyString());

        // What IdentityBrokerService.finishBrokerAuthentication leaves on a YTÜ sign-in.
        userSessionNotes.put(Details.IDENTITY_PROVIDER, "OBS");
    }

    private void trigger() {
        action.evaluateTriggers(context);
    }

    private void answer(String choice) {
        posted.clear();
        if (choice != null) {
            posted.putSingle(SkyStaySignedIn.CHOICE_PARAM, choice);
        }
        action.processAction(context);
    }

    private UserSessionModel liveSession(int lastRefresh) {
        UserSessionModel existing = mock(UserSessionModel.class);
        when(existing.getUser()).thenReturn(mock(UserModel.class));
        when(existing.getStarted()).thenReturn(lastRefresh);
        when(existing.getLastSessionRefresh()).thenReturn(lastRefresh);
        when(sessions.getUserSession(realm, SIGN_IN)).thenReturn(existing);
        return existing;
    }

    @Test
    void aYtuSignInGetsTheQuestionOnItsSignInSessionOnly() {
        trigger();

        assertEquals(List.of(SkyStaySignedIn.PROVIDER_ID), requiredActions, "on the sign-in session, not on the user");
    }

    @Test
    void noQuestionWithoutYtu() {
        userSessionNotes.clear();
        trigger();
        assertTrue(requiredActions.isEmpty(), "a password or passkey login keeps its own box");

        userSessionNotes.put(Details.IDENTITY_PROVIDER, "github");
        trigger();
        assertTrue(requiredActions.isEmpty(), "another identity provider");
    }

    // A Login code sign-in has no "Beni hatırla" box either (eskylab-login-ux 08; Microsoft asks
    // "Stay signed in?" after an e-mail code too): the code step leaves its note on the session.
    @Test
    void aLoginCodeSignInGetsTheQuestionToo() {
        userSessionNotes.clear();
        notes.put("sky-email-code.method", "email_code");

        trigger();

        assertEquals(List.of(SkyStaySignedIn.PROVIDER_ID), requiredActions);
    }

    @Test
    void aLoginCodeSignInIsNotAskedWhereNobodyIsAsked() {
        userSessionNotes.clear();
        notes.put("sky-email-code.method", "email_code");
        notes.put(AuthenticationProcessor.FORWARDED_PASSIVE_LOGIN, "true");
        trigger();
        assertTrue(requiredActions.isEmpty(), "a passive login");

        notes.remove(AuthenticationProcessor.FORWARDED_PASSIVE_LOGIN);
        notes.put("sky-email-code.method", "something-else");
        trigger();
        assertTrue(requiredActions.isEmpty(), "only the code step's own value counts");
    }

    // The question is the last page, so Keycloak writes the LOGIN event in its request: the code step's
    // method has to be put on that event again (the code step put it on an earlier request's).
    @Test
    void theAnswerOfACodeSignInKeepsTheMethodOnTheLoginEvent() {
        userSessionNotes.clear();
        notes.put("sky-email-code.method", "email_code");

        answer(SkyStaySignedIn.YES);

        verify(event).detail("sky_method", "email_code");
        verify(event).detail(SkyStaySignedIn.EVENT_DETAIL, SkyStaySignedIn.YES);
    }

    @Test
    void theAnswerOfAYtuSignInNamesNoMethod() {
        answer(SkyStaySignedIn.NO);

        verify(event, never()).detail(org.mockito.ArgumentMatchers.eq("sky_method"), anyString());
    }

    @Test
    void noQuestionWhenTheRealmHasRememberMeOff() {
        when(realm.isRememberMe()).thenReturn(false);

        trigger();

        assertTrue(requiredActions.isEmpty(), "Keycloak would refuse a remember-me session");
    }

    @Test
    void noQuestionOnAPassiveLogin() {
        notes.put(AuthenticationProcessor.FORWARDED_PASSIVE_LOGIN, "true");

        trigger();

        assertTrue(requiredActions.isEmpty(), "prompt=none meeting a required action fails with interaction_required");
    }

    @Test
    void noQuestionInSkyApp() {
        ClientModel skyapp = mock(ClientModel.class);
        when(skyapp.getClientId()).thenReturn("skyapp");
        when(authSession.getClient()).thenReturn(skyapp);

        trigger();

        assertTrue(requiredActions.isEmpty(), "SkyApp's sign-in browser keeps its own tokens (Yusuf, 2026-10-12)");

        when(skyapp.getClientId()).thenReturn("account-center");
        trigger();
        assertEquals(List.of(SkyStaySignedIn.PROVIDER_ID), requiredActions, "a web client still asks");
    }

    @Test
    void noQuestionOnAnApplicationInitiatedAction() {
        clientNotes.put(Constants.KC_ACTION, "idp_link:OBS");

        trigger();

        assertTrue(requiredActions.isEmpty());
    }

    @Test
    void noQuestionWhenARe_authenticationKeepsALiveSession() {
        liveSession(Time.currentTime() - 60);

        trigger();

        assertTrue(requiredActions.isEmpty(), "prompt=login inside a live session keeps that session as it is");
    }

    @Test
    void anExpiredOrOrphanedSessionUnderTheSameIdIsReplacedSoTheQuestionCounts() {
        liveSession(Time.currentTime() - 3 * 7200);
        trigger();
        assertEquals(List.of(SkyStaySignedIn.PROVIDER_ID), requiredActions, "an idle-expired session is restarted");

        requiredActions.clear();
        UserSessionModel orphan = liveSession(Time.currentTime());
        when(orphan.getUser()).thenReturn(null);
        trigger();
        assertEquals(List.of(SkyStaySignedIn.PROVIDER_ID), requiredActions, "a session without its user is restarted");
    }

    @Test
    void thePageCarriesTheRememberMeLifetimesInDays() {
        action.requiredActionChallenge(context);

        verify(context).challenge(page);
        verify(context, never()).success();
        assertEquals("7", pageAttributes.get(SkyStaySignedIn.IDLE_DAYS_ATTRIBUTE));
        assertEquals("30", pageAttributes.get(SkyStaySignedIn.MAX_DAYS_ATTRIBUTE));
    }

    @Test
    void thePageWordsKeycloaksOwnRememberMeLifetimes() {
        // Keycloak takes the longer of the ordinary and the remember-me values.
        when(realm.getSsoSessionIdleTimeoutRememberMe()).thenReturn(0);
        when(realm.getSsoSessionMaxLifespanRememberMe()).thenReturn(14 * 24 * 60 * 60);

        action.requiredActionChallenge(context);

        assertEquals("1", pageAttributes.get(SkyStaySignedIn.IDLE_DAYS_ATTRIBUTE), "two hours read as at least a day");
        assertEquals("14", pageAttributes.get(SkyStaySignedIn.MAX_DAYS_ATTRIBUTE));
        assertEquals("3", SkyStaySignedIn.days(3 * 24 * 60 * 60 + 5));
    }

    @Test
    void anActionPutOnAUserByHandLetsTheLoginGoOn() {
        userSessionNotes.clear();

        action.requiredActionChallenge(context);

        verify(context).success();
        verify(context, never()).challenge(any());
        assertEquals("true", notes.get(SkyStaySignedIn.ANSWERED_NOTE));
    }

    @Test
    void yesMakesTheNewSessionARememberMeSession() {
        answer(SkyStaySignedIn.YES);

        assertEquals("true", notes.get(Details.REMEMBER_ME), "what attachSession reads");
        assertEquals("true", notes.get(SkyStaySignedIn.ANSWERED_NOTE));
        verify(event).detail(SkyStaySignedIn.EVENT_DETAIL, "yes");
        verify(context).success();

        trigger();
        assertTrue(requiredActions.isEmpty(), "answered once per sign-in");
    }

    @Test
    void noLeavesAnOrdinarySession() {
        notes.put(Details.REMEMBER_ME, "true");

        answer(SkyStaySignedIn.NO);

        assertNull(notes.get(Details.REMEMBER_ME), "the answer is the last word");
        assertEquals("true", notes.get(SkyStaySignedIn.ANSWERED_NOTE));
        verify(event).detail(SkyStaySignedIn.EVENT_DETAIL, "no");
        verify(context).success();
    }

    @Test
    void yesCannotMakeARememberMeSessionInARealmWithoutRememberMe() {
        when(realm.isRememberMe()).thenReturn(false);

        answer(SkyStaySignedIn.YES);

        assertNull(notes.get(Details.REMEMBER_ME));
        verify(context).success();
    }

    @Test
    void anythingElseShowsThePageAgain() {
        answer("maybe");
        answer(null);

        assertNull(notes.get(Details.REMEMBER_ME));
        assertFalse(notes.containsKey(SkyStaySignedIn.ANSWERED_NOTE));
        verify(context, never()).success();
        verify(context, org.mockito.Mockito.times(2)).challenge(page);
    }

    @Test
    void itIsARequiredActionOfItsOwnThatNoApplicationCanRequest() {
        assertEquals("sky-stay-signed-in", action.getId());
        assertSame(action, action.create(session));
        assertEquals(InitiatedActionSupport.NOT_SUPPORTED, action.initiatedActionSupport());
        assertFalse(action.getDisplayText().isBlank());
        List<String> registered = ServiceLoader.load(RequiredActionFactory.class).stream()
                .map(provider -> provider.type().getName()).toList();
        assertTrue(registered.contains(SkyStaySignedIn.class.getName()), registered.toString());
        assertTrue(registered.contains(PersonalEmailOffer.class.getName()), registered.toString());
    }
}
