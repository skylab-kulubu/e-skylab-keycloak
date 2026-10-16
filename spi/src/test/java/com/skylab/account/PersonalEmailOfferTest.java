package com.skylab.account;

import jakarta.ws.rs.core.MultivaluedHashMap;
import jakarta.ws.rs.core.Response;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.keycloak.authentication.RequiredActionContext;
import org.keycloak.broker.provider.AbstractIdentityProvider;
import org.keycloak.common.ClientConnection;
import org.keycloak.common.util.Time;
import org.keycloak.email.EmailException;
import org.keycloak.email.EmailTemplateProvider;
import org.keycloak.events.EventBuilder;
import org.keycloak.forms.login.LoginFormsProvider;
import org.keycloak.http.HttpRequest;
import org.keycloak.models.KeycloakContext;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.RequiredActionProviderModel;
import org.keycloak.models.SingleUseObjectProvider;
import org.keycloak.models.UserModel;
import org.keycloak.models.UserProvider;
import org.keycloak.sessions.AuthenticationSessionModel;
import org.keycloak.sessions.RootAuthenticationSessionModel;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyBoolean;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyList;
import static org.mockito.ArgumentMatchers.anyMap;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.RETURNS_SELF;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * The first-login Personal e-mail offer (eskylab-login-ux 21) against mocked Keycloak models, an
 * in-memory single-use store and a mail provider that keeps the codes it was handed.
 */
class PersonalEmailOfferTest {

    private static final String SCHOOL = "yeni.ogrenci@std.yildiz.edu.tr";

    private final PersonalEmailOffer offer = new PersonalEmailOffer();
    private final MemoryStore store = new MemoryStore();
    private final KeycloakSession session = mock(KeycloakSession.class);
    private final RealmModel realm = mock(RealmModel.class);
    private final UserProvider users = mock(UserProvider.class);
    private final EmailTemplateProvider mail = mock(EmailTemplateProvider.class, RETURNS_SELF);
    private final List<String[]> mailed = new ArrayList<>();
    /** Lowercased address to the attribute another person holds it in. */
    private final Map<String, String> otherHolders = new HashMap<>();
    private final Map<String, UserModel> emailHolders = new HashMap<>();
    private final Map<String, UserModel> usernameHolders = new HashMap<>();

    private Browser browser;

    /** One sign-in session (browser tab) of the new account, at one remote address. */
    private final class Browser {
        final RequiredActionContext context = mock(RequiredActionContext.class);
        final AuthenticationSessionModel authSession = mock(AuthenticationSessionModel.class);
        final Map<String, String> notes = new HashMap<>();
        final List<String> requiredActions = new ArrayList<>();
        final Map<String, String> attributes = new HashMap<>();
        final UserModel user = mock(UserModel.class);
        final EventBuilder event = mock(EventBuilder.class, RETURNS_SELF);
        final LoginFormsProvider form = mock(LoginFormsProvider.class, RETURNS_SELF);
        Map<String, Object> page = new HashMap<>();
        final MultivaluedHashMap<String, String> posted = new MultivaluedHashMap<>();

