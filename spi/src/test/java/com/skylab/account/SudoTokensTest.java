package com.skylab.account;

import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.keycloak.common.util.Time;
import org.keycloak.jose.jws.JWSBuilder;
import org.keycloak.jose.jws.JWSInput;
import org.keycloak.models.ClientModel;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.UserModel;
import org.keycloak.models.UserSessionModel;
import org.keycloak.representations.AccessToken;

import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.SecureRandom;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class SudoTokensTest {

    private static final String USER_ID = "11111111-1111-4111-8111-111111111111";
    private static final String SESSION_ID = "session-a";
    private static final String ISSUER = "http://localhost:18080/realms/e-skylab-test";

    private final byte[] realmHmacKey = generateHmacKey();
    private final Fixture fixture = new Fixture(realmHmacKey);

    @AfterEach
    void resetClock() {
        Time.setOffset(0);
    }

    @Test
    void issuesAFiveMinuteTokenBoundToTheCallerAndSession() throws Exception {
        SudoTokens.Issued issued = fixture.sudoTokens.issue(fixture.caller, SudoTokens.Method.PASSWORD);
        SudoToken token = new JWSInput(issued.token()).readJsonContent(SudoToken.class);

        assertEquals(SudoTokens.TYPE, token.getType());
        assertEquals(ISSUER, token.getIssuer());
        assertEquals(USER_ID, token.getSubject());
        assertEquals(SESSION_ID, token.getSessionId());
        assertEquals(AccessGuard.ACCOUNT_CENTER_CLIENT_ID, token.getIssuedFor());
        assertEquals(List.of(SudoTokens.AUDIENCE), List.of(token.getAudience()));
        assertEquals(List.of("pwd"), token.getAuthenticationMethods());
        assertEquals(SudoTokens.TTL_SECONDS, token.getExp() - token.getIat());
        assertEquals(token.getExp(), issued.expiresAt());
        assertEquals(36, token.getId().length());

        assertEquals(token.getId(), fixture.sudoTokens.require(fixture.caller, issued.token()).getId());
    }

    @Test
    void aPasskeyProofRecordsAHardwareKeyAndUserPresenceInAmr() throws Exception {
        SudoTokens.Issued issued = fixture.sudoTokens.issue(fixture.caller, SudoTokens.Method.PASSKEY);
        SudoToken token = new JWSInput(issued.token()).readJsonContent(SudoToken.class);

        assertEquals(List.of("hwk", "user"), token.getAuthenticationMethods());
        assertEquals(token.getId(), fixture.sudoTokens.require(fixture.caller, issued.token()).getId());
    }

    @Test
    void aTokenForAnEarlierProofExpiresWithThatProofAndNeverLaterThanFiveMinutes() throws Exception {
        long now = Time.currentTime();
        long authenticatedAt = now - 120;

        SudoTokens.Issued issued = fixture.sudoTokens.issue(
                fixture.caller, SudoTokens.Method.AUTHENTICATION, authenticatedAt + SudoTokens.TTL_SECONDS, List.of("idp"));
        SudoToken token = new JWSInput(issued.token()).readJsonContent(SudoToken.class);

        assertEquals(authenticatedAt + SudoTokens.TTL_SECONDS, issued.expiresAt(), "the window starts at the authentication");
        assertEquals(issued.expiresAt(), token.getExp());
        assertTrue(Math.abs(token.getIat() - now) <= 1, "issued now");
        assertEquals(token.getIat(), token.getNbf());
        assertEquals(List.of("idp"), token.getAuthenticationMethods());
        assertEquals(SudoTokens.TYPE, token.getType());
        assertEquals(SESSION_ID, token.getSessionId());
        assertEquals(token.getId(), fixture.sudoTokens.require(fixture.caller, issued.token()).getId());

        Time.setOffset(SudoTokens.TTL_SECONDS - 120 + 1);
        assertEquals("sudo_expired", requireFailure(fixture.caller, issued.token()));
        Time.setOffset(0);

        SudoTokens.Issued capped = fixture.sudoTokens.issue(
                fixture.caller, SudoTokens.Method.AUTHENTICATION, now + 3600, List.of("pwd", "mfa"));
        SudoToken cappedToken = new JWSInput(capped.token()).readJsonContent(SudoToken.class);
        assertEquals(cappedToken.getIat() + SudoTokens.TTL_SECONDS, capped.expiresAt(), "never later than now + TTL");
        assertEquals(List.of("pwd", "mfa"), cappedToken.getAuthenticationMethods(), "the ID token's own amr is kept");
    }

    @Test
    void refusesATokenFromAnotherSessionOrSubject() {
        String token = fixture.sudoTokens.issue(fixture.caller, SudoTokens.Method.PASSWORD).token();

        Caller otherSession = fixture.callerWith(USER_ID, "session-b");
        assertEquals("sudo_required", requireFailure(otherSession, token));

        Caller otherUser = fixture.callerWith("22222222-2222-4222-8222-222222222222", SESSION_ID);
        assertEquals("sudo_required", requireFailure(otherUser, token));
    }

    @Test
    void refusesAnExpiredTokenWithItsOwnCode() throws Exception {
        String token = fixture.sudoTokens.issue(fixture.caller, SudoTokens.Method.TOTP).token();
        assertEquals(List.of("otp"), new JWSInput(token).readJsonContent(SudoToken.class).getAuthenticationMethods());

        Time.setOffset(SudoTokens.TTL_SECONDS - 1);
        fixture.sudoTokens.require(fixture.caller, token);

        Time.setOffset(SudoTokens.TTL_SECONDS + 1);
        assertEquals("sudo_expired", requireFailure(fixture.caller, token));
    }

    @Test
    void refusesTokensWithTheWrongTypeAudienceOrAuthorizedParty() {
        SudoToken wrongType = fixture.validClaims();
        wrongType.type("Bearer");
        assertEquals("sudo_required", requireFailure(fixture.caller, fixture.sign(wrongType)));

        SudoToken wrongAudience = fixture.validClaims();
        wrongAudience.audience("account");
        assertEquals("sudo_required", requireFailure(fixture.caller, fixture.sign(wrongAudience)));

        SudoToken wrongParty = fixture.validClaims();
        wrongParty.issuedFor("skyapp");
        assertEquals("sudo_required", requireFailure(fixture.caller, fixture.sign(wrongParty)));

        SudoToken wrongIssuer = fixture.validClaims();
        wrongIssuer.issuer("http://localhost:18080/realms/other");
        assertEquals("sudo_required", requireFailure(fixture.caller, fixture.sign(wrongIssuer)));

        SudoToken future = fixture.validClaims();
        future.iat((long) Time.currentTime() + 120).exp((long) Time.currentTime() + 420);
        assertEquals("sudo_required", requireFailure(fixture.caller, fixture.sign(future)));
    }

    @Test
    void refusesTokensSignedWithAnotherKeyOrAlgorithm() {
        SudoToken claims = fixture.validClaims();
        String foreignKey = new JWSBuilder().kid("realm-hmac").type("JWT").jsonContent(claims)
                .hmac512(generateHmacKey());
        assertEquals("sudo_required", requireFailure(fixture.caller, foreignKey));

        String weakerHmac = new JWSBuilder().kid("realm-hmac").type("JWT").jsonContent(claims)
                .hmac256(realmHmacKey);
        assertEquals("sudo_required", requireFailure(fixture.caller, weakerHmac));

        String asymmetric = new JWSBuilder().kid("realm-rsa").type("JWT").jsonContent(claims)
                .rsa256(generateRsaKey().getPrivate());
        assertEquals("sudo_required", requireFailure(fixture.caller, asymmetric));

        String unsigned = new JWSBuilder().type("JWT").jsonContent(claims).none();
        assertEquals("sudo_required", requireFailure(fixture.caller, unsigned));
    }

    @Test
    void refusesMissingOrMalformedTokens() {
        assertEquals("sudo_required", requireFailure(fixture.caller, null));
        assertEquals("sudo_required", requireFailure(fixture.caller, "   "));
        assertEquals("sudo_required", requireFailure(fixture.caller, "not.a.jwt"));
        assertEquals("sudo_required", requireFailure(fixture.caller, "x".repeat(SudoTokens.MAX_TOKEN_LENGTH + 1)));
    }

    private String requireFailure(Caller caller, String token) {
        ProblemException exception = assertThrows(ProblemException.class,
                () -> fixture.sudoTokens.require(caller, token));
        return exception.problem().code();
    }

    private static byte[] generateHmacKey() {
        byte[] key = new byte[64];
        new SecureRandom().nextBytes(key);
        return key;
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

    private static final class Fixture {
        private final KeycloakSession session = mock(KeycloakSession.class);
        private final byte[] key;
        private final SudoTokens sudoTokens;
        private final Caller caller;

        private Fixture(byte[] key) {
            this.key = key;
            when(session.tokens()).thenReturn(new InternalKeyTokenManager(key));
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
            return new Caller(user, userSession, bearer, mock(ClientModel.class));
        }

        private SudoToken validClaims() {
            SudoToken token = new SudoToken();
            token.id("jti-1");
            token.type(SudoTokens.TYPE);
            token.issuer(ISSUER);
            token.subject(USER_ID);
            token.issuedFor(AccessGuard.ACCOUNT_CENTER_CLIENT_ID);
            token.audience(SudoTokens.AUDIENCE);
            token.issuedNowWithTTL(SudoTokens.TTL_SECONDS);
            token.setSessionId(SESSION_ID);
            return token;
        }

        private String sign(SudoToken token) {
            return new JWSBuilder().kid("realm-hmac").type("JWT").jsonContent(token).hmac512(key);
        }
    }
}
