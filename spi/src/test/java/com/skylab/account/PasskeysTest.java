package com.skylab.account;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import org.junit.jupiter.api.Test;
import org.keycloak.credential.CredentialModel;
import org.keycloak.credential.CredentialProvider;
import org.keycloak.credential.WebAuthnPasswordlessCredentialProviderFactory;
import org.keycloak.models.credential.WebAuthnCredentialModel;
import org.keycloak.models.credential.dto.WebAuthnCredentialData;

import java.nio.charset.StandardCharsets;
import java.util.Base64;
import java.util.List;
import java.util.Map;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.when;

class PasskeysTest {

    private static final String REGISTER_KEY = "sky-account:webauthn:register:" + PasskeyFixture.USER_ID + ":"
            + PasskeyFixture.SESSION_ID;
    private static final String ASSERT_KEY = "sky-account:webauthn:assert:" + PasskeyFixture.USER_ID + ":"
            + PasskeyFixture.SESSION_ID;

    private final PasskeyFixture fixture = new PasskeyFixture();
    private final FakeAuthenticator authenticator = new FakeAuthenticator();

    // ------------------------------------------------------------------ options

    @Test
    void creationOptionsFollowThePasswordlessPolicyAndStoreTheChallenge() {
        ObjectNode options = fixture.passkeys().creationOptions(fixture.caller);

        assertEquals("localhost", options.get("rp").get("id").asText(), "an empty policy rpId falls back to the realm host");
        assertEquals("SKY LAB", options.get("rp").get("name").asText());
        assertEquals(base64url(PasskeyFixture.USER_ID.getBytes(StandardCharsets.UTF_8)), options.get("user").get("id").asText());
        assertEquals("account-fixture", options.get("user").get("name").asText());
        assertEquals("Ada Lovelace", options.get("user").get("displayName").asText());
        assertEquals(List.of(-7L, -257L), longs(options.get("pubKeyCredParams"), "alg"));
        assertEquals("public-key", options.get("pubKeyCredParams").get(0).get("type").asText());
        assertEquals("required", options.get("authenticatorSelection").get("residentKey").asText());
        assertTrue(options.get("authenticatorSelection").get("requireResidentKey").asBoolean());
        assertEquals("required", options.get("authenticatorSelection").get("userVerification").asText());
        assertNull(options.get("authenticatorSelection").get("authenticatorAttachment"));
        assertNull(options.get("attestation"), "an unspecified attestation preference is left to the browser default");
        assertNull(options.get("timeout"), "createTimeout 0 means no timeout");
        assertEquals(0, options.get("excludeCredentials").size());
        assertTrue(options.get("extensions").get("credProps").asBoolean());

        String challenge = options.get("challenge").asText();
        assertEquals(32, Base64.getUrlDecoder().decode(challenge).length);
        assertEquals(Map.of("challenge", challenge), fixture.store.peek(REGISTER_KEY));
        assertEquals(300L, fixture.store.lifespan(REGISTER_KEY));
    }

    @Test
    void creationOptionsCarryEveryPolicySettingTheRealmSpecifies() {
        registerPasskey("MacBook");
        fixture.policy.setRpId("yildizskylab.com");
        fixture.policy.setCreateTimeout(90);
        fixture.policy.setAttestationConveyancePreference("direct");
        fixture.policy.setAuthenticatorAttachment("platform");
        fixture.policy.setSignatureAlgorithm(List.of("ES256", "Ed25519", "bogus"));

        ObjectNode options = fixture.passkeys().creationOptions(fixture.caller);

        assertEquals("yildizskylab.com", options.get("rp").get("id").asText());
        assertEquals(90_000L, options.get("timeout").asLong(), "timeout is the policy seconds in milliseconds");
        assertEquals("direct", options.get("attestation").asText());
        assertEquals("platform", options.get("authenticatorSelection").get("authenticatorAttachment").asText());
        assertEquals(List.of(-7L, -8L), longs(options.get("pubKeyCredParams"), "alg"), "unknown algorithms are dropped");
        JsonNode excluded = options.get("excludeCredentials");
        assertEquals(1, excluded.size());
        assertEquals(authenticator.credentialIdBase64Url(), excluded.get(0).get("id").asText());
        assertEquals("public-key", excluded.get(0).get("type").asText());
        assertEquals(List.of("hybrid", "internal"), strings(excluded.get(0).get("transports")));
    }