        Browser(String sessionId, String remote) {
            when(context.getSession()).thenReturn(session);
            when(context.getRealm()).thenReturn(realm);
            when(context.getUser()).thenReturn(user);
            when(context.getAuthenticationSession()).thenReturn(authSession);
            when(context.getEvent()).thenReturn(event);
            when(context.form()).thenAnswer(call -> {
                page = new HashMap<>();
                return form;
            });
            when(form.setAttribute(anyString(), any())).thenAnswer(call -> {
                page.put(call.getArgument(0), call.getArgument(1));
                return form;
            });
            when(form.createForm(PersonalEmailOffer.TEMPLATE)).thenReturn(mock(Response.class));
            HttpRequest request = mock(HttpRequest.class);
            when(context.getHttpRequest()).thenReturn(request);
            when(request.getDecodedFormParameters()).thenReturn(posted);
            ClientConnection connection = mock(ClientConnection.class);
            when(connection.getRemoteAddr()).thenReturn(remote);
            when(context.getConnection()).thenReturn(connection);

            RootAuthenticationSessionModel root = mock(RootAuthenticationSessionModel.class);
            when(root.getId()).thenReturn(sessionId);
            when(authSession.getParentSession()).thenReturn(root);
            when(authSession.getTabId()).thenReturn("tab");
            when(authSession.getAuthNote(anyString())).thenAnswer(call -> notes.get(call.<String>getArgument(0)));
            doAnswer(call -> notes.put(call.getArgument(0), call.getArgument(1)))
                    .when(authSession).setAuthNote(anyString(), anyString());
            doAnswer(call -> notes.remove(call.<String>getArgument(0)))
                    .when(authSession).removeAuthNote(anyString());
            doAnswer(call -> requiredActions.add(call.getArgument(0)))
                    .when(authSession).addRequiredAction(anyString());

            when(user.getId()).thenReturn("new-user");
            when(user.getEmail()).thenReturn(SCHOOL);
            when(user.isEmailVerified()).thenReturn(true);
            when(user.getFirstAttribute(anyString())).thenAnswer(call -> attributes.get(call.<String>getArgument(0)));
            doAnswer(call -> attributes.put(call.getArgument(0), call.getArgument(1)))
                    .when(user).setSingleAttribute(anyString(), anyString());
            attributes.put(IdentityResource.SCHOOL_EMAIL_ATTRIBUTE, "Yeni.Ogrenci@STD.Yildiz.edu.tr");

            // What sky-ytu-first-login and IdpCreateUserIfUniqueAuthenticator leave on the session.
            notes.put(AbstractIdentityProvider.BROKER_REGISTERED_NEW_USER, "true");
            PersonalEmailOffer.schedule(realm, authSession, SCHOOL);
        }

        void challenge() {
            offer.requiredActionChallenge(context);
        }

        void post(String action, String name, String value) {
            posted.clear();
            posted.putSingle(PersonalEmailOffer.ACTION_PARAM, action);
            if (name != null) {
                posted.putSingle(name, value);
            }
            offer.processAction(context);
        }

        void send(String address) {
            post(PersonalEmailOffer.SEND, PersonalEmailOffer.ADDRESS_PARAM, address);
        }

        void verify(String code) {
            post(PersonalEmailOffer.VERIFY, PersonalEmailOffer.CODE_PARAM, code);
        }

        Object shown(String attribute) {
            return page.get(attribute);
        }
    }

    @BeforeEach
    void setUp() throws EmailException {
        KeycloakContext keycloakContext = mock(KeycloakContext.class);
        when(session.getContext()).thenReturn(keycloakContext);
        when(keycloakContext.getRealm()).thenReturn(realm);
        when(realm.getSmtpConfig()).thenReturn(Map.of());
        when(realm.getId()).thenReturn("realm-id");
        EmailAddressOwnershipTest.mockDatabase(session, realm);
        RequiredActionProviderModel model = new RequiredActionProviderModel();
        model.setAlias(PersonalEmailOffer.PROVIDER_ID);
        model.setProviderId(PersonalEmailOffer.PROVIDER_ID);
        model.setEnabled(true);
        when(realm.getRequiredActionProviderByAlias(PersonalEmailOffer.PROVIDER_ID)).thenReturn(model);
        when(session.singleUseObjects()).thenReturn(store);
        when(session.users()).thenReturn(users);
        when(session.getProvider(EmailTemplateProvider.class)).thenReturn(mail);
        doAnswer(call -> {
            Map<String, Object> attributes = call.getArgument(3);
            mailed.add(new String[] {call.getArgument(4), (String) attributes.get("code")});
            return null;
        }).when(mail).send(anyString(), anyList(), anyString(), anyMap(), anyString());
        when(users.getUserByEmail(eq(realm), anyString()))
                .thenAnswer(call -> emailHolders.get(call.<String>getArgument(1).toLowerCase()));
        when(users.getUserByUsername(eq(realm), anyString()))
                .thenAnswer(call -> usernameHolders.get(call.<String>getArgument(1).toLowerCase()));
        when(users.searchForUserStream(eq(realm), anyMap(), anyInt(), anyInt())).thenAnswer(call -> {
            Map<String, String> query = call.getArgument(1);
            return otherHolders.entrySet().stream()
                    .filter(entry -> entry.getKey().equalsIgnoreCase(query.get(entry.getValue())))
                    .map(entry -> {
                        UserModel other = mock(UserModel.class);
                        when(other.getId()).thenReturn("someone-else");
                        return other;
                    });
        });
        browser = new Browser("root-1", "203.0.113.7");
    }

