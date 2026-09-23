package com.skylab.handoff;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.skylab.account.RateLimiter;
import jakarta.ws.rs.Consumes;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.HeaderParam;
import jakarta.ws.rs.NotAuthorizedException;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.PUT;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.PathParam;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.QueryParam;
import jakarta.ws.rs.core.HttpHeaders;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;
import org.jboss.logging.Logger;
import org.keycloak.authentication.authenticators.util.AuthenticatorUtils;
import org.keycloak.common.ClientConnection;
import org.keycloak.events.Details;
import org.keycloak.events.EventBuilder;
import org.keycloak.events.EventType;
import org.keycloak.events.admin.OperationType;
import org.keycloak.headers.SecurityHeadersProvider;
import org.keycloak.models.BrowserSecurityHeaders;
import org.keycloak.models.ClientModel;
import org.keycloak.models.GroupModel;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;
import org.keycloak.models.UserSessionModel;
import org.keycloak.models.utils.KeycloakModelUtils;
import org.keycloak.protocol.oidc.OIDCLoginProtocol;
import org.keycloak.services.Urls;
import org.keycloak.services.managers.AppAuthManager;
import org.keycloak.services.managers.AuthenticationManager;
import org.keycloak.services.managers.BruteForceProtector;
import org.keycloak.services.managers.UserSessionManager;
import org.keycloak.services.resources.admin.AdminAuth;
import org.keycloak.services.resources.admin.AdminEventBuilder;
import org.keycloak.util.JsonSerialization;

import java.net.URI;
import java.util.Comparator;
import java.util.Objects;
import java.util.Optional;
import java.util.function.Supplier;

/**
 * {@code /realms/{realm}/sky-handoff/v1}: the Web handoff. SkyApp mints a 45-second single-use
 * code for a Handoff target and a path with its own bearer token; the WebView opens the code with
 * the per-code proof header; Keycloak sets up the browser session and sends the person to the
 * target's own sign-in entry, whose OIDC flow then completes silently from that session.
 *
 * <p>No response body, Keycloak log line or event carries a token, a code, a proof or a path. The
 * code itself travels in the {@code open} URL, where a reverse proxy may log it; it is useless
 * there without the proof, which only ever travels in a request header.
 */
public final class SkyHandoffResource {

    static final String PROOF_HEADER = "X-Sky-Handoff-Proof";
    /** User session note that marks a browser session as embedded in SkyApp; the {@code sky_embed} claim reads it. */
    static final String EMBED_NOTE = "sky.embed";
    static final String EMBED_SKYAPP = "skyapp";
    /** Per person: 30 codes per 5-minute window, far above tapping links in the app. */
    static final RateLimiter.Limit MINT_LIMIT = new RateLimiter.Limit("sky-handoff-mint", 30, 5 * 60);
    static final String AUDIT_ACTION = "sky-handoff";
    static final String AUDIT_ACTION_DETAIL = "action";
    static final String REPLACED_SESSION_DETAIL = "replaced_session";
    static final String ADDRESS_CHANGED_DETAIL = "address_changed";
    static final String REPLACED_BY_ANOTHER_USER = "replaced_by_another_user";
    /** Admin events of target changes: resource type and the last segment of their resource path. */
    static final String ADMIN_EVENT_RESOURCE = "SKY_HANDOFF_TARGET";
    static final String PROVIDER_PATH = "sky-handoff";

    private static final Logger LOG = Logger.getLogger(SkyHandoffResource.class);

    private final KeycloakSession session;
    private final RealmModel realm;
    private final AdminAccess adminAccess;

    SkyHandoffResource(KeycloakSession session, AdminAccess adminAccess) {
        this.session = session;
        this.realm = session.getContext().getRealm();
        this.adminAccess = adminAccess;
    }

