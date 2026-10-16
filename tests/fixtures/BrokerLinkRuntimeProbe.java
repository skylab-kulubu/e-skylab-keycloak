package com.skylab.account;

import jakarta.ws.rs.GET;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.PathParam;
import jakarta.ws.rs.QueryParam;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;
import org.keycloak.Config;
import org.keycloak.authentication.authenticators.broker.AbstractIdpAuthenticator;
import org.keycloak.broker.provider.BrokeredIdentityContext;
import org.keycloak.broker.provider.IdentityBrokerException;
import org.keycloak.common.util.Time;
import org.keycloak.models.credential.OTPCredentialModel;
import org.keycloak.connections.jpa.JpaConnectionProvider;
import org.keycloak.models.jpa.entities.UserEntity;
import org.keycloak.models.*;
import org.keycloak.services.resource.RealmResourceProvider;
import org.keycloak.services.resource.RealmResourceProviderFactory;
import org.keycloak.services.resources.IdentityBrokerService;
import org.keycloak.sessions.AuthenticationSessionModel;

import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/** Test-only barriers around the actual SPI hook and Keycloak JPA insert; never shipped. */
public final class BrokerLinkRuntimeProbe implements RealmResourceProviderFactory {
    private static final Map<String, Run> RUNS = new ConcurrentHashMap<>();
    private static final class Run {
        final CountDownLatch release = new CountDownLatch(1);
        String user, subject, root, tab, pause;
        boolean proof;
        int barrierSeconds = 20, proofExpiresAt;
        volatile boolean waiting, inserted, guarded, barrierTimedOut;
    }
    @Override public String getId() { return "broker-link-probe"; }
    @Override public RealmResourceProvider create(KeycloakSession session) {
        if (!"1".equals(System.getenv("SKY_HARNESS"))) throw new IllegalStateException("test-only provider");
        return new RealmResourceProvider() {
            @Override public Object getResource() { return new Resource(session); }
            @Override public void close() { }
        };
    }
    @Override public void init(Config.Scope config) { }
    @Override public void postInit(KeycloakSessionFactory factory) { }
    @Override public void close() { }

    @Produces(MediaType.APPLICATION_JSON)
    public static final class Resource {
        private final KeycloakSession session;
        Resource(KeycloakSession session) { this.session = session; }

        private static Run run(String label) {
            if (label == null || !label.matches("[a-z0-9-]{1,40}")) throw new IllegalArgumentException("invalid run");
            return RUNS.computeIfAbsent(label, ignored -> new Run());
        }

        @GET @Path("{label}")
        public Map<String, Boolean> state(@PathParam("label") String label) {
            Run run = run(label);
            return Map.of("waiting", run.waiting, "inserted", run.inserted, "guarded", run.guarded,
                    "barrierTimedOut", run.barrierTimedOut,
                    "proofLive", run.proof && run.proofExpiresAt > Time.currentTime());
        }

        @POST @Path("{label}/release")
        public Map<String, Boolean> release(@PathParam("label") String label) {
            run(label).release.countDown(); return Map.of("released", true);
        }

        @POST @Path("{label}/prepare")
        public Map<String, Boolean> prepare(@PathParam("label") String label, @QueryParam("user") String username,
                @QueryParam("subject") String subject, @QueryParam("pause") String pause,
                @QueryParam("ttl") Integer ttl, @QueryParam("native") boolean nativePath,
                @QueryParam("barrierSeconds") Integer barrierSeconds) {
            RealmModel realm = session.getContext().getRealm();
            UserModel user = session.users().getUserByUsername(realm, username);
            if (user == null || subject == null || !subject.matches("[a-z0-9-]{1,60}")) throw new IllegalArgumentException("invalid target");
            Run run = run(label); run.user = user.getId(); run.subject = subject; run.pause = pause; run.proof = !nativePath;
            run.barrierSeconds = barrierSeconds == null ? 20 : Math.max(2, Math.min(90, barrierSeconds));
            run.barrierTimedOut = false;
            var root = session.authenticationSessions().createRootAuthenticationSession(realm);
            AuthenticationSessionModel auth = root.createAuthenticationSession(realm.getClientByClientId("b12-app"));
            run.root = root.getId(); run.tab = auth.getTabId();
            BrokeredIdentityContext broker = broker(realm, auth, run);
            if (run.proof) {
                String handle = BrokerLinkState.handle();
                run.proofExpiresAt = Time.currentTime() + (ttl == null ? 120 : Math.max(2, Math.min(120, ttl)));
                new BrokerLinkProofs(session.singleUseObjects()).issueProof(handle,
                        BrokerLinkState.binding(realm, auth, broker, user, user.getEmail()),
                        BrokerLinkState.otpSnapshot(user), "email_code",
                        run.proofExpiresAt);
                auth.setAuthNote(BrokerLinkState.REQUIRED, "true"); auth.setAuthNote(BrokerLinkState.PROOF, handle);
                auth.setAuthNote(AbstractIdpAuthenticator.EXISTING_USER_INFO,
                        new org.keycloak.authentication.authenticators.broker.util.ExistingUserInfo(user.getId(), "username", user.getUsername()).serialize());
            }
            return Map.of("prepared", true);
        }