    @AfterEach
    void resetClock() {
        Time.setOffset(0);
    }

    private String lastCodeTo(String address) {
        for (int index = mailed.size() - 1; index >= 0; index--) {
            if (mailed.get(index)[0].equals(address)) {
                return mailed.get(index)[1];
            }
        }
        return null;
    }

    private static String otherCode(String code) {
        return String.format("%06d", (Integer.parseInt(code) + 1) % 1_000_000);
    }

    // ------------------------------------------------------------------ scheduling

    @Test
    void scheduledOnlyWhenTheRealmHasTheActionEnabled() {
        assertEquals(List.of(PersonalEmailOffer.PROVIDER_ID), browser.requiredActions);
        assertEquals(SCHOOL, browser.notes.get(PersonalEmailOffer.SCHEDULED_NOTE));

        AuthenticationSessionModel other = mock(AuthenticationSessionModel.class);
        RequiredActionProviderModel disabled = new RequiredActionProviderModel();
        disabled.setEnabled(false);
        when(realm.getRequiredActionProviderByAlias(PersonalEmailOffer.PROVIDER_ID)).thenReturn(disabled);
        PersonalEmailOffer.schedule(realm, other, SCHOOL);
        when(realm.getRequiredActionProviderByAlias(PersonalEmailOffer.PROVIDER_ID)).thenReturn(null);
        PersonalEmailOffer.schedule(realm, other, SCHOOL);
        verify(other, never()).addRequiredAction(anyString());
        verify(other, never()).setAuthNote(anyString(), anyString());
    }

    @Test
    void dueOnlyForTheAccountThisSessionOpenedWithTheSchoolPrimaryAndNoPersonalEmail() {
        assertTrue(PersonalEmailOffer.due(browser.authSession, browser.user));

        browser.notes.remove(AbstractIdentityProvider.BROKER_REGISTERED_NEW_USER);
        assertFalse(PersonalEmailOffer.due(browser.authSession, browser.user), "a linked account");
        browser.notes.put(AbstractIdentityProvider.BROKER_REGISTERED_NEW_USER, "true");

        when(browser.user.getEmail()).thenReturn("someone@example.org");
        assertFalse(PersonalEmailOffer.due(browser.authSession, browser.user), "another primary");
        when(browser.user.getEmail()).thenReturn(SCHOOL);

        when(browser.user.isEmailVerified()).thenReturn(false);
        assertFalse(PersonalEmailOffer.due(browser.authSession, browser.user), "an unverified primary");
        when(browser.user.isEmailVerified()).thenReturn(true);

        browser.attributes.put(PersonalEmailProof.ADDRESS_ATTRIBUTE, "ada@example.com");
        assertFalse(PersonalEmailOffer.due(browser.authSession, browser.user), "already a personal e-mail");
        browser.attributes.remove(PersonalEmailProof.ADDRESS_ATTRIBUTE);

        browser.attributes.put(PersonalEmailOffer.SKIPPED_AT_ATTRIBUTE, "2026-10-11T12:00:00Z");
        assertFalse(PersonalEmailOffer.due(browser.authSession, browser.user), "skipped before");
        browser.attributes.remove(PersonalEmailOffer.SKIPPED_AT_ATTRIBUTE);

        browser.notes.remove(PersonalEmailOffer.SCHEDULED_NOTE);
        assertFalse(PersonalEmailOffer.due(browser.authSession, browser.user), "never scheduled");
        assertFalse(PersonalEmailOffer.due(browser.authSession, null));
    }

    @Test
    void aSessionThatIsNotDueGoesOnWithoutAPage() {
        browser.notes.remove(AbstractIdentityProvider.BROKER_REGISTERED_NEW_USER);

        browser.challenge();

        verify(browser.context).success();
        verify(browser.context, never()).challenge(any());
        assertNull(browser.notes.get(PersonalEmailOffer.SCHEDULED_NOTE));
    }

