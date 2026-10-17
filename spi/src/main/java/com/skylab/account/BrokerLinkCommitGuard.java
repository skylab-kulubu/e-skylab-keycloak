package com.skylab.account;

import jakarta.persistence.FlushModeType;
import org.keycloak.broker.provider.BrokeredIdentityContext;
import org.keycloak.broker.provider.IdentityBrokerException;
import org.keycloak.connections.jpa.JpaConnectionProvider;
import org.keycloak.common.util.Time;
import org.keycloak.models.FederatedIdentityModel;
import org.keycloak.models.AuthenticationExecutionModel;
import org.keycloak.models.AbstractKeycloakTransaction;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;
import org.keycloak.models.jpa.entities.UserEntity;
import org.keycloak.services.managers.BruteForceProtector;
import org.keycloak.sessions.AuthenticationSessionModel;

import java.util.List;

/**
 * Vetoes a prompt-proven link in the native broker callback transaction, after Keycloak inserted
 * the link and before that transaction commits. A flow proof alone is insufficient: the callback
 * is another HTTP request and the target may have changed since the last challenge.
 */
public final class BrokerLinkCommitGuard {
    record Snapshot(boolean enabled, String primary, String serviceAccount, String realm, String otp,
                    boolean protectionEnabled) {
        Snapshot(boolean enabled, String primary, String serviceAccount, String realm, String otp) {
            this(enabled, primary, serviceAccount, realm, otp, true);
        }
    }

    @FunctionalInterface
    interface Snapshots { Snapshot locked(KeycloakSession session, RealmModel realm, UserModel user); }

    private BrokerLinkCommitGuard() { }

    /** Ordinary linked logins, native duplicates and A6 have no marker and keep native behaviour. */
    public static void check(KeycloakSession session, RealmModel realm, UserModel user,
                             BrokeredIdentityContext broker) {
        check(session, realm, user, broker, BrokerLinkCommitGuard::lockedSnapshot);
    }

    static void check(KeycloakSession session, RealmModel realm, UserModel user,
                      BrokeredIdentityContext broker, Snapshots snapshots) {
        check(session, realm, user, broker, snapshots, new PersistentLoginCodeFailures());
    }

    static void check(KeycloakSession session, RealmModel realm, UserModel user,
                      BrokeredIdentityContext broker, Snapshots snapshots, LoginCodeFailureCounter failures) {
        AuthenticationSessionModel auth = broker.getAuthenticationSession();
        boolean marked = auth != null && (auth.getAuthNote(BrokerLinkState.REQUIRED) != null
                || auth.getAuthNote(BrokerLinkState.PROOF) != null);
        boolean active = enabled(realm);
        if (!active && !marked) return;
        try {
            if (!active) throw refused(); // A pending proof cannot outlive turning the protection off.
            protectSubject(session, realm, user, broker);
            if (!marked) return; // Native/A6 callbacks share the subject guard, their semantics stay native.
            if (!"true".equals(auth.getAuthNote(BrokerLinkState.REQUIRED))) throw refused();
            if (!LoginIdentifiers.ytuIdpAlias(null).equals(broker.getIdpConfig().getAlias())) throw refused();
            BrokerLinkProofs.Proof proof = new BrokerLinkProofs(session.singleUseObjects())
                    .consumeProof(auth.getAuthNote(BrokerLinkState.PROOF));
            if (proof == null || !proof.binding().target().equals(user.getId())) throw refused();
            Snapshot fresh = snapshots.locked(session, realm, user);
            if (fresh == null || !fresh.enabled() || !fresh.protectionEnabled() || fresh.serviceAccount() != null
                    || !realm.getId().equals(fresh.realm()) || realm.isDuplicateEmailsAllowed()
                    || !proof.otpCredentials().equals(fresh.otp())
                    || !proof.binding().equals(BrokerLinkState.binding(realm, auth, broker, user, fresh.primary()))
                    || !broker.getIdpConfig().isEnabled()) throw refused();
            // The callback is a separate HTTP transaction from the code/TOTP proof. The existing
            // target lock is held; read the same persistent counter again before accepting the link.
            if ("email_code".equals(proof.method())) {
                LoginCodeFailureCounter.Guard persistent = failures.lock(session, realm, user.getId());
                if (persistent == null || persistent.blocked()) throw refused();
            }
            BruteForceProtector protector = session.getProvider(BruteForceProtector.class);
            if (realm.isBruteForceProtected() && (protector == null
                    || protector.isTemporarilyDisabled(session, realm, user)
                    || protector.isPermanentlyLockedOut(session, realm, user))) throw refused();
            FederatedIdentityModel link = session.users().getFederatedIdentity(realm, user, proof.binding().provider());
            if (link == null || !proof.binding().subject().equals(link.getUserId())) throw refused();
            UserModel owner = session.users().getUserByFederatedIdentity(realm, link);
            if (owner == null || !user.getId().equals(owner.getId())) throw refused();
            // The database row lock and its fresh queries can wait; consuming a still-live proof
            // before that wait must not extend its fixed deadline across the callback.
            if (proof.expiresAt() <= Time.currentTime()) throw refused();

            // LEGACY does not sync first/last names for an existing account. Once this link makes
            // the account a Verified YTÜ account, its locked name must be Microsoft's proven name.
            if (proof.binding().firstName().isBlank() || proof.binding().lastName().isBlank()) throw refused();
            // The department mapper may call Graph after this hook. The same fixed deadline is
            // checked in Keycloak's prepare phase, before the JPA transaction can commit the link.
            session.getTransactionManager().enlistPrepare(new AbstractKeycloakTransaction() {
                @Override protected void commitImpl() {
                    if (proof.expiresAt() <= Time.currentTime()) {
                        session.getTransactionManager().setRollbackOnly();
                        throw refused();
                    }
                }
                @Override protected void rollbackImpl() { }
            });
            broker.setEmail(null); // FORCE must preserve primary and the existing verification flag.
            user.setFirstName(proof.binding().firstName());
            user.setLastName(proof.binding().lastName());
            auth.removeAuthNote(BrokerLinkState.REQUIRED);
            auth.removeAuthNote(BrokerLinkState.PROOF);
        } catch (RuntimeException failed) {
            session.getTransactionManager().setRollbackOnly();
            throw refused();
        }
    }

