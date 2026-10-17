package com.skylab.passkey;

import com.skylab.account.EmailCodeSignUp;
import java.time.Duration;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.keycloak.authentication.AuthenticationFlowError;
import org.keycloak.models.Constants;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class SkyAfterLoginAuthenticatorTest {
    @Test void offKeepsExistingAccountCenterSkip() {
        var f=new AfterSignUpFixture();when(f.realm.getAttribute(AfterSignUpState.FEATURE_ATTRIBUTE)).thenReturn(null);
        f.authenticator.authenticate(f.flow);
        verify(f.flow).success();assertFalse(f.authNotes.containsKey(AfterSignUpState.NOTE));
    }
    @Test void nonSignupKeepsThirtyDayDismissal() {
        var f=new AfterSignUpFixture();f.authNotes.clear();when(f.client.getClientId()).thenReturn("another-client");
        when(f.user.getFirstAttribute(PasskeyOfferAuthenticator.ATTR_DISMISSED_AT)).thenReturn(Long.toString(System.currentTimeMillis()-Duration.ofDays(29).toMillis()));
        f.authenticator.authenticate(f.flow);
        verify(f.flow).success();verify(f.form,never()).createForm(anyString());
    }
    @Test void nonSignupOlderDismissalStillOffersExistingPasskeyForm() {
        var f=new AfterSignUpFixture();f.authNotes.clear();when(f.client.getClientId()).thenReturn("another-client");
        when(f.user.getFirstAttribute(PasskeyOfferAuthenticator.ATTR_DISMISSED_AT)).thenReturn(Long.toString(System.currentTimeMillis()-Duration.ofDays(31).toMillis()));
        f.authenticator.authenticate(f.flow);
        verify(f.form).createForm("passkey-offer.ftl");verify(f.flow).challenge(f.response);
    }
    @Test void signedUpTrustedClientShowsSchoolFirstAndConsumesMarker() {
        var f=new AfterSignUpFixture();f.authenticator.authenticate(f.flow);
        verify(f.form).createForm(SkyAfterLoginAuthenticator.TEMPLATE);
        assertEquals(AfterSignUpState.Stage.SCHOOL,f.state().stage());
        assertNull(f.authNotes.get(EmailCodeSignUp.SIGNED_UP_NOTE));assertTrue(f.actions.isEmpty());
        verify(f.form,never()).createForm("passkey-offer.ftl");
    }
    @ParameterizedTest @ValueSource(strings={"disabled-client","non-browser","protocol","page2-ra","foreign-action"})
    void unsupportedSignupFailsClosedWithoutFallbackOrGrant(String missing) {
        var f=new AfterSignUpFixture();
        switch(missing) {
            case "disabled-client"->when(f.client.isEnabled()).thenReturn(false);
            case "non-browser"->when(f.client.isStandardFlowEnabled()).thenReturn(false);
            case "protocol"->when(f.client.getProtocol()).thenReturn("saml");
            case "page2-ra"->when(f.realm.getRequiredActionProviderByAlias(SignUpCredentialsRequiredAction.PROVIDER_ID)).thenReturn(null);
            case "foreign-action"->f.clientNotes.put(Constants.KC_ACTION,"UPDATE_PASSWORD");
        }
        f.authenticator.authenticate(f.flow);
        verify(f.flow).failure(AuthenticationFlowError.GENERIC_AUTHENTICATION_ERROR);
        verify(f.flow,never()).success();assertTrue(f.actions.isEmpty());
        verify(f.user,never()).grantRole(any());
    }
    @Test void linkUsesOnlyNativeClientNotesAndDelaysPageTwo() {
        var f=new AfterSignUpFixture();f.start();f.body.putSingle(SkyAfterLoginAuthenticator.CHOICE,"link");
        f.authenticator.action(f.flow);
        assertEquals(AfterSignUpState.Stage.LINK_PENDING,f.state().stage());
        assertEquals("idp_link",f.clientNotes.get(Constants.KC_ACTION));assertEquals("OBS",f.clientNotes.get(Constants.KC_ACTION_PARAMETER));
        assertFalse(f.clientNotes.containsKey(Constants.KC_ACTION_ENFORCED));assertTrue(f.actions.isEmpty());
        verify(f.flow).success();verify(f.auth,never()).setRedirectUri(anyString());
    }
    @Test void skipSchedulesOnlySessionCredentialsAndNotDismissal() {
        var f=new AfterSignUpFixture();f.start();f.body.putSingle(SkyAfterLoginAuthenticator.CHOICE,"skip");
        f.authenticator.action(f.flow);
        assertEquals(AfterSignUpState.Stage.CREDENTIALS,f.state().stage());
        assertEquals(java.util.Set.of(SignUpCredentialsRequiredAction.PROVIDER_ID),f.actions);
        verify(f.user,never()).addRequiredAction(anyString());verify(f.user,never()).setSingleAttribute(anyString(),anyString());
    }
    @Test void unexpectedOrDuplicatedChoiceDoesNotAdvance() {
        var f=new AfterSignUpFixture();f.start();f.body.add(SkyAfterLoginAuthenticator.CHOICE,"skip");f.body.add(SkyAfterLoginAuthenticator.CHOICE,"link");
        f.authenticator.action(f.flow);
        assertEquals(AfterSignUpState.Stage.SCHOOL,f.state().stage());assertTrue(f.clientNotes.isEmpty());assertTrue(f.actions.isEmpty());
        verify(f.flow).challenge(f.response);
    }
    @Test void invalidSessionStateFailsClosedRatherThanBecomingLoginOffer() {
        var f=new AfterSignUpFixture();f.start();f.now.addAndGet(600);
        f.authenticator.action(f.flow);
        verify(f.flow).failure(AuthenticationFlowError.GENERIC_AUTHENTICATION_ERROR);
        verify(f.form,never()).createForm("passkey-offer.ftl");assertTrue(f.actions.isEmpty());
    }
    @Test void doneInThisSignupDoesNotShowExistingOfferAgain() {
        var f=new AfterSignUpFixture();f.start();f.stage(AfterSignUpState.Stage.CREDENTIALS);f.stage(AfterSignUpState.Stage.DONE);
        f.authenticator.authenticate(f.flow);
        verify(f.flow).success();verify(f.form,never()).createForm(anyString());
    }

    @Test void nullOrMalformedSignupStateFailsWithoutOverwritingNativeNotes() {
        var f=new AfterSignUpFixture();when(f.flow.getAuthenticationSession()).thenReturn(null);
        f.authenticator.authenticate(f.flow);verify(f.flow).failure(AuthenticationFlowError.GENERIC_AUTHENTICATION_ERROR);
        var other=new AfterSignUpFixture();other.authNotes.put(AfterSignUpState.NOTE,"bad-json");other.clientNotes.put(Constants.KC_ACTION,"UPDATE_PASSWORD");
        other.authenticator.authenticate(other.flow);verify(other.flow).failure(AuthenticationFlowError.GENERIC_AUTHENTICATION_ERROR);
        assertEquals("UPDATE_PASSWORD",other.clientNotes.get(Constants.KC_ACTION));assertTrue(other.actions.isEmpty());
    }
    @Test void ordinaryExistingLoginActionStillUsesThirtyDayOfferHandler() {
        var f=new AfterSignUpFixture();f.authNotes.clear();when(f.client.getClientId()).thenReturn("another-client");f.body.putSingle("passkey-choice","no");
        f.authenticator.action(f.flow);
        verify(f.user).setSingleAttribute(eq(PasskeyOfferAuthenticator.ATTR_DISMISSED_AT),anyString());
        assertFalse(f.authNotes.containsKey(AfterSignUpState.NOTE));verify(f.flow).success();
    }

    @Test void pendingLinkCannotSilentlyBecomeAnotherAia() {
        var f=new AfterSignUpFixture();f.start();f.stage(AfterSignUpState.Stage.LINK_PENDING);
        f.clientNotes.put(Constants.KC_ACTION,"UPDATE_PASSWORD");f.clientNotes.put(Constants.KC_ACTION_PARAMETER,"OBS");
        f.authenticator.authenticate(f.flow);verify(f.flow).failure(AuthenticationFlowError.GENERIC_AUTHENTICATION_ERROR);
        assertEquals("UPDATE_PASSWORD",f.clientNotes.get(Constants.KC_ACTION));assertTrue(f.actions.isEmpty());
    }

    @ParameterizedTest @ValueSource(strings={"role","scope","idp","native-ra"})
    void genericRpCanSkipDeferredSchoolLinkAndReachCredentials(String unavailable) {
        var f=new AfterSignUpFixture();when(f.client.getClientId()).thenReturn("frontend-main");
        switch(unavailable) {
            case "role"->when(f.user.hasRole(f.role)).thenReturn(false);
            case "scope"->when(f.client.hasScope(f.role)).thenReturn(false);
            case "idp"->when(f.session.identityProviders().getByAlias("OBS")).thenReturn(null);
            case "native-ra"->when(f.realm.getRequiredActionProviderByAlias("idp_link")).thenReturn(null);
        }
        f.authenticator.authenticate(f.flow);
        verify(f.form).setAttribute("skyYtuLinkAvailable",false);
        assertEquals(AfterSignUpState.Stage.SCHOOL,f.state().stage());
        f.body.putSingle(SkyAfterLoginAuthenticator.CHOICE,"skip");f.authenticator.action(f.flow);
        assertEquals(AfterSignUpState.Stage.CREDENTIALS,f.state().stage());
        assertEquals(java.util.Set.of(SignUpCredentialsRequiredAction.PROVIDER_ID),f.actions);
        assertTrue(f.clientNotes.isEmpty());verify(f.user,never()).grantRole(any());
    }
    @Test void unavailableNativeLinkChoiceStaysOnSchoolPageWithoutFalseSuccess() {
        var f=new AfterSignUpFixture();when(f.client.getClientId()).thenReturn("frontend-main");when(f.client.hasScope(f.role)).thenReturn(false);
        f.authenticator.authenticate(f.flow);int claims=f.store.values.size();f.body.putSingle(SkyAfterLoginAuthenticator.CHOICE,"link");f.authenticator.action(f.flow);
        assertEquals(claims,f.store.values.size());
        assertEquals(AfterSignUpState.Stage.SCHOOL,f.state().stage());assertTrue(f.clientNotes.isEmpty());assertTrue(f.actions.isEmpty());
        verify(f.flow,times(2)).challenge(f.response);verify(f.flow,never()).success();verify(f.flow,never()).failure(any());
    }
    @Test void factoryHasStableIdAndDoesNotActivateOrGrantAnything() {
        var factory=new SkyAfterLoginAuthenticatorFactory();
        assertEquals("sky-after-login",factory.getId());assertFalse(factory.isConfigurable());assertTrue(factory.create(null) instanceof SkyAfterLoginAuthenticator);
    }
}