    @Test
    void assertionOptionsListThePersonsPasskeysOrRefuseWhenThereAreNone() {
        ProblemException none = assertThrows(ProblemException.class,
                () -> fixture.passkeys().assertionOptions(fixture.caller));
        assertEquals("passkey_not_registered", none.problem().code());
        assertEquals(400, none.problem().status());
        assertNull(fixture.store.peek(ASSERT_KEY), "no challenge is stored for a person without passkeys");

        registerPasskey("MacBook");
        ObjectNode options = fixture.passkeys().assertionOptions(fixture.caller);

        assertEquals("localhost", options.get("rpId").asText());
        assertEquals("required", options.get("userVerification").asText());
        assertNull(options.get("timeout"));
        assertEquals(1, options.get("allowCredentials").size());
        assertEquals(authenticator.credentialIdBase64Url(), options.get("allowCredentials").get(0).get("id").asText());
        assertEquals(List.of("hybrid", "internal"), strings(options.get("allowCredentials").get(0).get("transports")));
        assertEquals(Map.of("challenge", options.get("challenge").asText()), fixture.store.peek(ASSERT_KEY));
        assertEquals(300L, fixture.store.lifespan(ASSERT_KEY));
    }

    @Test
    void refusesEveryPasskeyOperationWhenKeycloakHasNoPasswordlessProvider() {
        when(fixture.session.getProvider(CredentialProvider.class, WebAuthnPasswordlessCredentialProviderFactory.PROVIDER_ID))
                .thenReturn(null);

        for (Runnable operation : List.<Runnable>of(
                () -> fixture.passkeys().creationOptions(fixture.caller),
                () -> fixture.passkeys().assertionOptions(fixture.caller),
                () -> fixture.passkeys().register(fixture.caller, attestation(PasskeyFixture.EXTRA_ORIGIN, "x"), "MacBook"),
                () -> fixture.passkeys().verifyAssertion(fixture.caller, assertion(PasskeyFixture.EXTRA_ORIGIN, "x", 1)))) {
            ProblemException exception = assertThrows(ProblemException.class, operation::run);
            assertEquals("webauthn_not_configured", exception.problem().code());
            assertEquals(503, exception.problem().status());
        }
        assertNull(fixture.store.peek(REGISTER_KEY));
    }

    // ------------------------------------------------------------------ registration

    @Test
    void registersAPasskeyAttestedOnAnExtraOriginAndConsumesTheChallenge() {
        String challenge = creationChallenge();
        Passkeys.Attestation attestation = attestation(PasskeyFixture.EXTRA_ORIGIN, challenge);

        Passkeys.Registered registered = fixture.passkeys().register(fixture.caller, attestation, "MacBook");

        assertEquals(authenticator.credentialIdBase64Url(), registered.credentialId());
        assertEquals("00000000-0000-0000-0000-000000000000", registered.aaguid());
        CredentialModel stored = fixture.onlyPasskey();
        assertEquals(registered.credential().getId(), stored.getId());
        assertEquals(WebAuthnCredentialModel.TYPE_PASSWORDLESS, stored.getType());
        assertEquals("MacBook", stored.getUserLabel());
        assertNotNull(stored.getCreatedDate());
        WebAuthnCredentialData data = WebAuthnCredentialModel.createFromCredentialModel(stored).getWebAuthnCredentialData();
        assertArrayEquals(authenticator.credentialId, Base64.getDecoder().decode(data.getCredentialId()));
        assertEquals(0L, data.getCounter());
        assertEquals("none", data.getAttestationStatementFormat());
        assertEquals(Set.of("internal", "hybrid"), data.getTransports());
        assertNull(fixture.store.peek(REGISTER_KEY), "the challenge is consumed");

        ProblemException replay = assertThrows(ProblemException.class,
                () -> fixture.passkeys().register(fixture.caller, attestation, "MacBook 2"));
        assertEquals("webauthn_challenge_expired", replay.problem().code());
        assertEquals(400, replay.problem().status());
        assertEquals(1, fixture.credentials.size());
    }

