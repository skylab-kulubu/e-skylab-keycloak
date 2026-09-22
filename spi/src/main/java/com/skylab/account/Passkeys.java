package com.skylab.account;

import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.webauthn4j.WebAuthnRegistrationManager;
import com.webauthn4j.anchor.KeyStoreTrustAnchorRepository;
import com.webauthn4j.converter.util.ObjectConverter;
import com.webauthn4j.data.AttestationConveyancePreference;
import com.webauthn4j.data.AuthenticationRequest;
import com.webauthn4j.data.PublicKeyCredentialParameters;
import com.webauthn4j.data.PublicKeyCredentialType;
import com.webauthn4j.data.RegistrationData;
import com.webauthn4j.data.RegistrationParameters;
import com.webauthn4j.data.RegistrationRequest;
import com.webauthn4j.data.attestation.AttestationObject;
import com.webauthn4j.data.attestation.authenticator.AttestedCredentialData;
import com.webauthn4j.data.attestation.authenticator.AuthenticatorData;
import com.webauthn4j.data.attestation.statement.COSEAlgorithmIdentifier;
import com.webauthn4j.data.attestation.statement.NoneAttestationStatement;
import com.webauthn4j.data.client.Origin;
import com.webauthn4j.data.client.challenge.Challenge;
import com.webauthn4j.data.client.challenge.DefaultChallenge;
import com.webauthn4j.server.ServerProperty;
import com.webauthn4j.util.exception.WebAuthnException;
import com.webauthn4j.verifier.attestation.statement.AttestationStatementVerifier;
import com.webauthn4j.verifier.attestation.statement.androidkey.AndroidKeyAttestationStatementVerifier;
import com.webauthn4j.verifier.attestation.statement.androidsafetynet.AndroidSafetyNetAttestationStatementVerifier;
import com.webauthn4j.verifier.attestation.statement.none.NoneAttestationStatementVerifier;
import com.webauthn4j.verifier.attestation.statement.packed.PackedAttestationStatementVerifier;
import com.webauthn4j.verifier.attestation.statement.tpm.TPMAttestationStatementVerifier;
import com.webauthn4j.verifier.attestation.statement.u2f.FIDOU2FAttestationStatementVerifier;
import com.webauthn4j.verifier.attestation.trustworthiness.certpath.CertPathTrustworthinessVerifier;
import com.webauthn4j.verifier.attestation.trustworthiness.certpath.DefaultCertPathTrustworthinessVerifier;
import com.webauthn4j.verifier.attestation.trustworthiness.certpath.NullCertPathTrustworthinessVerifier;
import com.webauthn4j.verifier.attestation.trustworthiness.self.DefaultSelfAttestationTrustworthinessVerifier;
import com.webauthn4j.verifier.exception.BadOriginException;
import org.jboss.logging.Logger;
import org.keycloak.WebAuthnConstants;
import org.keycloak.common.util.Base64Url;
import org.keycloak.common.util.CollectionUtil;
import org.keycloak.common.util.SecretGenerator;
import org.keycloak.common.util.UriUtils;
import org.keycloak.credential.CredentialModel;
import org.keycloak.credential.CredentialProvider;
import org.keycloak.credential.WebAuthnCredentialModelInput;
import org.keycloak.credential.WebAuthnCredentialProvider;
import org.keycloak.credential.WebAuthnPasswordlessCredentialProviderFactory;
import org.keycloak.crypto.Algorithm;
import org.keycloak.models.Constants;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.ModelDuplicateException;
import org.keycloak.models.RealmModel;
import org.keycloak.models.SingleUseObjectProvider;
import org.keycloak.models.UserModel;
import org.keycloak.models.WebAuthnPolicy;
import org.keycloak.models.credential.WebAuthnCredentialModel;
import org.keycloak.truststore.TruststoreProvider;
import org.keycloak.util.JsonSerialization;

import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Base64;
import java.util.Collections;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;

