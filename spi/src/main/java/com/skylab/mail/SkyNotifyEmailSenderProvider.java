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
 * Sends Keycloak's system mails through SkyNotify, and never at their expense.
 *
 * <p>The mail's identity comes from {@link SkyNotifyEmailTemplateProvider} through the session; the
 * rendered subject and body Keycloak hands this provider are kept for the fallback. When SkyNotify
 * accepts the mail with {@code 201} nothing else happens. Otherwise — disabled provider, missing
 * template, refused or unreachable SkyNotify, timeout, unobtainable token — the mail goes out over
 * Keycloak's own SMTP with its stock rendering and one {@code skynotify_fallback} line records the
 * fixed reason. The line carries the reason and the template key only: no address, link, token or
 * secret is ever logged.</p>
 */
public final class SkyNotifyEmailSenderProvider implements EmailSenderProvider {

    static final String FALLBACK_PROVIDER_ID = "default";

    private static final Logger LOG = Logger.getLogger(SkyNotifyEmailSenderProvider.class);

    private final KeycloakSession session;
    private final SkyNotifySettings settings;
    private final SkyNotifyClient client;
    private final Supplier<EmailSenderProvider> fallbackSender;
    private final Supplier<URI> realmIssuer;

    SkyNotifyEmailSenderProvider(
            KeycloakSession session,
            SkyNotifySettings settings,
            SkyNotifyClient client,
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
        SkyNotifyMessage message = takePendingMessage();
        SkyNotifyFallback fallback = trySkyNotify(message, address);
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
    static String fallbackLine(SkyNotifyFallback fallback, SkyNotifyMessage message) {
        return "skynotify_fallback reason=" + fallback.reason() + " template=" + templateKey(message);
    }

    static String sentLine(SkyNotifyMessage message) {
        return "skynotify_sent template=" + templateKey(message);
    }

    private static String templateKey(SkyNotifyMessage message) {
        return message == null ? "none" : message.templateKey();
    }

    /** The fallback reason, or {@code null} when SkyNotify accepted the mail. */
    private SkyNotifyFallback trySkyNotify(SkyNotifyMessage message, String address) {
        if (!settings.enabled() || client == null) {
            return SkyNotifyFallback.DISABLED;
        }
        if (message == null || address == null || address.isBlank()) {
            return SkyNotifyFallback.NOT_MAPPED;
        }
        URI issuer = null;
        if (settings.tokenUrl() == null) {
            issuer = realmIssuer.get();
            if (issuer == null) {
                return SkyNotifyFallback.CONFIG;
            }
        }
        Optional<SkyNotifyFallback> outcome = client.send(message, address, issuer);
        return outcome.orElse(null);
    }

    /**
     * Takes the pending message off the session. A message is used by exactly one mail: a
     * Keycloak mail this provider does not template must not inherit the previous one.
     */
    private SkyNotifyMessage takePendingMessage() {
        Object pending = session.getAttribute(SkyNotifyMessage.SESSION_ATTRIBUTE);
        session.removeAttribute(SkyNotifyMessage.SESSION_ATTRIBUTE);
        return pending instanceof SkyNotifyMessage message ? message : null;
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
     * operator did not pin {@code SKYNOTIFY_TOKEN_URL}.
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