    private static IdentityBrokerException refused() {
        return new IdentityBrokerException("The existing account link could not be verified");
    }

    static boolean enabled(RealmModel realm) {
        var flow = realm.getFirstBrokerLoginFlow();
        return flow != null && realm.getAuthenticationExecutionsStream(flow.getId()).anyMatch(e ->
                SkyExistingAccountPrompt.PROVIDER_ID.equals(e.getAuthenticator())
                        && e.getRequirement() == AuthenticationExecutionModel.Requirement.REQUIRED);
    }

    /**
     * Keycloak's PK is provider+local user, not provider+external subject. While this feature is
     * active, every Microsoft callback (including native/A6) joins this narrow transaction guard.
     * Try-lock instead of waiting: native insertion already holds a user FK (and FORCE can have
     * written names), so waiting for another callback's subject lock could invert lock order.
     * PostgreSQL only; unsupported databases fail closed here, never fall back to an unlocked read.
     */
    private static void protectSubject(KeycloakSession session, RealmModel realm, UserModel user,
                                       BrokeredIdentityContext broker) {
        JpaConnectionProvider jpa = session.getProvider(JpaConnectionProvider.class);
        if (jpa == null || broker.getId() == null || broker.getId().isBlank()) throw refused();
        var em = jpa.getEntityManager();
        String scope = "sky-broker-subject:" + realm.getId().length() + ":" + realm.getId()
                + ":" + broker.getIdpConfig().getAlias().length() + ":" + broker.getIdpConfig().getAlias()
                + ":" + broker.getId().length() + ":" + broker.getId();
        Object claimed = em.createNativeQuery("select pg_try_advisory_xact_lock(hashtextextended(:scope,0))")
                .setFlushMode(FlushModeType.COMMIT).setParameter("scope", scope).getSingleResult();
        if (!Boolean.TRUE.equals(claimed)) throw refused();
        List<?> owners = em.createNativeQuery("select USER_ID from FEDERATED_IDENTITY where REALM_ID=:realm"
                        + " and IDENTITY_PROVIDER=:provider and FEDERATED_USER_ID=:subject")
                .setFlushMode(FlushModeType.COMMIT).setParameter("realm", realm.getId())
                .setParameter("provider", broker.getIdpConfig().getAlias()).setParameter("subject", broker.getId())
                .getResultList();
        if (owners.size() != 1 || !user.getId().equals(owners.getFirst())) throw refused();
    }

