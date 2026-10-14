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

    private EmailCodeAuthenticator authenticator = authenticator(500, null);

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
        public void alarm(AuthenticationFlowContext context, String level, int dailyLimit) {
            alarms.add(level + "/" + dailyLimit);
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
            when(form.createForm(EmailCodeAuthenticator.TEMPLATE)).thenReturn(mock(Response.class));
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
                when(failure.detail(anyString(), anyString())).thenAnswer(detail -> {
                    details.put(detail.getArgument(0), detail.getArgument(1));
                    return failure;
                });
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
        return new EmailCodeAuthenticator(new EmailCodeSettings(YTU, dailyLimit, null), mail, webauthn);
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

        browser.verify(code.substring(0, 3) + " " + code.substring(3));

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

        browser.verify("12a4");

        assertEquals("code", browser.stage());
        assertEquals("malformed_code", browser.error());
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

    @Test
    void aGuessedCodeForNobodySignsNobodyIn() {
        browser.send("nobody@example.com");
        String handle = browser.notes.get(EmailCodeAuthenticator.HANDLE_NOTE);
        // Nobody can read the code that was never mailed; put a known one in its place.
        String known = new LoginCodes(store).issue(handle, "", "");

        browser.verify(known);

        assertFalse(browser.succeeded);
        assertEquals("identifier", browser.stage());
        assertEquals("no_account", browser.error());
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
    void theFourthCodeToOneAddressInAQuarterHourIsNotMailedAndTheThirdStillWorks() {
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
        assertTrue(browser.succeeded, "the code already mailed must keep working");
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

    // ------------------------------------------------------------------------------- helpers

    /** A six-digit code that is certainly not {@code code}. */
    private static String other(String code) {
        return code.equals("000000") ? "000001" : "000000";
    }

    /** Keycloak's single-use store: atomic remove and putIfAbsent, lifespans ignored (Time drives expiry). */
    private static final class MemoryStore implements SingleUseObjectProvider {
        private final ConcurrentHashMap<String, Map<String, String>> entries = new ConcurrentHashMap<>();

        List<String> keys() {
            return new ArrayList<>(entries.keySet());
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
