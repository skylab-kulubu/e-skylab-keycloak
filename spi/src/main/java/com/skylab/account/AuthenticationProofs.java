package com.skylab.account;

import org.jboss.logging.Logger;
import org.keycloak.TokenCategory;
import org.keycloak.TokenVerifier;
import org.keycloak.common.VerificationException;
import org.keycloak.common.util.Time;
import org.keycloak.crypto.SignatureProvider;
import org.keycloak.jose.jws.Algorithm;
import org.keycloak.jose.jws.JWSHeader;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.protocol.oidc.TokenManager;
import org.keycloak.representations.IDToken;
import org.keycloak.util.TokenUtil;

import java.util.ArrayList;
import java.util.List;
import java.util.Objects;

/**
 * Verifies that an ID token proves a fresh Keycloak authentication of the caller, so a person
 * with no password, TOTP or passkey (who re-verified through the YTÜ Microsoft login) can enter
 * Sudo mode.
 *
 * <p>The BFF received the ID token at its OIDC callback and presents it together with the
 * account-center bearer of the same session. The token is verified the way Keycloak verifies its
 * own tokens ({@link TokenVerifier}: signature by the realm key the header names, issuer, type,
 * audience, authorized party, lifetime, realm/client/user not-before) and then bound to the bearer
 * ({@code sub}, {@code sid}). Every refusal is the same {@code sudo_required} problem; only a token
 * that passed everything else is refused as {@code authentication_stale}, so that answer never
 * says anything about a token that did not verify.
 */
final class AuthenticationProofs {

    /** The proof is good for the Sudo mode window measured from the authentication itself. */
    static final int MAX_AGE_SECONDS = SudoTokens.TTL_SECONDS;
    /** Tolerance for {@code iat} and {@code auth_time} slightly ahead of this node's clock. */
    static final int CLOCK_SKEW_SECONDS = 30;
    static final int MAX_AMR_VALUES = 16;
    static final int MAX_AMR_LENGTH = 64;

    private static final Logger LOG = Logger.getLogger(AuthenticationProofs.class);
    private static final String AMR_CLAIM = "amr";

    private final KeycloakSession session;

    AuthenticationProofs(KeycloakSession session) {
        this.session = session;
    }

    /** A verified fresh authentication: when it happened and how (RFC 8176 {@code amr}). */
    record Proof(long authTime, List<String> amr) {

        /** When a sudo token for this proof must expire: five minutes after the authentication. */
        long expiresAt() {
            return authTime + MAX_AGE_SECONDS;
        }
    }

    /** Verifies the ID token for this caller or throws the matching 401 problem. */
    Proof verify(Caller caller, String rawToken) {
        if (rawToken == null || rawToken.isBlank()) {
            throw reject("missing");
        }
        TokenVerifier<IDToken> verifier = TokenVerifier.create(rawToken.trim(), IDToken.class);
        final JWSHeader header;
        try {
            header = verifier.getHeader();
        } catch (VerificationException | RuntimeException exception) {
            throw reject("malformed");
        }
        Algorithm algorithm = header.getAlgorithm();
        String expectedAlgorithm = session.tokens().signatureAlgorithm(TokenCategory.ID);
        if (algorithm == null || !algorithm.name().equals(expectedAlgorithm)) {
            throw reject("unexpected signature algorithm");
        }
        String kid = header.getKeyId();
        if (kid == null || kid.isBlank()) {
            throw reject("kid missing");
        }
        SignatureProvider signatures = session.getProvider(SignatureProvider.class, algorithm.name());
        if (signatures == null) {
            throw reject("no signature provider for the algorithm");
        }
        RealmModel realm = session.getContext().getRealm();
        final IDToken token;
        try {
            token = verifier.verifierContext(signatures.verifier(kid))
                    .realmUrl(SudoTokens.issuer(caller))
                    .tokenType(List.of(TokenUtil.TOKEN_TYPE_ID))
                    .audience(AccessGuard.ACCOUNT_CENTER_CLIENT_ID)
                    .issuedFor(AccessGuard.ACCOUNT_CENTER_CLIENT_ID)
                    .checkActive(true)
                    .withChecks(
                            TokenVerifier.SUBJECT_EXISTS_CHECK,
                            // "Push not-before" revocations of the realm, the client and the person.
                            TokenManager.NotBeforeCheck.forModel(caller.client()),
                            new TokenManager.NotBeforeCheck(session.users().getNotBeforeOfUser(realm, caller.user())))
                    .verify()
                    .getToken();
        } catch (VerificationException | RuntimeException exception) {
            throw reject("signature or claims invalid");
        }
        String[] audience = token.getAudience();
        if (audience == null || audience.length != 1) {
            throw reject("audience is not exactly account-center");
        }
        if (!Objects.equals(caller.user().getId(), token.getSubject())) {
            throw reject("subject mismatch");
        }
        if (token.getSessionId() == null || !Objects.equals(caller.userSession().getId(), token.getSessionId())) {
            throw reject("session mismatch");
        }
        long now = Time.currentTime();
        if (token.getIat() == null || token.getIat() > now + CLOCK_SKEW_SECONDS) {
            throw reject("issued in the future");
        }
        if (token.getExp() == null || token.getExp() < now) {
            throw reject("expired");
        }
        Long authTime = token.getAuth_time();
        if (authTime == null) {
            throw reject("auth_time missing");
        }
        if (authTime > now + CLOCK_SKEW_SECONDS) {
            throw reject("auth_time in the future");
        }
        if (now - authTime > MAX_AGE_SECONDS) {
            LOG.debug("sky-account refused a stale authentication proof");
            throw Problems.authenticationStale().exception();
        }
        return new Proof(authTime, amrOf(token));
    }

    /** The ID token's own {@code amr} when Keycloak's AMR mapper wrote a usable one, else {@code ["idp"]}. */
    private static List<String> amrOf(IDToken token) {
        List<String> fallback = SudoTokens.Method.AUTHENTICATION.amr();
        if (!(token.getOtherClaims().get(AMR_CLAIM) instanceof List<?> values)
                || values.isEmpty() || values.size() > MAX_AMR_VALUES) {
            return fallback;
        }
        List<String> amr = new ArrayList<>(values.size());
        for (Object value : values) {
            if (!(value instanceof String text) || text.isBlank() || text.length() > MAX_AMR_LENGTH) {
                return fallback;
            }
            amr.add(text);
        }
        return List.copyOf(amr);
    }

    private static ProblemException reject(String reason) {
        LOG.debugf("sky-account refused an authentication proof: %s", reason);
        return Problems.sudoRequired().exception();
    }
}
