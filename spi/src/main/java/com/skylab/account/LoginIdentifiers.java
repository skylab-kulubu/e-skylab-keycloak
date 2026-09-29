package com.skylab.account;

import org.keycloak.models.KeycloakSession;
import org.keycloak.models.ModelDuplicateException;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;
import org.keycloak.models.UserProvider;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Which person the username field of the login form names (K4). A person signs in with the
 * password and any one of: the username, the Primary e-mail (Keycloak {@code email}), the
 * School e-mail of a Verified YTÜ account, or a proven Personal e-mail (CONTEXT, Primary
 * e-mail: "Either address signs in").
 *
 * <p>Only proven addresses are identifiers, by the same rules the rest of this extension uses:
 * {@code schoolEmail} counts only while the person has the YTÜ Microsoft link
 * ({@link AccountRequest#isVerifiedYtu}), {@code personalEmail} only while it carries the stamp
 * of its proof ({@link IdentityResource#isPersonalEmailVerified}). A pending Personal e-mail
 * never reaches the attribute: it waits in the single-use store until its code is confirmed.
 *
 * <p>Every route is always asked, so an input that names two different people is recognised
 * even when one route alone would pick one of them; the form then answers exactly as for an
 * unknown username. Keycloak's own routes are the ones {@code KeycloakModelUtils
 * .findUserByNameOrEmail} uses (case-insensitive username; case-insensitive {@code email} when
 * the realm allows e-mail login and the input holds an {@code @}); the two attributes are
 * compared case-insensitively too, because Microsoft writes {@code schoolEmail} as Graph returns
 * it while this extension stores {@code personalEmail} lowercased.
 */
public final class LoginIdentifiers {

    /**
     * Candidates read per attribute. Addresses are unique by the rules that write them, so a
     * second holder is already ambiguous; reaching the bound is treated the same way.
     */
    static final int CANDIDATE_LIMIT = 10;
    /** Attribute values up to this length are compared in the database (Keycloak's short-value column). */
    static final int MAX_ADDRESS_LENGTH = 255;

    /** What the typed identifier names. */
    public sealed interface Match permits Nobody, Ambiguous, Person {
    }

    /** No person by any route. */
    public record Nobody() implements Match {
    }

    /** Two or more different people by some combination of routes. */
    public record Ambiguous() implements Match {
    }

    /**
     * Exactly one person.
     *
     * @param byKeycloakLookup whether Keycloak's own username/e-mail lookup finds this person
     *                         from the same input, i.e. the stock form would find them as well
     */
    public record Person(UserModel user, boolean byKeycloakLookup) implements Match {
    }

    private LoginIdentifiers() {
    }

    /**
     * The alias of the YTÜ Microsoft identity provider for a component configured with
     * {@code configured} (may be null): the same resolution as the sky-account endpoints,
     * falling back to {@code SKY_ACCOUNT_YTU_IDP_ALIAS} and then {@code OBS}.
     */
    public static String ytuIdpAlias(String configured) {
        return SkyAccountResourceProviderFactory.resolveYtuIdpAlias(configured, System.getenv());
    }

    /**
     * Resolves {@code typed} (the raw username field) in {@code realm}.
     */
    public static Match resolve(KeycloakSession session, RealmModel realm, String ytuIdpAlias, String typed) {
        if (typed == null || typed.isBlank()) {
            return new Nobody();
        }
        String identifier = typed.trim();
        UserProvider users = session.users();
        boolean emailRoutes = realm.isLoginWithEmailAllowed() && identifier.indexOf('@') != -1;

        Map<String, UserModel> people = new LinkedHashMap<>();
        UserModel byUsername;
        UserModel byEmail;
        try {
            byUsername = users.getUserByUsername(realm, identifier);
            byEmail = emailRoutes ? users.getUserByEmail(realm, identifier) : null;
        } catch (ModelDuplicateException duplicate) {
            return new Ambiguous();
        }
        // KeycloakModelUtils.findUserByNameOrEmail prefers the e-mail route.
        UserModel keycloakMatch = byEmail != null ? byEmail : byUsername;
        add(people, byUsername);
        add(people, byEmail);

        if (emailRoutes && identifier.length() <= MAX_ADDRESS_LENGTH) {
            String address = PersonalEmailProof.normalise(identifier);
            List<UserModel> school = candidates(users, realm, IdentityResource.SCHOOL_EMAIL_ATTRIBUTE, address);
            List<UserModel> personal = candidates(users, realm, IdentityResource.PERSONAL_EMAIL_ATTRIBUTE, address);
            if (school == null || personal == null) {
                return new Ambiguous();
            }
            for (UserModel candidate : school) {
                if (holds(candidate, IdentityResource.SCHOOL_EMAIL_ATTRIBUTE, address)
                        && users.getFederatedIdentity(realm, candidate, ytuIdpAlias) != null) {
                    add(people, candidate);
                }
            }
            for (UserModel candidate : personal) {
                if (holds(candidate, IdentityResource.PERSONAL_EMAIL_ATTRIBUTE, address)
                        && IdentityResource.isPersonalEmailVerified(candidate)) {
                    add(people, candidate);
                }
            }
        }

        if (people.isEmpty()) {
            return new Nobody();
        }
        if (people.size() > 1) {
            return new Ambiguous();
        }
        UserModel person = people.values().iterator().next();
        return new Person(person, keycloakMatch != null);
    }

    /**
     * The people whose {@code attribute} equals {@code address} ignoring case (Keycloak's exact
     * attribute search lowercases both sides); null when the bound is reached.
     */
    private static List<UserModel> candidates(UserProvider users, RealmModel realm, String attribute, String address) {
        List<UserModel> found = users.searchForUserStream(realm, Map.of(
                        attribute, address,
                        UserModel.EXACT, Boolean.TRUE.toString(),
                        UserModel.INCLUDE_SERVICE_ACCOUNT, Boolean.FALSE.toString()),
                0, CANDIDATE_LIMIT).toList();
        return found.size() >= CANDIDATE_LIMIT ? null : found;
    }

    /** The database match, checked again on the value the rest of this extension reads. */
    private static boolean holds(UserModel user, String attribute, String address) {
        String value = user.getFirstAttribute(attribute);
        return value != null && !value.isBlank() && PersonalEmailProof.normalise(value).equals(address);
    }

    private static void add(Map<String, UserModel> people, UserModel user) {
        if (user != null) {
            people.putIfAbsent(user.getId(), user);
        }
    }
}
