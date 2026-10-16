package com.skylab.passkey;

import com.skylab.account.EmailCodeSignUp;
import jakarta.ws.rs.core.MultivaluedHashMap;
import jakarta.ws.rs.core.Response;
import java.util.*;
import java.util.concurrent.atomic.AtomicLong;
import java.util.stream.Stream;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.keycloak.authentication.*;
import org.keycloak.events.EventBuilder;
import org.keycloak.forms.login.LoginFormsProvider;
import org.keycloak.http.HttpRequest;
import org.keycloak.models.*;
import org.keycloak.sessions.AuthenticationSessionModel;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class AfterSignUpStateTest {
    @Test void absoluteTtlDoesNotRefreshBetweenStages() {
        var f=new AfterSignUpFixture();
        var state=AfterSignUpState.begin(f.session,f.realm,f.auth,f.user,f.now::get);
        assertNotNull(state);
        f.now.addAndGet(599);
        AfterSignUpState.move(f.session,f.auth,state,AfterSignUpState.Stage.CREDENTIALS,f.now::get);
        assertNotNull(f.state());
        f.now.incrementAndGet();
        assertNull(f.state());
    }
    @Test void signupMarkerIsConsumedAndStateIsBound() {
        var f=new AfterSignUpFixture();f.start();
        assertNull(f.authNotes.get(EmailCodeSignUp.SIGNED_UP_NOTE));
        assertEquals(AfterSignUpState.Stage.SCHOOL,f.state().stage());
        when(f.auth.getTabId()).thenReturn("another-tab");
        assertNull(f.state());
    }
    @ParameterizedTest @ValueSource(strings={"realm","user","root","client","disabled"})
    void rejectsAnotherSessionOrUser(String changed) {
        var f=new AfterSignUpFixture();f.start();
        switch(changed) {
            case "realm" -> when(f.realm.getId()).thenReturn("other");
            case "user" -> when(f.user.getId()).thenReturn("other");
            case "root" -> when(f.auth.getParentSession().getId()).thenReturn("other");
            case "client" -> when(f.client.getClientId()).thenReturn("other");
            case "disabled" -> when(f.user.isEnabled()).thenReturn(false);
        }
        assertNull(f.state());
    }
    @ParameterizedTest @ValueSource(strings={"", "garbage", "{}", "[]", "null", "{\"stage\":\"NOT_A_STAGE\"}"})
    void malformedStateNeverProducesAnAction(String raw) {
        var f=new AfterSignUpFixture();f.authNotes.put(AfterSignUpState.NOTE,raw);
        assertNull(f.state());
    }
    @Test void clockRollbackFailsClosed() {
        var f=new AfterSignUpFixture();f.start();f.now.decrementAndGet();
        assertNull(f.state());
    }

    @Test void malformedTypedFieldsAndExtraFieldsAreRejected() throws Exception {
        var f=new AfterSignUpFixture();f.start();String original=f.authNotes.get(AfterSignUpState.NOTE);
        for(String changed:List.of("issuedAt","stage","expiresAt","nonce","unknown")) {
            var node=(com.fasterxml.jackson.databind.node.ObjectNode)org.keycloak.util.JsonSerialization.mapper.readTree(original);
            if(changed.equals("issuedAt"))node.put(changed,"1000");
            else if(changed.equals("stage"))node.put(changed,1);
            else if(changed.equals("expiresAt"))node.put(changed,1601);
            else if(changed.equals("nonce"))node.put(changed,"short");
            else node.put(changed,"value");
            f.authNotes.put(AfterSignUpState.NOTE,node.toString());assertNull(f.state(),changed);
        }
    }
    @ParameterizedTest @ValueSource(strings={"first-null","first-blank","last-null","last-blank"})
    void incompleteSignupNamesCannotBeginOnboarding(String invalid) {
        var f=new AfterSignUpFixture();
        switch(invalid) {
            case "first-null" -> when(f.user.getFirstName()).thenReturn(null);
            case "first-blank" -> when(f.user.getFirstName()).thenReturn("  ");
            case "last-null" -> when(f.user.getLastName()).thenReturn(null);
            case "last-blank" -> when(f.user.getLastName()).thenReturn("  ");
        }
        assertNull(AfterSignUpState.begin(f.session,f.realm,f.auth,f.user,f.now::get));
        assertFalse(f.authNotes.containsKey(AfterSignUpState.NOTE));
    }
    @Test void stageCannotJumpBackOrSkipSchoolAndCredentials() {
        var f=new AfterSignUpFixture();f.start();
        assertThrows(IllegalArgumentException.class,()->AfterSignUpState.move(f.session,f.auth,f.state(),AfterSignUpState.Stage.DONE,f.now::get));
        f.stage(AfterSignUpState.Stage.CREDENTIALS);
        assertThrows(IllegalArgumentException.class,()->AfterSignUpState.move(f.session,f.auth,f.state(),AfterSignUpState.Stage.SCHOOL,f.now::get));
    }

    @Test void staleSchoolSnapshotCannotReopenCompletedSignup() {
        var f=new AfterSignUpFixture();f.start();var old=f.state();
        f.stage(AfterSignUpState.Stage.CREDENTIALS);f.stage(AfterSignUpState.Stage.DONE);
        int claims=f.store.values.size();
        assertNull(AfterSignUpState.move(f.session,f.auth,old,AfterSignUpState.Stage.LINK_PENDING,f.now::get));
        assertEquals(AfterSignUpState.Stage.DONE,f.state().stage());assertEquals(claims,f.store.values.size());
    }
    @Test void claimLifetimeUsesOnlyCapsuleRemainingTime() {
        var f=new AfterSignUpFixture();f.start();f.now.addAndGet(599);
        f.stage(AfterSignUpState.Stage.CREDENTIALS);
        assertEquals(1L,f.store.lifespans.entrySet().stream().filter(e->e.getKey().startsWith("sky-auth:after-sign-up:claim:")).findFirst().orElseThrow().getValue());
        assertTrue(f.store.lifespans.values().stream().allMatch(ttl->ttl<=600));
    }
    @Test void twoOverlappingClaimsHaveOnlyOneWinner() throws Exception {
        var f=new AfterSignUpFixture();f.start();f.stage(AfterSignUpState.Stage.CREDENTIALS);var same=f.state();
        var arrived=new java.util.concurrent.CountDownLatch(2);var release=new java.util.concurrent.CountDownLatch(1);
        f.store.beforeClaim=key->{arrived.countDown();try {assertTrue(release.await(5,java.util.concurrent.TimeUnit.SECONDS));}catch(InterruptedException interrupted){throw new IllegalStateException(interrupted);}};
        try(var executor=java.util.concurrent.Executors.newFixedThreadPool(2)) {
            var first=executor.submit(()->AfterSignUpState.move(f.session,f.auth,same,AfterSignUpState.Stage.DONE,f.now::get));
            var second=executor.submit(()->AfterSignUpState.move(f.session,f.auth,same,AfterSignUpState.Stage.DONE,f.now::get));
            try {assertTrue(arrived.await(5,java.util.concurrent.TimeUnit.SECONDS));}finally{release.countDown();}
            assertEquals(1,java.util.stream.Stream.of(first.get(5,java.util.concurrent.TimeUnit.SECONDS),second.get(5,java.util.concurrent.TimeUnit.SECONDS)).filter(java.util.Objects::nonNull).count());
            assertEquals(AfterSignUpState.Stage.DONE,f.state().stage());
        }
    }

    @Test void sameBindingCannotInitializeASecondCapsuleAfterAmbiguousPublish() {
        var f=new AfterSignUpFixture();f.start();assertTrue(f.state().nonce().matches("[A-Za-z0-9_-]{43}"));
        f.authNotes.remove(AfterSignUpState.NOTE);f.authNotes.put(EmailCodeSignUp.SIGNED_UP_NOTE,"true");
        assertNull(AfterSignUpState.begin(f.session,f.realm,f.auth,f.user,f.now::get));
        assertFalse(f.authNotes.containsKey(AfterSignUpState.NOTE));
    }
    @Test void featureRequiresExplicitTrue() {
        var f=new AfterSignUpFixture();
        when(f.realm.getAttribute(AfterSignUpState.FEATURE_ATTRIBUTE)).thenReturn(null,"TRUE","true");
        assertFalse(AfterSignUpState.enabled(f.realm));
        assertFalse(AfterSignUpState.enabled(f.realm));
        assertTrue(AfterSignUpState.enabled(f.realm));
    }
}

