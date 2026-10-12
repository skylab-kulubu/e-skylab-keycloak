package com.skylab.account;

import org.keycloak.email.EmailException;
import org.keycloak.email.EmailTemplateProvider;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.ModelDuplicateException;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;
import org.keycloak.models.UserProvider;
import org.keycloak.validate.ValidationContext;
import org.keycloak.validate.validators.EmailValidator;

import java.net.IDN;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * Proving a Personal e-mail with a six-digit code (ADR-0044): the part both places that do it share,
 * Account center's {@code v1/email} ({@link EmailResource}) and the offer at the end of a first YTÜ
 * login ({@link PersonalEmailOffer}). One rule for which address may receive a code, one mail, one
 * code store ({@link PendingEmailChanges}) and one record of the proof ({@link PersonalEmailProof}).
 *
 * <p>The mail is Keycloak's generic template send with {@value #TEMPLATE}: the SkyMail provider
 * routes exactly that name to SkyMail's {@code keycloak.personal-email-confirm} template (ADR-0045),
 * and Keycloak's own SMTP renders this extension's FreeMarker copy when SkyMail is unreachable.
 */
public final class PersonalEmailVerification {

    static final int MAX_ADDRESS_LENGTH = 255;
    /** Six digits, with room for the spaces people keep when they copy "123 456". */
    static final int MAX_CODE_INPUT_LENGTH = 12;
    /** The message bundle key of the subject, resolved in the realm locale of the person. */
    static final String SUBJECT_KEY = "skyPersonalEmailConfirmSubject";
    /**
     * {@code theme-resources/templates/{text,html}/} of this extension; no theme change needed.
     * Public because the SkyMail mail provider routes this mail by exactly this name.
     */
    public static final String TEMPLATE = "sky-personal-email-confirm.ftl";
    /**
     * The university's mail domain. A Personal e-mail has to outlive graduation, so no address on it
     * or on any of its subdomains ({@code std.yildiz.edu.tr}, department domains) may become one
     * (eskylab-login-ux 21, Yusuf 2026-10-11).
     */
    static final String UNIVERSITY_DOMAIN = "yildiz.edu.tr";

    private PersonalEmailVerification() {
    }

    /**
     * Whether the address is on the university's domain or one of its subdomains: such an address may
     * close after graduation, so it is never a Personal e-mail. The domain is compared in its ASCII
     * form ({@link #asciiDomain}), because Keycloak's validator accepts Unicode look-alikes (a
     * fullwidth letter, an ideographic full stop, a zero-width space, a soft hyphen) that the SMTP
     * sender turns back into {@code yildiz.edu.tr} on the way out. A domain without an ASCII form
     * is not one; {@link #isValidAddress} refuses it anyway.
     */
    static boolean isSchoolDomain(String address) {
        String domain = asciiDomain(address);
        return domain != null && (domain.equals(UNIVERSITY_DOMAIN) || domain.endsWith("." + UNIVERSITY_DOMAIN));
    }

    /**
     * The domain after the last {@code @} as a mail server sees it: trimmed, IDNA {@code toASCII}
     * (Unicode compatibility forms and label separators folded, ignorable characters dropped),
     * lowercased with {@link Locale#ROOT}, trailing dots removed; null when there is no domain or
     * it has no ASCII form.
     */
    static String asciiDomain(String address) {
        if (address == null) {
            return null;
        }
        int at = address.lastIndexOf('@');
        if (at < 0) {
            return null;
        }
        String domain = stripTrailingDots(address.substring(at + 1).strip());
        if (domain.isEmpty()) {
            return null;
        }
        try {
            domain = stripTrailingDots(IDN.toASCII(domain, IDN.ALLOW_UNASSIGNED).toLowerCase(Locale.ROOT));
        } catch (IllegalArgumentException noAsciiForm) {
            return null;
        }
        return domain.isEmpty() ? null : domain;
    }

    private static String stripTrailingDots(String domain) {
        String stripped = domain;
        while (stripped.endsWith(".")) {
            stripped = stripped.substring(0, stripped.length() - 1);
        }
        return stripped;
    }