    @POST
    @Path("v1/handoffs")
    @Consumes(MediaType.APPLICATION_JSON)
    @Produces({MediaType.APPLICATION_JSON, HandoffProblem.MEDIA_TYPE})
    public Response mint(String body) {
        return execute(() -> {
            AuthenticationManager.AuthResult caller = authenticateSkyapp();
            int retryAfter = new RateLimiter(session.singleUseObjects()).claim(MINT_LIMIT, caller.user().getId());
            if (retryAfter > 0) {
                throw HandoffProblem.rateLimited(retryAfter).exception();
            }
            MintRequest request = MintRequest.parse(body);
            HandoffTarget target = HandoffTarget.of(realm.getClientByClientId(request.target()))
                    .orElseThrow(() -> HandoffProblem.invalidTarget().exception());
            HandoffGrant grant = new HandoffGrant(
                    realm.getId(),
                    caller.user().getId(),
                    caller.session().getId(),
                    caller.session().isOffline(),
                    MintGuard.originalAuthTime(caller.session(), caller.token()),
                    target.clientId(),
                    request.path(),
                    connection().getRemoteHost());
            HandoffStore.Minted minted = new HandoffStore(session.singleUseObjects()).mint(grant);

            ObjectNode response = JsonSerialization.mapper.createObjectNode();
            response.put("handoffUrl", endpoint("v1/open") + "?code=" + minted.code());
            response.put("proof", minted.proof());
            response.put("expiresIn", minted.expiresIn());
            return Response.status(Response.Status.CREATED)
                    .type(MediaType.APPLICATION_JSON_TYPE)
                    .header(HttpHeaders.CACHE_CONTROL, "no-store")
                    .entity(response.toString())
                    .build();
        });
    }

    @GET
    @Path("v1/open")
    public Response open(@QueryParam("code") String code, @HeaderParam(PROOF_HEADER) String proof) {
        String userId = null;
        String clientId = null;
        try {
            HandoffStore.Redemption redemption = new HandoffStore(session.singleUseObjects())
                    .redeem(code, proof, realm.getId());
            if (redemption instanceof HandoffStore.Refused refused) {
                return fail(refused.reason(), refused.userId(), refused.clientId());
            }
            HandoffGrant grant = ((HandoffStore.Redeemed) redemption).grant();
            userId = grant.userId();
            clientId = grant.clientId();

            ClientModel client = realm.getClientByClientId(grant.clientId());
            Optional<HandoffTarget> target = HandoffTarget.of(client);
            if (target.isEmpty()) {
                return fail(FailureReason.TARGET_DISABLED, userId, clientId);
            }
            UserModel user = session.users().getUserById(realm, grant.userId());
            if (user == null || !user.isEnabled() || isLockedOut(user)) {
                return fail(FailureReason.ACCOUNT_UNAVAILABLE, userId, clientId);
            }
            if (!isSourceSessionAlive(grant, user)) {
                return fail(FailureReason.INVALID, userId, clientId);
            }
            boolean addressChanged = grant.ipAddress() != null
                    && !Objects.equals(grant.ipAddress(), connection().getRemoteHost());
            if (addressChanged) {
                LOG.infof("sky-handoff: user %s opened a %s handoff from another address than the one that minted it",
                        userId, clientId);
            }

            // The previous session goes first: ending it may expire the identity cookies, and the
            // browser applies Set-Cookie headers in order, so the new cookies must come after.
            ReplacedSession replaced = replacePreviousSession(user, grant.sourceSessionId());
            UserSessionModel userSession = new UserSessionManager(session).createUserSession(
                    realm, user, user.getUsername(), connection().getRemoteHost(),
                    OIDCLoginProtocol.LOGIN_PROTOCOL, false, null, null);
            userSession.setNote(AuthenticationManager.AUTH_TIME, Long.toString(grant.authTime()));
            userSession.setNote(EMBED_NOTE, EMBED_SKYAPP);
            userSession.setState(UserSessionModel.State.LOGGED_IN);
            AuthenticationManager.createLoginCookie(session, realm, user, userSession,
                    session.getContext().getUri(), connection());
            session.getContext().setUserSession(userSession);

            EventBuilder event = auditEvent()
                    .client(client)
                    .user(user)
                    .session(userSession);
            if (replaced != ReplacedSession.NONE) {
                event.detail(REPLACED_SESSION_DETAIL, replaced.detail());
            }
            if (addressChanged) {
                event.detail(ADDRESS_CHANGED_DETAIL, "true");
            }
            event.success();
            return redirect(target.get().entry(grant.path()));
        } catch (RuntimeException exception) {
            LOG.error("sky-handoff could not open a handoff", exception);
            session.getTransactionManager().setRollbackOnly();
            return fail(FailureReason.UNAVAILABLE, userId, clientId);
        }
    }

