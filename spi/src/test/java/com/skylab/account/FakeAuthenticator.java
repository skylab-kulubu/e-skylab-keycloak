package com.skylab.account;

import com.webauthn4j.converter.AttestationObjectConverter;
import com.webauthn4j.converter.AuthenticatorDataConverter;
import com.webauthn4j.converter.util.ObjectConverter;
import com.webauthn4j.data.attestation.AttestationObject;
import com.webauthn4j.data.attestation.authenticator.AAGUID;
import com.webauthn4j.data.attestation.authenticator.AttestedCredentialData;
import com.webauthn4j.data.attestation.authenticator.AuthenticatorData;
import com.webauthn4j.data.attestation.authenticator.EC2COSEKey;
import com.webauthn4j.data.attestation.statement.COSEAlgorithmIdentifier;
import com.webauthn4j.data.attestation.statement.NoneAttestationStatement;
import com.webauthn4j.data.extension.authenticator.AuthenticationExtensionAuthenticatorOutput;
import com.webauthn4j.data.extension.authenticator.RegistrationExtensionAuthenticatorOutput;

import java.nio.charset.StandardCharsets;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.security.Signature;
import java.security.spec.ECGenParameterSpec;
import java.util.Base64;
import java.util.Set;

/**
 * A software passkey for tests: one ES256 key pair with a credential id, producing "none"
 * attestations and signed assertions exactly as a browser would hand them to the BFF.
 */
final class FakeAuthenticator {

    private static final ObjectConverter CONVERTER = new ObjectConverter();
    private static final Base64.Encoder BASE64URL = Base64.getUrlEncoder().withoutPadding();

    final KeyPair keyPair;
    final byte[] credentialId;

    FakeAuthenticator() {
        try {
            KeyPairGenerator generator = KeyPairGenerator.getInstance("EC");
            generator.initialize(new ECGenParameterSpec("secp256r1"));
            keyPair = generator.generateKeyPair();
        } catch (Exception exception) {
            throw new IllegalStateException(exception);
        }
        credentialId = new byte[32];
        new SecureRandom().nextBytes(credentialId);
    }

    String credentialIdBase64Url() {
        return BASE64URL.encodeToString(credentialId);
    }

    /** {@code navigator.credentials.create()} as the BFF forwards it. */
    Passkeys.Attestation attest(String origin, String challenge, String rpId, boolean userVerified, long signCount) {
        return attest(origin, challenge, rpId, userVerified, signCount, credentialId);
    }

    Passkeys.Attestation attest(String origin, String challenge, String rpId, boolean userVerified, long signCount,
                                byte[] rawId) {
        byte[] clientDataJSON = clientData("webauthn.create", challenge, origin);
        byte flags = (byte) (AuthenticatorData.BIT_UP | AuthenticatorData.BIT_AT
                | (userVerified ? AuthenticatorData.BIT_UV : 0));
        AttestedCredentialData attested = new AttestedCredentialData(
                AAGUID.ZERO, credentialId, EC2COSEKey.create(keyPair, COSEAlgorithmIdentifier.ES256));
        AuthenticatorData<RegistrationExtensionAuthenticatorOutput> authenticatorData =
                new AuthenticatorData<>(sha256(rpId), flags, signCount, attested);
        AttestationObject attestationObject = new AttestationObject(authenticatorData, new NoneAttestationStatement());
        byte[] attestationBytes = new AttestationObjectConverter(CONVERTER).convertToBytes(attestationObject);
        return new Passkeys.Attestation(rawId, clientDataJSON, attestationBytes, Set.of("internal", "hybrid"), null);
    }

    /** {@code navigator.credentials.get()} as the BFF forwards it. */
    Passkeys.Assertion assertion(String origin, String challenge, String rpId, boolean userVerified, long signCount,
                                 String userId) {
        byte[] clientDataJSON = clientData("webauthn.get", challenge, origin);
        byte flags = (byte) (AuthenticatorData.BIT_UP | (userVerified ? AuthenticatorData.BIT_UV : 0));
        AuthenticatorData<AuthenticationExtensionAuthenticatorOutput> authenticatorData =
                new AuthenticatorData<>(sha256(rpId), flags, signCount);
        byte[] authenticatorBytes = new AuthenticatorDataConverter(CONVERTER).convert(authenticatorData);
        byte[] signed = new byte[authenticatorBytes.length + 32];
        System.arraycopy(authenticatorBytes, 0, signed, 0, authenticatorBytes.length);
        System.arraycopy(sha256Bytes(clientDataJSON), 0, signed, authenticatorBytes.length, 32);
        byte[] userHandle = userId == null ? null : userId.getBytes(StandardCharsets.UTF_8);
        return new Passkeys.Assertion(credentialId, clientDataJSON, authenticatorBytes, sign(signed), userHandle);
    }

    private byte[] sign(byte[] data) {
        try {
            Signature signature = Signature.getInstance("SHA256withECDSA");
            signature.initSign(keyPair.getPrivate());
            signature.update(data);
            return signature.sign();
        } catch (Exception exception) {
            throw new IllegalStateException(exception);
        }
    }

    private static byte[] clientData(String type, String challenge, String origin) {
        String json = "{\"type\":\"" + type + "\",\"challenge\":\"" + challenge + "\",\"origin\":\"" + origin
                + "\",\"crossOrigin\":false}";
        return json.getBytes(StandardCharsets.UTF_8);
    }

    static byte[] sha256(String value) {
        return sha256Bytes(value.getBytes(StandardCharsets.UTF_8));
    }

    static byte[] sha256Bytes(byte[] value) {
        try {
            return MessageDigest.getInstance("SHA-256").digest(value);
        } catch (Exception exception) {
            throw new IllegalStateException(exception);
        }
    }
}