/**
 * The passkey (WebAuthn passwordless) ceremonies the Account Center runs in the browser on
 * {@code my.}: creation and assertion options for {@code navigator.credentials.create/get}, and
 * the server-side verification of what the browser returns.
 *
 * <p>Verification is Keycloak's own: the realm <em>passwordless</em> {@link WebAuthnPolicy}, the
 * same webauthn4j {@link WebAuthnRegistrationManager} configuration as
 * {@code org.keycloak.authentication.requiredactions.WebAuthnRegister}, and for assertions the
 * {@code WebAuthnPasswordlessCredentialProvider} through {@code credentialManager().isValid(...)}
 * exactly as {@code org.keycloak.authentication.authenticators.browser.WebAuthnAuthenticator} does
 * (origin incl. extra origins, RP ID hash, challenge, user verification, signature, signature
 * counter update). Challenges live five minutes in Keycloak's single-use object store, bound to
 * the person and the Account Center session, and are consumed atomically before verification.
 */
final class Passkeys {

    static final int CHALLENGE_TTL_SECONDS = 300;
    static final int CHALLENGE_BYTES = 32;
    static final int MAX_BODY_BYTES = 64 * 1024;
    static final String CREDENTIAL_TYPE = WebAuthnCredentialModel.TYPE_PASSWORDLESS;
    static final Set<String> CREDENTIAL_FIELDS = Set.of(
            "id", "rawId", "type", "response", "authenticatorAttachment", "clientExtensionResults");
    static final Set<String> ATTESTATION_RESPONSE_FIELDS = Set.of(
            "clientDataJSON", "attestationObject", "transports", "authenticatorData", "publicKey", "publicKeyAlgorithm");
    static final Set<String> ASSERTION_RESPONSE_FIELDS = Set.of(
            "clientDataJSON", "authenticatorData", "signature", "userHandle");

    private static final Logger LOG = Logger.getLogger(Passkeys.class);
    private static final String REGISTER_KEY_PREFIX = "sky-account:webauthn:register:";
    private static final String ASSERT_KEY_PREFIX = "sky-account:webauthn:assert:";
    private static final String CHALLENGE_NOTE = "challenge";
    private static final String PUBLIC_KEY = "public-key";
    private static final Pattern BASE64URL = Pattern.compile("^[A-Za-z0-9_-]+={0,2}$");
    private static final Pattern TRANSPORT = Pattern.compile("^[a-z][a-z-]{0,31}$");
    private static final int MAX_CREDENTIAL_ID_BYTES = 1023;
    private static final int MAX_USER_HANDLE_BYTES = 64;
    private static final int MAX_CLIENT_DATA_BYTES = 8 * 1024;
    private static final int MAX_ATTESTATION_BYTES = 48 * 1024;
    private static final int MAX_AUTHENTICATOR_DATA_BYTES = 4 * 1024;
    private static final int MAX_SIGNATURE_BYTES = 2 * 1024;
    private static final int MAX_TRANSPORTS = 8;

    private final KeycloakSession session;
    private final RealmModel realm;

    Passkeys(KeycloakSession session) {
        this.session = session;
        this.realm = session.getContext().getRealm();
    }

    /** What the browser sent back from {@code navigator.credentials.create()}. */
    record Attestation(byte[] rawId, byte[] clientDataJSON, byte[] attestationObject, Set<String> transports,
                       String authenticatorAttachment) {
    }

    /** What the browser sent back from {@code navigator.credentials.get()}. */
    record Assertion(byte[] rawId, byte[] clientDataJSON, byte[] authenticatorData, byte[] signature,
                     byte[] userHandle) {
    }

    /** A passkey that was just stored: the Keycloak credential and its WebAuthn credential id. */
    record Registered(CredentialModel credential, String credentialId, String aaguid) {
    }

    /**
     * The outcome of an assertion check: verified (with the base64url id of the credential that
     * signed) or refused with the credential-failure problem the caller records as a failed attempt.
     */
    record AssertionOutcome(String credentialId, Problem refusal) {
        static AssertionOutcome verified(String credentialId) {
            return new AssertionOutcome(credentialId, null);
        }

        static AssertionOutcome refused(Problem refusal) {
            return new AssertionOutcome(null, refusal);
        }

        boolean isVerified() {
            return refusal == null;
        }
    }

    // ------------------------------------------------------------------ options

