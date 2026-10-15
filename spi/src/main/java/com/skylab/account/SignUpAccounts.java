package com.skylab.account;

import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;

/**
 * Opens the account of a Self-registration (eskylab-login-ux 09) for {@link EmailCodeAuthenticator}.
 * The real one ({@link ProfileSignUpAccounts}) goes through Keycloak's User Profile; a unit test
 * keeps what it was handed.
 */
interface SignUpAccounts {

    /**
     * Opens an enabled account with {@code username}, the proven {@code address} as its verified
     * Primary e-mail and its proven Personal e-mail ({@link PersonalEmailProof}), the two names, no
     * credential, the realm's default roles and groups only.
     *
     * @throws Refused when the realm's User Profile refuses a value, or the address or the username
     *                 went to another account meanwhile
     */
    UserModel open(KeycloakSession session, RealmModel realm, String username, String address,
            String firstName, String lastName) throws Refused;

    /** Why an account was not opened; nothing was written. */
    final class Refused extends Exception {

        enum Reason {
            /** The User Profile refused the first name. */
            FIRST_NAME,
            /** The User Profile refused the last name. */
            LAST_NAME,
            /** Another account holds the address now. */
            ADDRESS_TAKEN,
            /** Another account took the username between the choice and the write. */
            USERNAME_TAKEN,
            /** Anything else; the person may try again. */
            OTHER
        }

        private final Reason reason;

        Refused(Reason reason) {
            super(reason.name(), null, false, false);
            this.reason = reason;
        }

        Reason reason() {
            return reason;
        }
    }
}
