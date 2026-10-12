package com.skylab.broker;

import jakarta.ws.rs.core.UriBuilder;
import org.keycloak.OAuth2Constants;
import org.keycloak.authentication.AuthenticatorUtil;
import org.keycloak.broker.provider.AuthenticationRequest;
import org.keycloak.models.KeycloakSession;
import org.keycloak.sessions.AuthenticationSessionModel;
import org.keycloak.social.microsoft.MicrosoftIdentityProvider;
import org.keycloak.social.microsoft.MicrosoftIdentityProviderConfig;

/**
 * Keycloak's Microsoft identity provider that passes a re-authentication on to Microsoft.
 *
 * <p>When Keycloak asks a signed-in person to authenticate again (the client's {@code max_age}
 * has run out, a {@code kc_action} needs a fresh login, or the client sent {@code prompt=login}),
 * {@code CookieAuthenticator} sets the {@code FORCED_REAUTHENTICATION} auth note and the login
 * page is shown. Keycloak's own provider forwards a {@code prompt} only when the client sent one,
 * so after {@code max_age} the redirect to Microsoft carries none and a live Microsoft session
 * signs the person in without credentials. This provider then adds {@code prompt=login}, the way
 * Microsoft Entra passes a fresh-login request on to a federated identity provider.
 *
 * <p>An ordinary login (no Keycloak session) and a valid SSO session are unchanged. A
 * {@code prompt} configured on the identity provider, or sent by the client, is left exactly as
 * Keycloak forwards it.
 */
public class SkyMicrosoftIdentityProvider extends MicrosoftIdentityProvider {

    static final String PROMPT_LOGIN = "login";

    private final boolean forwardReauthentication;

    public SkyMicrosoftIdentityProvider(KeycloakSession session, MicrosoftIdentityProviderConfig config,
                                        boolean forwardReauthentication) {
        super(session, config);
        this.forwardReauthentication = forwardReauthentication;
    }

    @Override
    protected UriBuilder createAuthorizationUrl(AuthenticationRequest request) {
        UriBuilder uriBuilder = super.createAuthorizationUrl(request);
        AuthenticationSessionModel authSession = request.getAuthenticationSession();
        if (forwardReauthentication
                && isBlank(getConfig().getPrompt())
                && isBlank(authSession.getClientNote(OAuth2Constants.PROMPT))
                && AuthenticatorUtil.isForcedReauthentication(authSession)) {
            uriBuilder.queryParam(OAuth2Constants.PROMPT, PROMPT_LOGIN);
        }
        return uriBuilder;
    }

    private static boolean isBlank(String value) {
        return value == null || value.isBlank();
    }
}