    /**
     * {@code PublicKeyCredentialCreationOptions} for the browser, shaped as Keycloak's own
     * {@code webauthnRegister.js} shapes them from the passwordless policy; stores a fresh
     * challenge for this person and session. {@code excludeCredentials} always lists the person's
     * passkeys, which is stricter than Keycloak's {@code avoidSameAuthenticatorRegister} switch:
     * registering the same authenticator twice never helps the person.
     */
    ObjectNode creationOptions(Caller caller) {
        requireProvider();
        WebAuthnPolicy policy = policy();
        UserModel user = caller.user();
        String challenge = storeChallenge(registerKey(caller));

        ObjectNode options = JsonSerialization.mapper.createObjectNode();
        ObjectNode rp = options.putObject("rp");
        rp.put("id", rpId());
        rp.put("name", rpEntityName(policy));
        ObjectNode userNode = options.putObject("user");
        userNode.put("id", userHandleOf(user));
        userNode.put("name", user.getUsername());
        userNode.put("displayName", displayNameOf(user));
        options.put("challenge", challenge);
        ArrayNode params = options.putArray("pubKeyCredParams");
        for (Long algorithm : signatureAlgorithms(policy)) {
            params.addObject().put("type", PUBLIC_KEY).put("alg", algorithm);
        }
        if (policy.getCreateTimeout() > 0) {
            options.put("timeout", policy.getCreateTimeout() * 1000L);
        }
        ArrayNode exclude = options.putArray("excludeCredentials");
        for (CredentialModel existing : passkeysOf(user)) {
            String credentialId = credentialIdOf(existing);
            if (credentialId == null) {
                continue;
            }
            ObjectNode descriptor = exclude.addObject().put("type", PUBLIC_KEY).put("id", credentialId);
            putTransports(descriptor, existing);
        }
        ObjectNode selection = options.putObject("authenticatorSelection");
        if (isSpecified(policy.getAuthenticatorAttachment())) {
            selection.put("authenticatorAttachment", policy.getAuthenticatorAttachment());
        }
        String residentKey = residentKeyOf(policy);
        if (residentKey != null) {
            selection.put("residentKey", residentKey);
            selection.put("requireResidentKey", Constants.WEBAUTHN_POLICY_OPTION_REQUIRED.equals(residentKey));
        }
        if (isSpecified(policy.getUserVerificationRequirement())) {
            selection.put("userVerification", policy.getUserVerificationRequirement());
        }
        if (selection.isEmpty()) {
            options.remove("authenticatorSelection");
        }
        if (isSpecified(policy.getAttestationConveyancePreference())) {
            options.put("attestation", policy.getAttestationConveyancePreference());
        }
        options.putObject("extensions").put("credProps", true);
        return options;
    }

    /**
     * {@code PublicKeyCredentialRequestOptions} for a Sudo mode assertion with the person's own
     * passkeys as allowed credentials; stores a fresh challenge for this person and session.
     */
    ObjectNode assertionOptions(Caller caller) {
        requireProvider();
        WebAuthnPolicy policy = policy();
        List<CredentialModel> passkeys = passkeysOf(caller.user());
        if (passkeys.isEmpty()) {
            throw Problems.passkeyNotRegistered().exception();
        }
        String challenge = storeChallenge(assertKey(caller));

        ObjectNode options = JsonSerialization.mapper.createObjectNode();
        options.put("challenge", challenge);
        options.put("rpId", rpId());
        if (policy.getCreateTimeout() > 0) {
            options.put("timeout", policy.getCreateTimeout() * 1000L);
        }
        ArrayNode allow = options.putArray("allowCredentials");
        for (CredentialModel passkey : passkeys) {
            String credentialId = credentialIdOf(passkey);
            if (credentialId == null) {
                continue;
            }
            ObjectNode descriptor = allow.addObject().put("type", PUBLIC_KEY).put("id", credentialId);
            putTransports(descriptor, passkey);
        }
        // Sudo mode always demands user verification, whatever the policy says (see verifyAssertion).
        options.put("userVerification", Constants.WEBAUTHN_POLICY_OPTION_REQUIRED);
        return options;
    }

    // ------------------------------------------------------------------ registration

