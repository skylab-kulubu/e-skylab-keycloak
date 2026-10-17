package com.skylab.passkey;

import com.skylab.broker.SkyMicrosoftIdentityProvider;
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
import org.keycloak.broker.provider.IdentityProvider;
import org.keycloak.models.AccountRoles;
import org.keycloak.models.AuthenticationExecutionModel;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;
import org.keycloak.services.managers.AuthenticationSessionManager;
import org.keycloak.services.resource.RealmResourceProvider;
import org.keycloak.services.resource.RealmResourceProviderFactory;
import org.keycloak.services.resources.IdentityBrokerService;
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
            var client = session.getContext().getRealm().getClientByClientId("b12-app");
            if (client != null) client.setFullScopeAllowed(nativeScope);
            return Map.of("nativeRequested", nativeScope, "configuredClientFound", client != null,
                    "fullScopeAllowed", client != null && client.isFullScopeAllowed());
        }

        private AuthenticationSessionModel auth(String tab) {
            var root = new AuthenticationSessionManager(session).getCurrentRootAuthenticationSession(session.getContext().getRealm());
            if (root == null) return null;
            return root.getAuthenticationSessions().values().stream()
                    .filter(a -> tab != null && tab.equals(a.getTabId()) && "b12-app".equals(a.getClient().getClientId()))
                    .findFirst().orElse(null);
        }

        /** Read actual gate inputs; no identifiers, claims, notes, or exception text leave this endpoint. */
        @GET @Path("native-capability") public Map<String, Object> nativeCapability(@QueryParam("tab") String tab) {
            try {
                var realm = session.getContext().getRealm();
                var auth = auth(tab);
                if (auth == null) return Map.of("status", "auth_missing");
                var user = auth.getAuthenticatedUser();
                if (user == null) return Map.of("status", "user_missing");
                var client = auth.getClient();
                if (client == null) return Map.of("status", "client_missing");
                var result = new LinkedHashMap<String, Object>();
                result.put("status", "ok");
                result.put("nativeLinkSupported", AfterSignUpState.nativeLinkSupported(session, realm, auth, user));
                result.put("supportedRelyingParty", AfterSignUpState.supportedRelyingParty(realm, auth, user));
                result.put("credentialsActionEnabled", AfterSignUpState.actionEnabled(realm, SignUpCredentialsRequiredAction.PROVIDER_ID));
                result.put("idpLinkActionEnabled", AfterSignUpState.actionEnabled(realm, "idp_link"));
                var configured = realm.getClientByClientId("b12-app");
                result.put("configuredClientMatches", configured != null && configured.getId().equals(client.getId()));
                result.put("clientEnabled", client.isEnabled());
                result.put("clientStandardFlow", client.isStandardFlowEnabled());
                result.put("clientOidc", "openid-connect".equals(client.getProtocol()));
                result.put("clientFullScopeAllowed", client.isFullScopeAllowed());
                result.put("userEnabled", user.isEnabled());
                result.put("userIsServiceAccount", user.getServiceAccountClientLink() != null);
                var account = realm.getClientByClientId("account");
                result.put("accountClientFound", account != null);
                var manage = account == null ? null : account.getRole(AccountRoles.MANAGE_ACCOUNT);
                var links = account == null ? null : account.getRole(AccountRoles.MANAGE_ACCOUNT_LINKS);
                result.put("manageAccountRoleFound", manage != null);
                result.put("userHasManageAccount", manage != null && user.hasRole(manage));
                result.put("clientHasManageAccountScope", manage != null && client.hasScope(manage));
                result.put("manageAccountLinksRoleFound", links != null);
                result.put("userHasManageAccountLinks", links != null && user.hasRole(links));
                result.put("clientHasManageAccountLinksScope", links != null && client.hasScope(links));
                var provider = session.identityProviders().getByAlias(AfterSignUpState.YTU_ALIAS);
                result.put("obsFound", provider != null);
                result.put("obsEnabled", provider != null && provider.isEnabled());
                result.put("obsMicrosoft", provider != null && "microsoft".equals(provider.getProviderId()));
                var root = realm.getFirstBrokerLoginFlow();
                result.put("brokerRootFound", root != null);
                result.put("brokerOverride", provider == null ? "not_applicable"
                        : provider.getFirstBrokerLoginFlowId() == null ? "none"
                        : root != null && root.getId().equals(provider.getFirstBrokerLoginFlowId()) ? "same_root" : "other");
                var prompts = root == null ? List.<AuthenticationExecutionModel>of()
                        : realm.getAuthenticationExecutionsStream(root.getId())
                                .filter(e -> "sky-existing-account-prompt".equals(e.getAuthenticator())).limit(65).toList();
                result.put("promptCount", prompts.size()); // 65 means at least 65; the actual gate above is authoritative.
                result.put("promptCountAtLeast65", prompts.size() == 65);
                result.put("requiredLeafPromptCount", prompts.stream().filter(e -> !e.isAuthenticatorFlow()
                        && e.getRequirement() == AuthenticationExecutionModel.Requirement.REQUIRED).count());
                String selected = "missing";
                if (provider != null) {
                    try {
                        var active = IdentityBrokerService.getIdentityProvider(session, provider, IdentityProvider.class);
                        try { selected = active == null ? "missing" : active instanceof SkyMicrosoftIdentityProvider ? "guarded_microsoft" : "other"; }
                        finally { if (active != null) active.close(); }
                    } catch (RuntimeException unavailable) { selected = "unavailable"; }
                }
                result.put("selectedProvider", selected);
                return result;
            } catch (RuntimeException unavailable) {
                return Map.of("status", "read_error");
            }
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
