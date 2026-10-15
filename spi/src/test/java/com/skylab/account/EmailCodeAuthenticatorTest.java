package com.skylab.account;

import jakarta.ws.rs.core.MultivaluedHashMap;
import jakarta.ws.rs.core.Response;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.keycloak.WebAuthnConstants;
import org.keycloak.authentication.AuthenticationFlowContext;
import org.keycloak.authentication.authenticators.browser.AbstractUsernameFormAuthenticator;
import org.keycloak.authentication.authenticators.browser.WebAuthnConditionalUIAuthenticator;
import org.keycloak.common.ClientConnection;
import org.keycloak.common.util.Time;
import org.keycloak.events.Details;
import org.keycloak.events.EventBuilder;
import org.keycloak.events.EventType;
import org.keycloak.models.AuthenticatorConfigModel;
import org.keycloak.models.Constants;
import org.keycloak.forms.login.LoginFormsProvider;
import org.keycloak.http.HttpRequest;
import org.keycloak.models.AuthenticationExecutionModel;
import org.keycloak.models.FederatedIdentityModel;
import org.keycloak.models.KeycloakContext;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.SingleUseObjectProvider;
import org.keycloak.models.SubjectCredentialManager;
import org.keycloak.models.UserModel;
import org.keycloak.models.UserProvider;
import org.keycloak.models.credential.OTPCredentialModel;
import org.keycloak.services.managers.BruteForceProtector;
import org.keycloak.sessions.AuthenticationSessionModel;
import org.keycloak.sessions.RootAuthenticationSessionModel;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyBoolean;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyMap;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.ArgumentMatchers.isNull;
import static org.mockito.Mockito.RETURNS_SELF;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * "E-postayla devam et" (eskylab-login-ux 08, ADR-0063, CONTEXT "Login code") against mocked
 * Keycloak models, an in-memory single-use store and a mailer that keeps what it was handed.
 */
class EmailCodeAuthenticatorTest {

    private static final String YTU = "OBS";

    private final MemoryStore store = new MemoryStore();
    private final KeycloakSession session = mock(KeycloakSession.class);
    private final RealmModel realm = mock(RealmModel.class);
    private final UserProvider users = mock(UserProvider.class);
    private final BruteForceProtector protector = mock(BruteForceProtector.class);
    private final RecordingMail mail = new RecordingMail();
    private final Map<String, UserModel> byId = new HashMap<>();
    private final Set<String> lockedOut = new HashSet<>();
    private final Set<String> linkedToYtu = new HashSet<>();
    private final Set<String> withOtp = new HashSet<>();
    /** The realm's flows by id; the code step runs in the shape the reconciler builds. */
    private final Map<String, List<AuthenticationExecutionModel>> flows = new HashMap<>();
    private final AuthenticationExecutionModel step = OtpAfterCodeTest.reconciledShape(flows);

    /** Self-registration (ticket 09): the step's setting, off unless a test turns it on. */
    private boolean signUpOn;
    /** The accounts the sign-up opened, in order: username, address, firstName, lastName. */
    private final List<Map<String, String>> opened = new ArrayList<>();
    /** The next account the fake refuses to open, and why. */
    private SignUpAccounts.Refused.Reason refuseNext;
    /** Whether an opened account is found by lookups at once (committed) or only later. */
    private boolean openedVisible = true;
    private final List<UserModel> openedNotYetVisible = new ArrayList<>();
    private final SignUpAccounts accounts = (keycloakSession, keycloakRealm, username, address, firstName, lastName) -> {
        if (refuseNext != null) {
            SignUpAccounts.Refused.Reason reason = refuseNext;
            refuseNext = null;
            throw new SignUpAccounts.Refused(reason);
        }
        opened.add(Map.of("username", username, "address", address, "firstName", firstName, "lastName", lastName));
        UserModel user = person("new-" + opened.size(), username, address,
                IdentityResource.PERSONAL_EMAIL_ATTRIBUTE + "=" + address,
                IdentityResource.PERSONAL_EMAIL_VERIFIED_AT_ATTRIBUTE + "=2026-10-15T10:00:00Z");
        if (!openedVisible) {
            byId.remove(user.getId());
            openedNotYetVisible.add(user);
        }
        return user;
    };

    private EmailCodeAuthenticator authenticator = authenticator(500, null);

    private AuthenticatorConfigModel signUpConfig() {
        AuthenticatorConfigModel config = new AuthenticatorConfigModel();
        config.setConfig(Map.of(EmailCodeSignUp.CONFIG, Boolean.toString(signUpOn)));
        return config;
    }

    /** What the authenticator mailed: whom, where, which code, for what. */
    private record Sent(String userId, String address, String code, String purpose) {
    }

    private static final class RecordingMail implements LoginCodeMail {
        final List<Sent> sent = new ArrayList<>();
        final List<String> alarms = new ArrayList<>();

        @Override
        public void sendCode(AuthenticationFlowContext context, UserModel user, String address, String code,
                String purpose) {
            sent.add(new Sent(user.getId(), address, code, purpose));
        }

        @Override
        public void sendSignUpCode(AuthenticationFlowContext context, String address, String code) {
            sent.add(new Sent(null, address, code, "signup"));
        }

        @Override
        public void alarm(AuthenticationFlowContext context, String level, int dailyLimit) {
            alarms.add(level + "/" + dailyLimit);
        }

        @Override
        public void ceilingAlarm(AuthenticationFlowContext context, int ceiling, int accounts) {
            alarms.add("ceiling/" + ceiling + "/" + accounts);
        }

        Sent last() {
            return sent.get(sent.size() - 1);
        }
    }

    /** One sign-in session (browser tab) at one remote address. */
    private final class Browser {
        final AuthenticationFlowContext context = mock(AuthenticationFlowContext.class);
        final AuthenticationSessionModel authSession = mock(AuthenticationSessionModel.class);
        final Map<String, String> notes = new HashMap<>();
        final EventBuilder event = mock(EventBuilder.class, RETURNS_SELF);
        final List<EventBuilder> failures = new ArrayList<>();
        final List<Map<String, String>> failureDetails = new ArrayList<>();
        final LoginFormsProvider form = mock(LoginFormsProvider.class, RETURNS_SELF);
        final Map<String, Object> page = new HashMap<>();
        final MultivaluedHashMap<String, String> posted = new MultivaluedHashMap<>();
        /** The event type of each cloned event (REGISTER for the sign-up's), and whether it succeeded. */
        final List<EventType> clonedTypes = new ArrayList<>();
        final List<Boolean> clonedSucceeded = new ArrayList<>();
        String template;
        UserModel signedIn;
        boolean succeeded;

        Browser(String sessionId, String remote) {
            when(context.getSession()).thenReturn(session);
            when(context.getRealm()).thenReturn(realm);
            when(context.getAuthenticationSession()).thenReturn(authSession);
            when(context.getEvent()).thenReturn(event);
            when(context.getProtector()).thenReturn(protector);
            when(context.getExecution()).thenReturn(step);
            when(context.form()).thenAnswer(call -> {
                page.clear();
                return form;
            });
            when(form.setAttribute(anyString(), any())).thenAnswer(call -> {
                page.put(call.getArgument(0), call.getArgument(1));
                return form;
            });
            when(form.createForm(anyString())).thenAnswer(call -> {
                template = call.getArgument(0);
                return mock(Response.class);
            });
            when(context.getAuthenticatorConfig()).thenAnswer(call -> signUpConfig());
            HttpRequest request = mock(HttpRequest.class);
            when(context.getHttpRequest()).thenReturn(request);
            when(request.getDecodedFormParameters()).thenReturn(posted);
            ClientConnection connection = mock(ClientConnection.class);
            when(connection.getRemoteAddr()).thenReturn(remote);
            when(context.getConnection()).thenReturn(connection);
            doAnswer(call -> {
                signedIn = call.getArgument(0);
                return null;
            }).when(context).setUser(any());
            doAnswer(call -> {
                succeeded = true;
                return null;
            }).when(context).success();

            // Every failure is a clone of the flow's event; keep each one's details.
            when(event.clone()).thenAnswer(call -> {
                EventBuilder failure = mock(EventBuilder.class, RETURNS_SELF);
                Map<String, String> details = new HashMap<>();
                int index = clonedTypes.size();
                clonedTypes.add(EventType.LOGIN);
                clonedSucceeded.add(false);
                when(failure.detail(anyString(), anyString())).thenAnswer(detail -> {
                    details.put(detail.getArgument(0), detail.getArgument(1));
                    return failure;
                });
                when(failure.event(any(EventType.class))).thenAnswer(type -> {
                    clonedTypes.set(index, type.getArgument(0));
                    return failure;
                });
                doAnswer(success -> {
                    clonedSucceeded.set(index, true);
                    return null;
                }).when(failure).success();
                failures.add(failure);
                failureDetails.add(details);
                return failure;
            });

            RootAuthenticationSessionModel root = mock(RootAuthenticationSessionModel.class);
            when(root.getId()).thenReturn(sessionId);
            when(authSession.getParentSession()).thenReturn(root);
            when(authSession.getTabId()).thenReturn("tab");
            when(authSession.getAuthNote(anyString())).thenAnswer(call -> notes.get(call.<String>getArgument(0)));
            doAnswer(call -> notes.put(call.getArgument(0), call.getArgument(1)))
                    .when(authSession).setAuthNote(anyString(), anyString());
            doAnswer(call -> notes.remove(call.<String>getArgument(0)))
                    .when(authSession).removeAuthNote(anyString());
        }