    @Test
    void registersOnTheRealmOriginToo() {
        Passkeys.Attestation attestation = attestation(PasskeyFixture.KEYCLOAK_ORIGIN, creationChallenge());

        fixture.passkeys().register(fixture.caller, attestation, "Telefon");

        assertEquals("Telefon", fixture.onlyPasskey().getUserLabel());
    }

    @Test
    void refusesAttestationsFromAnOriginThePolicyDoesNotAllow() {
        ProblemException exception = assertThrows(ProblemException.class, () -> fixture.passkeys()
                .register(fixture.caller, attestation(PasskeyFixture.OTHER_ORIGIN, creationChallenge()), "MacBook"));

        assertEquals("webauthn_origin_not_allowed", exception.problem().code());
        assertEquals(400, exception.problem().status());
        assertTrue(fixture.credentials.isEmpty());
        assertNull(fixture.store.peek(REGISTER_KEY), "a refused attestation still consumes the challenge");
    }

    @Test
    void refusesAttestationsWithoutAStoredChallengeOrWithAnotherChallenge() {
        ProblemException none = assertThrows(ProblemException.class, () -> fixture.passkeys()
                .register(fixture.caller, attestation(PasskeyFixture.EXTRA_ORIGIN, base64url(new byte[32])), "MacBook"));
        assertEquals("webauthn_challenge_expired", none.problem().code());

        creationChallenge();
        ProblemException other = assertThrows(ProblemException.class, () -> fixture.passkeys()
                .register(fixture.caller, attestation(PasskeyFixture.EXTRA_ORIGIN, base64url(new byte[32])), "MacBook"));
        assertEquals("webauthn_invalid", other.problem().code());
        assertEquals(400, other.problem().status());
        assertTrue(fixture.credentials.isEmpty());
    }

    @Test
    void refusesAttestationsWithoutUserVerificationWrongRpIdOrMismatchedRawId() {
        ProblemException noVerification = assertThrows(ProblemException.class, () -> fixture.passkeys().register(
                fixture.caller, authenticator.attest(PasskeyFixture.EXTRA_ORIGIN, creationChallenge(), "localhost", false, 0),
                "MacBook"));
        assertEquals("webauthn_invalid", noVerification.problem().code());

        ProblemException wrongRpId = assertThrows(ProblemException.class, () -> fixture.passkeys().register(
                fixture.caller, authenticator.attest(PasskeyFixture.EXTRA_ORIGIN, creationChallenge(), "example.com", true, 0),
                "MacBook"));
        assertEquals("webauthn_invalid", wrongRpId.problem().code());

        ProblemException otherRawId = assertThrows(ProblemException.class, () -> fixture.passkeys().register(
                fixture.caller, authenticator.attest(PasskeyFixture.EXTRA_ORIGIN, creationChallenge(), "localhost", true, 0,
                        new byte[] {1, 2, 3}), "MacBook"));
        assertEquals("webauthn_invalid", otherRawId.problem().code());

        creationChallenge();
        ProblemException garbage = assertThrows(ProblemException.class, () -> fixture.passkeys().register(
                fixture.caller, new Passkeys.Attestation(authenticator.credentialId, "{}".getBytes(StandardCharsets.UTF_8),
                        new byte[] {(byte) 0xa0}, Set.of(), null), "MacBook"));
        assertEquals("webauthn_invalid", garbage.problem().code());
        assertTrue(fixture.credentials.isEmpty());
    }