    // ------------------------------------------------------------------ the page and the skip

    @Test
    void theAddressPageIsShownAndCountedOnce() {
        browser.challenge();
        browser.challenge();

        verify(browser.context, times(2)).challenge(any());
        assertEquals("address", browser.shown(PersonalEmailOffer.STAGE_ATTRIBUTE));
        assertEquals("10", browser.shown(PersonalEmailOffer.CODE_MINUTES_ATTRIBUTE));
        verify(browser.event, times(1)).detail(PersonalEmailOffer.EVENT_DETAIL, "shown");
    }

    @Test
    void skipIsRememberedAndTheLoginGoesOn() {
        browser.challenge();
        browser.post(PersonalEmailOffer.SKIP, null, null);

        verify(browser.context).success();
        assertNotNull(browser.attributes.get(PersonalEmailOffer.SKIPPED_AT_ATTRIBUTE));
        assertTrue(browser.attributes.get(PersonalEmailOffer.SKIPPED_AT_ATTRIBUTE)
                .matches("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"));
        verify(browser.event).detail(PersonalEmailOffer.EVENT_DETAIL, PersonalEmailOffer.SKIP);
        assertNull(browser.attributes.get(PersonalEmailProof.ADDRESS_ATTRIBUTE));
        assertFalse(PersonalEmailOffer.due(browser.authSession, browser.user), "never again");
    }

    // ------------------------------------------------------------------ sending

    @Test
    void anAddressThatIsNotAnAddressOrIsTheirOwnIsRefusedWithoutSpendingABudget() {
        browser.send("not an address");
        assertEquals("invalid_address", browser.shown(PersonalEmailOffer.ERROR_ATTRIBUTE));
        browser.send("  ");
        assertEquals("invalid_address", browser.shown(PersonalEmailOffer.ERROR_ATTRIBUTE));
        browser.send("Yeni.Ogrenci@STD.yildiz.edu.tr");
        assertEquals("own_address", browser.shown(PersonalEmailOffer.ERROR_ATTRIBUTE));

        assertTrue(mailed.isEmpty());
        assertEquals(0, store.claimedSlots(), "no budget may be spent on a typo");
    }

    @Test
    void anAddressAnotherAccountUsesIsRefusedAfterTheBudgetsAreCharged() {
        otherHolders.put("Taken.Personal@Example.org", IdentityResource.PERSONAL_EMAIL_ATTRIBUTE);
        UserModel holder = mock(UserModel.class);
        when(holder.getId()).thenReturn("holder");
        emailHolders.put("taken.primary@example.org", holder);
        usernameHolders.put("taken.username@example.org", holder);

        for (String address : List.of("taken.personal@example.org", "taken.primary@example.org", "Taken.Username@example.org")) {
            browser.send(address);
            assertEquals("email_taken", browser.shown(PersonalEmailOffer.ERROR_ATTRIBUTE), address);
            assertEquals("address", browser.shown(PersonalEmailOffer.STAGE_ATTRIBUTE));
        }
        assertTrue(mailed.isEmpty(), "nothing is mailed to a taken address");
        assertEquals(12, store.claimedSlots(), "each probe costs one slot of every budget");
        assertNull(browser.notes.get(PersonalEmailOffer.HANDLE_NOTE));
    }

    @Test
    void aUniversityAddressIsNeverAPersonalEmailAndCostsNoBudget() {
        for (String address : List.of("someone@std.yildiz.edu.tr", "Someone@CE.Yildiz.EDU.tr", "someone@yildiz.edu.tr",
                "someone@yildiz\u3002edu\u3002tr", "someone@yil\u00ADdiz.edu.tr")) {
            browser.send(address);
            assertEquals("email_school_domain", browser.shown(PersonalEmailOffer.ERROR_ATTRIBUTE), address);
            assertEquals("address", browser.shown(PersonalEmailOffer.STAGE_ATTRIBUTE));
        }
        assertTrue(mailed.isEmpty());
        assertEquals(0, store.claimedSlots(), "the domain rule says nothing about other accounts");

        browser.send("someone@notyildiz.edu.tr");
        assertEquals("code", browser.shown(PersonalEmailOffer.STAGE_ATTRIBUTE));
    }