        @POST @Path("{label}/factor")
        public Map<String, Boolean> factor(@PathParam("label") String label, @QueryParam("user") String username,
                @QueryParam("rotate") boolean rotate, @QueryParam("remove") boolean remove,
                @QueryParam("bounded") boolean bounded) {
            run(label);
            UserModel user = session.users().getUserByUsername(session.getContext().getRealm(), username);
            if (user == null) throw new IllegalArgumentException("invalid target");
            var em = session.getProvider(JpaConnectionProvider.class).getEntityManager();
            if (bounded) em.createNativeQuery("set local lock_timeout='500ms'").executeUpdate();
            if (rotate || remove) {
                var existing = user.credentialManager().getStoredCredentialsByTypeStream("otp").findFirst().orElseThrow();
                if (remove) user.credentialManager().removeStoredCredentialById(existing.getId());
                else {
                    existing.setSecretData("{\"value\":\"b12-rotated-fixture-secret-0123456789\"}");
                    user.credentialManager().updateStoredCredential(existing);
                }
            } else {
                user.credentialManager().createStoredCredential(OTPCredentialModel.createTOTP(
                        "b12-fixed-fixture-secret-0123456789", 6, 30, "HmacSHA1"));
            }
            em.flush();
            return Map.of("changed", true);
        }

        @POST @Path("{label}/admin-fields")
        public Map<String, Boolean> adminFields(@PathParam("label") String label) {
            Run run = run(label); RealmModel realm = session.getContext().getRealm();
            UserModel user = session.users().getUserById(realm, run.user);
            user.setEmailVerified(false);
            user.setUsername("probe-orm-renamed");
            session.users().setNotBeforeForUser(realm, user, 1700000000);
            return Map.of("changed", true);
        }

        @GET @Path("{label}/admin-fields")
        public Map<String, Boolean> adminFieldState(@PathParam("label") String label) {
            Run run = run(label);
            Object[] values = session.getProvider(JpaConnectionProvider.class).getEntityManager()
                    .createQuery("select u.emailVerified,u.username,u.notBefore from UserEntity u where u.id=:id", Object[].class)
                    .setParameter("id", run.user).getSingleResult();
            return Map.of("verificationPreserved", Boolean.FALSE.equals(values[0]),
                    "usernamePreserved", "probe-orm-renamed".equals(values[1]),
                    "notBeforePreserved", Integer.valueOf(1700000000).equals(values[2]));
        }

        private BrokeredIdentityContext broker(RealmModel realm, AuthenticationSessionModel auth, Run run) {
            var provider = IdentityBrokerService.getIdentityProvider(session, "OBS");
            BrokeredIdentityContext broker = new BrokeredIdentityContext(run.subject, session.identityProviders().getByAlias("OBS"));
            broker.setAuthenticationSession(auth); broker.setIdp(provider); broker.setEmail(null);
            broker.setUsername(run.subject + "@std.yildiz.edu.tr");
            broker.setUserAttribute("schoolEmail", run.subject + "@std.yildiz.edu.tr");
            broker.setFirstName("Microsoft"); broker.setLastName("Proof");
            return broker;
        }

        @POST @Path("{label}/complete")
        public Response complete(@PathParam("label") String label) throws Exception {
            Run run = run(label); RealmModel realm = session.getContext().getRealm();
            UserModel user = session.users().getUserById(realm, run.user);
            // Model a callback that already holds a managed entity before the guard's fresh read.
            session.getProvider(JpaConnectionProvider.class).getEntityManager().find(UserEntity.class, run.user);
            AuthenticationSessionModel auth = session.authenticationSessions().getRootAuthenticationSession(realm, run.root)
                    .getAuthenticationSession(realm.getClientByClientId("b12-app"), run.tab);
            BrokeredIdentityContext broker = broker(realm, auth, run);
            if ("before".equals(run.pause)) { run.waiting = true; await(run); }
            session.users().addFederatedIdentity(realm, user,
                    new FederatedIdentityModel("OBS", run.subject, broker.getUsername()));
            run.inserted = true;
            if ("insert".equals(run.pause)) await(run);
            try {
                broker.getIdp().updateBrokeredUser(session, realm, user, broker);
                run.guarded = true;
                if ("guard".equals(run.pause)) await(run);
                return Response.ok(Map.of("accepted", true)).build();
            } catch (IdentityBrokerException refused) {
                return Response.status(409).entity(Map.of("accepted", false)).build();
            }
        }

        private static void await(Run run) throws InterruptedException {
            if (!run.release.await(run.barrierSeconds, TimeUnit.SECONDS)) {
                run.barrierTimedOut = true;
                throw new IllegalStateException("probe release timeout");
            }
        }
    }
}
