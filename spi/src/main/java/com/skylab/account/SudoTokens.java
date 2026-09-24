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
 * it is signed with Keycloak's internal HMAC key, so only Keycloak can verify it: this
 * extension through {@link #require}, and core through Keycloak's introspection endpoint
 * (which is why core is the second audience).
 */
final class SudoTokens {

    static final String TYPE = "sky-sudo";
    static final String AUDIENCE = "sky-account";
    /**
     * The second audience: core verifies the sudo proof of a self-delete by introspecting the
     * token with its own confidential client, and Keycloak answers introspection only to a
     * client named in {@code aud} (K3e). {@link #require} still checks only {@link #AUDIENCE}.
     */
    static final String CORE_AUDIENCE = "core";
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

    /** How the person proved it is them: the audit name and the RFC 8176 {@code amr} values. */
    enum Method {
        PASSWORD("password", List.of("pwd")),
        TOTP("totp", List.of("otp")),
        /** A passkey assertion: a hardware-held key ({@code hwk}) after a user presence/verification test ({@code user}). */
        PASSKEY("passkey", List.of("hwk", "user")),
        /**
         * A fresh Keycloak authentication proven by its ID token (the Microsoft fallback for a person
         * without password, TOTP or passkey). {@code idp} is the default; an ID token that carries its
         * own {@code amr} (Keycloak's AMR mapper) hands those values through instead.
         */
        AUTHENTICATION("authentication", List.of("idp"));

        private final String auditName;
        private final List<String> amr;

        Method(String auditName, List<String> amr) {
            this.auditName = auditName;
            this.amr = amr;
        }

        String auditName() {
            return auditName;
        }

        List<String> amr() {
            return amr;
        }
    }

    Issued issue(Caller caller, Method method) {
        return issue(caller, method, Long.MAX_VALUE, method.amr());
    }

    /**
     * Issues a token that expires at {@code expiresAt} (epoch seconds) when that is earlier than
     * five minutes from now: a proof that was made earlier (a fresh authentication) must not
     * outlive the window that started when it was made. The window never extends past
     * {@code now + TTL_SECONDS}, whatever {@code expiresAt} says.
     */
    Issued issue(Caller caller, Method method, long expiresAt, List<String> amr) {
        long now = Time.currentTime();
        SudoToken token = new SudoToken();
        token.id(SecretGenerator.getInstance().generateSecureID());
        token.type(TYPE);
        token.issuer(issuer(caller));
        token.subject(caller.user().getId());
        token.issuedFor(AccessGuard.ACCOUNT_CENTER_CLIENT_ID);
        token.audience(AUDIENCE, CORE_AUDIENCE);
        token.iat(now);
        token.nbf(now);
        token.exp(Math.min(expiresAt, now + TTL_SECONDS));
        token.setSessionId(caller.userSession().getId());
        token.setAuthenticationMethods(List.copyOf(amr));
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
     * token (and the ID token of an authentication proof) is bound to the same issuer without
     * recomputing URLs.
     */
    static String issuer(Caller caller) {
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
