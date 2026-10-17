package com.skylab.account;

import org.junit.jupiter.api.Test;
import org.keycloak.models.UserModel;
import org.keycloak.userprofile.ValidationException;
import org.keycloak.validate.ValidationError;

import static org.junit.jupiter.api.Assertions.assertEquals;

/**
 * Which value the realm's User Profile refused, as the sign-up form words it (eskylab-login-ux 09):
 * the names first, in the form's order, then the address (another account has it now), then the
 * username (taken between the choice and the write).
 */
class ProfileSignUpAccountsTest {

    private static ValidationException refused(String... attributes) {
        ValidationException.ValidationExceptionBuilder builder = new ValidationException.ValidationExceptionBuilder();
        for (String attribute : attributes) {
            builder.accept(new ValidationError("validator", attribute, "message-" + attribute));
        }
        return builder.build();
    }

    @Test
    void theNamesComeFirstThenTheAddressThenTheUsername() {
        assertEquals(SignUpAccounts.Refused.Reason.FIRST_NAME,
                ProfileSignUpAccounts.reasonOf(refused(UserModel.EMAIL, UserModel.FIRST_NAME, UserModel.LAST_NAME)));
        assertEquals(SignUpAccounts.Refused.Reason.LAST_NAME,
                ProfileSignUpAccounts.reasonOf(refused(UserModel.USERNAME, UserModel.LAST_NAME)));
        assertEquals(SignUpAccounts.Refused.Reason.ADDRESS_TAKEN,
                ProfileSignUpAccounts.reasonOf(refused(UserModel.USERNAME, UserModel.EMAIL)));
        assertEquals(SignUpAccounts.Refused.Reason.USERNAME_TAKEN, ProfileSignUpAccounts.reasonOf(refused(UserModel.USERNAME)));
        assertEquals(SignUpAccounts.Refused.Reason.OTHER, ProfileSignUpAccounts.reasonOf(refused("personalEmail")));
    }
}