    /**
     * Whether any other person already uses the address: as their Keycloak {@code email} (Keycloak's
     * own case-insensitive lookup, authoritative while the realm keeps {@code duplicateEmailsAllowed=false};
     * two holders count as taken), as their username (the login form would then find two people by
     * it, {@link LoginIdentifiers}, and the username route of the other person would stop working)
     * or as their School or Personal e-mail attribute. The attributes are
     * compared ignoring case, as the login form compares them ({@link LoginIdentifiers}): Microsoft
     * writes {@code schoolEmail} as Graph returns it, this extension stores {@code personalEmail}
     * lowercased.
     */
    static boolean isTakenByAnother(KeycloakSession session, RealmModel realm, UserModel user, String address) {
        UserProvider users = session.users();
        UserModel byEmail;
        UserModel byUsername;
        try {
            byEmail = users.getUserByEmail(realm, address);
            byUsername = users.getUserByUsername(realm, address);
        } catch (ModelDuplicateException duplicate) {
            return true;
        }
        if (byEmail != null && !byEmail.getId().equals(user.getId())) {
            return true;
        }
        if (byUsername != null && !byUsername.getId().equals(user.getId())) {
            return true;
        }
        for (String attribute : List.of(
                IdentityResource.SCHOOL_EMAIL_ATTRIBUTE, IdentityResource.PERSONAL_EMAIL_ATTRIBUTE)) {
            boolean taken = users.searchForUserStream(realm, Map.of(
                            attribute, address,
                            UserModel.EXACT, Boolean.TRUE.toString(),
                            UserModel.INCLUDE_SERVICE_ACCOUNT, Boolean.FALSE.toString()),
                    0, 2)
                    .anyMatch(other -> !other.getId().equals(user.getId()));
            if (taken) {
                return true;
            }
        }
        return false;
    }

    /**
     * Whether the address is already the person's School or Personal e-mail, so there is nothing
     * to prove. Keycloak {@code email} alone does not count: the primary is one of these two, and
     * a primary that is neither (set before v2) is exactly what a person proves with a code to make
     * it their Personal e-mail (A1c).
     */
    static boolean isOwnAddress(UserModel user, String address) {
        return address.equalsIgnoreCase(trimmed(user.getFirstAttribute(IdentityResource.SCHOOL_EMAIL_ATTRIBUTE)))
                || address.equalsIgnoreCase(trimmed(user.getFirstAttribute(IdentityResource.PERSONAL_EMAIL_ATTRIBUTE)));
    }

    /**
     * Keycloak's own e-mail validator, with the realm this request runs in, and a domain that has an
     * ASCII form ({@link #asciiDomain}), so the domain rule can always be applied.
     */
    static boolean isValidAddress(KeycloakSession session, String address) {
        return EmailValidator.INSTANCE
                .validate(address, "address", new ValidationContext(session))
                .isValid()
                && asciiDomain(address) != null;
    }

    /**
     * The code as typed, without the spaces people keep when they copy "123 456" from a mail; null
     * when what is left is not six digits (such input never costs a try).
     */
    static String codeFromInput(String typed) {
        if (typed == null || typed.length() > MAX_CODE_INPUT_LENGTH) {
            return null;
        }
        String code = typed.strip().replace(" ", "");
        return PendingEmailChanges.CODE.matcher(code).matches() ? code : null;
    }

    /**
     * Mails the code through Keycloak's own e-mail template and sender providers. The attribute map
     * has to be mutable: Keycloak's FreeMarker template provider puts the resolved locale into the
     * very map it is handed. Neither the address nor the code may reach a log; the caller logs the
     * failure by user id only.
     */
    static void send(KeycloakSession session, RealmModel realm, UserModel user, String address, String code)
            throws EmailException {
        Map<String, Object> attributes = new HashMap<>();
        attributes.put("code", code);
        attributes.put("codeExpiration", PendingEmailChanges.TTL_SECONDS / 60);
        attributes.put("newEmail", address);
        session.getProvider(EmailTemplateProvider.class)
                .setRealm(realm)
                .setUser(user)
                .send(SUBJECT_KEY, List.of(), TEMPLATE, attributes, address);
    }

    /** Writes the proof: {@code personalEmail} and the moment it was proven ({@link PersonalEmailProof}). */
    static void prove(UserModel user, String address, long epochSeconds) {
        PersonalEmailProof.attributes(address, epochSeconds).forEach(user::setSingleAttribute);
    }

    private static String trimmed(String value) {
        return value == null ? null : value.trim();
    }
}
