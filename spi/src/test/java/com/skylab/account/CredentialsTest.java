package com.skylab.account;

import com.fasterxml.jackson.databind.node.ObjectNode;
import org.junit.jupiter.api.Test;
import org.keycloak.credential.CredentialModel;
import org.keycloak.models.credential.OTPCredentialModel;
import org.keycloak.models.credential.WebAuthnCredentialModel;

import java.util.Set;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class CredentialsTest {

    @Test
    void passkeySummariesCarrySortedTransportsAndSurviveUnreadableData() {
        WebAuthnCredentialModel passkey = WebAuthnCredentialModel.create(
                WebAuthnCredentialModel.TYPE_PASSWORDLESS, "MacBook", "00000000-0000-0000-0000-000000000000",
                "AQID", null, "pk", 3, "none", Set.of("internal", "hybrid"));
        passkey.setId("cred-1");
        passkey.setCreatedDate(1_758_460_000_000L);

        ObjectNode summary = Credentials.passkeySummary(passkey);

        assertEquals("cred-1", summary.get("id").asText());
        assertEquals("webauthn-passwordless", summary.get("type").asText());
        assertEquals("MacBook", summary.get("label").asText());
        assertEquals("2025-09-21T13:06:40Z", summary.get("createdAt").asText());
        assertEquals(2, summary.get("transports").size());
        assertEquals("hybrid", summary.get("transports").get(0).asText());
        assertEquals("internal", summary.get("transports").get(1).asText());

        CredentialModel corrupt = new CredentialModel();
        corrupt.setId("cred-2");
        corrupt.setType(WebAuthnCredentialModel.TYPE_PASSWORDLESS);
        corrupt.setCredentialData("not json");
        ObjectNode corruptSummary = Credentials.passkeySummary(corrupt);
        assertEquals("cred-2", corruptSummary.get("id").asText());
        assertEquals(0, corruptSummary.get("transports").size());
        assertTrue(corruptSummary.get("label").isNull());
        assertTrue(corruptSummary.get("createdAt").isNull());
    }

    @Test
    void onlyPasswordlessWebAuthnCredentialsArePasskeysButLegacyOnesStayDeletable() {
        assertTrue(Credentials.isPasskey(WebAuthnCredentialModel.TYPE_PASSWORDLESS));
        assertFalse(Credentials.isPasskey(WebAuthnCredentialModel.TYPE_TWOFACTOR));
        assertFalse(Credentials.isPasskey(OTPCredentialModel.TYPE));
        assertTrue(Credentials.isLegacyWebAuthn(WebAuthnCredentialModel.TYPE_TWOFACTOR));

        assertTrue(Credentials.isDeletable(OTPCredentialModel.TYPE));
        assertTrue(Credentials.isDeletable(WebAuthnCredentialModel.TYPE_PASSWORDLESS));
        assertTrue(Credentials.isDeletable(WebAuthnCredentialModel.TYPE_TWOFACTOR));
        assertFalse(Credentials.isDeletable("password"));
    }
}