    /**
     * Verifies the attestation against the challenge stored for this person and session, the
     * realm origin plus the policy's extra origins, the RP ID and the policy, then stores the
     * passkey with {@code label}. Every failure is a problem; the challenge is consumed first.
     */
    Registered register(Caller caller, Attestation attestation, String label) {
        WebAuthnCredentialProvider provider = requireProvider();
        WebAuthnPolicy policy = policy();
        UserModel user = caller.user();
        if (user.credentialManager().getStoredCredentialByNameAndType(label, CREDENTIAL_TYPE) != null) {
            throw Problems.duplicateLabel().exception();
        }
        Challenge challenge = consumeChallenge(registerKey(caller));
        ServerProperty serverProperty = new ServerProperty(allowedOrigins(), rpId(), challenge);
        boolean userVerificationRequired = isUserVerificationRequired(policy);
        RegistrationRequest registrationRequest = attestation.transports().isEmpty()
                ? new RegistrationRequest(attestation.attestationObject(), attestation.clientDataJSON())
                : new RegistrationRequest(attestation.attestationObject(), attestation.clientDataJSON(),
                        attestation.transports());
        RegistrationParameters registrationParameters = new RegistrationParameters(
                serverProperty, expectedCredentialParameters(policy), userVerificationRequired);

        final RegistrationData registrationData;
        try {
            WebAuthnRegistrationManager manager = registrationManager(policy);
            registrationData = manager.parse(registrationRequest);
            manager.verify(registrationData, registrationParameters);
            verifyCompliance(registrationData, policy, attestation.authenticatorAttachment());
        } catch (BadOriginException exception) {
            LOG.debugf("sky-account refused a passkey registration: origin not allowed (%s)", exception.getMessage());
            throw Problems.webAuthnOriginNotAllowed(400).exception();
        } catch (RuntimeException exception) {
            // WebAuthnException (verification, conversion) and anything else webauthn4j throws
            // on malformed input: refused, never a 500.
            LOG.debugf("sky-account refused a passkey registration: %s", exception.getMessage());
            throw Problems.webAuthnInvalid(400).exception();
        }

        AttestedCredentialData attested = attestedCredentialData(registrationData);
        if (attested == null || attested.getCredentialId() == null
                || !Arrays.equals(attested.getCredentialId(), attestation.rawId())) {
            LOG.debug("sky-account refused a passkey registration: rawId differs from the attested credential id");
            throw Problems.webAuthnInvalid(400).exception();
        }
        String credentialId = Base64Url.encode(attested.getCredentialId());
        for (CredentialModel existing : passkeysOf(user)) {
            if (credentialId.equals(credentialIdOf(existing))) {
                throw Problems.passkeyAlreadyRegistered().exception();
            }
        }

        WebAuthnCredentialModelInput credential = new WebAuthnCredentialModelInput(CREDENTIAL_TYPE);
        credential.setAttestedCredentialData(attested);
        credential.setCount(registrationData.getAttestationObject().getAuthenticatorData().getSignCount());
        credential.setAttestationStatementFormat(registrationData.getAttestationObject().getFormat());
        credential.setTransports(registrationData.getTransports());
        WebAuthnCredentialModel model = provider.getCredentialModelFromCredentialInput(credential, label);
        final CredentialModel stored;
        try {
            stored = provider.createCredential(realm, user, model);
        } catch (ModelDuplicateException exception) {
            throw Problems.duplicateLabel().exception();
        }
        if (stored == null) {
            throw Problems.internalError().exception();
        }
        return new Registered(stored, credentialId, model.getWebAuthnCredentialData().getAaguid());
    }

    // ------------------------------------------------------------------ assertion

    /**
     * Verifies a Sudo mode assertion with Keycloak's passwordless credential provider (the same
     * {@code credentialManager().isValid(...)} call the login flow makes), which also refuses a
     * signature counter that did not advance and persists the new counter. User verification is
     * demanded unconditionally: a step-up must prove the person, not merely possession of the
     * device, even if the realm policy only prefers it. Non-credential failures (no stored
     * challenge, no passkey) throw their problem instead of being refused, and anything that is
     * not a WebAuthn verification failure (persistence, corrupt credential data) propagates as
     * an internal error with rollback rather than masquerading as a refused assertion.
     */
    AssertionOutcome verifyAssertion(Caller caller, Assertion assertion) {
        requireProvider();
        UserModel user = caller.user();
        if (passkeysOf(user).isEmpty()) {
            throw Problems.passkeyNotRegistered().exception();
        }
        Challenge challenge = consumeChallenge(assertKey(caller));
        if (assertion.userHandle() != null
                && !Arrays.equals(assertion.userHandle(), user.getId().getBytes(StandardCharsets.UTF_8))) {
            LOG.debug("sky-account refused a passkey assertion: user handle belongs to another person");
            return AssertionOutcome.refused(Problems.webAuthnInvalid(401));
        }
        ServerProperty serverProperty = new ServerProperty(allowedOrigins(), rpId(), challenge);
        AuthenticationRequest authenticationRequest = new AuthenticationRequest(
                assertion.rawId(), assertion.authenticatorData(), assertion.clientDataJSON(), assertion.signature());
        WebAuthnCredentialModelInput input = new WebAuthnCredentialModelInput(CREDENTIAL_TYPE);
        input.setAuthenticationRequest(authenticationRequest);
        input.setAuthenticationParameters(new WebAuthnCredentialModelInput.KeycloakWebAuthnAuthenticationParameters(
                serverProperty, true));
        final boolean valid;
        try {
            valid = user.credentialManager().isValid(input);
        } catch (BadOriginException exception) {
            LOG.debugf("sky-account refused a passkey assertion: origin not allowed (%s)", exception.getMessage());
            return AssertionOutcome.refused(Problems.webAuthnOriginNotAllowed(401));
        } catch (WebAuthnException exception) {
            // Verification or conversion failure from webauthn4j, rethrown by Keycloak's provider.
            LOG.debugf("sky-account refused a passkey assertion: %s", exception.getMessage());
            return AssertionOutcome.refused(Problems.webAuthnInvalid(401));
        }
        if (!valid) {
            LOG.debug("sky-account refused a passkey assertion: unknown credential or signature counter regression");
            return AssertionOutcome.refused(Problems.webAuthnInvalid(401));
        }
        return AssertionOutcome.verified(Base64Url.encode(assertion.rawId()));
    }

