package com.skylab.account;

import org.junit.jupiter.api.Test;
import org.keycloak.authentication.AuthenticationFlowContext;
import org.keycloak.authentication.AuthenticationFlowError;
import org.keycloak.authentication.AuthenticationFlowException;
import org.keycloak.authentication.authenticators.broker.AbstractIdpAuthenticator;
import org.keycloak.authentication.authenticators.broker.IdpCreateUserIfUniqueAuthenticator;
import org.keycloak.authentication.authenticators.broker.util.ExistingUserInfo;
import org.keycloak.authentication.authenticators.broker.util.SerializedBrokeredIdentityContext;
import org.keycloak.broker.provider.AbstractIdentityProvider;
import org.keycloak.broker.provider.BrokeredIdentityContext;
import org.keycloak.models.IdentityProviderModel;
import org.keycloak.models.IdentityProviderSyncMode;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;
import org.keycloak.models.UserProvider;
import org.keycloak.sessions.AuthenticationSessionModel;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.anyBoolean;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

/**
 * Probes the pinned Keycloak 26.7.4 classes before the first-broker-login integration is built.
 * In particular, a candidate note is not proof, and a missing brokered e-mail must preserve both
 * the existing Primary e-mail and its verification flag even for a FORCE identity provider.
 */
class BrokerLinkNativeMechanicsTest {

    @Test
    void theStockCandidateNoteRoundTripsTheImmutableTargetId() {
        ExistingUserInfo candidate = new ExistingUserInfo("target-id", UserModel.USERNAME, "ada.example");

        ExistingUserInfo read = ExistingUserInfo.deserialize(candidate.serialize());

        assertEquals("target-id", read.getExistingUserId());
        assertEquals(UserModel.USERNAME, read.getDuplicateAttributeName());
        assertEquals("ada.example", read.getDuplicateAttributeValue());
    }

    @Test
    void aCandidateMakesStockCreateUserAttemptedAndDoesNotAuthenticateOrCreateAnybody() {
        AuthenticationFlowContext context = mock(AuthenticationFlowContext.class);
        AuthenticationSessionModel authSession = mock(AuthenticationSessionModel.class);
        KeycloakSession session = mock(KeycloakSession.class);
        RealmModel realm = mock(RealmModel.class);
        UserProvider users = mock(UserProvider.class);
        when(context.getSession()).thenReturn(session);
        when(context.getRealm()).thenReturn(realm);
        when(context.getAuthenticationSession()).thenReturn(authSession);
        when(session.users()).thenReturn(users);
        when(authSession.getAuthNote(AbstractIdpAuthenticator.EXISTING_USER_INFO))
                .thenReturn(new ExistingUserInfo("target-id", UserModel.USERNAME, "ada.example").serialize());

        new CreateUserProbe().run(context);

        verify(context).attempted();
        verify(context, never()).success();
        verify(context, never()).setUser(org.mockito.ArgumentMatchers.any());
        verifyNoInteractions(users);
    }

    @Test
    void theStockCandidateLookupRejectsADisabledTarget() {
        AuthenticationSessionModel authSession = mock(AuthenticationSessionModel.class);
        KeycloakSession session = mock(KeycloakSession.class);
        RealmModel realm = mock(RealmModel.class);
        UserProvider users = mock(UserProvider.class);
        UserModel target = mock(UserModel.class);
        when(session.users()).thenReturn(users);
        when(authSession.getAuthNote(AbstractIdpAuthenticator.EXISTING_USER_INFO))
                .thenReturn(new ExistingUserInfo("target-id", UserModel.USERNAME, "ada.example").serialize());
        when(users.getUserById(realm, "target-id")).thenReturn(target);
        when(target.isEnabled()).thenReturn(false);

        AuthenticationFlowException refused = assertThrows(AuthenticationFlowException.class,
                () -> AbstractIdpAuthenticator.getExistingUser(session, realm, authSession));

        assertEquals(AuthenticationFlowError.USER_DISABLED, refused.getError());
    }

    @Test
    void aNullBrokerEmailDoesNotWritePrimaryOrVerifiedEvenWithForceSync() {
        IdentityProviderModel idp = new IdentityProviderModel();
        idp.setAlias("OBS");
        idp.setEnabled(true);
        idp.setSyncMode(IdentityProviderSyncMode.FORCE);
        KeycloakSession session = mock(KeycloakSession.class);
        RealmModel realm = mock(RealmModel.class);
        UserModel target = mock(UserModel.class);
        BrokeredIdentityContext broker = new BrokeredIdentityContext("microsoft-subject", idp);
        broker.setAuthenticationSession(mock(AuthenticationSessionModel.class));
        broker.setFirstName("Microsoft Given");
        broker.setLastName("Microsoft Surname");
        broker.setUserAttribute("schoolEmail", "school@std.yildiz.edu.tr");
        broker.setEmail(null);

        new ProviderProbe(session, idp)
                .updateBrokeredUser(session, realm, target, broker);

        verify(target, never()).setEmail(anyString());
        verify(target, never()).setEmailVerified(anyBoolean());
        assertEquals("Microsoft Given", broker.getFirstName());
        assertEquals("Microsoft Surname", broker.getLastName());
        assertEquals("school@std.yildiz.edu.tr", broker.getUserAttribute("schoolEmail"));
    }

    @Test
    void forceSyncWouldOverwritePrimaryIfTheBrokerStillCarriedAnEmail() {
        IdentityProviderModel idp = new IdentityProviderModel();
        idp.setAlias("OBS");
        idp.setEnabled(true);
        idp.setSyncMode(IdentityProviderSyncMode.FORCE);
        idp.setTrustEmail(true);
        KeycloakSession session = mock(KeycloakSession.class);
        RealmModel realm = mock(RealmModel.class);
        UserModel target = mock(UserModel.class);
        BrokeredIdentityContext broker = new BrokeredIdentityContext("microsoft-subject", idp);
        broker.setAuthenticationSession(mock(AuthenticationSessionModel.class));
        broker.setEmail("school@std.yildiz.edu.tr");

        new ProviderProbe(session, idp)
                .updateBrokeredUser(session, realm, target, broker);

        verify(target).setEmail("school@std.yildiz.edu.tr");
    }

    private static final class CreateUserProbe extends IdpCreateUserIfUniqueAuthenticator {
        void run(AuthenticationFlowContext context) {
            authenticateImpl(context, new SerializedBrokeredIdentityContext(), null);
        }
    }

    private static final class ProviderProbe extends AbstractIdentityProvider<IdentityProviderModel> {
        ProviderProbe(KeycloakSession session, IdentityProviderModel idp) {
            super(session, idp);
        }

        @Override
        public jakarta.ws.rs.core.Response retrieveToken(KeycloakSession session,
                org.keycloak.models.FederatedIdentityModel identity) {
            throw new UnsupportedOperationException("This probe never retrieves a token");
        }

        @Override
        public jakarta.ws.rs.core.Response retrieveToken(KeycloakSession session,
                org.keycloak.models.FederatedIdentityModel identity,
                org.keycloak.models.UserSessionModel userSession, UserModel user) {
            throw new UnsupportedOperationException("This probe never retrieves a token");
        }
    }
}