    @Test
    void refusesDuplicateLabelsAndAlreadyRegisteredCredentials() {
        registerPasskey("MacBook");

        ProblemException sameLabel = assertThrows(ProblemException.class, () -> fixture.passkeys().register(
                fixture.caller, new FakeAuthenticator().attest(PasskeyFixture.EXTRA_ORIGIN, creationChallenge(), "localhost", true, 0),
                "MacBook"));
        assertEquals("duplicate_label", sameLabel.problem().code());
        assertEquals(409, sameLabel.problem().status());
        assertNotNull(fixture.store.peek(REGISTER_KEY), "a duplicate label is refused before the ceremony is consumed");

        ProblemException sameCredential = assertThrows(ProblemException.class, () -> fixture.passkeys().register(
                fixture.caller, attestation(PasskeyFixture.EXTRA_ORIGIN, creationChallenge()), "MacBook 2"));
        assertEquals("passkey_already_registered", sameCredential.problem().code());
        assertEquals(409, sameCredential.problem().status());

        ProblemException caseInsensitive = assertThrows(ProblemException.class, () -> fixture.passkeys().register(
                fixture.caller, new FakeAuthenticator().attest(PasskeyFixture.EXTRA_ORIGIN, creationChallenge(), "localhost", true, 0),
                "macbook"));
        assertEquals("duplicate_label", caseInsensitive.problem().code(), "Keycloak's store compares labels case-insensitively");
        assertEquals(1, fixture.credentials.size());
    }

    @Test
    void policyComplianceMirrorsKeycloaksAcceptableAaguidsAndAttachmentRules() {
        fixture.policy.setAcceptableAaguids(List.of("00000000-0000-0000-0000-000000000000"));
        ProblemException noneAttestation = assertThrows(ProblemException.class, () -> fixture.passkeys()
                .register(fixture.caller, attestation(PasskeyFixture.EXTRA_ORIGIN, creationChallenge()), "MacBook"));
        assertEquals("webauthn_invalid", noneAttestation.problem().code(),
                "acceptable AAGUIDs need a real attestation, so a 'none' attestation is refused like in Keycloak");

        fixture.policy.setAcceptableAaguids(List.of());
        fixture.policy.setAuthenticatorAttachment("platform");
        ProblemException noAttachment = assertThrows(ProblemException.class, () -> fixture.passkeys()
                .register(fixture.caller, attestation(PasskeyFixture.EXTRA_ORIGIN, creationChallenge()), "MacBook"));
        assertEquals("webauthn_invalid", noAttachment.problem().code());

        Passkeys.Attestation withAttachment = attestation(PasskeyFixture.EXTRA_ORIGIN, creationChallenge());
        fixture.passkeys().register(fixture.caller, new Passkeys.Attestation(withAttachment.rawId(),
                withAttachment.clientDataJSON(), withAttachment.attestationObject(), withAttachment.transports(),
                "platform"), "MacBook");
        assertEquals(1, fixture.credentials.size());
    }

    // ------------------------------------------------------------------ assertions

    @Test
    void verifiesAssertionsAdvancesTheCounterAndRefusesAReplayedOrRegressedCounter() {
        registerPasskey("MacBook");

        Passkeys.AssertionOutcome first = fixture.passkeys()
                .verifyAssertion(fixture.caller, assertion(PasskeyFixture.EXTRA_ORIGIN, assertionChallenge(), 1));
        assertTrue(first.isVerified());
        assertEquals(authenticator.credentialIdBase64Url(), first.credentialId());
        assertEquals(1L, storedCounter());
        assertNull(fixture.store.peek(ASSERT_KEY), "the assertion challenge is consumed");

        Passkeys.Assertion second = assertion(PasskeyFixture.KEYCLOAK_ORIGIN, assertionChallenge(), 5);
        assertTrue(fixture.passkeys().verifyAssertion(fixture.caller, second).isVerified());
        assertEquals(5L, storedCounter());

        ProblemException replay = assertThrows(ProblemException.class,
                () -> fixture.passkeys().verifyAssertion(fixture.caller, second));
        assertEquals("webauthn_challenge_expired", replay.problem().code(), "a replayed assertion finds no challenge");

        Passkeys.AssertionOutcome regressed = fixture.passkeys()
                .verifyAssertion(fixture.caller, assertion(PasskeyFixture.EXTRA_ORIGIN, assertionChallenge(), 3));
        assertFalse(regressed.isVerified());
        assertEquals("webauthn_invalid", regressed.refusal().code());
        assertEquals(401, regressed.refusal().status());
        assertEquals(5L, storedCounter(), "a regressed counter is refused and never stored");
    }