    // ------------------------------------------------------------------ request parsing

    static Attestation parseAttestation(RequestBody body) {
        byte[] rawId = requireCredentialId(body);
        RequestBody response = body.requireObject("response", ATTESTATION_RESPONSE_FIELDS);
        byte[] clientDataJSON = decode(response, "clientDataJSON", 1, MAX_CLIENT_DATA_BYTES);
        byte[] attestationObject = decode(response, "attestationObject", 1, MAX_ATTESTATION_BYTES);
        Set<String> transports = new LinkedHashSet<>();
        for (String transport : response.optionalStringList("transports", MAX_TRANSPORTS, 32)) {
            if (!TRANSPORT.matcher(transport).matches()) {
                throw Problems.invalidRequest("response.transports").exception();
            }
            transports.add(transport);
        }
        String attachment = body.optionalString("authenticatorAttachment", 1, 32);
        if (attachment != null && !WebAuthnConstants.SUPPORTED_AUTHENTICATOR_ATTACHMENTS.contains(attachment)) {
            throw Problems.invalidRequest("authenticatorAttachment").exception();
        }
        return new Attestation(rawId, clientDataJSON, attestationObject, Collections.unmodifiableSet(transports),
                attachment);
    }

    static Assertion parseAssertion(RequestBody body) {
        byte[] rawId = requireCredentialId(body);
        RequestBody response = body.requireObject("response", ASSERTION_RESPONSE_FIELDS);
        byte[] clientDataJSON = decode(response, "clientDataJSON", 1, MAX_CLIENT_DATA_BYTES);
        byte[] authenticatorData = decode(response, "authenticatorData", 1, MAX_AUTHENTICATOR_DATA_BYTES);
        byte[] signature = decode(response, "signature", 1, MAX_SIGNATURE_BYTES);
        byte[] userHandle = response.has("userHandle") ? decode(response, "userHandle", 1, MAX_USER_HANDLE_BYTES) : null;
        return new Assertion(rawId, clientDataJSON, authenticatorData, signature, userHandle);
    }

    private static byte[] requireCredentialId(RequestBody body) {
        if (!PUBLIC_KEY.equals(body.requireString("type", 1, 32))) {
            throw Problems.invalidRequest("type").exception();
        }
        byte[] rawId = decode(body, "rawId", 1, MAX_CREDENTIAL_ID_BYTES);
        byte[] id = decode(body, "id", 1, MAX_CREDENTIAL_ID_BYTES);
        if (!Arrays.equals(rawId, id)) {
            throw Problems.invalidRequest("id").exception();
        }
        return rawId;
    }

    /** Base64url (RFC 4648 §5, padding optional) as {@code PublicKeyCredential.toJSON()} emits it. */
    static byte[] decode(RequestBody body, String field, int minBytes, int maxBytes) {
        String value = body.requireString(field, 1, maxBytes * 2);
        if (!BASE64URL.matcher(value).matches()) {
            throw body.invalid(field);
        }
        final byte[] bytes;
        try {
            bytes = Base64.getUrlDecoder().decode(value);
        } catch (IllegalArgumentException exception) {
            throw body.invalid(field);
        }
        if (bytes.length < minBytes || bytes.length > maxBytes) {
            throw body.invalid(field);
        }
        return bytes;
    }