final class AfterSignUpFixture {
    final AtomicLong now=new AtomicLong(1000);
    final Map<String,String> authNotes=new java.util.concurrent.ConcurrentHashMap<>(),clientNotes=new java.util.concurrent.ConcurrentHashMap<>();
    final Set<String> actions=java.util.concurrent.ConcurrentHashMap.newKeySet();
    final AfterSignUpMemoryStore store=new AfterSignUpMemoryStore();
    final KeycloakSession session=mock(KeycloakSession.class,RETURNS_DEEP_STUBS);
    final RealmModel realm=mock(RealmModel.class);
    final AuthenticationSessionModel auth=mock(AuthenticationSessionModel.class,RETURNS_DEEP_STUBS);
    final ClientModel client=mock(ClientModel.class),account=mock(ClientModel.class);
    final RoleModel role=mock(RoleModel.class);
    final UserModel user=mock(UserModel.class,RETURNS_DEEP_STUBS);
    final AuthenticationFlowContext flow=mock(AuthenticationFlowContext.class);
    final RequiredActionContext required=mock(RequiredActionContext.class);
    final LoginFormsProvider form=mock(LoginFormsProvider.class,RETURNS_SELF);
    final Response response=mock(Response.class);
    final HttpRequest request=mock(HttpRequest.class);
    final MultivaluedHashMap<String,String> body=new MultivaluedHashMap<>();
    final SkyAfterLoginAuthenticator authenticator=new SkyAfterLoginAuthenticator(now::get);
    final SignUpCredentialsRequiredAction credentials=new SignUpCredentialsRequiredAction(now::get);
    AfterSignUpFixture() {
        when(session.singleUseObjects()).thenReturn(store);
        when(realm.getId()).thenReturn("realm");
        when(realm.getAttribute(AfterSignUpState.FEATURE_ATTRIBUTE)).thenReturn("true");
        when(user.getId()).thenReturn("user");when(user.isEnabled()).thenReturn(true);
        when(user.getFirstName()).thenReturn("İpek");when(user.getLastName()).thenReturn("Öğrenci");
        when(client.getClientId()).thenReturn("account-center");
        when(client.isEnabled()).thenReturn(true);when(client.isStandardFlowEnabled()).thenReturn(true);when(client.getProtocol()).thenReturn("openid-connect");
        when(auth.getClient()).thenReturn(client);when(auth.getRealm()).thenReturn(realm);
        when(auth.getParentSession().getId()).thenReturn("root");when(auth.getTabId()).thenReturn("tab");
        when(auth.getAuthenticatedUser()).thenReturn(user);
        when(auth.getAuthNote(anyString())).thenAnswer(i->authNotes.get(i.getArgument(0)));
        doAnswer(i->authNotes.put(i.getArgument(0),i.getArgument(1))).when(auth).setAuthNote(anyString(),anyString());
        doAnswer(i->authNotes.remove(i.getArgument(0))).when(auth).removeAuthNote(anyString());
        when(auth.getClientNote(anyString())).thenAnswer(i->clientNotes.get(i.getArgument(0)));
        doAnswer(i->clientNotes.put(i.getArgument(0),i.getArgument(1))).when(auth).setClientNote(anyString(),anyString());
        doAnswer(i->clientNotes.remove(i.getArgument(0))).when(auth).removeClientNote(anyString());
        doAnswer(i->actions.add(i.getArgument(0))).when(auth).addRequiredAction(anyString());
        doAnswer(i->actions.remove(i.getArgument(0))).when(auth).removeRequiredAction(anyString());
        when(auth.getRequiredActions()).thenReturn(actions);
        authNotes.put(EmailCodeSignUp.SIGNED_UP_NOTE,"true");
        when(realm.getClientByClientId("account")).thenReturn(account);
        when(account.getRole(anyString())).thenReturn(role);when(user.hasRole(role)).thenReturn(true);
        when(client.hasScope(role)).thenReturn(true);
        var idp=new IdentityProviderModel();idp.setAlias("OBS");idp.setEnabled(true);
        when(session.identityProviders().getByAlias("OBS")).thenReturn(idp);
        for(String alias:List.of("idp_link",SignUpCredentialsRequiredAction.PROVIDER_ID,"webauthn-register-passwordless","UPDATE_PASSWORD")) {
            var model=new RequiredActionProviderModel();model.setAlias(alias);model.setProviderId(alias);model.setEnabled(true);
            when(realm.getRequiredActionProviderByAlias(alias)).thenReturn(model);
        }
        when(flow.getSession()).thenReturn(session);when(flow.getRealm()).thenReturn(realm);
        when(flow.getAuthenticationSession()).thenReturn(auth);when(flow.getUser()).thenReturn(user);
        when(flow.form()).thenReturn(form);when(flow.getHttpRequest()).thenReturn(request);
        when(required.getSession()).thenReturn(session);when(required.getRealm()).thenReturn(realm);
        when(required.getAuthenticationSession()).thenReturn(auth);when(required.getUser()).thenReturn(user);
        when(required.form()).thenReturn(form);when(required.getHttpRequest()).thenReturn(request);
        when(request.getDecodedFormParameters()).thenReturn(body);
        when(form.createForm(anyString())).thenReturn(response);
        when(required.getEvent()).thenReturn(mock(EventBuilder.class,RETURNS_SELF));
        when(user.credentialManager().getStoredCredentialsByTypeStream(anyString())).thenAnswer(i->Stream.empty());
    }
    void start() {assertNotNull(AfterSignUpState.begin(session,realm,auth,user,now::get));}
    AfterSignUpState.State state() {return AfterSignUpState.read(realm,auth,user,now.get());}
    void stage(AfterSignUpState.Stage stage) {assertNotNull(AfterSignUpState.move(session,auth,state(),stage,now::get));}
}