    @Test
    void refusesAssertionsFromOtherOriginsOtherPeopleOrUnknownPasskeys() {
        registerPasskey("MacBook");

        Passkeys.AssertionOutcome origin = fixture.passkeys()
                .verifyAssertion(fixture.caller, assertion(PasskeyFixture.OTHER_ORIGIN, assertionChallenge(), 1));
        assertEquals("webauthn_origin_not_allowed", origin.refusal().code());
        assertEquals(401, origin.refusal().status());

        Passkeys.AssertionOutcome otherPerson = fixture.passkeys().verifyAssertion(fixture.caller, authenticator
                .assertion(PasskeyFixture.EXTRA_ORIGIN, assertionChallenge(), "localhost", true, 1, "22222222-2222-4222-8222-222222222222"));
        assertEquals("webauthn_invalid", otherPerson.refusal().code());

        Passkeys.AssertionOutcome unknownKey = fixture.passkeys().verifyAssertion(fixture.caller, new FakeAuthenticator()
                .assertion(PasskeyFixture.EXTRA_ORIGIN, assertionChallenge(), "localhost", true, 1, PasskeyFixture.USER_ID));
        assertEquals("webauthn_invalid", unknownKey.refusal().code());

        Passkeys.AssertionOutcome noVerification = fixture.passkeys().verifyAssertion(fixture.caller, authenticator
                .assertion(PasskeyFixture.EXTRA_ORIGIN, assertionChallenge(), "localhost", false, 1, PasskeyFixture.USER_ID));
        assertEquals("webauthn_invalid", noVerification.refusal().code());

        assertionChallenge();
        Passkeys.AssertionOutcome wrongChallenge = fixture.passkeys().verifyAssertion(fixture.caller, authenticator
                .assertion(PasskeyFixture.EXTRA_ORIGIN, base64url(new byte[32]), "localhost", true, 1, PasskeyFixture.USER_ID));
        assertEquals("webauthn_invalid", wrongChallenge.refusal().code());

        ProblemException noChallenge = assertThrows(ProblemException.class, () -> fixture.passkeys()
                .verifyAssertion(fixture.caller, assertion(PasskeyFixture.EXTRA_ORIGIN, base64url(new byte[32]), 1)));
        assertEquals("webauthn_challenge_expired", noChallenge.problem().code());
        assertEquals(0L, storedCounter(), "no refused assertion touched the counter");
    }

    @Test
    void sudoDemandsUserVerificationEvenWhenThePolicyOnlyPrefersIt() {
        registerPasskey("MacBook");
        fixture.policy.setUserVerificationRequirement("preferred");

        ObjectNode options = fixture.passkeys().assertionOptions(fixture.caller);
        assertEquals("required", options.get("userVerification").asText());

        Passkeys.AssertionOutcome withoutVerification = fixture.passkeys().verifyAssertion(fixture.caller, authenticator
                .assertion(PasskeyFixture.EXTRA_ORIGIN, options.get("challenge").asText(), "localhost", false, 1, PasskeyFixture.USER_ID));
        assertEquals("webauthn_invalid", withoutVerification.refusal().code());

        Passkeys.AssertionOutcome verified = fixture.passkeys()
                .verifyAssertion(fixture.caller, assertion(PasskeyFixture.EXTRA_ORIGIN, assertionChallenge(), 1));
        assertTrue(verified.isVerified());
    }