    // ------------------------------------------------------------------ policy and realm

    WebAuthnPolicy policy() {
        return realm.getWebAuthnPolicyPasswordless();
    }

    /** The policy RP ID, or the realm host when the policy leaves it empty, as Keycloak resolves it. */
    String rpId() {
        String rpId = policy().getRpId();
        if (rpId == null || rpId.isEmpty()) {
            rpId = session.getContext().getUri().getBaseUri().getHost();
        }
        return rpId;
    }

    /**
     * The realm origin (the base URI Keycloak serves) plus the passwordless policy's extra origins:
     * the very set {@code WebAuthnRegister} accepts. A malformed extra origin is skipped, so it
     * never widens the set.
     */
    Set<Origin> allowedOrigins() {
        Set<Origin> origins = new HashSet<>();
        origins.add(new Origin(UriUtils.getOrigin(session.getContext().getUri().getBaseUri())));
        List<String> extra = policy().getExtraOrigins();
        for (String candidate : extra == null ? List.<String>of() : extra) {
            try {
                origins.add(new Origin(candidate.trim()));
            } catch (RuntimeException exception) {
                LOG.warnf("sky-account ignored a malformed extra origin in the passwordless WebAuthn policy of realm %s",
                        realm.getName());
            }
        }
        return origins;
    }

    static boolean isUserVerificationRequired(WebAuthnPolicy policy) {
        return Constants.WEBAUTHN_POLICY_OPTION_REQUIRED.equals(policy.getUserVerificationRequirement());
    }

    static String rpEntityName(WebAuthnPolicy policy) {
        String name = policy.getRpEntityName();
        return name == null || name.isBlank() ? Constants.DEFAULT_WEBAUTHN_POLICY_RP_ENTITY_NAME : name;
    }

    /** Keycloak's {@code residentKey} with the deprecated {@code requireResidentKey} as fallback. */
    static String residentKeyOf(WebAuthnPolicy policy) {
        if (isSpecified(policy.getResidentKey())) {
            return policy.getResidentKey();
        }
        @SuppressWarnings("deprecation")
        String legacy = policy.getRequireResidentKey();
        if (Constants.WEBAUTHN_POLICY_OPTION_YES.equals(legacy)) {
            return Constants.WEBAUTHN_POLICY_OPTION_REQUIRED;
        }
        if (Constants.WEBAUTHN_POLICY_OPTION_NO.equals(legacy)) {
            return Constants.WEBAUTHN_POLICY_OPTION_DISCOURAGED;
        }
        return null;
    }

    static boolean isSpecified(String policyOption) {
        return policyOption != null && !policyOption.isBlank()
                && !Constants.DEFAULT_WEBAUTHN_POLICY_NOT_SPECIFIED.equals(policyOption);
    }

    /** The policy's signature algorithms as COSE identifiers, ES256/RS256 when the policy lists none. */
    static List<Long> signatureAlgorithms(WebAuthnPolicy policy) {
        List<String> names = policy.getSignatureAlgorithm();
        if (CollectionUtil.isEmpty(names)) {
            names = List.of(Constants.DEFAULT_WEBAUTHN_POLICY_SIGNATURE_ALGORITHMS.split(","));
        }
        List<Long> algorithms = new ArrayList<>();
        for (String name : names) {
            Long algorithm = coseAlgorithm(name.trim());
            if (algorithm != null && !algorithms.contains(algorithm)) {
                algorithms.add(algorithm);
            }
        }
        if (algorithms.isEmpty()) {
            algorithms.add(COSEAlgorithmIdentifier.ES256.getValue());
        }
        return algorithms;
    }

    private static Long coseAlgorithm(String name) {
        return switch (name) {
            case Algorithm.ES256 -> COSEAlgorithmIdentifier.ES256.getValue();
            case Algorithm.RS256 -> COSEAlgorithmIdentifier.RS256.getValue();
            case Algorithm.ES384 -> COSEAlgorithmIdentifier.ES384.getValue();
            case Algorithm.RS384 -> COSEAlgorithmIdentifier.RS384.getValue();
            case Algorithm.ES512 -> COSEAlgorithmIdentifier.ES512.getValue();
            case Algorithm.RS512 -> COSEAlgorithmIdentifier.RS512.getValue();
            case Algorithm.Ed25519 -> COSEAlgorithmIdentifier.EdDSA.getValue();
            case "RS1" -> COSEAlgorithmIdentifier.RS1.getValue();
            default -> null;
        };
    }