    /** Every client of the realm with its root URL and Handoff target settings, for the superadmin page. */
    @GET
    @Path("v1/admin/targets")
    @Produces({MediaType.APPLICATION_JSON, HandoffProblem.MEDIA_TYPE})
    public Response listTargets() {
        return execute(() -> {
            authenticateAdmin();
            ObjectNode response = JsonSerialization.mapper.createObjectNode();
            ArrayNode targets = response.putArray("targets");
            realm.getClientsStream()
                    .sorted(Comparator.comparing(ClientModel::getClientId))
                    .map(TargetSettings::describe)
                    .forEach(targets::add);
            return json(200, response);
        });
    }

    /**
     * Replaces the three Handoff target settings of one client. The origin rule is enforced here
     * as well as at every mint and open; nothing but the three attributes is written, and every
     * change is an admin event naming who changed which client from what to what.
     */
    @PUT
    @Path("v1/admin/targets/{clientId}")
    @Consumes(MediaType.APPLICATION_JSON)
    @Produces({MediaType.APPLICATION_JSON, HandoffProblem.MEDIA_TYPE})
    public Response updateTarget(@PathParam("clientId") String clientId, String body) {
        return execute(() -> {
            AuthenticationManager.AuthResult admin = authenticateAdmin();
            ClientModel client = clientId == null ? null : realm.getClientByClientId(clientId);
            if (client == null) {
                throw HandoffProblem.clientNotFound().exception();
            }
            TargetSettings requested = TargetSettings.parse(body);
            requested.requireAllowedFor(client);
            TargetSettings current = TargetSettings.of(client);
            if (!requested.equals(current)) {
                requested.writeTo(client);
                new AdminEventBuilder(realm, new AdminAuth(realm, admin.token(), admin.user(), admin.client()),
                        session, connection())
                        .resource(ADMIN_EVENT_RESOURCE)
                        .operation(OperationType.UPDATE)
                        .resourcePath("clients", client.getId(), PROVIDER_PATH)
                        .detail("clientId", client.getClientId())
                        .detail("before", current.toJson())
                        .detail("after", requested.toJson())
                        .representation(requested.toMap())
                        .success();
                LOG.infof("sky-handoff: user %s changed the Handoff target settings of client %s from %s to %s",
                        admin.user().getId(), client.getClientId(), current.toJson(), requested.toJson());
            }
            return json(200, TargetSettings.describe(client));
        });
    }

    /**
     * The failure page, in the realm's login theme (the SKY LAB LegacyFrame design) or, when the
     * theme cannot render it, as the built-in page. The reason is always one of the fixed codes.
     */
    @GET
    @Path("v1/failed")
    @Produces(MediaType.TEXT_HTML)
    public Response failed(@QueryParam("reason") String reason) {
        // Keycloak's realm browser security headers would replace the page's stricter ones
        // (same-origin framing, a looser CSP); the page sends its own and keeps the realm's HSTS.
        session.getProvider(SecurityHeadersProvider.class).options().skipHeaders();
        BrowserSecurityHeaders hsts = BrowserSecurityHeaders.STRICT_TRANSPORT_SECURITY;
        return FailurePage.render(session, FailureReason.fromCode(reason), URI.create(endpoint("v1/failed")),
                realm.getBrowserSecurityHeaders().getOrDefault(hsts.getKey(), hsts.getDefaultValue()));
    }