    @Test
    void aPersistenceFailureDuringAssertionIsNotReportedAsARefusedPasskey() {
        registerPasskey("MacBook");
        org.mockito.Mockito.doThrow(new IllegalStateException("database unavailable"))
                .when(fixture.credentialManager).updateStoredCredential(org.mockito.ArgumentMatchers.any());

        IllegalStateException failure = assertThrows(IllegalStateException.class, () -> fixture.passkeys()
                .verifyAssertion(fixture.caller, assertion(PasskeyFixture.EXTRA_ORIGIN, assertionChallenge(), 1)));

        assertEquals("database unavailable", failure.getMessage());
    }

    @Test
    void assertionsWithoutAUserHandleRelyOnTheSignedInPerson() {
        registerPasskey("MacBook");

        Passkeys.AssertionOutcome outcome = fixture.passkeys().verifyAssertion(fixture.caller,
                authenticator.assertion(PasskeyFixture.EXTRA_ORIGIN, assertionChallenge(), "localhost", true, 1, null));

        assertTrue(outcome.isVerified());
    }

    // ------------------------------------------------------------------ parsing

    @Test
    void parsesThePublicKeyCredentialJsonTheBrowserProduces() {
        String rawId = authenticator.credentialIdBase64Url();
        RequestBody body = RequestBody.parse("{\"id\":\"" + rawId + "\",\"rawId\":\"" + rawId + "\",\"type\":\"public-key\","
                + "\"authenticatorAttachment\":\"platform\",\"clientExtensionResults\":{\"credProps\":{\"rk\":true}},"
                + "\"response\":{\"clientDataJSON\":\"e30\",\"attestationObject\":\"oA==\",\"transports\":[\"internal\",\"hybrid\"],"
                + "\"publicKeyAlgorithm\":-7,\"publicKey\":\"AQID\",\"authenticatorData\":\"AQID\"}}",
                Passkeys.CREDENTIAL_FIELDS, Passkeys.MAX_BODY_BYTES);

        Passkeys.Attestation attestation = Passkeys.parseAttestation(body);

        assertArrayEquals(authenticator.credentialId, attestation.rawId());
        assertEquals("{}", new String(attestation.clientDataJSON(), StandardCharsets.UTF_8));
        assertArrayEquals(new byte[] {(byte) 0xa0}, attestation.attestationObject());
        assertEquals(Set.of("internal", "hybrid"), attestation.transports());
        assertEquals("platform", attestation.authenticatorAttachment());

        RequestBody assertionBody = RequestBody.parse("{\"id\":\"" + rawId + "\",\"rawId\":\"" + rawId + "\",\"type\":\"public-key\","
                + "\"clientExtensionResults\":{},\"response\":{\"clientDataJSON\":\"e30\",\"authenticatorData\":\"AQID\","
                + "\"signature\":\"BAUG\",\"userHandle\":null}}", Passkeys.CREDENTIAL_FIELDS, Passkeys.MAX_BODY_BYTES);

        Passkeys.Assertion assertion = Passkeys.parseAssertion(assertionBody);

        assertArrayEquals(new byte[] {1, 2, 3}, assertion.authenticatorData());
        assertArrayEquals(new byte[] {4, 5, 6}, assertion.signature());
        assertNull(assertion.userHandle());
    }