        void open() {
            authenticator.authenticate(context);
        }

        void post(String action, String name, String value) {
            posted.clear();
            if (action != null) {
                posted.putSingle(EmailCodeAuthenticator.ACTION_PARAM, action);
            }
            if (name != null) {
                posted.putSingle(name, value);
            }
            authenticator.action(context);
        }

        /** Keycloak's execution switch to this step, as the theme's "Hesap aç" (or, without it, "E-postayla devam et") posts it. */
        void choose(boolean signUp) {
            posted.clear();
            posted.putSingle(Constants.AUTHENTICATION_EXECUTION, "execution-id");
            if (signUp) {
                posted.putSingle(EmailCodeSignUp.INTENT_PARAM, EmailCodeSignUp.INTENT_SIGN_UP);
            }
            authenticator.authenticate(context);
        }

        /** "Hesabı aç" with the two names. */
        void signUp(String firstName, String lastName) {
            posted.clear();
            posted.putSingle(EmailCodeAuthenticator.ACTION_PARAM, EmailCodeSignUp.SIGN_UP);
            posted.putSingle(EmailCodeSignUp.FIRST_NAME_PARAM, firstName);
            posted.putSingle(EmailCodeSignUp.LAST_NAME_PARAM, lastName);
            authenticator.action(context);
        }

        /** "Devam et" on the existing stage. */
        void carryOn() {
            post(EmailCodeSignUp.CONTINUE, null, null);
        }

        String signUpStage() {
            return EmailCodeSignUp.TEMPLATE.equals(template) ? (String) shown(EmailCodeSignUp.STAGE_ATTRIBUTE) : null;
        }

        String signUpError() {
            return (String) shown(EmailCodeSignUp.ERROR_ATTRIBUTE);
        }

        /** The details of the last event of the given type this browser wrote. */
        Map<String, String> lastEvent(EventType type) {
            for (int i = clonedTypes.size() - 1; i >= 0; i--) {
                if (clonedTypes.get(i) == type) {
                    return failureDetails.get(i);
                }
            }
            return null;
        }

        void send(String identifier) {
            post(EmailCodeAuthenticator.SEND, EmailCodeAuthenticator.IDENTIFIER_PARAM, identifier);
        }

        void verify(String code) {
            post(EmailCodeAuthenticator.VERIFY, EmailCodeAuthenticator.CODE_PARAM, code);
        }

        void resend() {
            post(EmailCodeAuthenticator.RESEND, null, null);
        }

        Object shown(String attribute) {
            return page.get(attribute);
        }

        String stage() {
            return (String) shown(EmailCodeAuthenticator.STAGE_ATTRIBUTE);
        }

        String error() {
            return (String) shown(EmailCodeAuthenticator.ERROR_ATTRIBUTE);
        }

        /** The details of the last failure event this browser caused. */
        Map<String, String> lastFailure() {
            return failureDetails.get(failureDetails.size() - 1);
        }
    }

    private Browser browser;

    @BeforeEach
    void setUp() {
        KeycloakContext keycloakContext = mock(KeycloakContext.class);
        when(session.getContext()).thenReturn(keycloakContext);
        when(keycloakContext.getRealm()).thenReturn(realm);
        when(realm.getId()).thenReturn("realm-id");
        when(realm.getName()).thenReturn("e-skylab");
        when(realm.isLoginWithEmailAllowed()).thenReturn(true);
        when(realm.isBruteForceProtected()).thenReturn(true);
        when(session.singleUseObjects()).thenReturn(store);
        when(session.users()).thenReturn(users);
        OtpAfterCodeTest.knownAuthenticators(session);
        when(realm.getAuthenticationExecutionsStream(anyString()))
                .thenAnswer(call -> flows.getOrDefault(call.<String>getArgument(0), List.of()).stream());
        when(protector.isTemporarilyDisabled(eq(session), eq(realm), any()))
                .thenAnswer(call -> lockedOut.contains(call.<UserModel>getArgument(2).getId()));
        when(users.getUserById(eq(realm), anyString())).thenAnswer(call -> byId.get(call.<String>getArgument(1)));
        when(users.getUserByUsername(eq(realm), anyString())).thenAnswer(call -> byId.values().stream()
                .filter(user -> user.getUsername().equalsIgnoreCase(call.getArgument(1))).findFirst().orElse(null));
        when(users.getUserByEmail(eq(realm), anyString())).thenAnswer(call -> byId.values().stream()
                .filter(user -> user.getEmail() != null && user.getEmail().equalsIgnoreCase(call.getArgument(1)))
                .findFirst().orElse(null));
        when(users.searchForUserStream(eq(realm), anyMap(), anyInt(), anyInt())).thenAnswer(call -> {
            Map<String, String> query = call.getArgument(1);
            return byId.values().stream().filter(user -> query.entrySet().stream()
                    .filter(entry -> !entry.getKey().equals(UserModel.EXACT)
                            && !entry.getKey().equals(UserModel.INCLUDE_SERVICE_ACCOUNT))
                    .allMatch(entry -> entry.getValue().equalsIgnoreCase(user.getFirstAttribute(entry.getKey()))));
        });
        when(users.getFederatedIdentity(eq(realm), any(), eq(YTU))).thenAnswer(call ->
                linkedToYtu.contains(call.<UserModel>getArgument(1).getId()) ? mock(FederatedIdentityModel.class) : null);
        browser = new Browser("root-1", "203.0.113.7");
    }

    @AfterEach
    void resetClock() {
        Time.setOffset(0);
    }

    private EmailCodeAuthenticator authenticator(int dailyLimit, WebAuthnConditionalUIAuthenticator webauthn) {
        return authenticator(dailyLimit, webauthn, EmailCodeSettings.DEFAULT_WRONG_CODES_PER_ACCOUNT);
    }

    private EmailCodeAuthenticator authenticator(int dailyLimit, WebAuthnConditionalUIAuthenticator webauthn,
            int wrongCodesPerAccount) {
        return new EmailCodeAuthenticator(new EmailCodeSettings(YTU, dailyLimit, null, wrongCodesPerAccount), mail, webauthn,
                accounts, new SignUpUsernames());
    }

    /** A person of the realm; attributes are name=value pairs. */
    private UserModel person(String id, String username, String email, String... attributes) {
        UserModel user = mock(UserModel.class);
        Map<String, String> values = new HashMap<>();
        for (String attribute : attributes) {
            values.put(attribute.substring(0, attribute.indexOf('=')), attribute.substring(attribute.indexOf('=') + 1));
        }
        when(user.getId()).thenReturn(id);
        when(user.getUsername()).thenReturn(username);
        when(user.getEmail()).thenReturn(email);
        when(user.isEmailVerified()).thenReturn(true);
        when(user.isEnabled()).thenReturn(true);
        when(user.getFirstAttribute(anyString())).thenAnswer(call -> values.get(call.<String>getArgument(0)));
        SubjectCredentialManager credentials = mock(SubjectCredentialManager.class);
        when(credentials.isConfiguredFor(anyString())).thenAnswer(call ->
                OTPCredentialModel.TYPE.equals(call.getArgument(0)) && withOtp.contains(id));
        when(user.credentialManager()).thenReturn(credentials);
        byId.put(id, user);
        return user;
    }

    // ------------------------------------------------------------------------------- sending

    @Test
    void theFirstPageAsksForTheAddressOrUsername() {
        browser.open();

        assertEquals("identifier", browser.stage());
        assertNull(browser.error());
        assertEquals("10", browser.shown(EmailCodeAuthenticator.CODE_MINUTES_ATTRIBUTE));
    }

    @Test
    void theCodeGoesToThePrimaryAddressWhicheverIdentifierWasTyped() {
        person("ada", "ada", "ada@example.com",
                IdentityResource.SCHOOL_EMAIL_ATTRIBUTE + "=ada.lovelace@std.yildiz.edu.tr",
                IdentityResource.PERSONAL_EMAIL_ATTRIBUTE + "=ada@example.com",
                "personalEmailVerifiedAt=2026-10-01T10:00:00Z");
        linkedToYtu.add("ada");
        Time.setOffset(-(Time.currentTime() % (15 * 60)));

        for (String typed : List.of("ada", "ADA@example.com", "Ada.Lovelace@STD.yildiz.edu.tr")) {
            Browser tab = new Browser("root-" + typed, "203.0.113.7");
            tab.send(typed);
            assertEquals("code", tab.stage(), typed);
            assertEquals(new Sent("ada", "ada@example.com", mail.last().code(), "login"), mail.last(), typed);
        }
        assertEquals(3, mail.sent.size());
    }

    @Test
    void withoutAPrimaryAddressTheCodeGoesToTheSchoolAddressOfAVerifiedYtuAccount() {
        person("ytu", "ytu-user", null, IdentityResource.SCHOOL_EMAIL_ATTRIBUTE + "=Yeni@std.yildiz.edu.tr");
        linkedToYtu.add("ytu");

        browser.send("yeni@std.yildiz.edu.tr");

        assertEquals("Yeni@std.yildiz.edu.tr", mail.last().address());
    }

