package com.skylab.mail;

import org.keycloak.Config;
import org.keycloak.email.EmailTemplateProvider;
import org.keycloak.email.EmailTemplateProviderFactory;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;

/**
 * Registers the {@code sky-mail} e-mail template provider.
 *
 * <p>{@link #order()} is above Keycloak's own {@code freemarker} factory, which makes this the
 * realm's default template provider without a build option. The provider only records which
 * template Keycloak asked for; the rendering itself stays with {@code freemarker}, so the mails
 * and the theme are unchanged whether or not SkyMail is enabled.</p>
 */
public final class SkyMailEmailTemplateProviderFactory implements EmailTemplateProviderFactory {

    public static final String PROVIDER_ID = "sky-mail";
    static final String DELEGATE_PROVIDER_ID = "freemarker";

    @Override
    public String getId() {
        return PROVIDER_ID;
    }

    @Override
    public int order() {
        return 100;
    }

    @Override
    public EmailTemplateProvider create(KeycloakSession session) {
        EmailTemplateProvider delegate =
                session.getProvider(EmailTemplateProvider.class, DELEGATE_PROVIDER_ID);
        if (delegate == null) {
            throw new IllegalStateException(
                    "The " + DELEGATE_PROVIDER_ID + " e-mail template provider is not available.");
        }
        return new SkyMailEmailTemplateProvider(session, delegate);
    }

    @Override
    public void init(Config.Scope config) {
        // no-op
    }

    @Override
    public void postInit(KeycloakSessionFactory factory) {
        // no-op
    }

    @Override
    public void close() {
        // no-op
    }
}
