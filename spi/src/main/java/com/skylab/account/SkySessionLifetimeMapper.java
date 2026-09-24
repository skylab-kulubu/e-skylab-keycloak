package com.skylab.account;

import org.keycloak.models.AuthenticatedClientSessionModel;
import org.keycloak.models.ClientSessionContext;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.ProtocolMapperModel;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserSessionModel;
import org.keycloak.models.utils.SessionExpirationUtils;
import org.keycloak.protocol.oidc.mappers.AbstractOIDCProtocolMapper;
import org.keycloak.protocol.oidc.mappers.OIDCAccessTokenMapper;
import org.keycloak.protocol.oidc.mappers.OIDCAttributeMapperHelper;
import org.keycloak.protocol.oidc.mappers.OIDCIDTokenMapper;
import org.keycloak.protocol.oidc.mappers.TokenIntrospectionTokenMapper;
import org.keycloak.provider.ProviderConfigProperty;
import org.keycloak.representations.IDToken;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.TimeUnit;

/**
 * Emits the lifetime of the Keycloak session behind a token, both in epoch seconds:
 *
 * <ul>
 *   <li>{@code sky_session_started}: when the user session really began
 *       ({@link UserSessionModel#getStarted()});</li>
 *   <li>{@code sky_session_expires}: when Keycloak will end it by maximum lifespan, computed by
 *       Keycloak's own {@link SessionExpirationUtils}: the realm SSO max (the longer remember-me
 *       max for a remember-me session), shortened by a client or realm client-session max counted
 *       from this client's session start. Omitted when the session has no maximum (an offline
 *       session without an offline max).</li>
 * </ul>
 *
 * <p>{@code auth_time} says when the person last proved a credential; a Web handoff carries it
 * over from SkyApp and a remember-me login keeps it for weeks, so neither says how long the
 * session lasts. Account Center caps its own session with these claims and falls back to
 * {@code auth_time} when they are absent. Both values are the same for every token of one
 * session, refreshes included.</p>
 */
public final class SkySessionLifetimeMapper extends AbstractOIDCProtocolMapper
        implements OIDCIDTokenMapper, OIDCAccessTokenMapper, TokenIntrospectionTokenMapper {

    public static final String PROVIDER_ID = "sky-session-lifetime-mapper";
    public static final String STARTED_CLAIM = "sky_session_started";
    public static final String EXPIRES_CLAIM = "sky_session_expires";

    private static final List<ProviderConfigProperty> CONFIG_PROPERTIES;

    static {
        List<ProviderConfigProperty> properties = new ArrayList<>();
        OIDCAttributeMapperHelper.addIncludeInTokensConfig(properties, SkySessionLifetimeMapper.class);
        CONFIG_PROPERTIES = List.copyOf(properties);
    }

    @Override
    public String getId() {
        return PROVIDER_ID;
    }

    @Override
    public String getDisplayType() {
        return "SKY LAB session lifetime";
    }

    @Override
    public String getDisplayCategory() {
        return TOKEN_MAPPER_CATEGORY;
    }

    @Override
    public String getHelpText() {
        return "Adds sky_session_started and sky_session_expires: when the Keycloak user session began and "
                + "when its maximum lifespan ends it (epoch seconds).";
    }

    @Override
    public List<ProviderConfigProperty> getConfigProperties() {
        return CONFIG_PROPERTIES;
    }

    @Override
    protected void setClaim(IDToken token, ProtocolMapperModel mappingModel, UserSessionModel userSession,
                            KeycloakSession keycloakSession, ClientSessionContext clientSessionCtx) {
        if (userSession == null || userSession.getStarted() <= 0) {
            return;
        }
        token.getOtherClaims().put(STARTED_CLAIM, (long) userSession.getStarted());
        long expires = expiresAt(userSession, clientSessionCtx == null ? null : clientSessionCtx.getClientSession());
        if (expires > 0) {
            token.getOtherClaims().put(EXPIRES_CLAIM, expires);
        }
    }

    /** Epoch seconds at which the maximum lifespan ends the session, or {@code -1} when it has none. */
    static long expiresAt(UserSessionModel userSession, AuthenticatedClientSessionModel clientSession) {
        RealmModel realm = userSession.getRealm();
        long userSessionStarted = TimeUnit.SECONDS.toMillis(userSession.getStarted());
        long millis = clientSession == null
                ? SessionExpirationUtils.calculateUserSessionMaxLifespanTimestamp(
                        userSession.isOffline(), userSession.isRememberMe(), userSessionStarted, realm)
                : SessionExpirationUtils.calculateClientSessionMaxLifespanTimestamp(
                        userSession.isOffline(), userSession.isRememberMe(),
                        TimeUnit.SECONDS.toMillis(clientSession.getStarted()), userSessionStarted,
                        realm, clientSession.getClient());
        return millis > 0 ? TimeUnit.MILLISECONDS.toSeconds(millis) : -1;
    }
}
