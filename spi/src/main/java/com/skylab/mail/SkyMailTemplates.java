package com.skylab.mail;

import com.skylab.account.AccountErasureNotice;
import com.skylab.account.EmailCodeAuthenticator;
import com.skylab.account.EmailResource;
import com.skylab.account.SudoResource;
import org.keycloak.events.EventType;

import java.util.Locale;
import java.util.Map;

/**
 * The mapping from a Keycloak system mail to the SkyMail system template that renders it.
 *
 * <p>Keycloak names its mails twice: the {@code EmailTemplateProvider} method the caller uses and,
 * inside the generic {@code send(...)} overloads, the freemarker body template file. Both are
 * mapped here so a caller that goes through the generic overload — the Account Center personal
 * e-mail confirmation of K3c, for instance — reaches the same SkyMail template key.</p>
 *
 * <p>Anything unmapped becomes {@link #GENERIC} carrying the Keycloak subject key, so a mail
 * Keycloak gains in a later release still leaves through SkyMail instead of disappearing.</p>
 */
final class SkyMailTemplates {

    static final String VERIFY_EMAIL = "keycloak.verify-email";
    static final String RESET_PASSWORD = "keycloak.reset-password";
    static final String UPDATE_EMAIL = "keycloak.update-email";
    static final String IDP_LINK = "keycloak.idp-link";
    static final String PERSONAL_EMAIL_CONFIRM = "keycloak.personal-email-confirm";
    /** The Login code of "E-postayla devam et" (eskylab-login-ux 08); carries code and purpose. */
    static final String LOGIN_CODE = "keycloak.login-code";
    /**
     * A person whose Account erasure is running asked for a Login code: the account is being
     * deleted. Sent by Keycloak; named as SkyMail's other account deletion mails are.
     */
    static final String ACCOUNT_DELETION_IN_PROGRESS = "account.deletion-in-progress";
    /** The operator's alarm when the realm's Login codes reach half or all of the day's budget. */
    static final String LOGIN_CODE_ALARM = "keycloak.login-code-alarm";
    static final String GENERIC = "keycloak.generic";

    static final String VERIFY_EMAIL_SUBJECT_KEY = "emailVerificationSubject";
    static final String RESET_PASSWORD_SUBJECT_KEY = "passwordResetSubject";
    static final String UPDATE_EMAIL_SUBJECT_KEY = "emailUpdateConfirmationSubject";
    static final String IDP_LINK_SUBJECT_KEY = "identityProviderLinkSubject";
    static final String EXECUTE_ACTIONS_SUBJECT_KEY = "executeActionsSubject";

    /** Freemarker body template file (as Keycloak passes it) to SkyMail system template key. */
    private static final Map<String, String> BY_BODY_TEMPLATE = Map.of(
            "email-verification.ftl", VERIFY_EMAIL,
            "password-reset.ftl", RESET_PASSWORD,
            "email-update-confirmation.ftl", UPDATE_EMAIL,
            "identity-provider-link.ftl", IDP_LINK,
            // By the constant sky-account sends it with, so the two names cannot drift apart.
            EmailResource.TEMPLATE.toLowerCase(Locale.ROOT), PERSONAL_EMAIL_CONFIRM,
            EmailCodeAuthenticator.MAIL_TEMPLATE.toLowerCase(Locale.ROOT), LOGIN_CODE,
            SudoResource.MAIL_TEMPLATE.toLowerCase(Locale.ROOT), LOGIN_CODE,
            AccountErasureNotice.MAIL_TEMPLATE.toLowerCase(Locale.ROOT), ACCOUNT_DELETION_IN_PROGRESS);

    private SkyMailTemplates() {
    }

    /**
     * Whether SkyMail keeps no record of this mail's recipient: the Account erasure notice goes
     * after the person's Erasure command may have run in SkyMail, so nothing would erase its row
     * later. SkyMail erases it once its outcome is written ({@code erase_after_send}); an image
     * from before that ignores the field and keeps the row, so the mail carries no name either.
     */
    static boolean keepsNoRecord(String templateKey) {
        return ACCOUNT_DELETION_IN_PROGRESS.equals(templateKey);
    }

    /**
     * The SkyMail template key for a freemarker body template, or {@link #GENERIC}. Leading theme
     * directories ({@code text/}, {@code html/}) and letter case are ignored, and the
     * {@code .ftl} suffix is optional, so a caller may name the template either way.
     */
    static String forBodyTemplate(String bodyTemplate) {
        if (bodyTemplate == null || bodyTemplate.isBlank()) {
            return GENERIC;
        }
        String name = bodyTemplate.trim().toLowerCase(Locale.ROOT);
        int lastSlash = name.lastIndexOf('/');
        if (lastSlash >= 0) {
            name = name.substring(lastSlash + 1);
        }
        if (!name.endsWith(".ftl")) {
            name = name + ".ftl";
        }
        return BY_BODY_TEMPLATE.getOrDefault(name, GENERIC);
    }

    /**
     * Keycloak's own subject key for an event mail, built exactly as
     * {@code FreeMarkerEmailTemplateProvider#toCamelCase} builds it, so an unmapped event mail
     * still reports the subject key SkyMail's generic template prints.
     */
    static String eventSubjectKey(EventType eventType) {
        StringBuilder subjectKey = new StringBuilder("event");
        for (String part : eventType.name().toLowerCase(Locale.ROOT).split("_")) {
            if (!part.isEmpty()) {
                subjectKey.append(part.substring(0, 1).toUpperCase(Locale.ROOT)).append(part.substring(1));
            }
        }
        return subjectKey.append("Subject").toString();
    }
}