    /**
     * Keycloak's own bearer verification (it accepts a live online or offline session) followed by
     * the SkyApp contract. Every failure is the same 401 problem.
     */
    private AuthenticationManager.AuthResult authenticateSkyapp() {
        AuthenticationManager.AuthResult result = verifyBearer();
        String rejection = MintGuard.rejectionReason(result.token(), result.user(), result.session());
        if (rejection != null) {
            LOG.debugf("sky-handoff refused a bearer token: %s", rejection);
            throw HandoffProblem.invalidToken(realm.getName()).exception();
        }
        return result;
    }

    /**
     * A verified bearer issued to the admin client for a member of the admin group (directly or
     * through a subgroup) on a live online session. An unverifiable token is 401; every verified
     * caller who is not admitted gets the same 403 body. A missing admin group refuses everyone
     * and is logged once.
     */
    private AuthenticationManager.AuthResult authenticateAdmin() {
        AuthenticationManager.AuthResult result = verifyBearer();
        GroupModel group = KeycloakModelUtils.findGroupByPath(session, realm, adminAccess.groupPath());
        if (adminAccess.warnOfMissingGroup(realm.getId(), group != null)) {
            LOG.warnf("sky-handoff: the admin group %s does not exist in realm %s; every admin request is refused",
                    adminAccess.groupPath(), realm.getName());
        }
        String rejection = AdminGuard.rejectionReason(result.token(), result.user(), result.session(),
                group, adminAccess.clientId());
        if (rejection != null) {
            LOG.debugf("sky-handoff refused an admin request: %s", rejection);
            throw HandoffProblem.forbidden().exception();
        }
        return result;
    }

    private AuthenticationManager.AuthResult verifyBearer() {
        String authorization = session.getContext().getRequestHeaders().getHeaderString(HttpHeaders.AUTHORIZATION);
        if (authorization == null || authorization.isBlank()) {
            throw HandoffProblem.invalidToken(realm.getName()).exception();
        }
        final AuthenticationManager.AuthResult result;
        try {
            result = new AppAuthManager.BearerTokenAuthenticator(session).authenticate();
        } catch (NotAuthorizedException exception) {
            throw HandoffProblem.invalidToken(realm.getName()).exception();
        }
        if (result == null) {
            throw HandoffProblem.invalidToken(realm.getName()).exception();
        }
        return result;
    }

    /** Which Keycloak session of this browser a handoff replaced, for the audit event. */
    enum ReplacedSession {
        NONE(null),
        SAME_USER("same_user"),
        OTHER_USER("other_user");

        private final String detail;

        ReplacedSession(String detail) {
            this.detail = detail;
        }

        String detail() {
            return detail;
        }
    }

    /**
     * Ends the Keycloak session this browser holds, if any, before the new one is created (the
     * order Keycloak itself uses after a login). Another person's session is logged out properly
     * (its clients are told through back-channel logout, a {@code LOGOUT} event names that person)
     * because they must not stay signed in inside this WebView; an older session of the same
     * person is removed the way Keycloak replaces it on a new login in the same browser. The
     * SkyApp session the code was minted from is never touched.
     */
    private ReplacedSession replacePreviousSession(UserModel user, String sourceSessionId) {
        AuthenticationManager.AuthResult previous = AuthenticationManager.authenticateIdentityCookie(session, realm, false);
        if (previous == null || previous.session() == null || previous.session().getId().equals(sourceSessionId)) {
            return ReplacedSession.NONE;
        }
        UserSessionModel previousSession = previous.session();
        if (previous.user() != null && user.getId().equals(previous.user().getId())) {
            session.sessions().removeUserSession(realm, previousSession);
            return ReplacedSession.SAME_USER;
        }
        String previousSessionId = previousSession.getId();
        UserModel previousUser = previous.user();
        AuthenticationManager.backchannelLogout(session, realm, previousSession, session.getContext().getUri(),
                connection(), session.getContext().getRequestHeaders(), true);
        new EventBuilder(realm, session, connection())
                .event(EventType.LOGOUT)
                .user(previousUser)
                .session(previousSessionId)
                .detail(AUDIT_ACTION_DETAIL, AUDIT_ACTION)
                .detail(Details.REASON, REPLACED_BY_ANOTHER_USER)
                .success();
        return ReplacedSession.OTHER_USER;
    }