/** Atomic map adapter for Keycloak's SingleUseObjectProvider; the state clock enforces expiry. */
final class AfterSignUpMemoryStore implements org.keycloak.models.SingleUseObjectProvider {
    final java.util.concurrent.ConcurrentHashMap<String,Map<String,String>> values=new java.util.concurrent.ConcurrentHashMap<>();
    final java.util.concurrent.ConcurrentHashMap<String,Long> lifespans=new java.util.concurrent.ConcurrentHashMap<>();
    final java.util.concurrent.atomic.AtomicReference<Runnable> onNextClaim=new java.util.concurrent.atomic.AtomicReference<>();
    volatile java.util.function.Consumer<String> beforeClaim=key->{};
    public void put(String key,long ttl,Map<String,String> notes) {values.put(key,Map.copyOf(notes));lifespans.put(key,ttl);}
    public Map<String,String> get(String key) {return values.get(key);}
    public Map<String,String> remove(String key) {return values.remove(key);}
    public boolean replace(String key,Map<String,String> notes) {return values.replace(key,Map.copyOf(notes))!=null;}
    public boolean putIfAbsent(String key,long ttl) {
        beforeClaim.accept(key);Runnable hook=onNextClaim.getAndSet(null);if(hook!=null)hook.run();
        boolean added=values.putIfAbsent(key,Map.of())==null;if(added)lifespans.put(key,ttl);return added;
    }
    public boolean contains(String key) {return values.containsKey(key);}
    public void close() {}
}