    @Test
    void budgetKeysArePerRealmAndKeyedWithTheRealmsHmacKeyWhenThereIsOne() {
        RealmModel sandbox = mock(RealmModel.class);
        when(sandbox.getId()).thenReturn("sandbox-id");
        String production = BudgetKeys.keyed(session, realm, "ip-class:v4:203.0.113");
        assertTrue(production.startsWith("s"), "without an HMAC key the key is a SHA-256");
        assertNotEquals(production, BudgetKeys.keyed(session, sandbox, "ip-class:v4:203.0.113"));

        org.keycloak.models.KeyManager keys = mock(org.keycloak.models.KeyManager.class);
        org.keycloak.crypto.KeyWrapper hmac = new org.keycloak.crypto.KeyWrapper();
        hmac.setSecretKey(new javax.crypto.spec.SecretKeySpec(new byte[64], "HmacSHA512"));
        when(session.keys()).thenReturn(keys);
        when(keys.getActiveKey(realm, org.keycloak.crypto.KeyUse.SIG, org.keycloak.crypto.Algorithm.HS512)).thenReturn(hmac);
        String keyed = BudgetKeys.keyed(session, realm, "ip-class:v4:203.0.113");
        assertTrue(keyed.startsWith("h"), "with the realm's HMAC key the key is an HMAC");
        assertNotEquals(production, keyed);
        assertEquals(keyed, BudgetKeys.keyed(session, realm, "ip-class:v4:203.0.113"));
    }

    @Test
    void aFreeAddressGetsASixDigitCodeAndTheCodePage() {
        browser.challenge();
        browser.send("  Ada.Lovelace@Example.org ");

        String code = lastCodeTo("ada.lovelace@example.org");
        assertNotNull(code);
        assertTrue(code.matches("^[0-9]{6}$"));
        assertEquals("code", browser.shown(PersonalEmailOffer.STAGE_ATTRIBUTE));
        assertEquals("ada.lovelace@example.org", browser.shown(PersonalEmailOffer.ADDRESS_ATTRIBUTE));
        assertNull(browser.shown(PersonalEmailOffer.ERROR_ATTRIBUTE));
        String handle = browser.notes.get(PersonalEmailOffer.HANDLE_NOTE);
        assertNotNull(handle);
        assertTrue(store.notesHoldNo(code), "the store holds only a salted hash of the code");
        assertFalse(store.keys().stream().anyMatch(key -> key.contains("new-user") || key.contains("ada")),
                "store keys carry neither the user nor the address");
        verify(browser.event).detail(PersonalEmailOffer.EVENT_DETAIL, "code_sent");

        // A reload shows the code page again instead of spending another code.
        browser.challenge();
        assertEquals("code", browser.shown(PersonalEmailOffer.STAGE_ATTRIBUTE));
        assertEquals(1, mailed.size());
    }

    @Test
    void aMailThatCannotBeSentLeavesNoCode() throws EmailException {
        doThrow(new EmailException("smtp down")).when(mail).send(anyString(), anyList(), anyString(), anyMap(), anyString());

        browser.send("ada@example.org");

        assertEquals("email_not_sent", browser.shown(PersonalEmailOffer.ERROR_ATTRIBUTE));
        assertEquals("address", browser.shown(PersonalEmailOffer.STAGE_ATTRIBUTE));
        assertNull(browser.notes.get(PersonalEmailOffer.HANDLE_NOTE));
        assertTrue(store.pendingCodes().isEmpty());
    }

    // ------------------------------------------------------------------ the code

    @Test
    void theRightCodeProvesThePersonalEmailKeepsTheSchoolPrimaryAndTheLoginGoesOn() {
        browser.send("ada@example.org");
        browser.verify(" " + lastCodeTo("ada@example.org").substring(0, 3) + " " + lastCodeTo("ada@example.org").substring(3));

        verify(browser.context).success();
        assertEquals("ada@example.org", browser.attributes.get(PersonalEmailProof.ADDRESS_ATTRIBUTE));
        assertTrue(browser.attributes.get(PersonalEmailProof.VERIFIED_AT_ATTRIBUTE)
                .matches("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"));
        verify(browser.user, never()).setEmail(anyString());
        verify(browser.user, never()).setEmailVerified(anyBoolean());
        assertNull(browser.attributes.get(PersonalEmailOffer.SKIPPED_AT_ATTRIBUTE));
        verify(browser.event).detail(PersonalEmailOffer.EVENT_DETAIL, "added");
        assertTrue(store.pendingCodes().isEmpty(), "the code is single use");
        assertNull(browser.notes.get(PersonalEmailOffer.HANDLE_NOTE));
    }

