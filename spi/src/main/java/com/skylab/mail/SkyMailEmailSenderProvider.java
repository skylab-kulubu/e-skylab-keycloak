package com.skylab.mail;

import org.jboss.logging.Logger;
import org.keycloak.email.EmailException;
import org.keycloak.email.EmailSenderProvider;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.UserModel;

import java.net.URI;
import java.util.Map;
import java.util.Optional;
import java.util.function.Supplier;

/**
 * Sends Keycloak's system mails through SkyMail, and never at their expense.
 *
 * <p>The mail's identity comes from {@link SkyMailEmailTemplateProvider} through the session; the
 * rendered subject and body Keycloak hands this provider are kept for the fallback. When SkyMail
 * accepts the mail with {@code 201} nothing else happens. Otherwise — disabled provider, missing
 * template, refused or unreachable SkyMail, timeout, unobtainable token — the mail goes out over
 * Keycloak's own SMTP with its stock rendering and one {@code sky_mail_fallback} line records the
 * fixed reason. The line carries the reason and the template key only: no address, link, token or
 * secret is ever logged.</p>
 */
public final class SkyMailEmailSenderProvider implements EmailSenderProvider {

    static final String FALLBACK_PROVIDER_ID = "default";

    private static final Logger LOG = Logger.getLogger(SkyMailEmailSenderProvider.class);

    private final KeycloakSession session;
    private final SkyMailSettings settings;
    private final SkyMailClient client;
    private final Supplier<EmailSenderProvider> fallbackSender;
    private final Supplier<URI> realmIssuer;

    SkyMailEmailSenderProvider(
            KeycloakSession session,
            SkyMailSettings settings,
            SkyMailClient client,
            Supplier<EmailSenderProvider> fallbackSender,
            Supplier<URI> realmIssuer) {
        this.session = session;
        this.settings = settings;
        this.client = client;
        this.fallbackSender = fallbackSender;
        this.realmIssuer = realmIssuer;
    }

    @Override
    public void send(Map<String, String> config, UserModel user, String subject, String textBody,
            String htmlBody) throws EmailException {
        send(config, user == null ? null : user.getEmail(), subject, textBody, htmlBody);
    }

    @Override
    public void send(Map<String, String> config, String address, String subject, String textBody,
            String htmlBody) throws EmailException {
        SkyMailMessage message = takePendingMessage();
        SkyMailFallback fallback = trySkyMail(message, address);
        if (fallback == null) {
            LOG.debug(sentLine(message));
            return;
        }
        String line = fallbackLine(fallback, message);
        if (fallback.isFailure()) {
            LOG.warn(line);
        } else {
            LOG.debug(line);
        }
        fallbackSender().send(config, address, subject, textBody, htmlBody);
    }

    /**
     * Everything this provider says about a mail that fell back. The reason vocabulary is fixed
     * and the template key is a constant, so the line cannot carry an address, a link or a secret.
     */
    static String fallbackLine(SkyMailFallback fallback, SkyMailMessage message) {
        return "sky_mail_fallback reason=" + fallback.reason() + " template=" + templateKey(message);
    }

    static String sentLine(SkyMailMessage message) {
        return "sky_mail_sent template=" + templateKey(message);
    }

    private static String templateKey(SkyMailMessage message) {
        return message == null ? "none" : message.templateKey();
    }

    /** The fallback reason, or {@code null} when SkyMail accepted the mail. */
    private SkyMailFallback trySkyMail(SkyMailMessage message, String address) {
        if (!settings.enabled() || client == null) {
            return SkyMailFallback.DISABLED;
        }
        if (message == null || address == null || address.isBlank()) {
            return SkyMailFallback.NOT_MAPPED;
        }
        URI issuer = null;
        if (settings.tokenUrl() == null) {
            issuer = realmIssuer.get();
            if (issuer == null) {
                return SkyMailFallback.CONFIG;
            }
        }
        Optional<SkyMailFallback> outcome = client.send(message, address, issuer);
        return outcome.orElse(null);
    }

    /**
     * Takes the pending message off the session. A message is used by exactly one mail: a
     * Keycloak mail this provider does not template must not inherit the previous one.
     */
    private SkyMailMessage takePendingMessage() {
        Object pending = session.getAttribute(SkyMailMessage.SESSION_ATTRIBUTE);
        session.removeAttribute(SkyMailMessage.SESSION_ATTRIBUTE);
        return pending instanceof SkyMailMessage message ? message : null;
    }

    private EmailSenderProvider fallbackSender() throws EmailException {
        EmailSenderProvider sender = fallbackSender.get();
        if (sender == null) {
            throw new EmailException("Keycloak's own e-mail sender is not available.");
        }
        return sender;
    }

    @Override
    public void validate(Map<String, String> config) throws EmailException {
        fallbackSender().validate(config);
    }

    /**
     * The realm issuer this Keycloak is serving, used to derive the token endpoint when the
     * operator did not pin {@code SKY_MAIL_TOKEN_URL}.
     */
    static URI realmIssuer(URI baseUri, String realmName) {
        if (baseUri == null || realmName == null || realmName.isBlank()) {
            return null;
        }
        String base = baseUri.toString();
        while (base.endsWith("/")) {
            base = base.substring(0, base.length() - 1);
        }
        return URI.create(base + "/realms/" + realmName);
    }

    @Override
    public void close() {
        // The HTTP client and its token cache belong to the factory, not to one session.
    }
}
