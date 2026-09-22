package com.skylab.account;

import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.keycloak.common.VerificationException;
import org.keycloak.common.util.Time;
import org.keycloak.crypto.Algorithm;
import org.keycloak.crypto.AsymmetricSignatureVerifierContext;
import org.keycloak.crypto.KeyStatus;
import org.keycloak.crypto.KeyType;
import org.keycloak.crypto.KeyUse;
import org.keycloak.crypto.KeyWrapper;
import org.keycloak.crypto.SignatureProvider;
import org.keycloak.crypto.SignatureSignerContext;
import org.keycloak.crypto.SignatureVerifierContext;
import org.keycloak.jose.jws.JWSBuilder;
import org.keycloak.jose.jws.JWSInput;
import org.keycloak.models.ClientModel;
import org.keycloak.models.KeycloakContext;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;
import org.keycloak.models.UserProvider;
import org.keycloak.models.UserSessionModel;
import org.keycloak.representations.AccessToken;
import org.keycloak.representations.IDToken;
import org.keycloak.util.TokenUtil;

import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.SecureRandom;
import java.util.Arrays;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class AuthenticationProofsTest {

    private static final String USER_ID = "11111111-1111-4111-8111-111111111111";
    private static final String OTHER_USER_ID = "22222222-2222-4222-8222-222222222222";
    private static final String SESSION_ID = "session-a";
    private static final String ISSUER = "http://localhost:18080/realms/e-skylab-test";
    private static final String KID = "realm-rsa";

    private final Fixture fixture = new Fixture();

    @AfterEach
    void resetClock() {
        Time.setOffset(0);
    }

    @Test
    void aFreshIdTokenOfTheBearerSessionProvesAuthenticationAndYieldsABoundSudoToken() throws Exception {
        long authenticatedAt = Time.currentTime() - 60;
        IDToken idToken = fixture.freshIdToken(authenticatedAt);

        AuthenticationProofs.Proof proof = fixture.proofs.verify(fixture.caller, fixture.sign(idToken));

        assertEquals(authenticatedAt, proof.authTime());
        assertEquals(List.of("idp"), proof.amr(), "no amr in the ID token means an identity-provider login");
        assertEquals(authenticatedAt + SudoTokens.TTL_SECONDS, proof.expiresAt());

        SudoTokens.Issued issued = fixture.sudoTokens.issue(
                fixture.caller, SudoTokens.Method.AUTHENTICATION, proof.expiresAt(), proof.amr());
        SudoToken sudo = new JWSInput(issued.token()).readJsonContent(SudoToken.class);
        assertEquals(authenticatedAt + SudoTokens.TTL_SECONDS, sudo.getExp(), "the window started at the login");
        assertEquals(List.of("idp"), sudo.getAuthenticationMethods());
        assertEquals(USER_ID, sudo.getSubject());
        assertEquals(SESSION_ID, sudo.getSessionId());
        assertEquals(sudo.getId(), fixture.sudoTokens.require(fixture.caller, issued.token()).getId());
    }

    @Test
    void reusesTheIdTokensOwnAmrWhenKeycloakWroteAUsableOne() {
        IDToken withAmr = fixture.freshIdToken(Time.currentTime() - 5);
        withAmr.setOtherClaims("amr", List.of("pwd", "otp"));
        assertEquals(List.of("pwd", "otp"), fixture.proofs.verify(fixture.caller, fixture.sign(withAmr)).amr());

        IDToken emptyAmr = fixture.freshIdToken(Time.currentTime() - 5);
        emptyAmr.setOtherClaims("amr", List.of());
        assertEquals(List.of("idp"), fixture.proofs.verify(fixture.caller, fixture.sign(emptyAmr)).amr());

        IDToken oddAmr = fixture.freshIdToken(Time.currentTime() - 5);
        oddAmr.setOtherClaims("amr", Arrays.asList("pwd", 42));
        assertEquals(List.of("idp"), fixture.proofs.verify(fixture.caller, fixture.sign(oddAmr)).amr());

        IDToken stringAmr = fixture.freshIdToken(Time.currentTime() - 5);
        stringAmr.setOtherClaims("amr", "pwd");
        assertEquals(List.of("idp"), fixture.proofs.verify(fixture.caller, fixture.sign(stringAmr)).amr());

        IDToken longAmr = fixture.freshIdToken(Time.currentTime() - 5);
        longAmr.setOtherClaims("amr", List.of("x".repeat(AuthenticationProofs.MAX_AMR_LENGTH + 1)));
        assertEquals(List.of("idp"), fixture.proofs.verify(fixture.caller, fixture.sign(longAmr)).amr());
    }

    @Test
    void refusesAnAuthenticationOlderThanTheSudoWindowWithItsOwnCode() {
        IDToken stale = fixture.freshIdToken(Time.currentTime() - AuthenticationProofs.MAX_AGE_SECONDS - 1);
        assertEquals("authentication_stale", failure(fixture.caller, fixture.sign(stale)));

        IDToken justInside = fixture.freshIdToken(Time.currentTime() - AuthenticationProofs.MAX_AGE_SECONDS + 5);
        assertEquals(List.of("idp"), fixture.proofs.verify(fixture.caller, fixture.sign(justInside)).amr());

        IDToken longLived = fixture.freshIdToken(Time.currentTime() - 10);
        longLived.exp(Time.currentTime() + 3600L);
        String signed = fixture.sign(longLived);
        Time.setOffset(AuthenticationProofs.MAX_AGE_SECONDS);
        assertEquals("authentication_stale", failure(fixture.caller, signed), "the clock moved past the window");
    }

    @Test
    void theStaleCodeNeverLeaksForATokenThatDoesNotVerify() {
        IDToken stale = fixture.freshIdToken(Time.currentTime() - AuthenticationProofs.MAX_AGE_SECONDS - 1);
        stale.setSessionId("session-b");
        assertEquals("sudo_required", failure(fixture.caller, fixture.sign(stale)));

        IDToken staleForeign = fixture.freshIdToken(Time.currentTime() - AuthenticationProofs.MAX_AGE_SECONDS - 1);
        assertEquals("sudo_required", failure(fixture.caller, fixture.signWith(staleForeign, generateRsaKey())));
    }

    @Test
    void refusesTheIdTokenOfAnotherSessionOrPerson() {
        IDToken otherSession = fixture.freshIdToken(Time.currentTime() - 5);
        otherSession.setSessionId("session-b");
        assertEquals("sudo_required", failure(fixture.caller, fixture.sign(otherSession)));

        IDToken noSession = fixture.freshIdToken(Time.currentTime() - 5);
        noSession.setSessionId(null);
        assertEquals("sudo_required", failure(fixture.caller, fixture.sign(noSession)));

        IDToken otherPerson = fixture.freshIdToken(Time.currentTime() - 5);
        otherPerson.subject(OTHER_USER_ID);
        assertEquals("sudo_required", failure(fixture.caller, fixture.sign(otherPerson)));

        String valid = fixture.sign(fixture.freshIdToken(Time.currentTime() - 5));
        assertEquals("sudo_required", failure(fixture.callerWith(USER_ID, "session-b"), valid));
        assertEquals("sudo_required", failure(fixture.callerWith(OTHER_USER_ID, SESSION_ID), valid));
    }

    @Test
    void refusesTheWrongAudienceAuthorizedPartyOrIssuer() {
        IDToken otherAudience = fixture.freshIdToken(Time.currentTime() - 5);
        otherAudience.audience(AccessGuard.ACCOUNT_CLIENT_ID);
        assertEquals("sudo_required", failure(fixture.caller, fixture.sign(otherAudience)));

        IDToken widerAudience = fixture.freshIdToken(Time.currentTime() - 5);
        widerAudience.audience(AccessGuard.ACCOUNT_CENTER_CLIENT_ID, AccessGuard.ACCOUNT_CLIENT_ID);
        assertEquals("sudo_required", failure(fixture.caller, fixture.sign(widerAudience)),
                "the audience must be exactly account-center");

        IDToken noAudience = fixture.freshIdToken(Time.currentTime() - 5);
        noAudience.audience((String[]) null);
        assertEquals("sudo_required", failure(fixture.caller, fixture.sign(noAudience)));

        IDToken otherParty = fixture.freshIdToken(Time.currentTime() - 5);
        otherParty.issuedFor("skyapp");
        assertEquals("sudo_required", failure(fixture.caller, fixture.sign(otherParty)));

        IDToken otherRealm = fixture.freshIdToken(Time.currentTime() - 5);
        otherRealm.issuer("http://localhost:18080/realms/other");
        assertEquals("sudo_required", failure(fixture.caller, fixture.sign(otherRealm)));
    }

    @Test
    void refusesTokensThatAreNotIdTokens() {
        IDToken bearerType = fixture.freshIdToken(Time.currentTime() - 5);
        bearerType.type(TokenUtil.TOKEN_TYPE_BEARER);
        assertEquals("sudo_required", failure(fixture.caller, fixture.sign(bearerType)),
                "an access token is not a proof of authentication");

        IDToken noType = fixture.freshIdToken(Time.currentTime() - 5);
        noType.type(null);
        assertEquals("sudo_required", failure(fixture.caller, fixture.sign(noType)));

        IDToken noSubject = fixture.freshIdToken(Time.currentTime() - 5);
        noSubject.subject(null);
        assertEquals("sudo_required", failure(fixture.caller, fixture.sign(noSubject)));
    }

    @Test
    void refusesExpiredFutureOrTimelessTokens() {
        long now = Time.currentTime();

        IDToken expired = fixture.freshIdToken(now - 5);
        expired.exp(now - 1);
        assertEquals("sudo_required", failure(fixture.caller, fixture.sign(expired)));

        IDToken noExpiry = fixture.freshIdToken(now - 5);
        noExpiry.exp(null);
        assertEquals("sudo_required", failure(fixture.caller, fixture.sign(noExpiry)));

        IDToken issuedInTheFuture = fixture.freshIdToken(now - 5);
        issuedInTheFuture.iat(now + AuthenticationProofs.CLOCK_SKEW_SECONDS + 1);
        assertEquals("sudo_required", failure(fixture.caller, fixture.sign(issuedInTheFuture)));

        IDToken slightlyAhead = fixture.freshIdToken(now - 5);
        slightlyAhead.iat(now + AuthenticationProofs.CLOCK_SKEW_SECONDS - 1);
        assertEquals(List.of("idp"), fixture.proofs.verify(fixture.caller, fixture.sign(slightlyAhead)).amr(),
                "a few seconds of clock skew are tolerated");

        IDToken noIssuedAt = fixture.freshIdToken(now - 5);
        noIssuedAt.iat(null);
        assertEquals("sudo_required", failure(fixture.caller, fixture.sign(noIssuedAt)));

        IDToken authenticatedInTheFuture = fixture.freshIdToken(now + AuthenticationProofs.CLOCK_SKEW_SECONDS + 1);
        assertEquals("sudo_required", failure(fixture.caller, fixture.sign(authenticatedInTheFuture)));

        IDToken noAuthTime = fixture.freshIdToken(now - 5);
        noAuthTime.setAuth_time(null);
        assertEquals("sudo_required", failure(fixture.caller, fixture.sign(noAuthTime)),
                "without auth_time there is no fresh authentication to prove");
    }

    @Test
    void refusesMalformedForeignOrDowngradedSignatures() {
        IDToken claims = fixture.freshIdToken(Time.currentTime() - 5);
        String valid = fixture.sign(claims);

        assertEquals("sudo_required", failure(fixture.caller, null));
        assertEquals("sudo_required", failure(fixture.caller, "   "));
        assertEquals("sudo_required", failure(fixture.caller, "not.a.jwt"));
        assertEquals("sudo_required", failure(fixture.caller, "x".repeat(RequestBody.MAX_BYTES)));

        // The first signature character carries only significant bits (the last one also carries padding).
        int signatureStart = valid.lastIndexOf('.') + 1;
        String tampered = valid.substring(0, signatureStart)
                + (valid.charAt(signatureStart) == 'A' ? 'B' : 'A')
                + valid.substring(signatureStart + 1);
        assertEquals("sudo_required", failure(fixture.caller, tampered));

        String foreignKey = fixture.signWith(claims, generateRsaKey());
        assertEquals("sudo_required", failure(fixture.caller, foreignKey), "same kid, another key");

        String unknownKid = new JWSBuilder().kid("rotated-away").type("JWT").jsonContent(claims)
                .rsa256(fixture.keyPair.getPrivate());
        assertEquals("sudo_required", failure(fixture.caller, unknownKid));

        String noKid = new JWSBuilder().type("JWT").jsonContent(claims).rsa256(fixture.keyPair.getPrivate());
        assertEquals("sudo_required", failure(fixture.caller, noKid));

        String internalHmac = new JWSBuilder().kid(InternalKeyTokenManager.KID).type("JWT").jsonContent(claims)
                .hmac512(fixture.hmacKey);
        assertEquals("sudo_required", failure(fixture.caller, internalHmac),
                "only the realm's ID token algorithm is accepted, even with a Keycloak key");

        String unsigned = new JWSBuilder().kid(KID).type("JWT").jsonContent(claims).none();
        assertEquals("sudo_required", failure(fixture.caller, unsigned));

        assertEquals(List.of("idp"), fixture.proofs.verify(fixture.caller, valid).amr(),
                "the untouched token still verifies");
    }

    @Test
    void honoursPushedNotBeforeOfTheRealmClientAndPerson() {
        long now = Time.currentTime();
        String valid = fixture.sign(fixture.freshIdToken(now - 5));

        when(fixture.realm.getNotBefore()).thenReturn((int) now + 1);
        assertEquals("sudo_required", failure(fixture.caller, valid), "realm not-before revokes the ID token");
        when(fixture.realm.getNotBefore()).thenReturn(0);

        when(fixture.client.getNotBefore()).thenReturn((int) now + 1);
        assertEquals("sudo_required", failure(fixture.caller, valid), "client not-before revokes the ID token");
        when(fixture.client.getNotBefore()).thenReturn(0);

        when(fixture.users.getNotBeforeOfUser(eq(fixture.realm), any())).thenReturn((int) now + 1);
        assertEquals("sudo_required", failure(fixture.caller, valid), "user not-before revokes the ID token");
        when(fixture.users.getNotBeforeOfUser(eq(fixture.realm), any())).thenReturn(0);

        assertEquals(List.of("idp"), fixture.proofs.verify(fixture.caller, valid).amr());
    }

    private String failure(Caller caller, String idToken) {
        ProblemException exception = assertThrows(ProblemException.class,
                () -> fixture.proofs.verify(caller, idToken));
        assertEquals(401, exception.problem().status());
        return exception.problem().code();
    }

    private static KeyPair generateRsaKey() {
        try {
            KeyPairGenerator generator = KeyPairGenerator.getInstance("RSA");
            generator.initialize(2048);
            return generator.generateKeyPair();
        } catch (Exception exception) {
            throw new IllegalStateException(exception);
        }
    }

    private static byte[] generateHmacKey() {
        byte[] key = new byte[64];
        new SecureRandom().nextBytes(key);
        return key;
    }

    /**
     * A realm with one active RS256 signing key (for ID tokens) and the HMAC key of the internal
     * token manager, an account-center bearer session, and the signature provider Keycloak would
     * hand out for {@code RS256}: it verifies with the realm key the {@code kid} names and knows
     * no other key.
     */
    private static final class Fixture {
        private final KeyPair keyPair = generateRsaKey();
        private final byte[] hmacKey = generateHmacKey();
        private final KeycloakSession session = mock(KeycloakSession.class);
        private final KeycloakContext context = mock(KeycloakContext.class);
        private final RealmModel realm = mock(RealmModel.class);
        private final UserProvider users = mock(UserProvider.class);
        private final ClientModel client = mock(ClientModel.class);
        private final AuthenticationProofs proofs;
        private final SudoTokens sudoTokens;
        private final Caller caller;

        private Fixture() {
            when(session.getContext()).thenReturn(context);
            when(context.getRealm()).thenReturn(realm);
            when(session.users()).thenReturn(users);
            when(session.tokens()).thenReturn(new InternalKeyTokenManager(hmacKey));
            when(client.getRealm()).thenReturn(realm);
            when(session.getProvider(SignatureProvider.class, Algorithm.RS256))
                    .thenReturn(new RealmRsaSignatureProvider());
            this.proofs = new AuthenticationProofs(session);
            this.sudoTokens = new SudoTokens(session);
            this.caller = callerWith(USER_ID, SESSION_ID);
        }

        private Caller callerWith(String userId, String sessionId) {
            UserModel user = mock(UserModel.class);
            when(user.getId()).thenReturn(userId);
            UserSessionModel userSession = mock(UserSessionModel.class);
            when(userSession.getId()).thenReturn(sessionId);
            AccessToken bearer = new AccessToken();
            bearer.issuer(ISSUER);
            return new Caller(user, userSession, bearer, client);
        }

        /** The ID token Keycloak issues to account-center at the callback of a login at {@code authenticatedAt}. */
        private IDToken freshIdToken(long authenticatedAt) {
            long now = Time.currentTime();
            IDToken token = new IDToken();
            token.id("id-token-1");
            token.type(TokenUtil.TOKEN_TYPE_ID);
            token.issuer(ISSUER);
            token.subject(USER_ID);
            token.audience(AccessGuard.ACCOUNT_CENTER_CLIENT_ID);
            token.issuedFor(AccessGuard.ACCOUNT_CENTER_CLIENT_ID);
            token.iat(now);
            token.exp(now + 300);
            token.setAuth_time(authenticatedAt);
            token.setSessionId(SESSION_ID);
            token.setNonce("nonce-ignored");
            token.setOtherClaims("sky_authorization", Map.of("skyapp", Map.of("roles", List.of("member"))));
            return token;
        }

        private String sign(IDToken token) {
            return signWith(token, keyPair);
        }

        private String signWith(IDToken token, KeyPair signer) {
            return new JWSBuilder().kid(KID).type("JWT").jsonContent(token).rsa256(signer.getPrivate());
        }

        private final class RealmRsaSignatureProvider implements SignatureProvider {
            @Override
            public SignatureSignerContext signer() {
                throw new UnsupportedOperationException();
            }

            @Override
            public SignatureSignerContext signer(KeyWrapper key) {
                throw new UnsupportedOperationException();
            }

            @Override
            public SignatureVerifierContext verifier(String kid) throws VerificationException {
                if (!KID.equals(kid)) {
                    throw new VerificationException("Key not found");
                }
                KeyWrapper key = new KeyWrapper();
                key.setKid(KID);
                key.setAlgorithm(Algorithm.RS256);
                key.setType(KeyType.RSA);
                key.setUse(KeyUse.SIG);
                key.setStatus(KeyStatus.ACTIVE);
                key.setPublicKey(keyPair.getPublic());
                return new AsymmetricSignatureVerifierContext(key);
            }

            @Override
            public SignatureVerifierContext verifier(KeyWrapper key) {
                throw new UnsupportedOperationException();
            }

            @Override
            public boolean isAsymmetricAlgorithm() {
                return true;
            }
        }
    }
}
