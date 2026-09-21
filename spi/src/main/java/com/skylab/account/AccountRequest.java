package com.skylab.account;

import com.fasterxml.jackson.databind.node.ObjectNode;
import jakarta.ws.rs.core.HttpHeaders;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;
import org.jboss.logging.Logger;
import org.keycloak.events.EventBuilder;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;

import java.time.Instant;
import java.util.function.Supplier;

/**
 * Everything one sky-account request needs, shared by the sub-resources: the session and
 * realm, the bearer guard, the rate limiter, Sudo mode, User Profile fail-closed check,
 * event building and the uniform response/problem handling.
 */
final class AccountRequest {

    private static final Logger LOG = Logger.getLogger(AccountRequest.class);

    private final KeycloakSession session;
    private final RealmModel realm;
    private final String ytuIdpAlias;
    private final SudoTokens sudoTokens;
    private RateLimiter rateLimiter;

    AccountRequest(KeycloakSession session, String ytuIdpAlias) {
        this.session = session;
        this.realm = session.getContext().getRealm();
        this.ytuIdpAlias = ytuIdpAlias;
        this.sudoTokens = new SudoTokens(session);
    }

    KeycloakSession session() {
        return session;
    }

    RealmModel realm() {
        return realm;
    }

    /** Runs an endpoint: problems become their response; anything else is a 500 with rollback. */
    Response execute(Supplier<Response> action) {
        try {
            return action.get();
        } catch (ProblemException exception) {
            if (exception.problem().status() >= 500) {
                session.getTransactionManager().setRollbackOnly();
            }
            return exception.problem().toResponse();
        } catch (RuntimeException exception) {
            LOG.error("sky-account request failed", exception);
            session.getTransactionManager().setRollbackOnly();
            return Problems.internalError().toResponse();
        }
    }

    Caller authenticate() {
        return AccessGuard.authenticate(session);
    }

    void limit(RateLimiter.Limit limit, Caller caller) {
        if (rateLimiter == null) {
            rateLimiter = new RateLimiter(session.singleUseObjects());
        }
        rateLimiter.hit(limit, caller.user().getId());
    }

    /** The checks every attribute- or credential-changing endpoint shares, in order. */
    void beginMutation(Caller caller, RateLimiter.Limit limit) {
        UserProfileGuard.requireManagedAttributes(session);
        limit(limit, caller);
    }

    void requireSudo(Caller caller, String sudoToken) {
        sudoTokens.require(caller, sudoToken);
    }

    SudoTokens.Issued issueSudo(Caller caller, SudoTokens.Method method) {
        return sudoTokens.issue(caller, method);
    }

    EventBuilder event(Caller caller) {
        return new EventBuilder(realm, session, session.getContext().getConnection())
                .client(caller.client())
                .user(caller.user())
                .session(caller.userSession());
    }

    boolean isVerifiedYtu(UserModel user) {
        return session.users().getFederatedIdentity(realm, user, ytuIdpAlias) != null;
    }

    PolicyMessages policyMessages() {
        return new PolicyMessages(session);
    }

    static Response ok(int status, ObjectNode body) {
        return Response.status(status)
                .type(MediaType.APPLICATION_JSON_TYPE)
                .header(HttpHeaders.CACHE_CONTROL, "no-store")
                .entity(body.toString())
                .build();
    }

    static Response noContent() {
        return Response.noContent()
                .header(HttpHeaders.CACHE_CONTROL, "no-store")
                .build();
    }

    static String isoSeconds(long epochSeconds) {
        return Instant.ofEpochSecond(epochSeconds).toString();
    }
}