    @Test
    void fiveWrongCodesKillTheCodeAndTheRightOneNoLongerWorks() {
        browser.send("ada@example.org");
        String code = lastCodeTo("ada@example.org");

        for (int left = 4; left >= 1; left--) {
            browser.verify(otherCode(code));
            assertEquals("wrong_code", browser.shown(PersonalEmailOffer.ERROR_ATTRIBUTE));
            assertEquals(Integer.toString(left), browser.shown(PersonalEmailOffer.ATTEMPTS_LEFT_ATTRIBUTE));
            assertEquals("code", browser.shown(PersonalEmailOffer.STAGE_ATTRIBUTE));
        }
        browser.verify(otherCode(code));
        assertEquals("too_many_tries", browser.shown(PersonalEmailOffer.ERROR_ATTRIBUTE));
        assertEquals("address", browser.shown(PersonalEmailOffer.STAGE_ATTRIBUTE));

        browser.verify(code);
        assertEquals("code_expired", browser.shown(PersonalEmailOffer.ERROR_ATTRIBUTE));
        assertNull(browser.attributes.get(PersonalEmailProof.ADDRESS_ATTRIBUTE));
        verify(browser.context, never()).success();
        verify(browser.event, times(5)).detail(PersonalEmailOffer.EVENT_DETAIL, "wrong_code");
    }

    @Test
    void aMalformedCodeDoesNotCostATry() {
        browser.send("ada@example.org");
        browser.verify("12345");
        assertEquals("malformed_code", browser.shown(PersonalEmailOffer.ERROR_ATTRIBUTE));
        browser.verify("abcdef");
        browser.verify(otherCode(lastCodeTo("ada@example.org")));
        assertEquals("4", browser.shown(PersonalEmailOffer.ATTEMPTS_LEFT_ATTRIBUTE));
    }

    @Test
    void aCodeOlderThanTenMinutesIsDead() {
        browser.send("ada@example.org");
        String code = lastCodeTo("ada@example.org");

        Time.setOffset(PendingEmailChanges.TTL_SECONDS + 1);
        browser.verify(code);

        assertEquals("code_expired", browser.shown(PersonalEmailOffer.ERROR_ATTRIBUTE));
        assertEquals("address", browser.shown(PersonalEmailOffer.STAGE_ATTRIBUTE));
        assertNull(browser.attributes.get(PersonalEmailProof.ADDRESS_ATTRIBUTE));
    }

    @Test
    void aCodeOnlyWorksInTheSignInSessionThatAskedForIt() {
        browser.send("ada@example.org");
        String code = lastCodeTo("ada@example.org");
        Browser other = new Browser("root-2", "198.51.100.9");

        other.verify(code);

        assertEquals("code_expired", other.shown(PersonalEmailOffer.ERROR_ATTRIBUTE));
        assertNull(other.attributes.get(PersonalEmailProof.ADDRESS_ATTRIBUTE));
        browser.verify(code);
        assertEquals("ada@example.org", browser.attributes.get(PersonalEmailProof.ADDRESS_ATTRIBUTE));
    }

    @Test
    void aNewCodeReplacesTheOldOneAndChangeGoesBackToTheAddress() {
        browser.send("ada@example.org");
        String first = lastCodeTo("ada@example.org");
        browser.post(PersonalEmailOffer.CHANGE, null, null);
        assertEquals("address", browser.shown(PersonalEmailOffer.STAGE_ATTRIBUTE));
        assertTrue(store.pendingCodes().isEmpty());

        browser.send("ada.second@example.org");
        browser.verify(first);
        assertEquals("wrong_code", browser.shown(PersonalEmailOffer.ERROR_ATTRIBUTE));
        browser.verify(lastCodeTo("ada.second@example.org"));
        assertEquals("ada.second@example.org", browser.attributes.get(PersonalEmailProof.ADDRESS_ATTRIBUTE));
    }

