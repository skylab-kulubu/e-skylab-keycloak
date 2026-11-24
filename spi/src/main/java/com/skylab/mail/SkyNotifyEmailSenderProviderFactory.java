package com.skylab.mail;

import org.jboss.logging.Logger;
import org.keycloak.Config;
import org.keycloak.email.EmailSenderProvider;
import org.keycloak.email.EmailSenderProviderFactory;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;
import org.keycloak.models.RealmModel;

import java.net.URI;

/**
 * Registers the {@code skynotify} e-mail sender and holds everything that outlives one mail: the
 * validated environment configuration, the HTTP client and the client-credentials token cache.
 *
 * <p>{@link #init(Config.Scope)} reads and validates the environment once. {@code SKYNOTIFY_ENABLED}
 * defaults to {@code false}, so building the optimized image — which initialises every factory
 * without the runtime environment — neither validates nor needs a secret. A malformed value is an
 * operator mistake and fails initialisation; a missing or empty secret file fails closed instead,
 * leaving the provider disabled with one warning while every mail keeps going out over SMTP.</p>
 *
 * <p>{@link #order()} is above Keycloak's own {@code default} factory, which makes this the
 * realm's e-mail sender without a build option.</p>
 */
public final class SkyNotifyEmailSenderProviderFactory implements EmailSenderProviderFactory {

    public static final String PROVIDER_ID = "skynotify";

    private static final Logger LOG = Logger.getLogger(SkyNotifyEmailSenderProviderFactory.class);

    private volatile SkyNotifySettings settings = SkyNotifySettings.disabled(SkyNotifySettings.REASON_NOT_ENABLED);
    private volatile SkyNotifyClient client;

    @Override
    public String getId() {
        return PROVIDER_ID;
    }

    @Override
    public int order() {
        return 100;
    }

    @Override
    public EmailSenderProvider create(KeycloakSession session) {
        return new SkyNotifyEmailSenderProvider(
                session,
                settings,
                client,
                () -> session.getProvider(
                        EmailSenderProvider.class, SkyNotifyEmailSenderProvider.FALLBACK_PROVIDER_ID),
                () -> realmIssuer(session));
    }

    @Override
    public void init(Config.Scope config) {
        settings = SkyNotifySettings.fromEnvironment(System.getenv());
        if (settings.enabled()) {
            client = SkyNotifyClient.create(settings);
            LOG.infof("skynotify_enabled client=%s", settings.clientId());
            return;
        }
        client = null;
        if (SkyNotifySettings.REASON_NOT_ENABLED.equals(settings.disabledReason())) {
            // Nobody asked for SkyNotify; stock Keycloak behaviour is not worth a warning.
            LOG.debugf("skynotify_disabled reason=%s", settings.disabledReason());
        } else {
            // An operator asked for SkyNotify and the secret is not there: say so once, loudly.
            LOG.warnf("skynotify_disabled reason=%s", settings.disabledReason());
        }
    }

    /**
     * The realm issuer of the request this mail belongs to. A mail sent without an active request
     * context has no issuer to derive a token endpoint from; the sender then falls back to SMTP
     * unless the operator pinned {@code SKYNOTIFY_TOKEN_URL}.
     */
    private static URI realmIssuer(KeycloakSession session) {
        try {
            RealmModel realm = session.getContext().getRealm();
            if (realm == null) {
                return null;
            }
            return SkyNotifyEmailSenderProvider.realmIssuer(
                    session.getContext().getUri().getBaseUri(), realm.getName());
        } catch (RuntimeException exception) {
            return null;
        }
    }

    @Override
    public void postInit(KeycloakSessionFactory factory) {
        // no-op
    }

    @Override
    public void close() {
        client = null;
    }
}
