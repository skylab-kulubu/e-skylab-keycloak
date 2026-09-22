package com.skylab.handoff;

import com.fasterxml.jackson.databind.node.ObjectNode;
import com.skylab.account.RateLimiter;
import jakarta.ws.rs.Consumes;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.HeaderParam;
import jakarta.ws.rs.NotAuthorizedException;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.QueryParam;
import jakarta.ws.rs.core.HttpHeaders;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;
import org.jboss.logging.Logger;
import org.keycloak.authentication.authenticators.util.AuthenticatorUtils;
import org.keycloak.common.ClientConnection;
import org.keycloak.events.EventBuilder;
import org.keycloak.events.EventType;
import org.keycloak.models.ClientModel;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;
import org.keycloak.models.UserSessionModel;
import org.keycloak.protocol.oidc.OIDCLoginProtocol;
import org.keycloak.services.Urls;
import org.keycloak.services.managers.AppAuthManager;
import org.keycloak.services.managers.AuthenticationManager;
import org.keycloak.services.managers.BruteForceProtector;
import org.keycloak.services.managers.UserSessionManager;
import org.keycloak.util.JsonSerialization;

import java.net.URI;
import java.util.Objects;
import java.util.Optional;
import java.util.function.Supplier;

/**
 * {@code /realms/{realm}/sky-handoff/v1}: the Web handoff. SkyApp mints a 45-second single-use
 * code for a Handoff target and a path with its own bearer token; the WebView opens the code with
 * the per-code proof header; Keycloak sets up the browser session and sends the person to the
 * target's own sign-in entry, whose OIDC flow then completes silently from that session.
 *
 * <p>No response, log line or event ever carries a token, a code, a proof or a path.
 */
public final class SkyHandoffResource {

    static final String PROOF_HEADER = "X-Sky-Handoff-Proof";
    /** User session note that marks a browser session as embedded in SkyApp; the {@code sky_embed} claim reads it. */
    static final String EMBED_NOTE = "sky.embed";
    static final String EMBED_SKYAPP = "skyapp";
    /** Per person: 30 codes per 5-minute window, far above tapping links in the app. */
    static final RateLimiter.Limit MINT_LIMIT = new RateLimiter.Limit("sky-handoff-mint", 30, 5 * 60);
    static final String AUDIT_ACTION = "sky-handoff";

    private static final Logger LOG = Logger.getLogger(SkyHandoffResource.class);

    private final KeycloakSession session;
    private final RealmModel realm;

    public SkyHandoffResource(KeycloakSession session) {
        this.session = session;
        this.realm = session.getContext().getRealm();
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

            UserSessionModel userSession = new UserSessionManager(session).createUserSession(
                    realm, user, user.getUsername(), connection().getRemoteHost(),
                    OIDCLoginProtocol.LOGIN_PROTOCOL, false, null, null);
            userSession.setNote(AuthenticationManager.AUTH_TIME, Long.toString(grant.authTime()));
            userSession.setNote(EMBED_NOTE, EMBED_SKYAPP);
            // The new cookies go out first: Keycloak keeps the first Set-Cookie per name, so the
            // expiry a logout of the previous session writes afterwards cannot shadow them.
            AuthenticationManager.createLoginCookie(session, realm, user, userSession,
                    session.getContext().getUri(), connection());
            String replaced = replacePreviousSession(user, userSession);
            session.getContext().setUserSession(userSession);

            EventBuilder event = auditEvent()
                    .client(client)
                    .user(user)
                    .session(userSession);
            if (replaced != null) {
                event.detail("replaced_session", replaced);
            }
            if (addressChanged) {
                event.detail("address_changed", "true");
            }
            event.success();
            return redirect(target.get().entry(grant.path()));
        } catch (RuntimeException exception) {
            LOG.error("sky-handoff could not open a handoff", exception);
            session.getTransactionManager().setRollbackOnly();
            return fail(FailureReason.UNAVAILABLE, userId, clientId);
        }
    }

    @GET
    @Path("v1/failed")
    @Produces(MediaType.TEXT_HTML)
    public Response failed(@QueryParam("reason") String reason) {
        return FailurePage.render(FailureReason.fromCode(reason));
    }

    /**
     * Keycloak's own bearer verification (it accepts a live online or offline session) followed by
     * the SkyApp contract. Every failure is the same 401 problem.
     */
    private AuthenticationManager.AuthResult authenticateSkyapp() {
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
        String rejection = MintGuard.rejectionReason(result.token(), result.user(), result.session());
        if (rejection != null) {
            LOG.debugf("sky-handoff refused a bearer token: %s", rejection);
            throw HandoffProblem.invalidToken(realm.getName()).exception();
        }
        return result;
    }

    /**
     * Ends the Keycloak session this browser held before, if any. Another person's session is
     * logged out properly (its clients are told through back-channel logout) because that person
     * must not stay signed in inside this WebView; an older session of the same person is removed
     * the way Keycloak replaces it on a new login in the same browser.
     *
     * @return {@code other_user}, {@code same_user} or {@code null} when nothing was replaced
     */
    private String replacePreviousSession(UserModel user, UserSessionModel current) {
        AuthenticationManager.AuthResult previous = AuthenticationManager.authenticateIdentityCookie(session, realm, false);
        if (previous == null || previous.session() == null || previous.session().getId().equals(current.getId())) {
            return null;
        }
        UserSessionModel previousSession = previous.session();
        if (previous.user() != null && user.getId().equals(previous.user().getId())) {
            session.sessions().removeUserSession(realm, previousSession);
            return "same_user";
        }
        String previousSessionId = previousSession.getId();
        UserModel previousUser = previous.user();
        AuthenticationManager.backchannelLogout(session, realm, previousSession, session.getContext().getUri(),
                connection(), session.getContext().getRequestHeaders(), false);
        new EventBuilder(realm, session, connection())
                .event(EventType.LOGOUT)
                .user(previousUser)
                .session(previousSessionId)
                .detail("action", AUDIT_ACTION)
                .detail("reason", "replaced_by_another_user")
                .success();
        return "other_user";
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
                .detail("action", AUDIT_ACTION);
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