    private boolean isLockedOut(UserModel user) {
        if (!realm.isBruteForceProtected()) {
            return false;
        }
        BruteForceProtector protector = session.getProvider(BruteForceProtector.class);
        return AuthenticatorUtils.getDisabledByBruteForceEventError(protector, session, realm, user) != null;
    }

    /**
     * The SkyApp session the code was minted from must still exist: signing out of the app voids
     * its codes. An offline session is looked up as such, because the online session of the same
     * login shares its id and may outlive it.
     */
    private boolean isSourceSessionAlive(HandoffGrant grant, UserModel user) {
        UserSessionModel source = grant.sourceOffline()
                ? session.sessions().getOfflineUserSession(realm, grant.sourceSessionId())
                : session.sessions().getUserSession(realm, grant.sourceSessionId());
        return source != null
                && AuthenticationManager.isSessionValid(realm, source)
                && source.getUser() != null
                && user.getId().equals(source.getUser().getId());
    }

    private Response fail(FailureReason reason, String userId, String clientId) {
        try {
            EventBuilder event = auditEvent();
            if (userId != null) {
                event.user(userId);
            }
            if (clientId != null) {
                event.client(clientId);
            }
            event.error(reason.code());
        } catch (RuntimeException exception) {
            LOG.warn("sky-handoff could not record a failed handoff", exception);
        }
        return redirect(endpoint("v1/failed") + "?reason=" + reason.code());
    }

    private EventBuilder auditEvent() {
        return new EventBuilder(realm, session, connection())
                .event(EventType.CUSTOM_REQUIRED_ACTION)
                .detail(AUDIT_ACTION_DETAIL, AUDIT_ACTION);
    }

    private static Response json(int status, JsonNode body) {
        return Response.status(status)
                .type(MediaType.APPLICATION_JSON_TYPE)
                .header(HttpHeaders.CACHE_CONTROL, "no-store")
                .entity(body.toString())
                .build();
    }

    private static Response redirect(String location) {
        return Response.seeOther(URI.create(location))
                .header(HttpHeaders.CACHE_CONTROL, "no-store")
                .header("Referrer-Policy", "no-referrer")
                .build();
    }

    /** An absolute URL of this provider, on the frontend URL Keycloak serves the realm under. */
    private String endpoint(String path) {
        return Urls.realmBase(session.getContext().getUri().getBaseUri())
                .path(realm.getName())
                .path(SkyHandoffResourceProviderFactory.PROVIDER_ID)
                .path(path)
                .build()
                .toString();
    }

    private ClientConnection connection() {
        return session.getContext().getConnection();
    }

    /** Runs a JSON endpoint: problems become their response; anything else is a 500 with rollback. */
    private Response execute(Supplier<Response> action) {
        try {
            return action.get();
        } catch (HandoffProblem.Raised raised) {
            if (raised.problem().status() >= 500) {
                session.getTransactionManager().setRollbackOnly();
            }
            return raised.problem().toResponse();
        } catch (RuntimeException exception) {
            LOG.error("sky-handoff request failed", exception);
            session.getTransactionManager().setRollbackOnly();
            return HandoffProblem.internalError().toResponse();
        }
    }
}