    @Test
    void anAddressTakenWhileTheCodeWaitedIsNotWritten() {
        browser.send("ada@example.org");
        otherHolders.put("ada@example.org", IdentityResource.PERSONAL_EMAIL_ATTRIBUTE);

        browser.verify(lastCodeTo("ada@example.org"));

        assertEquals("email_taken", browser.shown(PersonalEmailOffer.ERROR_ATTRIBUTE));
        assertNull(browser.attributes.get(PersonalEmailProof.ADDRESS_ATTRIBUTE));
        verify(browser.context, never()).success();
    }

    // ------------------------------------------------------------------ budgets

    @Test
    void aSignInSessionSendsAtMostThreeCodes() {
        browser.send("one@example.org");
        browser.send("two@example.org");
        browser.send("three@example.org");
        browser.send("four@example.org");

        assertEquals("rate_limited", browser.shown(PersonalEmailOffer.ERROR_ATTRIBUTE));
        assertEquals(3, mailed.size());
        assertNull(lastCodeTo("four@example.org"));
    }

    @Test
    void anAddressGetsAtMostThreeCodesAnHourAcrossSessions() {
        for (int index = 0; index < 3; index++) {
            new Browser("root-a" + index, "198.51.100." + index).send("ada@example.org");
        }
        Browser fourth = new Browser("root-a4", "192.0.2.4");
        fourth.send("ada@example.org");

        assertEquals("rate_limited", fourth.shown(PersonalEmailOffer.ERROR_ATTRIBUTE));
        assertEquals(3, mailed.size());
    }

    @Test
    void anIpClassSharesOneBudgetWhoseKeyIsNeverTheIp() {
        int limit = RateLimiter.OFFER_IP_CLASS.maxAttempts();
        for (int index = 0; index < limit; index++) {
            new Browser("root-ip" + index, "203.0.113." + (index % 250 + 1)).send("person" + index + "@example.org");
        }
        Browser next = new Browser("root-ip-next", "203.0.113.254");
        next.send("next@example.org");
        assertEquals("rate_limited", next.shown(PersonalEmailOffer.ERROR_ATTRIBUTE));

        Browser elsewhere = new Browser("root-elsewhere", "203.0.114.1");
        elsewhere.send("elsewhere@example.org");
        assertEquals("code", elsewhere.shown(PersonalEmailOffer.STAGE_ATTRIBUTE));
        assertFalse(store.keys().stream().anyMatch(key -> key.contains("203.0.11")), "no IP in any key");
    }

    @Test
    void ipClassesAreTheIpv4Slash24AndTheIpv6Slash64AndNothingIsResolved() {
        assertEquals("v4:203.0.113", BudgetKeys.ipClass("203.0.113.7"));
        assertEquals(BudgetKeys.ipClass("203.0.113.200"), BudgetKeys.ipClass("203.0.113.7"));
        assertNotEquals(BudgetKeys.ipClass("203.0.114.7"), BudgetKeys.ipClass("203.0.113.7"));
        assertEquals("v6:20010db800010002", BudgetKeys.ipClass("2001:db8:1:2::17"));
        assertEquals(BudgetKeys.ipClass("2001:db8:1:2:ffff::1"), BudgetKeys.ipClass("2001:db8:1:2::17"));
        assertEquals("v4:198.51.100", BudgetKeys.ipClass("::ffff:198.51.100.3"));
        assertEquals("unknown", BudgetKeys.ipClass("999.1.1.1"));
        assertEquals("unknown", BudgetKeys.ipClass("example.org"));
        assertEquals("unknown", BudgetKeys.ipClass("fe80::1%eth0"));
        assertEquals("unknown", BudgetKeys.ipClass(null));
    }

    @Test
    void theOfferCannotBeRequestedByAnApplication() {
        assertEquals(org.keycloak.authentication.InitiatedActionSupport.NOT_SUPPORTED, offer.initiatedActionSupport());
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

        List<String> pendingCodes() {
            return entries.keySet().stream().filter(key -> key.startsWith("sky-account:login-email-offer:")).toList();
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