    @Test
    void refusesCredentialJsonThatIsNotWhatTheBrowserProduces() {
        String rawId = authenticator.credentialIdBase64Url();
        assertEquals("type", invalidAttestation("{\"id\":\"" + rawId + "\",\"rawId\":\"" + rawId + "\",\"type\":\"password\","
                + "\"response\":{\"clientDataJSON\":\"e30\",\"attestationObject\":\"oA\"}}"));
        assertEquals("id", invalidAttestation("{\"id\":\"AAAA\",\"rawId\":\"" + rawId + "\",\"type\":\"public-key\","
                + "\"response\":{\"clientDataJSON\":\"e30\",\"attestationObject\":\"oA\"}}"));
        assertEquals("rawId", invalidAttestation("{\"id\":\"" + rawId + "\",\"rawId\":\"not base64url!\",\"type\":\"public-key\","
                + "\"response\":{\"clientDataJSON\":\"e30\",\"attestationObject\":\"oA\"}}"));
        assertEquals("response", invalidAttestation("{\"id\":\"" + rawId + "\",\"rawId\":\"" + rawId + "\",\"type\":\"public-key\"}"));
        assertEquals("response.signature", invalidAttestation("{\"id\":\"" + rawId + "\",\"rawId\":\"" + rawId + "\",\"type\":\"public-key\","
                + "\"response\":{\"clientDataJSON\":\"e30\",\"attestationObject\":\"oA\",\"signature\":\"AQ\"}}"));
        assertEquals("response.transports", invalidAttestation("{\"id\":\"" + rawId + "\",\"rawId\":\"" + rawId + "\",\"type\":\"public-key\","
                + "\"response\":{\"clientDataJSON\":\"e30\",\"attestationObject\":\"oA\",\"transports\":[\"USB drive\"]}}"));
        assertEquals("authenticatorAttachment", invalidAttestation("{\"id\":\"" + rawId + "\",\"rawId\":\"" + rawId + "\",\"type\":\"public-key\","
                + "\"authenticatorAttachment\":\"remote\",\"response\":{\"clientDataJSON\":\"e30\",\"attestationObject\":\"oA\"}}"));
        assertEquals("label", invalidAttestation("{\"id\":\"" + rawId + "\",\"rawId\":\"" + rawId + "\",\"type\":\"public-key\",\"label\":\"x\","
                + "\"response\":{\"clientDataJSON\":\"e30\",\"attestationObject\":\"oA\"}}"));
        assertEquals("response.userHandle", invalidAssertion("{\"id\":\"" + rawId + "\",\"rawId\":\"" + rawId + "\",\"type\":\"public-key\","
                + "\"response\":{\"clientDataJSON\":\"e30\",\"authenticatorData\":\"AQID\",\"signature\":\"BAUG\",\"userHandle\":\""
                + base64url(new byte[65]) + "\"}}"));
    }

    // ------------------------------------------------------------------ helpers

    private String creationChallenge() {
        return fixture.passkeys().creationOptions(fixture.caller).get("challenge").asText();
    }

    private String assertionChallenge() {
        return fixture.passkeys().assertionOptions(fixture.caller).get("challenge").asText();
    }

    private Passkeys.Attestation attestation(String origin, String challenge) {
        return authenticator.attest(origin, challenge, "localhost", true, 0);
    }

    private Passkeys.Assertion assertion(String origin, String challenge, long signCount) {
        return authenticator.assertion(origin, challenge, "localhost", true, signCount, PasskeyFixture.USER_ID);
    }

    private void registerPasskey(String label) {
        fixture.passkeys().register(fixture.caller, attestation(PasskeyFixture.EXTRA_ORIGIN, creationChallenge()), label);
    }

    private long storedCounter() {
        return WebAuthnCredentialModel.createFromCredentialModel(fixture.onlyPasskey()).getWebAuthnCredentialData().getCounter();
    }

    private static String invalidAttestation(String json) {
        return invalidField(json, body -> Passkeys.parseAttestation(body));
    }

    private static String invalidAssertion(String json) {
        return invalidField(json, body -> Passkeys.parseAssertion(body));
    }

    private static String invalidField(String json, java.util.function.Consumer<RequestBody> read) {
        ProblemException exception = assertThrows(ProblemException.class,
                () -> read.accept(RequestBody.parse(json, Passkeys.CREDENTIAL_FIELDS, Passkeys.MAX_BODY_BYTES)));
        assertEquals("invalid_request", exception.problem().code());
        return (String) exception.problem().extensions().get("field");
    }

    private static String base64url(byte[] bytes) {
        return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes);
    }

    private static List<Long> longs(JsonNode array, String field) {
        List<Long> values = new java.util.ArrayList<>();
        array.forEach(node -> values.add(node.get(field).asLong()));
        return values;
    }

    private static List<String> strings(JsonNode array) {
        List<String> values = new java.util.ArrayList<>();
        array.forEach(node -> values.add(node.asText()));
        return values;
    }
}
