package com.skylab.passkey;

import jakarta.ws.rs.GET;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.QueryParam;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import org.keycloak.Config;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;
import org.keycloak.services.managers.AuthenticationSessionManager;
import org.keycloak.services.resource.RealmResourceProvider;
import org.keycloak.services.resource.RealmResourceProviderFactory;
import org.keycloak.sessions.AuthenticationSessionModel;
import org.keycloak.util.JsonSerialization;

/** Disposable-fixture observation and fault controls. Never compiled into the production SPI. */
public final class AfterSignUpRuntimeProbe implements RealmResourceProviderFactory {
    @Override public String getId() { return "after-sign-up-probe"; }
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

        @GET @Path("person") public Map<String, Object> person(@QueryParam("email") String email) {
            var realm = session.getContext().getRealm();
            var user = session.users().getUserByEmail(realm, email);
            if (user == null) return Map.of("found", false);
            var result = new LinkedHashMap<String, Object>();
            result.put("found", true);
            result.put("username", user.getUsername());
            result.put("email", user.getEmail());
            result.put("emailVerified", user.isEmailVerified());
            result.put("firstName", user.getFirstName());
            result.put("lastName", user.getLastName());
            result.put("schoolEmail", user.getFirstAttribute("schoolEmail"));
            result.put("links", session.users().getFederatedIdentitiesStream(realm, user).count());
            result.put("obsLinked", session.users().getFederatedIdentity(realm, user, "OBS") != null);
            result.put("credentials", user.credentialManager().getStoredCredentialsStream().map(c -> c.getType()).toList());
            result.put("requiredActions", user.getRequiredActionsStream().toList());
            return result;
        }

        @POST @Path("scope") public Map<String, Boolean> scope(@QueryParam("native") boolean nativeScope) {
            session.getContext().getRealm().getClientByClientId("b12-app").setFullScopeAllowed(nativeScope);
            return Map.of("native", nativeScope);
        }

        private AuthenticationSessionModel auth(String tab) {
            var root = new AuthenticationSessionManager(session).getCurrentRootAuthenticationSession(session.getContext().getRealm());
            if (root == null) return null;
            return root.getAuthenticationSessions().values().stream()
                    .filter(a -> tab != null && tab.equals(a.getTabId()) && "b12-app".equals(a.getClient().getClientId()))
                    .findFirst().orElse(null);
        }

        @GET @Path("continuation") public Map<String, Object> continuation(@QueryParam("tab") String tab) throws Exception {
            var auth = auth(tab);
            if (auth == null) return Map.of("found", false);
            String raw = auth.getAuthNote(AfterSignUpState.NOTE);
            var tree = raw == null ? null : JsonSerialization.mapper.readTree(raw);
            return Map.of("found", true, "stage", tree == null ? "missing" : tree.path("stage").asText(),
                    "requiredActions", List.copyOf(auth.getRequiredActions()));
        }

        @POST @Path("continuation") public Response fault(@QueryParam("tab") String tab, @QueryParam("mode") String mode) throws Exception {
            var auth = auth(tab);
            if (auth == null || auth.getAuthNote(AfterSignUpState.NOTE) == null) return Response.status(404).build();
            var tree = (com.fasterxml.jackson.databind.node.ObjectNode) JsonSerialization.mapper.readTree(auth.getAuthNote(AfterSignUpState.NOTE));
            if ("expire".equals(mode)) {
                long now = org.keycloak.common.util.Time.currentTime();
                tree.put("issuedAt", now - 601); tree.put("expiresAt", now - 1);
            } else if ("wrong-tab".equals(mode)) tree.put("tabId", "another-fixture-tab");
            else return Response.status(400).build();
            auth.setAuthNote(AfterSignUpState.NOTE, tree.toString());
            return Response.noContent().build();
        }
    }
}