    @Test
    void aSchoolAddressWithoutTheYtuLinkReceivesNothing() {
        person("unlinked", "unlinked", null, IdentityResource.SCHOOL_EMAIL_ATTRIBUTE + "=old@std.yildiz.edu.tr");

        browser.send("unlinked");

        assertEquals("code", browser.stage());
        assertTrue(mail.sent.isEmpty());
    }

    // Spec §7.4: the page is the same whether or not an account exists; no mail goes for nobody
    // while Self-registration (ticket 09) is off.
    @Test
    void anIdentifierThatNamesNobodyGetsTheSamePageAndNoMail() {
        person("ada", "ada", "ada@example.com");
        browser.send("ada@example.com");
        Map<String, Object> known = new HashMap<>(browser.page);

        Browser stranger = new Browser("root-2", "203.0.113.7");
        stranger.send("nobody@example.com");
        Map<String, Object> unknown = new HashMap<>(stranger.page);

        assertEquals(1, mail.sent.size(), "nobody must not receive a code");
        known.remove(EmailCodeAuthenticator.IDENTIFIER_ATTRIBUTE);
        unknown.remove(EmailCodeAuthenticator.IDENTIFIER_ATTRIBUTE);
        assertEquals(known, unknown, "the code page must not tell whether the account exists");
        assertEquals("nobody@example.com", stranger.shown(EmailCodeAuthenticator.IDENTIFIER_ATTRIBUTE),
                "the page shows what the person typed, never where a code went");
        assertTrue(stranger.failures.isEmpty(), "asking for a code is not a failure");
    }

    @Test
    void aDisabledOrAmbiguousOrServiceAccountGetsNoMailAndTheSamePage() {
        UserModel disabled = person("off", "off", "off@example.com");
        when(disabled.isEnabled()).thenReturn(false);
        person("one", "one", "shared@example.com");
        person("two", "shared@example.com", "two@example.com");
        UserModel robot = person("robot", "robot", "robot@example.com");
        when(robot.getServiceAccountClientLink()).thenReturn("client-id");

        for (String typed : List.of("off", "shared@example.com", "robot")) {
            Browser tab = new Browser("root-" + typed, "203.0.113.7");
            tab.send(typed);
            assertEquals("code", tab.stage(), typed);
            assertNull(tab.error(), typed);
        }
        assertTrue(mail.sent.isEmpty());
    }

    @Test
    void anEmptyOrOverlongIdentifierIsRefusedBeforeAnyBudgetIsSpent() {
        browser.send("   ");
        assertEquals("identifier", browser.stage());
        assertEquals("invalid_identifier", browser.error());
        browser.send("a".repeat(256) + "@example.com");
        assertEquals("invalid_identifier", browser.error());
        assertEquals(0, store.claimedSlots());
    }

    // ------------------------------------------------------------------------------- the code

    @Test
    void theRightCodeSignsInThePersonAndMarksTheLoginAsACodeLogin() {
        UserModel ada = person("ada", "ada", "ada@example.com");
        browser.send("Ada@Example.com");

        browser.verify(mail.last().code());

        assertTrue(browser.succeeded);
        assertEquals(ada, browser.signedIn);
        assertEquals("Ada@Example.com", browser.notes.get(AbstractUsernameFormAuthenticator.ATTEMPTED_USERNAME),
                "the login event and the session name what was typed, as the password form does");
        assertEquals("email_code", browser.notes.get(EmailCodeAuthenticator.METHOD_NOTE));
        assertNull(browser.notes.get(EmailCodeAuthenticator.HANDLE_NOTE));
        verify(browser.event).detail("sky_method", "email_code");
        verify(protector, never()).failedLogin(any(), any(), any(), any(), any());
    }

    @Test
    void theCodeCanBeTypedWithTheSpaceTheMailShows() {
        person("ada", "ada", "ada@example.com");
        browser.send("ada");
        String code = mail.last().code();

        browser.verify(code.substring(0, 4) + " " + code.substring(4));

        assertTrue(browser.succeeded);
    }

    @Test
    void aPersonWithOtpGoesOnToItWhileTheFlowAsksForItAfterTheCode() {
        UserModel fikret = person("fikret", "fikret", "fikret@example.com");
        withOtp.add("fikret");
        browser.send("fikret");

        browser.verify(mail.last().code());

        assertTrue(browser.succeeded, "Keycloak's conditional OTP comes next");
        assertEquals(fikret, browser.signedIn);
    }

    // Security review K1: someone turns the OTP subflow off in the Admin Console; until the
    // reconciler (or an operator) puts it back, the code signs in nobody with OTP.
    @Test
    void aPersonWithOtpIsRefusedWhenTheFlowNoLongerAsksForItAfterTheCode() {
        UserModel fikret = person("fikret", "fikret", "fikret@example.com");
        when(fikret.isEmailVerified()).thenReturn(false);
        withOtp.add("fikret");
        flows.get(OtpAfterCodeTest.CODE_FLOW).stream().filter(model -> model.getId().equals("otp")).findFirst()
                .orElseThrow().setRequirement(AuthenticationExecutionModel.Requirement.DISABLED);
        browser.send("fikret");

        browser.verify(mail.last().code());

        assertFalse(browser.succeeded);
        assertNull(browser.signedIn);
        assertEquals("identifier", browser.stage());
        assertEquals("unavailable", browser.error());
        assertEquals("otp_unguarded", browser.lastFailure().get("sky_email_code"));
        assertNull(browser.notes.get(EmailCodeAuthenticator.HANDLE_NOTE), "the code is spent");
        assertNull(browser.notes.get(EmailCodeAuthenticator.METHOD_NOTE));
        verify(fikret, never()).setEmailVerified(anyBoolean());
        verify(protector, never()).failedLogin(any(), any(), any(), any(), any());
    }

    @Test
    void aPersonWithoutOtpLosesNothingWhenTheOtpSubflowIsOff() {
        UserModel ada = person("ada", "ada", "ada@example.com");
        flows.get(OtpAfterCodeTest.OTP_FLOW).forEach(model ->
                model.setRequirement(AuthenticationExecutionModel.Requirement.DISABLED));
        browser.send("ada");

        browser.verify(mail.last().code());

        assertTrue(browser.succeeded);
        assertEquals(ada, browser.signedIn);
    }

    // The flow's last step may run in a later request (the TOTP page, the passkey offer); the
    // subflow's success puts the method on that request's LOGIN event.
    @Test
    void theEndOfTheSubflowPutsTheMethodOnTheLoginEventOnlyAfterACode() {
        authenticator.onParentFlowSuccess(browser.context);
        verify(browser.event, never()).detail(eq("sky_method"), anyString());

        browser.notes.put(EmailCodeAuthenticator.METHOD_NOTE, "email_code");
        authenticator.onParentFlowSuccess(browser.context);
        verify(browser.event).detail("sky_method", "email_code");
    }

    @Test
    void aWrongCodeCostsATryAndCountsTowardThePersonsBruteForceLock() {
        UserModel ada = person("ada", "ada", "ada@example.com");
        browser.send("ada");

        browser.verify(other(mail.last().code()));

        assertFalse(browser.succeeded);
        assertEquals("code", browser.stage());
        assertEquals("wrong_code", browser.error());
        assertEquals("4", browser.shown(EmailCodeAuthenticator.ATTEMPTS_LEFT_ATTRIBUTE));
        verify(protector).failedLogin(eq(realm), eq(ada), any(), any(), isNull());
        EventBuilder failure = browser.failures.get(0);
        verify(failure).user(ada);
        verify(failure).error("invalid_code");
        assertEquals("wrong_code", browser.lastFailure().get(EmailCodeAuthenticator.EVENT_DETAIL));
        assertEquals("email_code", browser.lastFailure().get("sky_method"));
    }

    // Spec §7.5: the events of wrong codes, locks and limits reach the log (jboss-logging) without
    // the person's address or IP.
    @Test
    void failureEventsCarryNeitherTheIpNorTheTypedAddress() {
        person("ada", "ada", "ada@example.com");
        browser.send("ada@example.com");
        browser.verify(other(mail.last().code()));

        EventBuilder failure = browser.failures.get(0);
        verify(failure).ipAddress(null);
        verify(failure).removeDetail(Details.USERNAME);
        browser.failureDetails.forEach(details -> details.values().forEach(value -> {
            assertFalse(value.contains("ada@example.com"), value);
            assertFalse(value.contains("203.0.113"), value);
        }));
    }

    @Test
    void aWrongCodeForNobodyLooksTheSameButCountsAgainstNoOne() {
        person("ada", "ada", "ada@example.com");
        browser.send("ada");
        browser.verify(other(mail.last().code()));
        Map<String, Object> known = new HashMap<>(browser.page);

        Browser stranger = new Browser("root-2", "203.0.113.7");
        stranger.send("nobody@example.com");
        // Nobody can read the code that was never mailed; put a known one in its place.
        String decoy = new LoginCodes(store).issue(stranger.notes.get(EmailCodeAuthenticator.HANDLE_NOTE), "", "");
        stranger.verify(other(decoy));
        Map<String, Object> unknown = new HashMap<>(stranger.page);

        known.remove(EmailCodeAuthenticator.IDENTIFIER_ATTRIBUTE);
        unknown.remove(EmailCodeAuthenticator.IDENTIFIER_ATTRIBUTE);
        assertEquals(known, unknown, "a wrong code must look the same for nobody");
        verify(protector, times(1)).failedLogin(any(), any(), any(), any(), any());
        verify(stranger.failures.get(0)).error("invalid_code");
        verify(stranger.failures.get(0), never()).user(any(UserModel.class));
    }

