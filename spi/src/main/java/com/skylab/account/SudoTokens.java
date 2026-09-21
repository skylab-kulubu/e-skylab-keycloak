package com.skylab.account;

import org.jboss.logging.Logger;
import org.keycloak.TokenCategory;
import org.keycloak.common.util.SecretGenerator;
import org.keycloak.common.util.Time;
import org.keycloak.jose.jws.Algorithm;
import org.keycloak.jose.jws.JWSInput;
import org.keycloak.jose.jws.JWSInputException;
import org.keycloak.models.KeycloakSession;

import java.util.List;
import java.util.Objects;

/**
 * Issues and verifies Sudo mode tokens.
 *
 * <p>A sudo token is valid for five minutes and is deliberately <em>not</em> single-use: one
 * successful re-verification covers every sensitive action the person completes inside that
 * window, exactly as the Sudo mode definition promises. Replay is bounded by the window and by
 * the {@code sub}/{@code sid} binding: the token only works together with the very Account
 * Center bearer session that proved the credential. The BFF treats it as an opaque string:
 * it is signed with Keycloak's internal HMAC key and only this extension verifies it.
 */
final class SudoTokens {

    static final String TYPE = "sky-sudo";
    static final String AUDIENCE = "sky-account";
    static final String HEADER = "X-Sky-Sudo";
    static final int TTL_SECONDS = 300;
    static final int CLOCK_SKEW_SECONDS = 10;
    static final int MAX_TOKEN_LENGTH = 4096;

    private static final Logger LOG = Logger.getLogger(SudoTokens.class);

    private final KeycloakSession session;

    SudoTokens(KeycloakSession session) {
        this.session = session;
    }

    record Issued(String token, long expiresAt) {
    }

    /** How the person proved it is them: the audit name and the RFC 8176 {@code amr} value. */
    enum Method {
        PASSWORD("password", "pwd"),
        TOTP("totp", "otp");

        private final String auditName;
        private final String amr;

        Method(String auditName, String amr) {
            this.auditName = auditName;
            this.amr = amr;
        }

        String auditName() {
            return auditName;
        }

        String amr() {
            return amr;
        }
    }

    Issued issue(Caller caller, Method method) {
        SudoToken token = new SudoToken();
        token.id(SecretGenerator.getInstance().generateSecureID());
        token.type(TYPE);
        token.issuer(issuer(caller));
        token.subject(caller.user().getId());
        token.issuedFor(AccessGuard.ACCOUNT_CENTER_CLIENT_ID);
        token.audience(AUDIENCE);
        token.issuedNowWithTTL(TTL_SECONDS);
        token.setSessionId(caller.userSession().getId());
        token.setAuthenticationMethods(List.of(method.amr()));
        return new Issued(session.tokens().encode(token), token.getExp());
    }

    /** Verifies the presented sudo token for this caller or throws the matching 401 problem. */
    SudoToken require(Caller caller, String rawToken) {
        if (rawToken == null || rawToken.isBlank() || rawToken.length() > MAX_TOKEN_LENGTH) {
            throw Problems.sudoRequired().exception();
        }
        String presented = rawToken.trim();
        final Algorithm algorithm;
        try {
            algorithm = new JWSInput(presented).getHeader().getAlgorithm();
        } catch (JWSInputException | RuntimeException exception) {
            throw reject("malformed");
        }
        String expectedAlgorithm = session.tokens().signatureAlgorithm(TokenCategory.INTERNAL);
        if (algorithm == null || !algorithm.name().equals(expectedAlgorithm)) {
            throw reject("unexpected signature algorithm");
        }
        SudoToken token = session.tokens().decode(presented, SudoToken.class);
        if (token == null) {
            throw reject("signature or structure invalid");
        }
        if (!TYPE.equals(token.getType())) {
            throw reject("typ mismatch");
        }
        if (!issuer(caller).equals(token.getIssuer())) {
            throw reject("issuer mismatch");
        }
        if (!token.hasAudience(AUDIENCE)) {
            throw reject("audience mismatch");
        }
        if (!AccessGuard.ACCOUNT_CENTER_CLIENT_ID.equals(token.getIssuedFor())) {
            throw reject("azp mismatch");
        }
        if (token.getId() == null || token.getId().isBlank()) {
            throw reject("jti missing");
        }
        if (token.getExp() == null || token.getIat() == null) {
            throw reject("lifetime claims missing");
        }
        if (!Objects.equals(caller.user().getId(), token.getSubject())) {
            throw reject("subject mismatch");
        }
        if (!Objects.equals(caller.userSession().getId(), token.getSessionId())) {
            throw reject("session mismatch");
        }
        if (token.getIat() > Time.currentTime() + CLOCK_SKEW_SECONDS || !token.isNotBefore(CLOCK_SKEW_SECONDS)) {
            throw reject("issued in the future");
        }
        if (token.isExpired()) {
            LOG.debug("sky-account refused an expired sudo token");
            throw Problems.sudoExpired().exception();
        }
        return token;
    }

    /**
     * The realm issuer exactly as Keycloak wrote it into the verified bearer token, so the sudo
     * token is bound to the same issuer without recomputing URLs.
     */
    private static String issuer(Caller caller) {
        String issuer = caller.token().getIssuer();
        if (issuer == null || issuer.isBlank()) {
            throw reject("bearer without issuer");
        }
        return issuer;
    }

    private static ProblemException reject(String reason) {
        LOG.debugf("sky-account refused a sudo token: %s", reason);
        return Problems.sudoRequired().exception();
    }
}
