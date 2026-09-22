package com.skylab.account;

import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import org.jboss.logging.Logger;
import org.keycloak.credential.CredentialModel;
import org.keycloak.models.credential.OTPCredentialModel;
import org.keycloak.models.credential.WebAuthnCredentialModel;
import org.keycloak.util.JsonSerialization;

import java.time.Instant;
import java.util.Set;
import java.util.TreeSet;

/**
 * The one place that knows which Keycloak credential types the Account Center may list and
 * remove: authenticator-app codes and passkeys. Only passwordless WebAuthn credentials are
 * passkeys (they sign in and prove Sudo mode); a legacy two-factor {@code webauthn} credential
 * is never listed or used but stays deletable. The password never appears here because the
 * person can only replace it, not delete it.
 */
final class Credentials {

    static final Set<String> TOTP_TYPES = Set.of(OTPCredentialModel.TYPE);
    static final Set<String> PASSKEY_TYPES = Set.of(WebAuthnCredentialModel.TYPE_PASSWORDLESS);
    static final Set<String> LEGACY_WEBAUTHN_TYPES = Set.of(WebAuthnCredentialModel.TYPE_TWOFACTOR);

    private static final Logger LOG = Logger.getLogger(Credentials.class);

    private Credentials() {
    }

    static boolean isTotp(String type) {
        return TOTP_TYPES.contains(type);
    }

    static boolean isPasskey(String type) {
        return PASSKEY_TYPES.contains(type);
    }

    static boolean isLegacyWebAuthn(String type) {
        return LEGACY_WEBAUTHN_TYPES.contains(type);
    }

    static boolean isDeletable(String type) {
        return isTotp(type) || isPasskey(type) || isLegacyWebAuthn(type);
    }

    static ObjectNode summary(CredentialModel credential) {
        ObjectNode node = JsonSerialization.mapper.createObjectNode();
        node.put("id", credential.getId());
        node.put("type", credential.getType());
        String label = credential.getUserLabel();
        node.put("label", label == null || label.isBlank() ? null : label);
        Long createdDate = credential.getCreatedDate();
        if (createdDate == null) {
            node.putNull("createdAt");
        } else {
            node.put("createdAt", Instant.ofEpochMilli(createdDate).toString());
        }
        return node;
    }

    /**
     * The summary plus the authenticator transports the browser reported at registration (sorted,
     * empty when unknown). Unreadable credential data never hides the credential itself.
     */
    static ObjectNode passkeySummary(CredentialModel credential) {
        ObjectNode node = summary(credential);
        ArrayNode transports = node.putArray("transports");
        for (String transport : transportsOf(credential)) {
            transports.add(transport);
        }
        return node;
    }

    static Set<String> transportsOf(CredentialModel credential) {
        try {
            Set<String> stored = WebAuthnCredentialModel.createFromCredentialModel(credential)
                    .getWebAuthnCredentialData().getTransports();
            return stored == null ? new TreeSet<>() : new TreeSet<>(stored);
        } catch (RuntimeException exception) {
            LOG.debugf("sky-account could not read the transports of credential %s", credential.getId());
            return new TreeSet<>();
        }
    }
}
