package com.skylab.account;

import org.keycloak.common.util.Time;
import org.keycloak.connections.jpa.JpaConnectionProvider;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.ModelDuplicateException;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;
import org.keycloak.userprofile.UserProfile;
import org.keycloak.userprofile.UserProfileContext;
import org.keycloak.userprofile.UserProfileProvider;
import org.keycloak.userprofile.ValidationException;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Opens a Self-registration account through Keycloak's User Profile (spec §4.3, §5.3): the realm's own
 * validators decide the names (length, {@code person-name-prohibited-characters}), the address
 * (format, already in use) and the username (format, already in use). The profile is created in the
 * administrative context ({@link UserProfileContext#USER_API}): the realm keeps names and e-mail
 * read-only for the person everywhere else (CONTEXT, sky-account SPI), and this extension, not the
 * person, writes exactly these four values. Keycloak's registration context would refuse them as
 * read-only. Then the account is enabled, its address is a verified Primary e-mail and a proven
 * Personal e-mail ({@link PersonalEmailVerification#prove}, the one shape of that record), and the
 * write is flushed at once so that a concurrent account with the same address or username fails here
 * ({@link ModelDuplicateException}) and not at the commit, after the page was built.
 */
final class ProfileSignUpAccounts implements SignUpAccounts {

    @Override
    public UserModel open(KeycloakSession session, RealmModel realm, String username, String address,
            String firstName, String lastName) throws Refused {
        if (EmailAddressOwnership.isTakenAfterLock(session, realm, null, address)) {
            throw new Refused(Refused.Reason.ADDRESS_TAKEN);
        }
        Map<String, List<String>> attributes = new LinkedHashMap<>();
        attributes.put(UserModel.USERNAME, List.of(username));
        attributes.put(UserModel.EMAIL, List.of(address));
        attributes.put(UserModel.FIRST_NAME, List.of(firstName));
        attributes.put(UserModel.LAST_NAME, List.of(lastName));
        UserProfile profile = session.getProvider(UserProfileProvider.class).create(UserProfileContext.USER_API, attributes);
        try {
            profile.validate();
        } catch (ValidationException refused) {
            throw new Refused(reasonOf(refused));
        }
        try {
            UserModel user = profile.create();
            user.setEnabled(true);
            user.setEmailVerified(true);
            PersonalEmailVerification.prove(user, address, Time.currentTime());
            JpaConnectionProvider jpa = session.getProvider(JpaConnectionProvider.class);
            if (jpa != null) {
                jpa.getEntityManager().flush();
            }
            return user;
        } catch (ModelDuplicateException duplicate) {
            session.getTransactionManager().setRollbackOnly();
            throw new Refused(Refused.Reason.OTHER);
        }
    }

    /** The first reason the User Profile gave, in the order the form shows them. */
    static Refused.Reason reasonOf(ValidationException refused) {
        if (refused.isAttributeOnError(UserModel.FIRST_NAME)) {
            return Refused.Reason.FIRST_NAME;
        }
        if (refused.isAttributeOnError(UserModel.LAST_NAME)) {
            return Refused.Reason.LAST_NAME;
        }
        if (refused.isAttributeOnError(UserModel.EMAIL)) {
            return Refused.Reason.ADDRESS_TAKEN;
        }
        if (refused.isAttributeOnError(UserModel.USERNAME)) {
            return Refused.Reason.USERNAME_TAKEN;
        }
        return Refused.Reason.OTHER;
    }
}