    private static List<PublicKeyCredentialParameters> expectedCredentialParameters(WebAuthnPolicy policy) {
        return signatureAlgorithms(policy).stream()
                .map(algorithm -> new PublicKeyCredentialParameters(
                        PublicKeyCredentialType.PUBLIC_KEY, COSEAlgorithmIdentifier.create(algorithm)))
                .toList();
    }

    /**
     * The registration manager {@code WebAuthnRegister} builds: the attestation formats it accepts,
     * the trust anchors of Keycloak's truststore, and self attestation only while the policy lists
     * no acceptable AAGUIDs.
     */
    WebAuthnRegistrationManager registrationManager(WebAuthnPolicy policy) {
        List<AttestationStatementVerifier> verifiers = new ArrayList<>(6);
        String attestationPreference = policy.getAttestationConveyancePreference();
        if (attestationPreference == null
                || Constants.DEFAULT_WEBAUTHN_POLICY_NOT_SPECIFIED.equals(attestationPreference)
                || AttestationConveyancePreference.NONE.getValue().equals(attestationPreference)) {
            verifiers.add(new NoneAttestationStatementVerifier());
        }
        verifiers.add(new PackedAttestationStatementVerifier());
        verifiers.add(new TPMAttestationStatementVerifier());
        verifiers.add(new AndroidKeyAttestationStatementVerifier());
        verifiers.add(new AndroidSafetyNetAttestationStatementVerifier());
        verifiers.add(new FIDOU2FAttestationStatementVerifier());

        DefaultSelfAttestationTrustworthinessVerifier selfAttestationVerifier =
                new DefaultSelfAttestationTrustworthinessVerifier();
        List<String> acceptableAaguids = policy.getAcceptableAaguids();
        selfAttestationVerifier.setSelfAttestationAllowed(acceptableAaguids == null || acceptableAaguids.isEmpty());

        return new WebAuthnRegistrationManager(
                verifiers,
                certPathTrustworthinessVerifier(),
                selfAttestationVerifier,
                Collections.emptyList(),
                new ObjectConverter());
    }

    /** Trust anchors from Keycloak's truststore, as {@code WebAuthnRegisterFactory} wires them. */
    private CertPathTrustworthinessVerifier certPathTrustworthinessVerifier() {
        TruststoreProvider truststore = session.getProvider(TruststoreProvider.class);
        KeyStore keyStore = truststore == null ? null : truststore.getTruststore();
        if (keyStore == null) {
            return new NullCertPathTrustworthinessVerifier();
        }
        return new DefaultCertPathTrustworthinessVerifier(new KeyStoreTrustAnchorRepository(keyStore));
    }

    /**
     * The policy checks webauthn4j does not cover, as {@code WebAuthnRegister.PolicyVerifier}
     * applies them: acceptable AAGUIDs (only provable with a real attestation) and the required
     * authenticator attachment (client-reported, best effort).
     */
    static void verifyCompliance(RegistrationData registrationData, WebAuthnPolicy policy, String authenticatorAttachment) {
        List<String> acceptableAaguids = policy.getAcceptableAaguids();
        if (CollectionUtil.isNotEmpty(acceptableAaguids)) {
            AttestedCredentialData attested = attestedCredentialData(registrationData);
            if (attested == null) {
                throw new WebAuthnException("Cannot obtain attested credential data from the response");
            }
            String aaguid = attested.getAaguid().toString();
            if (NoneAttestationStatement.FORMAT.equals(registrationData.getAttestationObject().getFormat())) {
                throw new WebAuthnException("Acceptable AAGUIDs require an attestation format other than 'none'.");
            }
            if (acceptableAaguids.stream().noneMatch(aaguid::equals)) {
                throw new WebAuthnException("Not acceptable authenticator model (based on the AAGUID).");
            }
        }
        String requiredAttachment = policy.getAuthenticatorAttachment();
        if (!isSpecified(requiredAttachment)) {
            return;
        }
        if (authenticatorAttachment == null || authenticatorAttachment.isBlank()) {
            throw new WebAuthnException("Authenticator attachment is required by the policy but was not provided by the client.");
        }
        if (!WebAuthnConstants.SUPPORTED_AUTHENTICATOR_ATTACHMENTS.contains(authenticatorAttachment)) {
            throw new WebAuthnException("Unexpected authenticator attachment value.");
        }
        if (!requiredAttachment.equals(authenticatorAttachment)) {
            throw new WebAuthnException("Policy requires '" + requiredAttachment + "' authenticator attachment.");
        }
    }