    @Test
    void theFifthWrongCodeKillsTheCodeAndTheRightOneNoLongerWorks() {
        person("ada", "ada", "ada@example.com");
        browser.send("ada");
        String code = mail.last().code();

        for (int attempt = 1; attempt < LoginCodes.MAX_ATTEMPTS; attempt++) {
            browser.verify(other(code));
            assertEquals("wrong_code", browser.error());
        }
        browser.verify(other(code));
        assertEquals("identifier", browser.stage());
        assertEquals("too_many_tries", browser.error());

        browser.verify(code);
        assertFalse(browser.succeeded);
        assertEquals("code_expired", browser.error());
    }

    @Test
    void aMalformedCodeCostsNoTry() {
        person("ada", "ada", "ada@example.com");
        browser.send("ada");

        for (String malformed : new String[] {"12a4", "123456", mail.last().code().substring(0, 6), "1234-5678"}) {
            browser.verify(malformed);

            assertEquals("code", browser.stage());
            assertEquals("malformed_code", browser.error(), malformed);
        }
        verify(protector, never()).failedLogin(any(), any(), any(), any(), any());
        browser.verify(mail.last().code());
        assertTrue(browser.succeeded);
    }

    @Test
    void aCodeOlderThanTenMinutesNoLongerWorks() {
        person("ada", "ada", "ada@example.com");
        browser.send("ada");

        Time.setOffset(LoginCodes.TTL_SECONDS + 1);
        browser.verify(mail.last().code());

        assertFalse(browser.succeeded);
        assertEquals("identifier", browser.stage());
        assertEquals("code_expired", browser.error());
    }

    // CONTEXT "Login code": it works only in the sign-in session (browser and tab) that asked for it.
    // Security review M1: the code is keyed to the sign-in session's handle, not to the person, so
    // two sessions that ask for the same person each have their own code.
    @Test
    void twoSessionsOfOnePersonCannotUseEachOthersCode() {
        UserModel ada = person("ada", "ada", "ada@example.com");
        Browser second = new Browser("root-2", "198.51.100.2");
        browser.send("ada");
        String firstCode = mail.last().code();
        second.send("ada@example.com");
        String secondCode = mail.last().code();

        second.verify(firstCode);
        assertEquals("wrong_code", second.error());
        browser.verify(secondCode);
        assertEquals("wrong_code", browser.error());

        browser.verify(firstCode);
        second.verify(secondCode);
        assertTrue(browser.succeeded && second.succeeded, "each session's own code still works");
        assertEquals(ada, browser.signedIn);
        assertEquals(ada, second.signedIn);
    }

    @Test
    void theCodeDoesNotWorkInAnotherBrowser() {
        person("ada", "ada", "ada@example.com");
        browser.send("ada");
        String code = mail.last().code();

        Browser other = new Browser("root-2", "198.51.100.4");
        other.verify(code);

        assertFalse(other.succeeded);
        assertEquals("code_expired", other.error());
        browser.verify(code);
        assertTrue(browser.succeeded, "the other browser's attempt must not cost this one its code");
    }

    @Test
    void theRightCodeWorksOnce() {
        person("ada", "ada", "ada@example.com");
        browser.send("ada");
        String code = mail.last().code();
        browser.verify(code);
        browser.succeeded = false;

        browser.verify(code);

        assertFalse(browser.succeeded);
    }

    @Test
    void aPersonLockedByBruteForceProtectionCannotSignInWithTheRightCode() {
        person("ada", "ada", "ada@example.com");
        browser.send("ada");
        lockedOut.add("ada");

        browser.verify(mail.last().code());

        assertFalse(browser.succeeded);
        assertEquals("identifier", browser.stage());
        assertEquals("account_locked", browser.error());
        verify(browser.failures.get(0)).error("user_temporarily_disabled");
    }

    @Test
    void aPersonDisabledWhileTheCodeWaitedCannotSignIn() {
        UserModel ada = person("ada", "ada", "ada@example.com");
        browser.send("ada");
        when(ada.isEnabled()).thenReturn(false);

        browser.verify(mail.last().code());

        assertFalse(browser.succeeded);
        assertEquals("account_disabled", browser.error());
    }

    // The code proves the mailbox it went to; if the person's codes go elsewhere by now (the Primary
    // e-mail changed in the ten minutes), it no longer signs them in.
    @Test
    void theCodeStopsWorkingWhenThePrimaryAddressChangedMeanwhile() {
        UserModel ada = person("ada", "ada", "ada@example.com");
        browser.send("ada");
        when(ada.getEmail()).thenReturn("ada@new.example.com");

        browser.verify(mail.last().code());

        assertFalse(browser.succeeded);
        assertEquals("code_expired", browser.error());
    }

    // Like Keycloak's reset-password link: the code proves the address it was mailed to.
    @Test
    void anUnverifiedPrimaryAddressBecomesVerifiedByTheCode() {
        UserModel ada = person("ada", "ada", "ada@example.com");
        when(ada.isEmailVerified()).thenReturn(false);
        browser.send("ada");

        browser.verify(mail.last().code());

        assertTrue(browser.succeeded);
        verify(ada).setEmailVerified(true);
        verify(ada).removeRequiredAction(UserModel.RequiredAction.VERIFY_EMAIL);
    }

    @Test
    void aVerifiedPrimaryAddressIsLeftAsItIs() {
        UserModel ada = person("ada", "ada", "ada@example.com");
        browser.send("ada");
        browser.verify(mail.last().code());

        verify(ada, never()).setEmailVerified(anyBoolean());
    }

    // The #103 review: the page never says "no account" (the code page itself never tells an
    // address apart). The right code of a code nobody was mailed gets a dead code's page; only the
    // event, which administrators read, says what it was.
    @Test
    void aGuessedCodeForNobodySignsNobodyInAndLooksLikeADeadCode() {
        browser.send("nobody@example.com");
        String handle = browser.notes.get(EmailCodeAuthenticator.HANDLE_NOTE);
        // Nobody can read the code that was never mailed; put a known one in its place.
        String known = new LoginCodes(store).issue(handle, "", "");

        browser.verify(known);

        assertFalse(browser.succeeded);
        assertNull(browser.signedIn);
        assertEquals("no_account", browser.lastFailure().get(EmailCodeAuthenticator.EVENT_DETAIL));
        Map<String, Object> guessed = new HashMap<>(browser.page);

        Browser late = new Browser("root-late", "198.51.100.9");
        late.send("nobody@example.com");
        Time.setOffset(LoginCodes.TTL_SECONDS + 1);
        late.verify(other(""));

        assertEquals("code_expired", late.error());
        assertEquals(late.page, guessed, "the same page as a code that ran out");
        for (EmailCodeAuthenticator.Problem problem : EmailCodeAuthenticator.Problem.values()) {
            assertNotEquals("no_account", problem.value, "the page has no sentence for it");
        }
    }

    // ------------------------------------------------------------------------------- navigation

    @Test
    void aReloadedPageShowsTheCodeBoxAgainWithoutANewCode() {
        person("ada", "ada", "ada@example.com");
        browser.send("ada");

        browser.open();

        assertEquals("code", browser.stage());
        assertEquals("ada", browser.shown(EmailCodeAuthenticator.IDENTIFIER_ATTRIBUTE));
        assertEquals(1, mail.sent.size());
    }

    @Test
    void anotherAddressGoesBackToTheFirstPageAndKillsTheCode() {
        person("ada", "ada", "ada@example.com");
        browser.send("ada");
        String code = mail.last().code();

        browser.post(EmailCodeAuthenticator.CHANGE, null, null);

        assertEquals("identifier", browser.stage());
        assertEquals("ada", browser.shown(EmailCodeAuthenticator.IDENTIFIER_ATTRIBUTE));
        browser.verify(code);
        assertFalse(browser.succeeded);
    }

    @Test
    void resendWaitsSixtySecondsThenReplacesTheCode() {
        person("ada", "ada", "ada@example.com");
        Time.setOffset(-(Time.currentTime() % (15 * 60)));
        browser.send("ada");
        String first = mail.last().code();
        assertEquals("60", browser.shown(EmailCodeAuthenticator.RESEND_AFTER_ATTRIBUTE));

        browser.resend();
        assertEquals("resend_too_soon", browser.error());
        assertEquals(1, mail.sent.size());

        Time.setOffset(Time.getOffset() + EmailCodeAuthenticator.RESEND_SECONDS);
        browser.resend();
        assertEquals("code", browser.stage());
        assertNull(browser.error());
        assertEquals(2, mail.sent.size());
        String second = mail.last().code();
        if (!first.equals(second)) {
            browser.verify(first);
            assertFalse(browser.succeeded, "a new code replaces the old one");
        }
        browser.verify(second);
        assertTrue(browser.succeeded);
    }

