package com.skylab.mail;

import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;
import org.keycloak.util.JsonSerialization;

import java.io.IOException;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * One SkyMail single-mail task: the system template to render and the variables it is rendered
 * with. Built by {@link SkyMailEmailTemplateProvider} while Keycloak still knows which template it
 * asked for, handed to {@link SkyMailEmailSenderProvider} through the Keycloak session.
 *
 * <p>SkyMail renders subjects and bodies with Go {@code text/template}, which prints
 * {@code &lt;no value&gt;} for a variable the caller left out. Every message therefore carries all
 * of {@link #VARIABLE_NAMES}, with an empty string wherever Keycloak does not know the value.</p>
 */
record SkyMailMessage(String templateKey, String recipientFullName, Map<String, String> variables) {

    /** Session attribute the template provider hands the sender the pending message through. */
    static final String SESSION_ATTRIBUTE = "com.skylab.mail.pending-message";

    static final String LINK = "link";
    static final String LINK_EXPIRATION_MINUTES = "linkExpirationMinutes";
    /** The sky-account personal e-mail proof (K3c) is a code the person types, not a link. */
    static final String CODE = "code";
    static final String CODE_EXPIRATION_MINUTES = "codeExpirationMinutes";
    static final String FIRST_NAME = "firstName";
    static final String USERNAME = "username";
    static final String REALM_DISPLAY_NAME = "realmDisplayName";
    static final String SUBJECT_KEY = "subjectKey";

    /** Always sent, in this order, never omitted. */
    static final List<String> VARIABLE_NAMES = List.of(
            LINK, LINK_EXPIRATION_MINUTES, CODE, CODE_EXPIRATION_MINUTES,
            FIRST_NAME, USERNAME, REALM_DISPLAY_NAME, SUBJECT_KEY);

    SkyMailMessage {
        variables = Map.copyOf(variables);
    }

    /** A mail whose action is a link (every Keycloak system mail). */
    static SkyMailMessage of(
            String templateKey,
            String subjectKey,
            String link,
            String linkExpirationMinutes,
            UserModel user,
            RealmModel realm) {
        return of(templateKey, subjectKey, link, linkExpirationMinutes, "", "", user, realm);
    }

    /** A mail whose action is a code the person types (the sky-account personal e-mail proof). */
    static SkyMailMessage ofCode(
            String templateKey,
            String subjectKey,
            String code,
            String codeExpirationMinutes,
            UserModel user,
            RealmModel realm) {
        return of(templateKey, subjectKey, "", "", code, codeExpirationMinutes, user, realm);
    }

    static SkyMailMessage of(
            String templateKey,
            String subjectKey,
            String link,
            String linkExpirationMinutes,
            String code,
            String codeExpirationMinutes,
            UserModel user,
            RealmModel realm) {
        Map<String, String> variables = new LinkedHashMap<>();
        variables.put(LINK, text(link));
        variables.put(LINK_EXPIRATION_MINUTES, text(linkExpirationMinutes));
        variables.put(CODE, text(code));
        variables.put(CODE_EXPIRATION_MINUTES, text(codeExpirationMinutes));
        variables.put(FIRST_NAME, user == null ? "" : text(user.getFirstName()));
        variables.put(USERNAME, user == null ? "" : text(user.getUsername()));
        variables.put(REALM_DISPLAY_NAME, realmDisplayName(realm));
        variables.put(SUBJECT_KEY, text(subjectKey));
        return new SkyMailMessage(templateKey, fullName(user), variables);
    }

    /**
     * The request body of {@code POST /v1/mail_tasks/single}. The recipient is the address
     * Keycloak resolved for this mail, so an address override (the new address of an e-mail
     * change) reaches SkyMail exactly as Keycloak's own sender would have used it.
     */
    String toRequestBody(String recipientEmail) throws IOException {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("template_key", templateKey);
        body.put("recipient_email", text(recipientEmail));
        body.put("recipient_full_name", text(recipientFullName));
        Map<String, String> bodyVariables = new LinkedHashMap<>();
        for (String name : VARIABLE_NAMES) {
            bodyVariables.put(name, variables.getOrDefault(name, ""));
        }
        body.put("body_variables", bodyVariables);
        return JsonSerialization.writeValueAsString(body);
    }

    /**
     * Keycloak's own rule: the realm display name when it has one, otherwise the capitalised
     * realm name (see {@code FreeMarkerEmailTemplateProvider#getRealmName}).
     */
    static String realmDisplayName(RealmModel realm) {
        if (realm == null) {
            return "";
        }
        String displayName = realm.getDisplayName();
        if (displayName != null && !displayName.isBlank()) {
            return displayName;
        }
        String name = text(realm.getName());
        return name.isEmpty()
                ? ""
                : name.substring(0, 1).toUpperCase(Locale.ROOT) + name.substring(1);
    }

    static String fullName(UserModel user) {
        if (user == null) {
            return "";
        }
        String first = text(user.getFirstName());
        String last = text(user.getLastName());
        String full = (first + " " + last).trim();
        return full.isEmpty() ? text(user.getUsername()) : full;
    }

    static String minutes(long expirationInMinutes) {
        return expirationInMinutes <= 0 ? "" : String.valueOf(expirationInMinutes);
    }

    /** {@code linkExpiration} / {@code codeExpiration} as the freemarker attributes carry it: a number, or nothing. */
    static String minutes(Object attribute) {
        if (attribute instanceof Number number) {
            return minutes(number.longValue());
        }
        return "";
    }

    private static String text(String value) {
        return value == null ? "" : value;
    }
}
