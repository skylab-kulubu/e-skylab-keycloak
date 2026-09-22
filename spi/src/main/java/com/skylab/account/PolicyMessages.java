package com.skylab.account;

import org.jboss.logging.Logger;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.theme.Theme;

import java.text.MessageFormat;
import java.util.Locale;
import java.util.Properties;

/**
 * Renders Keycloak password-policy message keys (for example
 * {@code invalidPasswordMinLengthMessage}) in Turkish through the realm's login theme bundle,
 * the same bundle the login pages use, so the Account Center shows the sentence the person
 * would have seen on {@code e.}.
 */
final class PolicyMessages {

    static final Locale TURKISH = Locale.forLanguageTag("tr");
    static final String GENERIC_DETAIL = "Yeni parola, parola politikasına uymuyor.";

    private static final Logger LOG = Logger.getLogger(PolicyMessages.class);

    private final KeycloakSession session;

    PolicyMessages(KeycloakSession session) {
        this.session = session;
    }

    String render(String messageKey, Object[] parameters) {
        if (messageKey == null || messageKey.isBlank()) {
            return GENERIC_DETAIL;
        }
        try {
            RealmModel realm = session.getContext().getRealm();
            Theme theme = session.theme().getTheme(Theme.Type.LOGIN);
            Properties messages = theme.getEnhancedMessages(realm, TURKISH);
            String template = messages.getProperty(messageKey);
            if (template == null || template.isBlank()) {
                return GENERIC_DETAIL;
            }
            Object[] safeParameters = parameters == null ? new Object[0] : parameters;
            return new MessageFormat(template.replace("'", "''"), TURKISH).format(safeParameters);
        } catch (Exception exception) {
            LOG.debugf("sky-account could not localize policy message %s", messageKey);
            return GENERIC_DETAIL;
        }
    }
}