    @Test
    void passkeysOnTheFirstPageAreKeycloaksOwn() {
        WebAuthnConditionalUIAuthenticator webauthn = mock(WebAuthnConditionalUIAuthenticator.class);
        when(webauthn.isPasskeysEnabled()).thenReturn(true);
        authenticator = authenticator(500, webauthn);

        browser.open();
        verify(webauthn).fillContextForm(browser.context);

        browser.post(null, WebAuthnConstants.AUTHENTICATOR_DATA, "assertion");
        verify(webauthn).action(browser.context);
        assertTrue(mail.sent.isEmpty());
    }

    @Test
    void withoutPasskeysThePageHasNoPasskeyData() {
        WebAuthnConditionalUIAuthenticator webauthn = mock(WebAuthnConditionalUIAuthenticator.class);
        authenticator = authenticator(500, webauthn);

        browser.open();
        browser.post(null, WebAuthnConstants.AUTHENTICATOR_DATA, "assertion");

        verify(webauthn, never()).fillContextForm(any());
        verify(webauthn, never()).action(any());
    }

    // ------------------------------------------------------------------------------- budgets

    @Test
    void theSixthCodeOfOneSessionIsRefused() {
        Time.setOffset(-(Time.currentTime() % 3600));
        for (int i = 0; i < RateLimiter.LOGIN_CODE_SESSION.maxAttempts(); i++) {
            browser.send("nobody" + i + "@example.com");
            assertNull(browser.error());
        }

        browser.send("nobody@example.com");

        assertEquals("identifier", browser.stage());
        assertEquals("rate_limited", browser.error());
        verify(browser.failures.get(0)).error("sky_email_code_rate_limited");
    }

    @Test
    void oneNetworkCannotAskForMoreThanItsHourlyShare() {
        Time.setOffset(-(Time.currentTime() % 3600));
        for (int i = 0; i < RateLimiter.LOGIN_CODE_IP_CLASS.maxAttempts(); i++) {
            new Browser("root-" + i, "203.0.113." + (i % 250)).send("nobody" + i + "@example.com");
        }
        Browser last = new Browser("root-last", "203.0.113.251");
        last.send("nobody@example.com");
        assertEquals("rate_limited", last.error());

        Browser elsewhere = new Browser("root-elsewhere", "198.51.100.1");
        elsewhere.send("nobody@example.com");
        assertNull(elsewhere.error(), "another network has its own budget");
    }

    // Spec §7.2: past three codes a quarter of an hour one mailbox gets no more; the page stays
    // the same and the code already mailed keeps working.
    @Test
    void theFourthCodeToOneAddressInAQuarterHourIsNotMailedAndReplacesTheThird() {
        person("ada", "ada", "ada@example.com");
        Time.setOffset(-(Time.currentTime() % (15 * 60)));
        for (int i = 0; i < RateLimiter.LOGIN_CODE_ADDRESS.maxAttempts(); i++) {
            Time.setOffset(Time.getOffset() + EmailCodeAuthenticator.RESEND_SECONDS);
            browser.send("ada");
        }
        String third = mail.last().code();
        Map<String, Object> mailedPage = new HashMap<>(browser.page);

        Time.setOffset(Time.getOffset() + EmailCodeAuthenticator.RESEND_SECONDS);
        browser.resend();

        assertEquals(3, mail.sent.size());
        assertEquals(mailedPage, browser.page, "the page must not tell that nothing was mailed");
        assertEquals("rate_limited_address", browser.lastFailure().get(EmailCodeAuthenticator.EVENT_DETAIL));
        browser.verify(third);
        assertFalse(browser.succeeded, "a new code replaces the old one, mailed or not (review B3)");
        assertEquals("wrong_code", browser.error());
        assertEquals("4", browser.shown(EmailCodeAuthenticator.ATTEMPTS_LEFT_ATTRIBUTE), "a fresh code's tries");
    }

    /**
     * Security review B3: session S asks a code for one identifier and spends a try; two other
     * sessions ask for another identifier; S asks again and spends a try. Had S kept its old code
     * once the address budget was full, the tries left would say whether the two identifiers name
     * one account (3) or not (4).
     */
    private String triesLeftAfterAnotherIdentifierSpentTheBudget(String first, String second) {
        Time.setOffset(-(Time.currentTime() % (15 * 60)));
        Browser asker = new Browser("root-s", "198.51.100.1");
        asker.send(first);
        asker.verify(other(""));
        for (int i = 0; i < 2; i++) {
            new Browser("root-o" + i, "198.51.100.2" + i).send(second);
        }
        Time.setOffset(Time.getOffset() + EmailCodeAuthenticator.RESEND_SECONDS);
        asker.resend();
        asker.verify(other(""));
        assertEquals("wrong_code", asker.error());
        return (String) asker.shown(EmailCodeAuthenticator.ATTEMPTS_LEFT_ATTRIBUTE);
    }

    @Test
    void theTriesLeftDoNotTellThatTwoIdentifiersNameOneAccount() {
        person("ada", "ada", "ada@example.com");
        String oneAccount = triesLeftAfterAnotherIdentifierSpentTheBudget("ada@example.com", "ada");
        store.clear();
        String nobody = triesLeftAfterAnotherIdentifierSpentTheBudget("x@example.com", "y@example.com");

        assertEquals(nobody, oneAccount);
        assertEquals("4", oneAccount);
    }

    @Test
    void anIdentifierThatNamesNobodySpendsTheAddressBudgetToo() {
        Time.setOffset(-(Time.currentTime() % (15 * 60)));
        List<Browser> browsers = new ArrayList<>();
        for (int i = 0; i < 4; i++) {
            Browser other = new Browser("root-" + i, "198.51.100." + i);
            other.send("nobody@example.com");
            browsers.add(other);
        }

        for (int i = 0; i < 3; i++) {
            assertTrue(browsers.get(i).failureDetails.isEmpty(), "request " + (i + 1) + " is within the budget");
        }
        assertEquals("rate_limited_address", browsers.get(3).lastFailure().get(EmailCodeAuthenticator.EVENT_DETAIL),
                "the same work and the same event as for an account");
        assertTrue(mail.sent.isEmpty());
    }

    @Test
    void anotherSessionCannotGetAroundTheAddressBudget() {
        person("ada", "ada", "ada@example.com");
        Time.setOffset(-(Time.currentTime() % (15 * 60)));
        for (int i = 0; i < 4; i++) {
            new Browser("root-" + i, "198.51.100." + i).send(i % 2 == 0 ? "ada" : "ADA@example.com");
        }
        assertEquals(3, mail.sent.size());
    }

    @Test
    void theOverallBudgetAlarmsAtHalfAndFullButLoginCodesStillGo() {
        authenticator = authenticator(4, null);
        Time.setOffset(-(Time.currentTime() % (24 * 60 * 60)));
        for (int i = 0; i < 5; i++) {
            person("p" + i, "p" + i, "p" + i + "@example.com");
            new Browser("root-" + i, "198.51.100." + i).send("p" + i);
        }

        assertEquals(5, mail.sent.size(), "sign-in codes go on past the overall budget");
        assertEquals(List.of("half/4", "full/4"), mail.alarms);
    }

    @Test
    void codesForNobodyDoNotCountTowardTheOverallBudget() {
        authenticator = authenticator(2, null);
        Time.setOffset(-(Time.currentTime() % (24 * 60 * 60)));
        for (int i = 0; i < 3; i++) {
            new Browser("root-" + i, "198.51.100." + i).send("nobody" + i + "@example.com");
        }
        assertTrue(mail.alarms.isEmpty());
    }

    // Security review K2 (Yusuf, 2026-10-15): at most so many wrong codes per account a day.
    // Past the ceiling the account gets no new code by mail, the page stays as it is (no account
    // is told apart), and no outstanding code is looked at any more.

    /** {@code count} wrong codes for the person, each from a session of its own. */
    private void wrongCodes(String identifier, int count) {
        for (int i = 0; i < count; i++) {
            Browser guesser = new Browser("root-guess-" + identifier + "-" + i, "198.51.100." + (100 + i));
            guesser.send(identifier);
            guesser.verify(other(mail.last().code()));
            assertEquals("wrong_code", guesser.error());
        }
    }

    @Test
    void pastTheDaysCeilingOfWrongCodesTheAccountIsMailedNoCodeAndThePageIsTheSame() {
        authenticator = authenticator(500, null, 2);
        person("ada", "ada", "ada@example.com");
        Time.setOffset(-(Time.currentTime() % (24 * 60 * 60)));
        wrongCodes("ada", 2);
        Browser mailed = new Browser("root-mailed", "198.51.100.1");
        mailed.send("nobody@example.com");
        Map<String, Object> page = new HashMap<>(mailed.page);
        int sent = mail.sent.size();

        browser.send("ADA@example.com");

        assertEquals(sent, mail.sent.size(), "no code is mailed to the account past its ceiling");
        page.put(EmailCodeAuthenticator.IDENTIFIER_ATTRIBUTE, "ADA@example.com");
        assertEquals(page, browser.page, "the page must not tell the account apart");
        assertEquals("wrong_code_ceiling", browser.lastFailure().get(EmailCodeAuthenticator.EVENT_DETAIL));
        browser.verify(other(""));
        assertEquals("wrong_code", browser.error());
        assertEquals("4", browser.shown(EmailCodeAuthenticator.ATTEMPTS_LEFT_ATTRIBUTE));
    }