    /** Target and existing OTP rows only; never acquire EmailAddressOwnership's realm lock here. */
    private static Snapshot lockedSnapshot(KeycloakSession session, RealmModel realm, UserModel user) {
        JpaConnectionProvider jpa = session.getProvider(JpaConnectionProvider.class);
        if (jpa == null) throw refused();
        var em = jpa.getEntityManager();
        // Explicit FOR UPDATE also blocks an OTP insert's FK KEY SHARE; a dialect's weaker
        // FOR NO KEY UPDATE would allow a new second factor after our empty-factor snapshot.
        if (em.createNativeQuery("select ID from USER_ENTITY where ID=:id and REALM_ID=:realm for update nowait")
                .setFlushMode(FlushModeType.COMMIT).setParameter("id", user.getId()).setParameter("realm", realm.getId())
                .getResultList().size() != 1) throw refused();
        // A user-row lock alone does not block updating/deleting an existing credential. Lock
        // those rows before the fresh scalar snapshot; NOWAIT avoids a credential->user inversion.
        em.createNativeQuery("select ID from CREDENTIAL where USER_ID=:id and TYPE='otp' order by ID for update nowait")
                .setFlushMode(FlushModeType.COMMIT).setParameter("id", user.getId()).getResultList();
        // A fresh scalar query does not refresh an already managed UserEntity. Keycloak's entity
        // uses a full-row UPDATE when trusted names become dirty; without this refresh, that
        // flush could restore old verification/username/notBefore values committed before our lock.
        // Only this proof path writes trusted names. The target row is locked for the whole txn.
        UserEntity managed = em.find(UserEntity.class, user.getId());
        if (managed == null) throw refused();
        em.refresh(managed);
        List<Object[]> rows = em.createQuery("select u.enabled,u.email,u.serviceAccountClientLink,u.realmId"
                        + " from UserEntity u where u.id=:id", Object[].class)
                .setFlushMode(FlushModeType.COMMIT).setHint("org.hibernate.cacheable", false)
                .setParameter("id", user.getId()).getResultList();
        if (rows.size() != 1) throw refused();
        List<Object[]> credentials = em.createQuery("select c.id,c.credentialData,c.secretData from CredentialEntity c"
                        + " where c.user.id=:id and c.type='otp' order by c.id", Object[].class)
                .setFlushMode(FlushModeType.COMMIT).setHint("org.hibernate.cacheable", false)
                .setParameter("id", user.getId()).getResultList();
        String otp = BrokerLinkState.otpSnapshot(credentials.stream()
                .map(c -> new String[]{(String)c[0], (String)c[1], (String)c[2]}).toList());
        // Operator off/disabled execution or an IdP override must invalidate a pending proof,
        // including when the callback held an older cached RealmModel before the operator write.
        List<String> bindings = em.createQuery("select a.value from RealmAttributeEntity a"
                        + " where a.realm.id=:realm and a.name='firstBrokerLoginFlowId'", String.class)
                .setFlushMode(FlushModeType.COMMIT).setHint("org.hibernate.cacheable", false)
                .setParameter("realm", realm.getId()).getResultList();
        boolean configuration = false;
        if (bindings.size() == 1) {
            List<AuthenticationExecutionModel.Requirement> requirements = em.createQuery(
                            "select e.requirement from AuthenticationExecutionEntity e where e.realm.id=:realm"
                                    + " and e.parentFlow.id=:flow and e.authenticator=:provider",
                            AuthenticationExecutionModel.Requirement.class)
                    .setFlushMode(FlushModeType.COMMIT).setHint("org.hibernate.cacheable", false)
                    .setParameter("realm", realm.getId()).setParameter("flow", bindings.getFirst())
                    .setParameter("provider", SkyExistingAccountPrompt.PROVIDER_ID).getResultList();
            List<Object[]> idps = em.createQuery("select i.enabled,i.firstBrokerLoginFlowId from IdentityProviderEntity i"
                            + " where i.realmId=:realm and i.alias=:alias", Object[].class)
                    .setFlushMode(FlushModeType.COMMIT).setHint("org.hibernate.cacheable", false)
                    .setParameter("realm", realm.getId())
                    .setParameter("alias", LoginIdentifiers.ytuIdpAlias(null)).getResultList();
            configuration = requirements.equals(List.of(AuthenticationExecutionModel.Requirement.REQUIRED))
                    && idps.size() == 1 && Boolean.TRUE.equals(idps.getFirst()[0])
                    && (idps.getFirst()[1] == null || bindings.getFirst().equals(idps.getFirst()[1]));
        }
        Object[] row = rows.getFirst();
        return new Snapshot(Boolean.TRUE.equals(row[0]), (String) row[1], (String) row[2], (String) row[3], otp,
                configuration);
    }
}