    private static AttestedCredentialData attestedCredentialData(RegistrationData registrationData) {
        AttestationObject attestationObject = registrationData.getAttestationObject();
        if (attestationObject == null) {
            return null;
        }
        AuthenticatorData<?> authenticatorData = attestationObject.getAuthenticatorData();
        return authenticatorData == null ? null : authenticatorData.getAttestedCredentialData();
    }

    // ------------------------------------------------------------------ credentials

    /** Keycloak's passwordless credential provider; absent when the WebAuthn feature is off. */
    private WebAuthnCredentialProvider requireProvider() {
        CredentialProvider<?> provider = session.getProvider(CredentialProvider.class,
                WebAuthnPasswordlessCredentialProviderFactory.PROVIDER_ID);
        if (!(provider instanceof WebAuthnCredentialProvider webAuthnProvider)) {
            LOG.warnf("sky-account refused a passkey operation: the %s credential provider is unavailable "
                    + "(is the web-authn feature enabled?)", WebAuthnPasswordlessCredentialProviderFactory.PROVIDER_ID);
            throw Problems.webAuthnNotConfigured().exception();
        }
        return webAuthnProvider;
    }

    static List<CredentialModel> passkeysOf(UserModel user) {
        return user.credentialManager().getStoredCredentialsByTypeStream(CREDENTIAL_TYPE).toList();
    }

    /** The WebAuthn credential id (base64url) of a stored passkey, {@code null} when unreadable. */
    static String credentialIdOf(CredentialModel credential) {
        try {
            String base64 = WebAuthnCredentialModel.createFromCredentialModel(credential)
                    .getWebAuthnCredentialData().getCredentialId();
            return base64 == null ? null : Base64Url.encodeBase64ToBase64Url(base64);
        } catch (RuntimeException exception) {
            LOG.warnf("sky-account skipped passkey credential %s: unreadable credential data", credential.getId());
            return null;
        }
    }

    private static void putTransports(ObjectNode descriptor, CredentialModel credential) {
        Set<String> transports = Credentials.transportsOf(credential);
        if (transports.isEmpty()) {
            return;
        }
        ArrayNode node = descriptor.putArray("transports");
        for (String transport : transports) {
            node.add(transport);
        }
    }

    /** The user handle as Keycloak encodes it: base64url of the UTF-8 bytes of the user id. */
    static String userHandleOf(UserModel user) {
        return Base64Url.encode(user.getId().getBytes(StandardCharsets.UTF_8));
    }

    static String displayNameOf(UserModel user) {
        String first = user.getFirstName() == null ? "" : user.getFirstName().trim();
        String last = user.getLastName() == null ? "" : user.getLastName().trim();
        String full = (first + " " + last).trim();
        return full.isEmpty() ? user.getUsername() : full;
    }

    // ------------------------------------------------------------------ challenges

    private String storeChallenge(String key) {
        String challenge = Base64Url.encode(SecretGenerator.getInstance().randomBytes(CHALLENGE_BYTES));
        session.singleUseObjects().put(key, CHALLENGE_TTL_SECONDS, Map.of(CHALLENGE_NOTE, challenge));
        return challenge;
    }

    /** Removes and returns the stored challenge; only one caller can win this for a given key. */
    private Challenge consumeChallenge(String key) {
        SingleUseObjectProvider store = session.singleUseObjects();
        Map<String, String> notes = store.remove(key);
        String value = notes == null ? null : notes.get(CHALLENGE_NOTE);
        if (value == null || value.isBlank()) {
            throw Problems.webAuthnChallengeExpired().exception();
        }
        return new DefaultChallenge(value);
    }

    static String registerKey(Caller caller) {
        return REGISTER_KEY_PREFIX + caller.user().getId() + ":" + caller.userSession().getId();
    }

    static String assertKey(Caller caller) {
        return ASSERT_KEY_PREFIX + caller.user().getId() + ":" + caller.userSession().getId();
    }
}