    @Test
    void pastTheCeilingEvenTheRightCodeOfACodeMailedBeforeNoLongerSignsIn() {
        authenticator = authenticator(500, null, 2);
        UserModel ada = person("ada", "ada", "ada@example.com");
        Time.setOffset(-(Time.currentTime() % (24 * 60 * 60)));
        browser.send("ada");
        String waiting = mail.last().code();
        Browser guesser = new Browser("root-guesser", "198.51.100.2");
        guesser.send("ada");
        guesser.verify(other(mail.last().code()));
        guesser.verify(other(mail.last().code()));

        browser.verify(waiting);

        assertFalse(browser.succeeded, "the ceiling holds for codes mailed before it was reached");
        assertNull(browser.signedIn);
        assertEquals("wrong_code", browser.error(), "answered as any wrong code");
        assertEquals("4", browser.shown(EmailCodeAuthenticator.ATTEMPTS_LEFT_ATTRIBUTE));
        assertEquals("wrong_code_ceiling", browser.lastFailure().get(EmailCodeAuthenticator.EVENT_DETAIL));
        verify(protector, times(3)).failedLogin(eq(realm), eq(ada), any(), any(), isNull());
    }

    @Test
    void theCeilingCountsWrongCodesPerAccountWhicheverIdentifierAndBrowser() {
        authenticator = authenticator(500, null, 3);
        person("ada", "ada", "ada@example.com", IdentityResource.PERSONAL_EMAIL_ATTRIBUTE + "=ada.home@example.org",
                IdentityResource.PERSONAL_EMAIL_VERIFIED_AT_ATTRIBUTE + "=2026-10-01T10:00:00Z");
        person("bea", "bea", "bea@example.com");
        Time.setOffset(-(Time.currentTime() % (24 * 60 * 60)));
        wrongCodes("ada", 1);
        wrongCodes("ada@example.com", 1);
        wrongCodes("bea", 2);
        int sent = mail.sent.size();

        new Browser("root-a", "198.51.100.3").send("ada.home@example.org");
        new Browser("root-b", "198.51.100.4").send("bea");

        assertEquals(sent + 2, mail.sent.size(), "two wrong codes leave both below a ceiling of three");
        // A quarter of an hour later each time, so the address budget never decides here.
        Time.setOffset(Time.getOffset() + 15 * 60);
        wrongCodes("ada.home@example.org", 1);
        Time.setOffset(Time.getOffset() + 15 * 60);
        int before = mail.sent.size();
        new Browser("root-c", "198.51.100.5").send("ada");
        assertEquals(before, mail.sent.size(), "the third wrong code of ada, under any identifier, reached it");
    }

    @Test
    void theCeilingAlarmGoesOnceADayAtTheFirstAccountThatReachesIt() {
        authenticator = authenticator(500, null, 1);
        person("ada", "ada", "ada@example.com");
        person("bea", "bea", "bea@example.com");
        Time.setOffset(-(Time.currentTime() % (24 * 60 * 60)));

        wrongCodes("ada", 1);
        wrongCodes("bea", 1);

        assertEquals(List.of("ceiling/1/1"), mail.alarms, "once a day, with the ceiling and the account count");
        Time.setOffset(Time.getOffset() + 24 * 60 * 60);
        person("cem", "cem", "cem@example.com");
        wrongCodes("cem", 1);
        assertEquals(List.of("ceiling/1/1", "ceiling/1/1"), mail.alarms, "a new day, a new alarm");
    }

    @Test
    void wrongCodesForNobodyReachNoCeilingAndNoAlarm() {
        authenticator = authenticator(500, null, 1);
        Time.setOffset(-(Time.currentTime() % (24 * 60 * 60)));
        for (int i = 0; i < 3; i++) {
            Browser guesser = new Browser("root-n" + i, "198.51.100.1" + i);
            guesser.send("nobody@example.com");
            guesser.verify(other(""));
        }
        assertTrue(mail.alarms.isEmpty());
    }

    // Spec §7.2: the IP is written nowhere; the budget keys are keyed hashes, not addresses or IPs.
    @Test
    void neitherTheStoreNorTheBudgetKeysHoldTheCodeTheAddressOrTheIp() {
        person("ada", "ada", "ada@example.com");
        browser.send("ada@example.com");
        String code = mail.last().code();

        for (String key : store.keys()) {
            assertFalse(key.contains("ada@example.com"), key);
            assertFalse(key.contains("203.0.113"), key);
            assertFalse(key.contains(code), key);
        }
        assertTrue(store.notesHoldNo(code));
        assertNotEquals(0, store.claimedSlots());
    }

    // ------------------------------------------------------------------------------- sign-up

    // Self-registration (eskylab-login-ux 09, ADR-0063 decision 1, CONTEXT "Self-registration"): an
    // e-mail address that names nobody gets a sign-up code while the step's setting is on. The page is
    // the one any address gets; only the right code tells the branches apart.

    /** A sign-up code for {@code address} in a browser of its own, typed right; returns the browser. */
    private Browser provenSignUp(String sessionId, String address) {
        Browser tab = new Browser(sessionId, "198.51.100.40");
        tab.send(address);
        assertEquals("signup", mail.last().purpose(), "a sign-up code was mailed");
        tab.verify(mail.last().code());
        return tab;
    }

    @Test
    void selfRegistrationIsOffUnlessTheStepsSettingIsOn() {
        browser.send("new@example.com");
        assertTrue(mail.sent.isEmpty(), "off: an address that names nobody is mailed nothing");
        assertNull(browser.shown(EmailCodeSignUp.ON_ATTRIBUTE));

        signUpOn = true;
        Browser on = new Browser("root-on", "198.51.100.41");
        on.send("new@example.com");
        assertEquals(new Sent(null, "new@example.com", mail.last().code(), "signup"), mail.last());
        assertEquals("true", on.shown(EmailCodeSignUp.ON_ATTRIBUTE));
    }

    @Test
    void withSignUpOnAnUnknownAddressGetsASignUpCodeAndTheSamePage() {
        signUpOn = true;
        person("ada", "ada", "ada@example.com");
        browser.send("ada@example.com");
        Map<String, Object> known = new HashMap<>(browser.page);

        Browser stranger = new Browser("root-2", "203.0.113.7");
        stranger.send("New.Person@Example.com");
        Map<String, Object> unknown = new HashMap<>(stranger.page);

        assertEquals("login", mail.sent.get(0).purpose());
        assertEquals(new Sent(null, "new.person@example.com", mail.last().code(), "signup"), mail.last(),
                "the sign-up code goes to the typed address, lowercased");
        known.remove(EmailCodeAuthenticator.IDENTIFIER_ATTRIBUTE);
        unknown.remove(EmailCodeAuthenticator.IDENTIFIER_ATTRIBUTE);
        assertEquals(known, unknown, "the code page must not tell whether the account exists");
        assertTrue(stranger.failures.isEmpty(), "asking for a sign-up code is not a failure");
    }

    @Test
    void aUsernameOrSomethingThatIsNoAddressNeverGetsASignUpCode() {
        signUpOn = true;
        for (String typed : List.of("nobody", "nobody@", "@example.com", "no body@example.com")) {
            Browser tab = new Browser("root-" + typed, "198.51.100.42");
            tab.send(typed);
            assertEquals("code", tab.stage(), typed);
        }
        assertTrue(mail.sent.isEmpty());
    }

    @Test
    void theRightSignUpCodeOpensTheFormForTheProvenAddress() {
        signUpOn = true;
        Browser tab = provenSignUp("root-new", "new@example.com");

        assertEquals("form", tab.signUpStage());
        assertEquals("new@example.com", tab.shown(EmailCodeSignUp.ADDRESS_ATTRIBUTE));
        assertFalse(tab.succeeded);
        assertNull(tab.signedIn);
        assertTrue(opened.isEmpty(), "no account before the names");
        assertNull(tab.notes.get(EmailCodeAuthenticator.HANDLE_NOTE), "the code is used up");

        tab.open();
        assertEquals("form", tab.signUpStage(), "a reload shows the form again");
    }

    @Test
    void theNamesOpenTheAccountAndSignItIn() {
        signUpOn = true;
        Browser tab = provenSignUp("root-new", "new.person@example.com");

        tab.signUp("  Ayşe  ", " Yılmaz ");

        assertEquals(List.of(Map.of("username", "new.person", "address", "new.person@example.com",
                "firstName", "Ayşe", "lastName", "Yılmaz")), opened);
        assertTrue(tab.succeeded);
        assertEquals("new-1", tab.signedIn.getId());
        assertEquals("email_code", tab.notes.get(EmailCodeAuthenticator.METHOD_NOTE));
        assertEquals("true", tab.notes.get(EmailCodeSignUp.SIGNED_UP_NOTE), "ticket 10 reads it");
        assertNull(tab.notes.get(EmailCodeSignUp.ADDRESS_NOTE), "the form cannot open a second account");
        Map<String, String> register = tab.lastEvent(EventType.REGISTER);
        assertEquals(Map.of(Details.USERNAME, "new.person", Details.EMAIL, "new.person@example.com",
                Details.REGISTER_METHOD, "email_code", "sky_method", "email_code"), register);
        assertTrue(tab.clonedSucceeded.get(tab.clonedTypes.lastIndexOf(EventType.REGISTER)));
        verify(tab.event).detail("sky_method", "email_code");

        tab.signUp("Ayşe", "Yılmaz");
        assertEquals(1, opened.size(), "posting the form again opens nothing");
    }

