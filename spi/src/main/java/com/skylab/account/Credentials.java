package com.skylab.account;

import com.fasterxml.jackson.databind.node.ObjectNode;
import org.keycloak.credential.CredentialModel;
import org.keycloak.models.credential.OTPCredentialModel;
import org.keycloak.models.credential.WebAuthnCredentialModel;
import org.keycloak.util.JsonSerialization;

import java.time.Instant;
import java.util.Set;

/**
 * The one place that knows which Keycloak credential types the Account Center may list and
 * remove: authenticator-app codes and passkeys. The password never appears here because the
 * person can only replace it, not delete it.
 */
final class Credentials {

    static final Set<String> TOTP_TYPES = Set.of(OTPCredentialModel.TYPE);
    static final Set<String> PASSKEY_TYPES = Set.of(
            WebAuthnCredentialModel.TYPE_PASSWORDLESS,
            WebAuthnCredentialModel.TYPE_TWOFACTOR);

    private Credentials() {
    }

    static boolean isTotp(String type) {
        return TOTP_TYPES.contains(type);
    }

    static boolean isPasskey(String type) {
        return PASSKEY_TYPES.contains(type);
    }

    static boolean isDeletable(String type) {
        return isTotp(type) || isPasskey(type);
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
}
