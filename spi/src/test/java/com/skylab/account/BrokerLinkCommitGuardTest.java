package com.skylab.account;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.keycloak.broker.provider.BrokeredIdentityContext;
import org.keycloak.broker.provider.IdentityBrokerException;
import org.keycloak.common.util.Time;
import org.keycloak.connections.jpa.JpaConnectionProvider;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.keycloak.models.*;
import org.keycloak.sessions.AuthenticationSessionModel;
import org.keycloak.sessions.RootAuthenticationSessionModel;

import java.util.HashMap;
import java.util.Map;
import java.util.List;
import java.util.concurrent.ConcurrentHashMap;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class BrokerLinkCommitGuardTest {
    private final KeycloakSession session = mock(KeycloakSession.class);
    private final RealmModel realm = mock(RealmModel.class);
    private final UserModel user = mock(UserModel.class);
    private final UserProvider users = mock(UserProvider.class);
    private final KeycloakTransactionManager tx = mock(KeycloakTransactionManager.class);
    private final AuthenticationSessionModel auth = mock(AuthenticationSessionModel.class);
    private final SingleUseObjectProvider store = mock(SingleUseObjectProvider.class);
    private final Map<String, Map<String, String>> entries = new ConcurrentHashMap<>();
    private final Map<String, String> notes = new HashMap<>();
    private BrokeredIdentityContext broker;
    private final Query subjectClaim = mock(Query.class, RETURNS_SELF);
    private final Query subjectOwners = mock(Query.class, RETURNS_SELF);
    private final LoginCodeFailureCounter failures = mock(LoginCodeFailureCounter.class);
    private final LoginCodeFailureCounter.Guard persistent = mock(LoginCodeFailureCounter.Guard.class);

    @AfterEach
    void resetClock() { Time.setOffset(0); }

    @BeforeEach
    void setup() {
        when(failures.lock(session, realm, "target")).thenReturn(persistent);
        when(session.singleUseObjects()).thenReturn(store);
        when(session.getTransactionManager()).thenReturn(tx);
        when(session.users()).thenReturn(users);
        when(store.get(anyString())).thenAnswer(c -> entries.get(c.getArgument(0)));
        when(store.remove(anyString())).thenAnswer(c -> entries.remove(c.getArgument(0)));
        doAnswer(c -> entries.put(c.getArgument(0), Map.copyOf(c.getArgument(2))))
                .when(store).put(anyString(), anyLong(), anyMap());
        when(auth.getAuthNote(anyString())).thenAnswer(c -> notes.get(c.getArgument(0)));
        doAnswer(c -> notes.remove(c.getArgument(0))).when(auth).removeAuthNote(anyString());
        when(realm.getId()).thenReturn("realm");
        AuthenticationFlowModel flow = new AuthenticationFlowModel(); flow.setId("first-broker");
        when(realm.getFirstBrokerLoginFlow()).thenReturn(flow);
        AuthenticationExecutionModel prompt = new AuthenticationExecutionModel();
        prompt.setAuthenticator(SkyExistingAccountPrompt.PROVIDER_ID);
        prompt.setRequirement(AuthenticationExecutionModel.Requirement.REQUIRED);
        when(realm.getAuthenticationExecutionsStream("first-broker")).thenAnswer(c -> java.util.stream.Stream.of(prompt));
        var jpa = mock(JpaConnectionProvider.class); var em = mock(EntityManager.class);
        when(session.getProvider(JpaConnectionProvider.class)).thenReturn(jpa); when(jpa.getEntityManager()).thenReturn(em);
        when(em.createNativeQuery(contains("pg_try_advisory"))).thenReturn(subjectClaim);
        when(em.createNativeQuery(contains("FEDERATED_IDENTITY"))).thenReturn(subjectOwners);
        when(subjectClaim.getSingleResult()).thenReturn(true);
        when(subjectOwners.getResultList()).thenReturn(List.of("target"));
        when(user.getId()).thenReturn("target");
        var root = mock(RootAuthenticationSessionModel.class);
        var client = mock(ClientModel.class);
        when(root.getId()).thenReturn("root");
        when(client.getClientId()).thenReturn("client");
        when(auth.getParentSession()).thenReturn(root);
        when(auth.getClient()).thenReturn(client);
        when(auth.getTabId()).thenReturn("tab");
        IdentityProviderModel idp = new IdentityProviderModel();
        idp.setAlias("OBS"); idp.setEnabled(true);
        broker = new BrokeredIdentityContext("subject", idp);
        broker.setAuthenticationSession(auth);
        broker.setUserAttribute("schoolEmail", "school@std.yildiz.edu.tr");
        broker.setFirstName("Microsoft"); broker.setLastName("Name");
        FederatedIdentityModel link = new FederatedIdentityModel("OBS", "subject", "school@std.yildiz.edu.tr");
        when(users.getFederatedIdentity(realm, user, "OBS")).thenReturn(link);
        when(users.getUserByFederatedIdentity(realm, link)).thenReturn(user);
    }

    private BrokerLinkCommitGuard.Snapshot snapshot() {
        return new BrokerLinkCommitGuard.Snapshot(true, "primary@example.org", null, "realm", "");
    }

    private void check(BrokerLinkCommitGuard.Snapshots snapshots) {
        BrokerLinkCommitGuard.check(session, realm, user, broker, snapshots, failures);
    }

    private void proof() {
        proof("email_code");
    }

    private void proof(String method) {
        notes.put(BrokerLinkState.REQUIRED, "true"); notes.put(BrokerLinkState.PROOF, "handle");
        new BrokerLinkProofs(store).issueProof("handle",
                BrokerLinkState.binding(realm, auth, broker, user, "primary@example.org"), "", method,
                Time.currentTime() + 600);
    }

    @Test
    void anEmailProofCannotCommitWhenAnotherRequestHasReached100() {
        proof();
        when(persistent.blocked()).thenReturn(true);
        assertThrows(IdentityBrokerException.class, () -> check((s, r, u) -> snapshot()));
        verify(tx).setRollbackOnly();
        verify(user, never()).setFirstName(any());
        verify(user, never()).setLastName(any());
    }

    @Test
    void aPasswordOrPasskeyProofRemainsAvailableForABlockedEmailAccount() {
        proof("password_or_passkey");
        when(persistent.blocked()).thenReturn(true);
        assertDoesNotThrow(() -> check((s, r, u) -> snapshot()));
        verifyNoInteractions(failures);
        verify(user).setFirstName("Microsoft");
        verify(tx, never()).setRollbackOnly();
    }

    @Test
    void anUnavailableCounterRollsBackAnEmailProvenCallbackBeforeTrustedNamesAreWritten() {
        proof();
        when(failures.lock(session, realm, "target")).thenThrow(new IllegalStateException("fixture"));
        assertThrows(IdentityBrokerException.class, () -> check((s, r, u) -> snapshot()));
        verify(tx).setRollbackOnly();
        verify(user, never()).setFirstName(any());
    }

    @Test
    void ordinaryLinkedLoginNativeDuplicateAndA6DoNotEnterTheGuard() {
        when(realm.getFirstBrokerLoginFlow()).thenReturn(null);
        check((s, r, u) -> {
            fail("No lock or snapshot may run outside the prompt's marked path"); return null;
        });
        verifyNoInteractions(tx, store);
    }

    @Test
    void callbackConsumesProofAndUsesTrustedNamesWithoutWritingPrimaryOrVerified() {
        proof();
        check((s, r, u) -> snapshot());
        verify(user).setFirstName("Microsoft"); verify(user).setLastName("Name");
        verify(user, never()).setEmail(any()); verify(user, never()).setEmailVerified(anyBoolean());
        verify(tx, never()).setRollbackOnly();
        assertNull(new BrokerLinkProofs(store).peekProof("handle"));
        assertNull(notes.get(BrokerLinkState.REQUIRED));
    }

    @Test
    void primaryChangingBetweenFlowAndCallbackRollsBackTheNativeLinkTransaction() {
        proof();
        assertThrows(IdentityBrokerException.class, () -> check(
                (s, r, u) -> new BrokerLinkCommitGuard.Snapshot(true, "new@example.org", null, "realm", "")));
        verify(tx).setRollbackOnly();
        verify(user, never()).setFirstName(any()); verify(user, never()).setLastName(any());
    }

    @Test
    void disabledTargetAndChangedOtpCannotCommitALink() {
        proof();
        assertThrows(IdentityBrokerException.class, () -> check(
                (s, r, u) -> new BrokerLinkCommitGuard.Snapshot(false, "primary@example.org", null, "realm", "")));
        verify(tx).setRollbackOnly();
        reset(tx);
        proof();
        assertThrows(IdentityBrokerException.class, () -> check(
                (s, r, u) -> new BrokerLinkCommitGuard.Snapshot(true, "primary@example.org", null, "realm", "new-otp")));
        verify(tx).setRollbackOnly();
    }

    @Test
    void missingExpiredOrReplayedProofIsABlockingRollback() {
        proof();
        new BrokerLinkProofs(store).consumeProof("handle");
        assertThrows(IdentityBrokerException.class,
                () -> check((s, r, u) -> snapshot()));
        verify(tx).setRollbackOnly();
    }

    @Test
    void aPresentMalformedMarkerOrProofWithoutRequiredNeverFallsBackToNative() {
        for (String malformed : List.of("false", "broken", "")) {
            notes.clear(); reset(tx);
            notes.put(BrokerLinkState.REQUIRED, malformed);
            assertThrows(IdentityBrokerException.class,
                    () -> check((s, r, u) -> snapshot()));
            verify(tx).setRollbackOnly();
        }
        notes.clear(); reset(tx);
        notes.put(BrokerLinkState.PROOF, "orphaned-proof");
        assertThrows(IdentityBrokerException.class,
                () -> check((s, r, u) -> snapshot()));
        verify(tx).setRollbackOnly();
    }

    @Test
    void aProofExpiringWhileTheCallbackWaitsForTheTargetLockCannotCommit() {
        proof();
        assertThrows(IdentityBrokerException.class, () -> check(
                (s, r, u) -> {
                    Time.setOffset(BrokerLinkProofs.PROOF_TTL_SECONDS + 1);
                    return snapshot();
                }));
        verify(tx).setRollbackOnly();
        verify(user, never()).setFirstName(any());
    }

    @Test
    void featureOnNativeAndA6CallbacksJoinOnlyTheNarrowSubjectGuard() {
        check((s, r, u) -> {
            fail("An unmarked native callback must not take the proof target/factor locks"); return null;
        });
        verify(subjectClaim).getSingleResult(); verify(subjectOwners).getResultList();
        verify(user, never()).setFirstName(any()); verify(tx, never()).setRollbackOnly();
    }

    @Test
    void subjectBusyOrTwoSubjectOwnersRollBackTheLinkInsteadOfWaiting() {
        when(subjectClaim.getSingleResult()).thenReturn(false);
        assertThrows(IdentityBrokerException.class,
                () -> check((s, r, u) -> snapshot()));
        verify(tx).setRollbackOnly(); verify(subjectOwners, never()).getResultList();
        reset(tx); when(subjectClaim.getSingleResult()).thenReturn(true);
        when(subjectOwners.getResultList()).thenReturn(List.of("target", "other-target"));
        assertThrows(IdentityBrokerException.class,
                () -> check((s, r, u) -> snapshot()));
        verify(tx).setRollbackOnly();
    }

    @Test
    void aProofExpiringAfterTheHookStillVetoesTheDatabaseCommitInThePreparePhase() {
        proof();
        check((s, r, u) -> snapshot());
        var prepare = org.mockito.ArgumentCaptor.forClass(KeycloakTransaction.class);
        verify(tx).enlistPrepare(prepare.capture());
        prepare.getValue().begin();
        Time.setOffset(BrokerLinkProofs.PROOF_TTL_SECONDS + 1);
        assertThrows(IdentityBrokerException.class, () -> prepare.getValue().commit());
        verify(tx).setRollbackOnly();
    }

    @Test
    void aPendingProofCannotSurviveOperatorOffOrAChangedEffectiveBrokerFlow() {
        proof(); when(realm.getFirstBrokerLoginFlow()).thenReturn(null);
        assertThrows(IdentityBrokerException.class,
                () -> check((s, r, u) -> snapshot()));
        verify(tx).setRollbackOnly(); reset(tx);
        AuthenticationFlowModel flow = new AuthenticationFlowModel(); flow.setId("first-broker");
        when(realm.getFirstBrokerLoginFlow()).thenReturn(flow);
        proof();
        assertThrows(IdentityBrokerException.class, () -> check(
                (s, r, u) -> new BrokerLinkCommitGuard.Snapshot(true, "primary@example.org", null, "realm", "", false)));
        verify(tx).setRollbackOnly();
    }
}
