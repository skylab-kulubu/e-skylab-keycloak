package com.skylab.passkey;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.keycloak.authentication.InitiatedActionSupport;
import org.keycloak.models.Constants;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class SignUpCredentialsRequiredActionTest {
    @Test void pendingNativeLinkDoesNotSchedulePageTwo() {
        var f=new AfterSignUpFixture();f.start();f.stage(AfterSignUpState.Stage.LINK_PENDING);
        f.clientNotes.put(Constants.KC_ACTION,"idp_link");f.clientNotes.put(Constants.KC_ACTION_PARAMETER,"OBS");
        f.credentials.evaluateTriggers(f.required);assertTrue(f.actions.isEmpty());
    }
    @ParameterizedTest @ValueSource(strings={"success","cancelled","error"})
    void nativeResultSchedulesPageTwoOnceAndConsumesOnlyOwnedNotes(String result) {
        var f=new AfterSignUpFixture();f.start();f.stage(AfterSignUpState.Stage.LINK_PENDING);
        f.clientNotes.put(Constants.KC_ACTION_STATUS,result);f.clientNotes.put(Constants.KC_ACTION_PARAMETER,"OBS");
        f.clientNotes.put("state","original-oidc-state");
        f.credentials.evaluateTriggers(f.required);f.credentials.evaluateTriggers(f.required);
        assertEquals(AfterSignUpState.Stage.CREDENTIALS,f.state().stage());
        verify(f.auth,times(1)).addRequiredAction(SignUpCredentialsRequiredAction.PROVIDER_ID);
        assertEquals(java.util.Map.of("state","original-oidc-state"),f.clientNotes);
        verify(f.user,never()).addRequiredAction(anyString());
    }
    @ParameterizedTest @ValueSource(strings={"unknown","SUCCESS",""})
    void unknownNativeStatusDoesNotAdvance(String status) {
        var f=new AfterSignUpFixture();f.start();f.stage(AfterSignUpState.Stage.LINK_PENDING);
        f.clientNotes.put(Constants.KC_ACTION_STATUS,status);f.clientNotes.put(Constants.KC_ACTION_PARAMETER,"OBS");
        f.credentials.evaluateTriggers(f.required);assertTrue(f.actions.isEmpty());
        assertEquals(AfterSignUpState.Stage.LINK_PENDING,f.state().stage());
    }
    @Test void foreignParameterOrActionCannotCompletePendingLink() {
        var f=new AfterSignUpFixture();f.start();f.stage(AfterSignUpState.Stage.LINK_PENDING);
        f.clientNotes.put(Constants.KC_ACTION_STATUS,"success");f.clientNotes.put(Constants.KC_ACTION_PARAMETER,"another-provider");
        f.credentials.evaluateTriggers(f.required);assertTrue(f.actions.isEmpty());
        assertEquals("success",f.clientNotes.get(Constants.KC_ACTION_STATUS));
    }
    @Test void directAiaWithoutSignupStateCannotAddCredential() {
        var f=new AfterSignUpFixture();f.authNotes.clear();f.body.putSingle(SignUpCredentialsRequiredAction.CHOICE,"passkey");
        f.credentials.processAction(f.required);assertTrue(f.actions.isEmpty());verify(f.required).failure(anyString());
        assertEquals(InitiatedActionSupport.NOT_SUPPORTED,f.credentials.initiatedActionSupport());
    }
    @ParameterizedTest @ValueSource(strings={"passkey","password","skip"})
    void choiceSchedulesNativeActionOnSessionOnlyAndIsNotReplayable(String choice) {
        var f=new AfterSignUpFixture();f.start();f.stage(AfterSignUpState.Stage.CREDENTIALS);
        f.body.putSingle(SignUpCredentialsRequiredAction.CHOICE,choice);
        f.credentials.processAction(f.required);
        assertEquals(AfterSignUpState.Stage.DONE,f.state().stage());
        String expected=choice.equals("passkey")?"webauthn-register-passwordless":choice.equals("password")?"UPDATE_PASSWORD":null;
        if(expected==null)assertTrue(f.actions.isEmpty());else assertEquals(java.util.Set.of(expected),f.actions);
        verify(f.user,never()).addRequiredAction(anyString());verify(f.user,never()).setSingleAttribute(anyString(),anyString());
        f.credentials.processAction(f.required);verify(f.required).failure(anyString());
    }
    @Test void wrongStageOrExpiredStateCannotAddCredential() {
        var f=new AfterSignUpFixture();f.start();f.stage(AfterSignUpState.Stage.CREDENTIALS);f.now.addAndGet(600);
        f.body.putSingle(SignUpCredentialsRequiredAction.CHOICE,"password");
        f.credentials.processAction(f.required);assertTrue(f.actions.isEmpty());verify(f.required).failure(anyString());
    }
    @Test void disabledFeatureCannotUseAnOutstandingPage() {
        var f=new AfterSignUpFixture();f.start();f.stage(AfterSignUpState.Stage.CREDENTIALS);
        when(f.realm.getAttribute(AfterSignUpState.FEATURE_ATTRIBUTE)).thenReturn("false");
        f.body.putSingle(SignUpCredentialsRequiredAction.CHOICE,"passkey");
        f.credentials.processAction(f.required);assertTrue(f.actions.isEmpty());verify(f.required).failure(anyString());
    }
    @Test void missingNativeCredentialActionDoesNotFinishOrGrant() {
        var f=new AfterSignUpFixture();f.start();f.stage(AfterSignUpState.Stage.CREDENTIALS);
        when(f.realm.getRequiredActionProviderByAlias("UPDATE_PASSWORD")).thenReturn(null);
        f.body.putSingle(SignUpCredentialsRequiredAction.CHOICE,"password");f.credentials.processAction(f.required);
        assertTrue(f.actions.isEmpty());assertEquals(AfterSignUpState.Stage.CREDENTIALS,f.state().stage());
        verify(f.required).failure(anyString());
    }

    @Test void invalidOrUnrelatedStateDoesNotClearNativeActionNotes() {
        var f=new AfterSignUpFixture();f.start();f.stage(AfterSignUpState.Stage.LINK_PENDING);
        f.now.addAndGet(600);f.clientNotes.put(Constants.KC_ACTION_STATUS,"success");f.clientNotes.put(Constants.KC_ACTION_PARAMETER,"OBS");
        f.credentials.evaluateTriggers(f.required);assertTrue(f.actions.isEmpty());
        assertEquals("success",f.clientNotes.get(Constants.KC_ACTION_STATUS));
        assertEquals("OBS",f.clientNotes.get(Constants.KC_ACTION_PARAMETER));
    }
    @Test void anotherAiaCannotUseOutstandingCredentialState() {
        var f=new AfterSignUpFixture();f.start();f.stage(AfterSignUpState.Stage.CREDENTIALS);
        f.clientNotes.put(Constants.KC_ACTION,"UPDATE_PASSWORD");f.body.putSingle(SignUpCredentialsRequiredAction.CHOICE,"passkey");
        f.credentials.processAction(f.required);assertTrue(f.actions.isEmpty());verify(f.required).failure(anyString());
    }
    @Test void duplicateCredentialChoicesDoNotAdvance() {
        var f=new AfterSignUpFixture();f.start();f.stage(AfterSignUpState.Stage.CREDENTIALS);
        f.body.add(SignUpCredentialsRequiredAction.CHOICE,"password");f.body.add(SignUpCredentialsRequiredAction.CHOICE,"skip");
        f.credentials.processAction(f.required);assertTrue(f.actions.isEmpty());
        assertEquals(AfterSignUpState.Stage.CREDENTIALS,f.state().stage());verify(f.required).challenge(f.response);
    }

    @ParameterizedTest @ValueSource(strings={"SUCCESS","CANCELLED"})
    void actualNativeSchedulerSelectsLinkThenTheRealDelayedPageTwo(String outcome) throws Exception {
        var f=new AfterSignUpFixture();f.start();f.stage(AfterSignUpState.Stage.LINK_PENDING);
        f.clientNotes.put(Constants.KC_ACTION,"idp_link");f.clientNotes.put(Constants.KC_ACTION_PARAMETER,"OBS");
        when(f.realm.getRequiredActionProvidersStream()).thenAnswer(i->java.util.stream.Stream.of(f.realm.getRequiredActionProviderByAlias(SignUpCredentialsRequiredAction.PROVIDER_ID)));
        when(f.session.getKeycloakSessionFactory().getProviderFactory(org.keycloak.authentication.RequiredActionProvider.class,SignUpCredentialsRequiredAction.PROVIDER_ID)).thenReturn(f.credentials);
        var manager=org.keycloak.services.managers.AuthenticationManager.class;
        var sorted=manager.getDeclaredMethod("getApplicableRequiredActionsSorted",org.keycloak.models.RealmModel.class,org.keycloak.sessions.AuthenticationSessionModel.class,org.keycloak.models.UserModel.class,String.class,java.util.Set.class);
        sorted.setAccessible(true);
        org.keycloak.services.managers.AuthenticationManager.evaluateRequiredActionTriggers(f.session,f.auth,null,f.required.getEvent(),f.realm,f.user);
        assertEquals(java.util.List.of("idp_link"),aliases(sorted.invoke(null,f.realm,f.auth,f.user,"idp_link",java.util.Set.of())));
        org.keycloak.services.managers.AuthenticationManager.setKcActionStatus("idp_link",org.keycloak.authentication.RequiredActionContext.KcActionStatus.valueOf(outcome),f.auth);
        org.keycloak.services.managers.AuthenticationManager.evaluateRequiredActionTriggers(f.session,f.auth,null,f.required.getEvent(),f.realm,f.user);
        assertEquals(java.util.List.of(SignUpCredentialsRequiredAction.PROVIDER_ID),aliases(sorted.invoke(null,f.realm,f.auth,f.user,null,java.util.Set.of())));
        assertFalse(f.clientNotes.containsKey(Constants.KC_ACTION_ENFORCED));assertFalse(f.clientNotes.containsKey(Constants.KC_ACTION_STATUS));
        assertEquals(AfterSignUpState.Stage.CREDENTIALS,f.state().stage());
    }
    @SuppressWarnings("unchecked")
    private static java.util.List<String> aliases(Object models) {
        return ((java.util.List<org.keycloak.models.RequiredActionProviderModel>)models).stream().map(org.keycloak.models.RequiredActionProviderModel::getAlias).toList();
    }

    @ParameterizedTest @ValueSource(strings={"passkey","password","skip"})
    void genericRpWithoutAccountRolesCanChooseCredentialsAndPreserveCallback(String choice) {
        var f=new AfterSignUpFixture();when(f.client.getClientId()).thenReturn("frontend-main");when(f.user.hasRole(f.role)).thenReturn(false);when(f.client.hasScope(f.role)).thenReturn(false);
        f.start();f.stage(AfterSignUpState.Stage.CREDENTIALS);f.clientNotes.put("state","rp-state");f.clientNotes.put("nonce","rp-nonce");f.clientNotes.put("code_challenge","rp-pkce");
        f.body.putSingle(SignUpCredentialsRequiredAction.CHOICE,choice);f.credentials.processAction(f.required);
        assertEquals(AfterSignUpState.Stage.DONE,f.state().stage());verify(f.required).success();
        assertEquals(java.util.Map.of("state","rp-state","nonce","rp-nonce","code_challenge","rp-pkce"),f.clientNotes);
        verify(f.user,never()).grantRole(any());verify(f.auth,never()).setRedirectUri(anyString());
    }

    @Test void reentrantOverlappingChoicesCannotAddBothNativeActions() {
        var f=new AfterSignUpFixture();f.start();f.stage(AfterSignUpState.Stage.CREDENTIALS);
        f.body.putSingle(SignUpCredentialsRequiredAction.CHOICE,"password");
        f.store.onNextClaim.set(()->{f.body.putSingle(SignUpCredentialsRequiredAction.CHOICE,"passkey");f.credentials.processAction(f.required);});
        f.credentials.processAction(f.required);
        assertEquals(java.util.Set.of("webauthn-register-passwordless"),f.actions);
        assertEquals(AfterSignUpState.Stage.DONE,f.state().stage());verify(f.required,times(1)).success();verify(f.required,times(1)).failure(anyString());
    }
    @Test void deadlineDuringAtomicClaimCannotPublishCredentialAction() {
        var f=new AfterSignUpFixture();f.start();f.stage(AfterSignUpState.Stage.CREDENTIALS);
        f.body.putSingle(SignUpCredentialsRequiredAction.CHOICE,"password");f.store.onNextClaim.set(()->f.now.addAndGet(600));
        f.credentials.processAction(f.required);assertTrue(f.actions.isEmpty());verify(f.required).failure(anyString());
    }
    @Test void ambiguousClaimFailureNeverRetriesIntoAnotherAction() {
        var f=new AfterSignUpFixture();f.start();f.stage(AfterSignUpState.Stage.CREDENTIALS);
        f.body.putSingle(SignUpCredentialsRequiredAction.CHOICE,"password");
        f.store.beforeClaim=key->{f.store.values.put(key,java.util.Map.of());throw new IllegalStateException("store unavailable");};
        assertThrows(IllegalStateException.class,()->f.credentials.processAction(f.required));assertTrue(f.actions.isEmpty());
        f.store.beforeClaim=key->{};f.credentials.processAction(f.required);
        assertTrue(f.actions.isEmpty());verify(f.required).failure(anyString());
    }
    @Test void challengeRequiresBoundCredentialStage() {
        var f=new AfterSignUpFixture();f.start();f.stage(AfterSignUpState.Stage.CREDENTIALS);
        f.credentials.requiredActionChallenge(f.required);verify(f.form).createForm(SignUpCredentialsRequiredAction.TEMPLATE);
    }
}