    @Test
    void theNamesAreCheckedBeforeAnyAccountIsOpened() {
        signUpOn = true;
        Browser tab = provenSignUp("root-new", "new@example.com");

        tab.signUp("   ", "Yılmaz");
        assertEquals("form", tab.signUpStage());
        assertEquals("first_name_missing", tab.signUpError());
        tab.signUp("Ayşe", "");
        assertEquals("last_name_missing", tab.signUpError());
        tab.signUp("<script>", "Yılmaz");
        assertEquals("first_name_invalid", tab.signUpError());
        assertEquals("<script>", tab.shown(EmailCodeSignUp.FIRST_NAME_ATTRIBUTE), "what was typed comes back");
        tab.signUp("Ayşe", "x".repeat(IdentityResource.MAX_NAME_LENGTH + 1));
        assertEquals("last_name_invalid", tab.signUpError());
        refuseNext = SignUpAccounts.Refused.Reason.LAST_NAME;
        tab.signUp("Ayşe", "Yılmaz");
        assertEquals("last_name_invalid", tab.signUpError(), "the realm's User Profile has the last word");

        assertTrue(opened.isEmpty());
        tab.signUp("Ayşe", "Yılmaz");
        assertEquals(1, opened.size());
    }

    @Test
    void aSchoolAddressIsSentToTheYtuSignInAndOpensNoAccount() {
        signUpOn = true;
        for (String address : List.of("yeni@std.yildiz.edu.tr", "Hoca@YILDIZ.edu.tr", "x@ce.yildiz.edu.tr")) {
            Browser tab = provenSignUp("root-" + address, address);

            assertEquals("ytu", tab.signUpStage(), address);
            assertEquals(YTU, tab.shown(EmailCodeSignUp.YTU_ALIAS_ATTRIBUTE));
            assertEquals("school_domain", tab.lastEvent(EventType.REGISTER).get("sky_email_code"));
            tab.signUp("Ayşe", "Yılmaz");
            assertNotEquals("form", tab.signUpStage(), "the form never opens for a school address");
        }
        assertTrue(opened.isEmpty());
    }

    // Spec §7.4: "Hesap aç" for an address that has an account signs the person in with the code
    // and says so; no second account.
    @Test
    void hesapAcForAnAddressWithAnAccountSignsInAndSaysSo() {
        signUpOn = true;
        UserModel ada = person("ada", "ada", "ada@example.com");
        browser.choose(true);
        assertEquals("sign-up", browser.shown(EmailCodeSignUp.INTENT_ATTRIBUTE));
        browser.send("ada@example.com");
        assertEquals("login", mail.last().purpose(), "the code is a sign-in code to the primary address");
        assertEquals("sign-up", browser.shown(EmailCodeSignUp.INTENT_ATTRIBUTE));

        browser.verify(mail.last().code());
        assertEquals("existing", browser.signUpStage());
        assertFalse(browser.succeeded, "the note comes first");

        browser.open();
        assertEquals("existing", browser.signUpStage(), "a reload shows the note again");
        browser.carryOn();
        assertTrue(browser.succeeded);
        assertEquals(ada, browser.signedIn);
        assertTrue(opened.isEmpty());
        verify(browser.event).detail("sky_email_code", "existing_account");
    }

    @Test
    void withoutHesapAcAnAccountIsSignedInWithoutTheNote() {
        signUpOn = true;
        person("ada", "ada", "ada@example.com");
        browser.choose(true);
        browser.choose(false);
        assertNull(browser.shown(EmailCodeSignUp.INTENT_ATTRIBUTE), "plain 'E-postayla devam et' forgets the intent");
        browser.send("ada");
        browser.verify(mail.last().code());

        assertTrue(browser.succeeded);
        assertNull(browser.signUpStage());
    }

    @Test
    void theIntentIsKeptOnlyWhileSelfRegistrationIsOn() {
        browser.choose(true);
        assertNull(browser.notes.get(EmailCodeSignUp.INTENT_NOTE));
        assertNull(browser.shown(EmailCodeSignUp.INTENT_ATTRIBUTE));
    }

    @Test
    void theExistingNoteChecksThePersonAgainOnContinue() {
        signUpOn = true;
        UserModel ada = person("ada", "ada", "ada@example.com");
        browser.choose(true);
        browser.send("ada");
        browser.verify(mail.last().code());
        assertEquals("existing", browser.signUpStage());

        when(ada.isEnabled()).thenReturn(false);
        browser.carryOn();

        assertFalse(browser.succeeded);
        assertEquals("account_disabled", browser.error());
    }

    // The race (ticket 09): the address got an account meanwhile; the code signs the person in to it.
    @Test
    void anAccountOpenedForTheAddressSinceTheCodeIsSignedInNotDuplicated() {
        signUpOn = true;
        browser.send("new@example.com");
        String code = mail.last().code();
        UserModel meanwhile = person("meanwhile", "meanwhile", "new@example.com");

        browser.verify(code);

        assertEquals("existing", browser.signUpStage());
        browser.carryOn();
        assertEquals(meanwhile, browser.signedIn);
        assertTrue(opened.isEmpty());
    }

    @Test
    void anAccountOpenedForTheAddressWhileTheFormWasOpenIsSignedInNotDuplicated() {
        signUpOn = true;
        Browser tab = provenSignUp("root-new", "new@example.com");
        UserModel meanwhile = person("meanwhile", "meanwhile", "new@example.com");

        tab.signUp("Ayşe", "Yılmaz");

        assertTrue(opened.isEmpty());
        assertEquals("existing", tab.signUpStage());
        tab.carryOn();
        assertEquals(meanwhile, tab.signedIn);
    }

    @Test
    void twoSessionsSigningUpTheSameAddressOpenOneAccount() {
        signUpOn = true;
        Browser first = provenSignUp("root-first", "new@example.com");
        Browser second = provenSignUp("root-second", "new@example.com");

        first.signUp("Ayşe", "Yılmaz");
        second.signUp("Ayşe", "Yılmaz");

        assertEquals(1, opened.size());
        assertTrue(first.succeeded);
        assertEquals("existing", second.signUpStage(), "the second sign-up finds the account the first opened");
        second.carryOn();
        assertEquals(first.signedIn, second.signedIn);
    }

    @Test
    void whileAnotherSignUpOfTheAddressIsStillWritingTheFormSaysTryAgain() {
        signUpOn = true;
        openedVisible = false;
        Browser first = provenSignUp("root-first", "new@example.com");
        Browser second = provenSignUp("root-second", "new@example.com");

        first.signUp("Ayşe", "Yılmaz");
        second.signUp("Ayşe", "Yılmaz");

        assertEquals(1, opened.size(), "one account, whatever the timing");
        assertEquals("form", second.signUpStage());
        assertEquals("try_again", second.signUpError());
    }

    @Test
    void anAddressHeldByAnAccountThatDoesNotSignInWithItOpensNothing() {
        signUpOn = true;
        // An unproven Personal e-mail: not a sign-in identifier, still nobody else's to open.
        person("x", "x", "x@example.com", IdentityResource.PERSONAL_EMAIL_ATTRIBUTE + "=held@example.com");
        Browser tab = provenSignUp("root-held", "held@example.com");

        assertEquals("unavailable", tab.signUpStage());
        assertEquals("sign_up_taken", tab.lastEvent(EventType.REGISTER).get("sky_email_code"));
        tab.signUp("Ayşe", "Yılmaz");
        assertTrue(opened.isEmpty());
    }

    @Test
    void aSignUpCodeOpensNothingWhenSelfRegistrationWentOffMeanwhile() {
        signUpOn = true;
        browser.send("new@example.com");
        signUpOn = false;

        browser.verify(mail.last().code());

        assertEquals("unavailable", browser.signUpStage());
        assertEquals("sign_up_off", browser.lastEvent(EventType.REGISTER).get("sky_email_code"));
        assertTrue(opened.isEmpty());
    }

    @Test
    void theFormNeedsAnAddressProvenInThisSessionRecently() {
        signUpOn = true;
        browser.signUp("Ayşe", "Yılmaz");
        assertTrue(opened.isEmpty());
        assertEquals("identifier", browser.stage());

        Browser tab = provenSignUp("root-new", "new@example.com");
        Time.setOffset(EmailCodeSignUp.PROOF_SECONDS + 1);
        tab.signUp("Ayşe", "Yılmaz");
        assertTrue(opened.isEmpty(), "the proof does not outlive half an hour");
    }

    @Test
    void anotherAddressFromTheSignUpPageStartsAgain() {
        signUpOn = true;
        Browser tab = provenSignUp("root-new", "new@example.com");

        tab.post(EmailCodeAuthenticator.CHANGE, null, null);

        assertEquals("identifier", tab.stage());
        assertNull(tab.notes.get(EmailCodeSignUp.ADDRESS_NOTE));
        tab.signUp("Ayşe", "Yılmaz");
        assertTrue(opened.isEmpty());
    }

