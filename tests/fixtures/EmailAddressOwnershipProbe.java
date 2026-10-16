package com.skylab.account;

import jakarta.ws.rs.GET;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.PathParam;
import jakarta.ws.rs.QueryParam;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;
import org.keycloak.Config;
import org.keycloak.connections.jpa.JpaConnectionProvider;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;
import org.keycloak.services.resource.RealmResourceProvider;
import org.keycloak.services.resource.RealmResourceProviderFactory;

import java.util.Map;
import java.util.Locale;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/** Test-only provider: compiled/mounted by sign-up-by-email-code.sh, never shipped in the SPI. */
public final class EmailAddressOwnershipProbe implements RealmResourceProviderFactory {
    private static final Map<String, Run> RUNS = new ConcurrentHashMap<>();

    private static final class Run {
        final CountDownLatch release = new CountDownLatch(1);
        volatile boolean locked;
        volatile boolean waiting;
        volatile boolean finished;
    }

    @Override
    public String getId() { return "email-ownership-probe"; }

    @Override
    public RealmResourceProvider create(KeycloakSession session) {
        if (!"1".equals(System.getenv("SKY_HARNESS"))) {
            throw new IllegalStateException("test-only provider");
        }
        return new RealmResourceProvider() {
            @Override
            public Object getResource() { return new Resource(session); }
            @Override
            public void close() { }
        };
    }

    @Override
    public void init(Config.Scope config) { }
    @Override
    public void postInit(KeycloakSessionFactory factory) { }
    @Override
    public void close() { }

    @Produces(MediaType.APPLICATION_JSON)
    public static final class Resource {
        private final KeycloakSession session;
        Resource(KeycloakSession session) { this.session = session; }

        private static Run run(String label) {
            if (label == null || !label.matches("[a-z-]{1,32}")) {
                throw new IllegalArgumentException("invalid probe label");
            }
            return RUNS.computeIfAbsent(label, ignored -> new Run());
        }

        @GET
        @Path("{label}")
        public Map<String, Boolean> state(@PathParam("label") String label) {
            Run run = run(label);
            return Map.of("locked", run.locked, "waiting", run.waiting, "finished", run.finished);
        }

        @POST
        @Path("{label}/release")
        public Map<String, Boolean> release(@PathParam("label") String label) {
            run(label).release.countDown();
            return Map.of("released", true);
        }

        @POST
        @Path("{label}/hold")
        public Map<String, Boolean> hold(@PathParam("label") String label, @QueryParam("slot") String slot,
                @QueryParam("rollback") boolean rollback) throws Exception {
            Run run = run(label);
            RealmModel realm = session.getContext().getRealm();
            String address = label + "@ownership.invalid";
            UserModel owner = session.users().getUserByUsername(realm, "ownership-" + label);
            if ("signup".equals(slot)) {
                new ProfileSignUpAccounts().open(session, realm, "ownership-" + label, address, "Guard", "Probe");
            } else {
                if (owner == null || EmailAddressOwnership.isTakenAfterLock(session, realm, owner, address)) {
                    throw new IllegalStateException("probe address is unavailable");
                }
                switch (slot) {
                    case "personal" -> PersonalEmailVerification.prove(owner, address, 1_800_000_000L);
                    case "school" -> owner.setSingleAttribute(IdentityResource.SCHOOL_EMAIL_ATTRIBUTE, address.toUpperCase(Locale.ROOT));
                    case "email" -> owner.setEmail(address);
                    case "username" -> owner.setUsername(address);
                    default -> throw new IllegalArgumentException("invalid probe slot");
                }
            }
            session.getProvider(JpaConnectionProvider.class).getEntityManager().flush();
            run.locked = true;
            if (!run.release.await(15, TimeUnit.SECONDS)) {
                session.getTransactionManager().setRollbackOnly();
                throw new IllegalStateException("probe release timeout");
            }
            if (rollback) {
                session.getTransactionManager().setRollbackOnly();
            }
            return Map.of("rolledBack", rollback);
        }

        @POST
        @Path("{label}/check")
        public Map<String, Boolean> check(@PathParam("label") String label) {
            Run run = run(label);
            RealmModel realm = session.getContext().getRealm();
            String address = label + "@ownership.invalid";
            // Keep an old UserModel in this session while the other transaction commits.
            session.users().getUserByUsername(realm, "ownership-" + label);
            boolean before = PersonalEmailVerification.isTakenByAnother(session, realm, null, address);
            run.waiting = true;
            boolean after = EmailAddressOwnership.isTakenAfterLock(session, realm, null, address);
            run.finished = true;
            return Map.of("before", before, "after", after);
        }
    }
}
