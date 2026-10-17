package com.skylab.account;

import org.keycloak.models.KeycloakSession;
import org.keycloak.models.UserModel;
import org.keycloak.models.credential.PasswordCredentialModel;

/** The one capability rule used by identity, send and verify; no school or pending-email fallback. */
final class SudoEmailEligibility {
    private SudoEmailEligibility() { }

    static boolean hasFactor(UserModel user) {
        return user.credentialManager().isConfiguredFor(PasswordCredentialModel.TYPE)
                || user.credentialManager().getStoredCredentialsStream()
                .anyMatch(credential -> Credentials.isPasskey(credential.getType()) || Credentials.isTotp(credential.getType()));
    }

    static String destination(KeycloakSession session, UserModel user) {
        String address = user.getEmail();
        if (!user.isEmailVerified() || address == null || address.isBlank()) return null;
        String normalized = EmailResource.normalise(address);
        return EmailResource.isValidAddress(session, normalized) ? normalized : null;
    }

    static boolean available(KeycloakSession session, UserModel user) {
        return !hasFactor(user) && destination(session, user) != null;
    }
}