    @Test
    void aUsernameTakenBetweenTheChoiceAndTheWriteMovesToTheNextName() {
        signUpOn = true;
        Browser tab = provenSignUp("root-new", "ada@example.com");
        refuseNext = SignUpAccounts.Refused.Reason.USERNAME_TAKEN;

        tab.signUp("Ayşe", "Yılmaz");

        assertEquals("ada2", opened.get(0).get("username"));
        assertTrue(tab.succeeded);
    }

    @Test
    void anExistingUsernameIsNeverReusedForTheNewAccount() {
        signUpOn = true;
        person("ada", "ada", "someone@example.com");
        Browser tab = provenSignUp("root-new", "ada@example.org");

        tab.signUp("Ayşe", "Yılmaz");

        assertEquals("ada2", opened.get(0).get("username"));
    }

    // Spec §7.2: at the overall daily budget sign-up codes stop; sign-in codes go on.
    @Test
    void signUpCodesStopAtTheOverallBudgetButSignInCodesGoOn() {
        signUpOn = true;
        authenticator = authenticator(2, null);
        Time.setOffset(-(Time.currentTime() % (24 * 60 * 60)));
        new Browser("root-a", "198.51.100.50").send("first@example.com");
        new Browser("root-b", "198.51.100.51").send("second@example.com");
        assertEquals(2, mail.sent.size());

        Browser third = new Browser("root-c", "198.51.100.52");
        third.send("third@example.com");
        assertEquals(2, mail.sent.size(), "no sign-up code past the budget");
        assertEquals("code", third.stage());
        assertEquals("sign_up_paused", third.lastEvent(EventType.REGISTER).get("sky_email_code"));

        person("ada", "ada", "ada@example.com");
        new Browser("root-d", "198.51.100.53").send("ada");
        assertEquals(3, mail.sent.size(), "a sign-in code still goes");
    }

    @Test
    void wrongSignUpCodesReachTheCeilingOfTheirAddress() {
        signUpOn = true;
        authenticator = authenticator(500, null, 2);
        Time.setOffset(-(Time.currentTime() % (24 * 60 * 60)));
        Browser waiting = new Browser("root-waiting", "198.51.100.60");
        waiting.send("new@example.com");
        String mailed = mail.last().code();
        for (int i = 0; i < 2; i++) {
            Browser guesser = new Browser("root-g" + i, "198.51.100.6" + (i + 1));
            guesser.send("new@example.com");
            guesser.verify(other(mail.last().code()));
            assertEquals("wrong_code", guesser.error());
        }
        int sent = mail.sent.size();

        waiting.verify(mailed);
        assertEquals("wrong_code", waiting.error(), "a code mailed before is not looked at");
        // A quarter of an hour later, so the address budget does not decide.
        Time.setOffset(Time.getOffset() + 15 * 60);
        Browser after = new Browser("root-after", "198.51.100.70");
        after.send("new@example.com");
        assertEquals(sent, mail.sent.size(), "no sign-up code to the address past its ceiling");
        assertEquals("wrong_code_ceiling", after.lastEvent(EventType.REGISTER).get("sky_email_code"));
        assertTrue(opened.isEmpty());
        assertTrue(mail.alarms.isEmpty(), "no account at stake, no operator alarm");
        verify(protector, never()).failedLogin(any(), any(), any(), any(), any());
    }

    @Test
    void aWrongSignUpCodeCostsATryLikeAnyOther() {
        signUpOn = true;
        browser.send("new@example.com");
        String code = mail.last().code();

        browser.verify(other(code));
        assertEquals("wrong_code", browser.error());
        assertEquals("4", browser.shown(EmailCodeAuthenticator.ATTEMPTS_LEFT_ATTRIBUTE));
        browser.verify(code);
        assertEquals("form", browser.signUpStage());
    }

    @Test
    void anAddressThatNamesTwoPeopleOrADisabledAccountGetsNoSignUpCode() {
        signUpOn = true;
        person("one", "one", "shared@example.com");
        person("two", "shared@example.com", "two@example.com");
        UserModel disabled = person("off", "off", "off@example.com");
        when(disabled.isEnabled()).thenReturn(false);

        for (String typed : List.of("shared@example.com", "off@example.com")) {
            Browser tab = new Browser("root-" + typed, "198.51.100.43");
            tab.send(typed);
            assertEquals("code", tab.stage(), typed);
        }
        assertTrue(mail.sent.isEmpty(), "an address that names somebody is never signed up");
    }

    // Nobody is signed in by an address that is not where their codes go (spec S4): an address that
    // became somebody's proven Personal e-mail in the ten minutes, while their Primary is another,
    // opens nothing and signs nobody in.
    @Test
    void anAddressThatBecameSomebodysSecondAddressMeanwhileSignsNobodyIn() {
        signUpOn = true;
        browser.send("new@example.com");
        String code = mail.last().code();
        person("ada", "ada", "ada@example.com", IdentityResource.PERSONAL_EMAIL_ATTRIBUTE + "=new@example.com",
                IdentityResource.PERSONAL_EMAIL_VERIFIED_AT_ATTRIBUTE + "=2026-10-15T10:00:00Z");

        browser.verify(code);

        assertEquals("unavailable", browser.signUpStage());
        assertFalse(browser.succeeded);
        browser.carryOn();
        assertFalse(browser.succeeded, "there is no existing stage to continue from");
        assertTrue(opened.isEmpty());
    }

    // Spec §7.5: the sign-up's refusals name neither the IP nor the address.
    @Test
    void signUpRefusalsCarryNeitherTheIpNorTheAddress() {
        signUpOn = true;
        Browser tab = provenSignUp("root-ytu", "yeni@std.yildiz.edu.tr");

        int index = tab.clonedTypes.lastIndexOf(EventType.REGISTER);
        EventBuilder refusal = tab.failures.get(index);
        verify(refusal).ipAddress(null);
        verify(refusal).removeDetail(Details.USERNAME);
        verify(refusal).error(org.keycloak.events.Errors.INVALID_REGISTRATION);
        assertFalse(tab.failureDetails.get(index).containsValue("yeni@std.yildiz.edu.tr"));
    }

    @Test
    void theFourthSignUpCodeToOneAddressInAQuarterHourIsNotMailed() {
        signUpOn = true;
        Time.setOffset(-(Time.currentTime() % (15 * 60)));
        for (int i = 0; i < 4; i++) {
            Browser tab = new Browser("root-q" + i, "198.51.100.8" + i);
            tab.send("new@example.com");
            assertEquals("code", tab.stage());
        }
        assertEquals(3, mail.sent.size(), "the address budget holds for sign-up codes too");
    }

    // ADR-0044's rule for a sign-up code too: it works only in the sign-in session that asked for it.
    @Test
    void aSignUpCodeDoesNotWorkInAnotherBrowser() {
        signUpOn = true;
        browser.send("new@example.com");
        String code = mail.last().code();
        Browser other = new Browser("root-other", "198.51.100.90");
        other.send("other@example.com");

        other.verify(code);

        assertEquals("wrong_code", other.error());
        assertNull(other.signUpStage());
        browser.verify(code);
        assertEquals("form", browser.signUpStage(), "the other browser's try cost this one nothing");
    }

    @Test
    void theStoreHoldsNeitherTheSignUpCodeNorTheAddressInAnyKey() {
        signUpOn = true;
        Browser tab = provenSignUp("root-new", "new@example.com");
        tab.signUp("Ayşe", "Yılmaz");

        for (String key : store.keys()) {
            assertFalse(key.contains("new@example.com"), key);
        }
    }

    // ------------------------------------------------------------------------------- helpers

    /** An eight-digit code that is certainly not {@code code}. */
    private static String other(String code) {
        return code.equals("00000000") ? "00000001" : "00000000";
    }

    /** Keycloak's single-use store: atomic remove and putIfAbsent, lifespans ignored (Time drives expiry). */
    private static final class MemoryStore implements SingleUseObjectProvider {
        private final ConcurrentHashMap<String, Map<String, String>> entries = new ConcurrentHashMap<>();

        List<String> keys() {
            return new ArrayList<>(entries.keySet());
        }

        void clear() {
            entries.clear();
        }

        long claimedSlots() {
            return entries.keySet().stream().filter(key -> key.startsWith("sky-account:rate:")).count();
        }

        boolean notesHoldNo(String code) {
            return entries.values().stream().flatMap(notes -> notes.values().stream()).noneMatch(value -> value.contains(code));
        }

        @Override
        public void put(String key, long lifespanSeconds, Map<String, String> notes) {
            entries.put(key, Map.copyOf(notes));
        }

        @Override
        public Map<String, String> get(String key) {
            return entries.get(key);
        }

        @Override
        public Map<String, String> remove(String key) {
            return entries.remove(key);
        }

        @Override
        public boolean replace(String key, Map<String, String> notes) {
            throw new UnsupportedOperationException();
        }

        @Override
        public boolean putIfAbsent(String key, long lifespanInSeconds) {
            return entries.putIfAbsent(key, Map.of()) == null;
        }

        @Override
        public boolean contains(String key) {
            return entries.containsKey(key);
        }

        @Override
        public void close() {
            // no-op
        }
    }
}
