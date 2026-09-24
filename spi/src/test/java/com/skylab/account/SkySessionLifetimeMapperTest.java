package com.skylab.account;

import org.junit.jupiter.api.Test;
import org.keycloak.models.AuthenticatedClientSessionModel;
import org.keycloak.models.ClientModel;
import org.keycloak.models.ClientSessionContext;
import org.keycloak.models.KeycloakContext;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.ProtocolMapperModel;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserSessionModel;
import org.keycloak.protocol.ProtocolMapper;
import org.keycloak.protocol.oidc.mappers.OIDCAccessTokenMapper;
import org.keycloak.protocol.oidc.mappers.OIDCIDTokenMapper;
import org.keycloak.protocol.oidc.mappers.TokenIntrospectionTokenMapper;
import org.keycloak.protocol.oidc.mappers.UserInfoTokenMapper;
import org.keycloak.representations.AccessToken;
import org.keycloak.representations.IDToken;

import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class SkySessionLifetimeMapperTest {

    private static final int STARTED = 1_790_000_000;
    private static final int EIGHT_HOURS = 8 * 60 * 60;
    private static final int THIRTY_DAYS = 30 * 24 * 60 * 60;

    @Test
    void writesWhenTheKeycloakSessionStartedAndWhenItsMaxLifespanEndsItIntoIdAndAccessTokens() {
        Fixture fixture = new Fixture();
        SkySessionLifetimeMapper mapper = new SkySessionLifetimeMapper();

        IDToken idToken = new IDToken();
        mapper.transformIDToken(idToken, model(), fixture.session, fixture.userSession, fixture.clientSessionCtx);
        AccessToken accessToken = new AccessToken();
        mapper.transformAccessToken(accessToken, model(), fixture.session, fixture.userSession, fixture.clientSessionCtx);

        for (IDToken token : new IDToken[] {idToken, accessToken}) {
            assertEquals(1_790_000_000L, token.getOtherClaims().get("sky_session_started"));
            assertEquals(1_790_000_000L + EIGHT_HOURS, token.getOtherClaims().get("sky_session_expires"));
        }
    }

    @Test
    void aRememberMeSessionLivesForTheLongerRememberMeLifespan() {
        Fixture fixture = new Fixture();
        when(fixture.userSession.isRememberMe()).thenReturn(true);
        when(fixture.realm.getSsoSessionMaxLifespanRememberMe()).thenReturn(THIRTY_DAYS);

        assertEquals(1_790_000_000L + THIRTY_DAYS, expires(fixture));

        when(fixture.realm.getSsoSessionMaxLifespanRememberMe()).thenReturn(3600);
        assertEquals(1_790_000_000L + EIGHT_HOURS, expires(fixture),
                "Keycloak never ends a remember-me session earlier than an ordinary one");

        when(fixture.realm.getSsoSessionMaxLifespanRememberMe()).thenReturn(0);
        assertEquals(1_790_000_000L + EIGHT_HOURS, expires(fixture));
    }

    @Test
    void anUnsetRealmLifespanIsKeycloaksTenHourDefault() {
        Fixture fixture = new Fixture();
        when(fixture.realm.getSsoSessionMaxLifespan()).thenReturn(0);

        assertEquals(1_790_000_000L + 10 * 60 * 60, expires(fixture));
    }

    @Test
    void aShorterClientSessionMaxLifespanEndsTheClientsSessionEarlier() {
        Fixture fixture = new Fixture();
        when(fixture.clientSession.getStarted()).thenReturn(STARTED + 600);
        when(fixture.client.getAttribute("client.session.max.lifespan")).thenReturn("3600");
        assertEquals(1_790_000_000L + 600 + 3600, expires(fixture), "counted from the client session start");

        when(fixture.client.getAttribute("client.session.max.lifespan")).thenReturn(String.valueOf(2 * EIGHT_HOURS));
        assertEquals(1_790_000_000L + EIGHT_HOURS, expires(fixture), "never later than the SSO session itself");

        when(fixture.client.getAttribute("client.session.max.lifespan")).thenReturn(null);
        when(fixture.realm.getClientSessionMaxLifespan()).thenReturn(1800);
        assertEquals(1_790_000_000L + 600 + 1800, expires(fixture), "the realm-wide client session max applies too");
    }

    @Test
    void withoutAClientSessionTheSsoSessionLifespanIsUsed() {
        Fixture fixture = new Fixture();
        IDToken token = new IDToken();

        new SkySessionLifetimeMapper().transformIDToken(token, model(), fixture.session, fixture.userSession, null);

        assertEquals(1_790_000_000L + EIGHT_HOURS, token.getOtherClaims().get("sky_session_expires"));
    }

    @Test
    void anOfflineSessionWithoutAMaxLifespanHasNoExpiryClaim() {
        Fixture fixture = new Fixture();
        when(fixture.userSession.isOffline()).thenReturn(true);
        when(fixture.realm.isOfflineSessionMaxLifespanEnabled()).thenReturn(false);
        IDToken token = new IDToken();

        new SkySessionLifetimeMapper().transformIDToken(token, model(), fixture.session, fixture.userSession,
                fixture.clientSessionCtx);

        assertEquals(1_790_000_000L, token.getOtherClaims().get("sky_session_started"));
        assertNull(token.getOtherClaims().get("sky_session_expires"));
    }

    @Test
    void writesNothingWhereTheMapperIsSwitchedOffOrWithoutASession() {
        Fixture fixture = new Fixture();
        SkySessionLifetimeMapper mapper = new SkySessionLifetimeMapper();
        ProtocolMapperModel off = model();
        off.getConfig().put("id.token.claim", "false");

        IDToken switchedOff = new IDToken();
        mapper.transformIDToken(switchedOff, off, fixture.session, fixture.userSession, fixture.clientSessionCtx);
        assertTrue(switchedOff.getOtherClaims().isEmpty());

        IDToken sessionless = new IDToken();
        mapper.transformIDToken(sessionless, model(), fixture.session, null, null);
        assertTrue(sessionless.getOtherClaims().isEmpty());
    }

    @Test
    void isAnIdAccessAndIntrospectionMapperRegisteredAsAProvider() throws IOException {
        SkySessionLifetimeMapper mapper = new SkySessionLifetimeMapper();

        assertEquals("sky-session-lifetime-mapper", mapper.getId());
        assertEquals("openid-connect", mapper.getProtocol());
        assertTrue(OIDCIDTokenMapper.class.isInstance(mapper));
        assertTrue(OIDCAccessTokenMapper.class.isInstance(mapper));
        assertTrue(TokenIntrospectionTokenMapper.class.isInstance(mapper));
        assertFalse(UserInfoTokenMapper.class.isAssignableFrom(SkySessionLifetimeMapper.class));
        try (InputStream services = SkySessionLifetimeMapper.class.getClassLoader()
                .getResourceAsStream("META-INF/services/" + ProtocolMapper.class.getName())) {
            assertNotNull(services, "protocol mapper service registration is missing");
            String registered = new String(services.readAllBytes(), StandardCharsets.UTF_8);
            assertTrue(registered.lines().anyMatch(SkySessionLifetimeMapper.class.getName()::equals),
                    "SkySessionLifetimeMapper is not registered as a ProtocolMapper provider");
        }
    }

    private static Object expires(Fixture fixture) {
        AccessToken token = new AccessToken();
        new SkySessionLifetimeMapper().transformAccessToken(token, model(), fixture.session, fixture.userSession,
                fixture.clientSessionCtx);
        return token.getOtherClaims().get("sky_session_expires");
    }

    private static ProtocolMapperModel model() {
        ProtocolMapperModel model = new ProtocolMapperModel();
        model.setName("sky_session_lifetime");
        model.setProtocol("openid-connect");
        model.setProtocolMapper(SkySessionLifetimeMapper.PROVIDER_ID);
        Map<String, String> config = new HashMap<>();
        config.put("id.token.claim", "true");
        config.put("access.token.claim", "true");
        config.put("introspection.token.claim", "true");
        model.setConfig(config);
        return model;
    }

    /** An account-center login on a realm with an 8-hour SSO session and nothing else configured. */
    private static final class Fixture {
        private final KeycloakSession session = mock(KeycloakSession.class);
        private final RealmModel realm = mock(RealmModel.class);
        private final ClientModel client = mock(ClientModel.class);
        private final UserSessionModel userSession = mock(UserSessionModel.class);
        private final AuthenticatedClientSessionModel clientSession = mock(AuthenticatedClientSessionModel.class);
        private final ClientSessionContext clientSessionCtx = mock(ClientSessionContext.class);

        private Fixture() {
            KeycloakContext context = mock(KeycloakContext.class);
            when(session.getContext()).thenReturn(context);
            when(context.getClient()).thenReturn(client);
            when(context.getRealm()).thenReturn(realm);
            when(client.getClientId()).thenReturn("account-center");
            when(realm.getSsoSessionMaxLifespan()).thenReturn(EIGHT_HOURS);
            when(userSession.getStarted()).thenReturn(STARTED);
            when(userSession.getRealm()).thenReturn(realm);
            when(clientSession.getStarted()).thenReturn(STARTED);
            when(clientSession.getClient()).thenReturn(client);
            when(clientSession.getUserSession()).thenReturn(userSession);
            when(clientSessionCtx.getClientSession()).thenReturn(clientSession);
        }
    }
}
