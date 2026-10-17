package com.skylab.account;

import com.skylab.broker.SkyMicrosoftIdentityProvider;
import com.skylab.broker.SkyMicrosoftIdentityProviderFactory;
import jakarta.ws.rs.core.MultivaluedHashMap;
import jakarta.ws.rs.core.MultivaluedMap;
import jakarta.ws.rs.core.Response;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.keycloak.authentication.AuthenticationFlowContext;
import org.keycloak.authentication.AuthenticationProcessor;
import org.keycloak.authentication.authenticators.broker.AbstractIdpAuthenticator;
import org.keycloak.authentication.authenticators.broker.util.SerializedBrokeredIdentityContext;
import org.keycloak.broker.provider.DefaultDataMarshaller;
import org.keycloak.broker.provider.IdentityProvider;
import org.keycloak.broker.social.SocialIdentityProvider;
import org.keycloak.events.EventBuilder;
import org.keycloak.forms.login.LoginFormsProvider;
import org.keycloak.http.HttpRequest;
import org.keycloak.models.*;
import org.keycloak.sessions.AuthenticationSessionModel;
import org.keycloak.sessions.RootAuthenticationSessionModel;
import org.mockito.ArgumentCaptor;

import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicReference;
import java.util.stream.Stream;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class SkyExistingAccountPromptTest {
    private final AuthenticationFlowContext context = mock(AuthenticationFlowContext.class);
    private final KeycloakSession session = mock(KeycloakSession.class);
    private final RealmModel realm = mock(RealmModel.class);
    private final UserProvider users = mock(UserProvider.class);
    private final UserModel target = mock(UserModel.class);
    private final AuthenticationSessionModel auth = mock(AuthenticationSessionModel.class);
    private final LoginFormsProvider form = mock(LoginFormsProvider.class, RETURNS_SELF);
    private final LoginCodeMail mail = mock(LoginCodeMail.class);
    private final LoginCodeFailureCounter failures = mock(LoginCodeFailureCounter.class);
    private final LoginCodeFailureCounter.Guard persistent = mock(LoginCodeFailureCounter.Guard.class);
    private final Map<String, String> notes = new HashMap<>();
    private final Map<String, Object> attributes = new HashMap<>();
    private final MultivaluedMap<String, String> posted = new MultivaluedHashMap<>();
    private final AtomicReference<UserModel> current = new AtomicReference<>();
    private final SkyExistingAccountPrompt step = new SkyExistingAccountPrompt(
            new EmailCodeSettings("OBS", 500, null, 10), mail, failures);

    @BeforeEach
    void setup() {
        when(failures.lock(session, realm, "target")).thenReturn(persistent);
        when(context.getSession()).thenReturn(session); when(context.getRealm()).thenReturn(realm);
        when(context.getAuthenticationSession()).thenReturn(auth); when(auth.getRealm()).thenReturn(realm);
        when(context.getUser()).thenAnswer(c -> current.get());
        doAnswer(c -> { current.set(c.getArgument(0)); return null; }).when(context).setUser(any());
        doAnswer(c -> { current.set(null); return null; }).when(context).clearUser();
        when(context.form()).thenReturn(form);
        when(form.createForm(anyString())).thenReturn(mock(Response.class));
        when(form.createLoginTotp()).thenReturn(mock(Response.class));
        when(form.createLoginUsernamePassword()).thenReturn(mock(Response.class));
        when(form.setAttribute(anyString(), any())).thenAnswer(c -> {
            attributes.put(c.getArgument(0), c.getArgument(1)); return form;
        });
        when(context.getEvent()).thenReturn(mock(EventBuilder.class, RETURNS_SELF));
        HttpRequest request = mock(HttpRequest.class);
        when(context.getHttpRequest()).thenReturn(request); when(request.getDecodedFormParameters()).thenReturn(posted);
        when(auth.getAuthNote(anyString())).thenAnswer(c -> notes.get(c.getArgument(0)));
        doAnswer(c -> notes.put(c.getArgument(0), c.getArgument(1))).when(auth).setAuthNote(anyString(), anyString());
        doAnswer(c -> notes.remove(c.getArgument(0))).when(auth).removeAuthNote(anyString());
        when(realm.getId()).thenReturn("realm"); when(realm.isLoginWithEmailAllowed()).thenReturn(true);
        when(session.getContext()).thenReturn(mock(KeycloakContext.class));
        when(session.users()).thenReturn(users);
        when(users.searchForUserStream(eq(realm), anyMap(), anyInt(), anyInt())).thenAnswer(c -> Stream.empty());
        when(users.getUserByEmail(realm, "personal@example.org")).thenReturn(target);
        when(users.getUserById(realm, "target")).thenReturn(target);
        when(target.getId()).thenReturn("target"); when(target.getUsername()).thenReturn("canonical.user");
        when(target.getEmail()).thenReturn("primary@example.org"); when(target.isEnabled()).thenReturn(true);
        var credentials = mock(SubjectCredentialManager.class);
        when(target.credentialManager()).thenReturn(credentials);
        when(credentials.getStoredCredentialsByTypeStream("otp")).thenAnswer(c -> Stream.empty());
        var root = mock(RootAuthenticationSessionModel.class); var client = mock(ClientModel.class);
        when(root.getId()).thenReturn("root"); when(auth.getParentSession()).thenReturn(root);
        when(client.getClientId()).thenReturn("client"); when(auth.getClient()).thenReturn(client);
        when(auth.getTabId()).thenReturn("tab");
        var entries = new ConcurrentHashMap<String, Map<String, String>>();
        var store = mock(SingleUseObjectProvider.class); when(session.singleUseObjects()).thenReturn(store);
        when(store.get(anyString())).thenAnswer(c -> entries.get(c.getArgument(0)));
        when(store.remove(anyString())).thenAnswer(c -> entries.remove(c.getArgument(0)));
        when(store.putIfAbsent(anyString(), anyLong())).thenAnswer(c -> entries.putIfAbsent(c.getArgument(0), Map.of()) == null);
        doAnswer(c -> entries.put(c.getArgument(0), Map.copyOf(c.getArgument(2))))
                .when(store).put(anyString(), anyLong(), anyMap());
        IdentityProviderModel obs = new IdentityProviderModel();
        obs.setAlias("OBS"); obs.setProviderId("microsoft"); obs.setEnabled(true);
        var providers = mock(IdentityProviderStorageProvider.class);
        when(session.identityProviders()).thenReturn(providers); when(providers.getByAlias("OBS")).thenReturn(obs);
        var factory = mock(SkyMicrosoftIdentityProviderFactory.class);
        when(factory.getId()).thenReturn("microsoft");
        var provider = mock(SkyMicrosoftIdentityProvider.class);
        when(factory.create(session, obs)).thenReturn(provider);
        when(provider.getMarshaller()).thenReturn(new DefaultDataMarshaller());
        var sessionFactory = mock(KeycloakSessionFactory.class);
        when(session.getKeycloakSessionFactory()).thenReturn(sessionFactory);
        when(sessionFactory.getProviderFactoriesStream(IdentityProvider.class)).thenAnswer(c -> Stream.of(factory));
        when(sessionFactory.getProviderFactoriesStream(SocialIdentityProvider.class)).thenAnswer(c -> Stream.empty());
        SerializedBrokeredIdentityContext broker = new SerializedBrokeredIdentityContext();
        broker.setIdentityProviderId("OBS"); broker.setId("subject"); broker.setBrokerUserId("OBS.subject");
        broker.setUsername("school@std.yildiz.edu.tr"); broker.setModelUsername("school@std.yildiz.edu.tr");
        broker.setFirstName("Microsoft"); broker.setLastName("Name");
        broker.setEmail("school@std.yildiz.edu.tr");
        broker.setSingleAttribute("schoolEmail", "school@std.yildiz.edu.tr");
        broker.saveToAuthenticationSession(auth, AbstractIdpAuthenticator.BROKERED_CONTEXT_NOTE);
    }

    private void action(String action, String field, String value) {
        posted.clear(); posted.putSingle(SkyExistingAccountPrompt.ACTION, action);
        if (field != null) posted.putSingle(field, value);
        attributes.clear(); step.action(context);
    }

    private String send() {
        action("send", "username", "personal@example.org");
        ArgumentCaptor<String> code = ArgumentCaptor.forClass(String.class);
        verify(mail).sendCode(eq(context), eq(target), eq("primary@example.org"), code.capture(), eq("link"));
        return code.getValue();
    }

    @Test
    void thePersistentLimitSuppressesANewLinkMailWithoutChangingTheCodePage() {
        when(persistent.blocked()).thenReturn(true);
        action("send", "username", "personal@example.org");
        assertEquals("code", attributes.get("skyExistingAccountStage"));
        assertEquals("", notes.get(BrokerLinkState.TARGET));
        verify(mail, never()).sendCode(any(), any(), anyString(), anyString(), anyString());
        verify(context, never()).success();
    }

    @Test
    void aPreviouslyIssuedCorrectLinkCodeCannotPassAt100() {
        String code = send();
        when(persistent.blocked()).thenReturn(true);
        action("verify", "code", code);
        assertEquals("wrong_code", attributes.get("skyExistingAccountError"));
        assertNull(notes.get(BrokerLinkState.PROOF));
        verify(context, never()).success();
        verify(persistent, never()).wrongCode();
        verify(mail, never()).consecutiveAlarm(any(), anyInt());
    }

    @Test
    void aComparedWrongLinkCodeAt99SharesTheCounterAndAlarmsOnce() {
        String code = send();
        when(persistent.wrongCode()).thenReturn(true);
        action("verify", "code", (code.charAt(0) == '9' ? "0" : "9") + code.substring(1));
        verify(persistent).wrongCode();
        verify(mail).consecutiveAlarm(context, 100);
        assertEquals("wrong_code", attributes.get("skyExistingAccountError"));
        verify(context, never()).success();
    }

    @Test
    void firstLoginAsksBeforeCreatingAnyAccount() {
        step.authenticate(context);
        assertEquals("question", attributes.get("skyExistingAccountStage"));
        verify(users, never()).addUser(any(), anyString()); verify(context, never()).success();
    }

    @Test
    void aMicrosoftProvenSchoolAddressSuggestsItsUniquePersonalEmailHolderWithoutProvingIt() {
        when(users.searchForUserStream(eq(realm), argThat((Map<String, String> values) ->
                        "school@std.yildiz.edu.tr".equals(values.get("personalEmail"))), anyInt(), anyInt()))
                .thenAnswer(c -> Stream.of(target));
        when(target.getFirstAttribute("personalEmail")).thenReturn("SCHOOL@std.yildiz.edu.tr");
        when(target.getFirstAttribute("personalEmailVerifiedAt")).thenReturn("2026-10-01T00:00:00Z");
        step.authenticate(context);
        assertEquals(true, attributes.get("skyExistingAccountSchoolCandidate"));
        action("existing", null, null);
        assertEquals("school@std.yildiz.edu.tr", attributes.get("skyExistingAccountIdentifier"));
        assertFalse(attributes.containsValue("canonical.user"));
        assertFalse(attributes.containsValue("primary@example.org"));
        assertNull(current.get()); verifyNoInteractions(mail); verify(context, never()).success();
    }

    @Test
    void nativeDuplicateAndAnAlreadyAuthenticatedLinkSkipThePrompt() {
        when(users.getUserByEmail(realm, "school@std.yildiz.edu.tr")).thenReturn(target);
        step.authenticate(context);
        verify(context).success(); verifyNoInteractions(mail);
        clearInvocations(context);
        current.set(target); step.authenticate(context); verify(context).success();
    }

    @Test
    void anExplicitNewAccountChoiceContinuesWithoutAuthenticatingOrChangingAnExistingUser() {
        action("new-account", null, null);
        verify(context).success(); assertNull(current.get());
        verifyNoInteractions(mail); verify(target, never()).setEmail(any());
    }

    @Test
    void linkCodeGoesToCurrentPrimaryAndCompletesAProvenCandidateWithoutPrimaryMutation() {
        String code = send();
        assertEquals("code", attributes.get("skyExistingAccountStage"));
        assertFalse(attributes.containsValue("primary@example.org"));
        action("verify", "code", code);
        verify(context).success(); assertSame(target, current.get());
        assertEquals("true", notes.get(BrokerLinkState.REQUIRED));
        assertNotNull(BrokerLinkState.proof(session, auth));
        assertNull(SkyExistingAccountPrompt.broker(context).getEmail());
        verify(target, never()).setEmail(any()); verify(target, never()).setEmailVerified(anyBoolean());
        verify(users, never()).addFederatedIdentity(any(), any(), any());
    }

    @Test
    void unknownIdentifierGetsTheSameCodePageWithoutMail() {
        action("send", "username", "unknown@example.org");
        assertEquals("code", attributes.get("skyExistingAccountStage")); verifyNoInteractions(mail);
        assertNotNull(new BrokerLinkProofs(session.singleUseObjects()).waiting(notes.get(BrokerLinkState.CODE)));
        assertNull(current.get()); verify(context, never()).success();
    }

    @Test
    void changingPrimaryOrLinkingAnotherMicrosoftIdentityWhileWaitingInvalidatesTheCode() {
        String code = send();
        when(target.getEmail()).thenReturn("changed@example.org");
        action("verify", "code", code);
        assertEquals("code_expired", attributes.get("skyExistingAccountError"));
        verify(context, never()).success(); assertNull(notes.get(BrokerLinkState.REQUIRED));
    }

    @Test
    void anExistingMicrosoftLinkIsNeverOverridden() {
        when(users.getFederatedIdentity(realm, target, "OBS"))
                .thenReturn(new FederatedIdentityModel("OBS", "other-subject", "other-school"));
        action("send", "username", "personal@example.org");
        assertEquals("code", attributes.get("skyExistingAccountStage")); verifyNoInteractions(mail);
        verify(users, never()).removeFederatedIdentity(any(), any(), anyString());
    }

    @Test
    void aMarkedButInvalidProofBlocksInsteadOfFallingThroughToCreateUser() {
        notes.put(BrokerLinkState.REQUIRED, "true"); notes.put(BrokerLinkState.PROOF, "missing");
        new SkyExistingAccountPromptFactory.Proven().create(session).authenticate(context);
        verify(context).failureChallenge(any(), any()); verify(context, never()).attempted();
        verify(context, never()).success(); verify(users, never()).addUser(any(), anyString());
    }

    @Test
    void explicitEscapeFromAFailedProofRestoresTheBrokerAfterNativeResetClearsEveryAuthNote() {
        String code = send(); action("verify", "code", code);
        String proofHandle = notes.get(BrokerLinkState.PROOF);
        assertNull(SkyExistingAccountPrompt.broker(context).getEmail());
        doAnswer(call -> {
            notes.clear(); // AuthenticationProcessor.resetFlow does this BEFORE running the listener.
            call.<Runnable>getArgument(0).run();
            return null;
        }).when(context).resetFlow(any(Runnable.class));
        posted.clear(); posted.putSingle(SkyExistingAccountPrompt.ACTION, "new-account");
        new SkyExistingAccountPromptFactory.Proven().create(session).action(context);
        assertEquals("school@std.yildiz.edu.tr", SkyExistingAccountPrompt.broker(context).getEmail());
        assertEquals("new-account", notes.get(BrokerLinkState.STAGE));
        assertNull(notes.get(BrokerLinkState.PROOF));
        assertNull(new BrokerLinkProofs(session.singleUseObjects()).peekProof(proofHandle));
    }

    @Test
    void nativePasswordPasskeyAndOtpKeepCredentialBookkeepingOnlyForTheSelectedTarget() throws Exception {
        var adapter = SkyExistingAccountPrompt.class.getDeclaredMethod("nativeContext",
                AuthenticationFlowContext.class, Runnable.class);
        adapter.setAccessible(true);
        var completed = new java.util.concurrent.atomic.AtomicInteger();
        AuthenticationFlowContext nativeContext = (AuthenticationFlowContext) adapter.invoke(step, context,
                (Runnable) completed::incrementAndGet);
        notes.put(BrokerLinkState.TARGET, target.getId()); current.set(target);
        for (String category : new String[]{"password", "webauthn-passwordless", "otp"}) {
            notes.remove(AuthenticationProcessor.AUTHN_CREDENTIALS);
            nativeContext.success(category);
            assertTrue(notes.get(AuthenticationProcessor.AUTHN_CREDENTIALS).contains(category));
        }
        assertEquals(3, completed.get());
        notes.remove(AuthenticationProcessor.AUTHN_CREDENTIALS);
        notes.put(BrokerLinkState.TARGET, "another-user");
        nativeContext.success("password");
        assertNull(notes.get(AuthenticationProcessor.AUTHN_CREDENTIALS));
        verify(context, never()).success(); // The adapter holds completion for the next factor.
    }

    @Test
    void anExplicitChangeOrEscapeClearsPreviouslyRecordedCredentialCategories() {
        notes.put(AuthenticationProcessor.AUTHN_CREDENTIALS, "password,otp");
        action("existing", null, null);
        assertNull(notes.get(AuthenticationProcessor.AUTHN_CREDENTIALS));
        notes.put(AuthenticationProcessor.AUTHN_CREDENTIALS, "webauthn-passwordless");
        action("new-account", null, null);
        assertNull(notes.get(AuthenticationProcessor.AUTHN_CREDENTIALS));
    }
}
