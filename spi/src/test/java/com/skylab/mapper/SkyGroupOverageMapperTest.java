package com.skylab.mapper;

import org.junit.jupiter.api.Test;
import org.keycloak.models.ClientModel;
import org.keycloak.models.GroupModel;
import org.keycloak.models.KeycloakContext;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakUriInfo;
import org.keycloak.models.ProtocolMapperModel;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;
import org.keycloak.models.UserSessionModel;
import org.keycloak.protocol.ProtocolMapper;
import org.keycloak.protocol.ProtocolMapperConfigException;
import org.keycloak.protocol.oidc.mappers.OIDCAccessTokenMapper;
import org.keycloak.protocol.oidc.mappers.OIDCIDTokenMapper;
import org.keycloak.protocol.oidc.mappers.TokenIntrospectionTokenMapper;
import org.keycloak.protocol.oidc.mappers.UserInfoTokenMapper;
import org.keycloak.representations.AccessToken;
import org.keycloak.representations.IDToken;

import java.io.IOException;
import java.io.InputStream;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.stream.IntStream;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class SkyGroupOverageMapperTest {

    private static final String USER_ID = "11111111-1111-4111-8111-111111111111";
    private static final String REALM = "e-skylab";
    private static final String MEMBERS_ENDPOINT =
            "https://e.yildizskylab.com/admin/realms/e-skylab/users/" + USER_ID + "/groups";

    @Test
    void writesNoClaimAndNoMarkerForAPersonWithoutGroups() {
        AccessToken token = accessToken(model(Map.of()), user(0));

        assertFalse(token.getOtherClaims().containsKey("groups"));
        assertFalse(token.getOtherClaims().containsKey(SkyGroupOverageMapper.CLAIM_NAMES));
        assertFalse(token.getOtherClaims().containsKey(SkyGroupOverageMapper.CLAIM_SOURCES));
    }

    @Test
    void writesTheFullPathsLikeGroupMembershipAtTheThreshold() {
        AccessToken token = accessToken(model(Map.of()), user(30));

        assertEquals(paths(30), token.getOtherClaims().get("groups"));
        assertFalse(token.getOtherClaims().containsKey(SkyGroupOverageMapper.CLAIM_NAMES));
        assertFalse(token.getOtherClaims().containsKey(SkyGroupOverageMapper.CLAIM_SOURCES));
    }

    @Test
    void writesTheMicrosoftMarkerInsteadOfTheListAboveTheThreshold() {
        AccessToken token = accessToken(model(Map.of()), user(31));

        assertFalse(token.getOtherClaims().containsKey("groups"));
        assertEquals(Map.of("groups", "src1"), token.getOtherClaims().get(SkyGroupOverageMapper.CLAIM_NAMES));
        assertEquals(Map.of("src1", Map.of("endpoint", MEMBERS_ENDPOINT)),
                token.getOtherClaims().get(SkyGroupOverageMapper.CLAIM_SOURCES));
    }

    @Test
    void theThresholdIsConfigurable() {
        ProtocolMapperModel two = model(Map.of(SkyGroupOverageMapper.THRESHOLD, "2"));

        assertEquals(paths(2), accessToken(two, user(2)).getOtherClaims().get("groups"));
        AccessToken over = accessToken(two, user(3));
        assertFalse(over.getOtherClaims().containsKey("groups"));
        assertEquals(Map.of("groups", "src1"), over.getOtherClaims().get(SkyGroupOverageMapper.CLAIM_NAMES));

        ProtocolMapperModel zero = model(Map.of(SkyGroupOverageMapper.THRESHOLD, "0"));
        assertEquals(Map.of("groups", "src1"),
                accessToken(zero, user(1)).getOtherClaims().get(SkyGroupOverageMapper.CLAIM_NAMES));
    }

    @Test
    void anUnreadableThresholdFallsBackToThirty() {
        ProtocolMapperModel broken = model(Map.of(SkyGroupOverageMapper.THRESHOLD, "many"));

        assertEquals(paths(30), accessToken(broken, user(30)).getOtherClaims().get("groups"));
        assertFalse(accessToken(broken, user(31)).getOtherClaims().containsKey("groups"));
    }

    @Test
    void theClaimNameNamesBothTheListAndTheMarker() {
        ProtocolMapperModel memberOf = model(Map.of("claim.name", "member_of"));

        assertEquals(paths(1), accessToken(memberOf, user(1)).getOtherClaims().get("member_of"));
        AccessToken over = accessToken(memberOf, user(31));
        assertFalse(over.getOtherClaims().containsKey("member_of"));
        assertEquals(Map.of("member_of", "src1"), over.getOtherClaims().get(SkyGroupOverageMapper.CLAIM_NAMES));
    }

    @Test
    void writesGroupNamesWhenFullPathIsOff() {
        ProtocolMapperModel names = model(Map.of("full.path", "false"));

        assertEquals(List.of("G01", "G02"), accessToken(names, user(2)).getOtherClaims().get("groups"));
    }

    @Test
    void theIdTokenUserinfoAndIntrospectionFollowTheSameRule() {
        SkyGroupOverageMapper mapper = new SkyGroupOverageMapper();
        ProtocolMapperModel model = model(Map.of());

        IDToken idToken = new IDToken();
        mapper.transformIDToken(idToken, model, session(), userSession(user(31)), null);
        assertEquals(Map.of("groups", "src1"), idToken.getOtherClaims().get(SkyGroupOverageMapper.CLAIM_NAMES));
        assertFalse(idToken.getOtherClaims().containsKey("groups"));

        AccessToken userInfo = new AccessToken();
        mapper.transformUserInfoToken(userInfo, model, session(), userSession(user(30)), null);
        assertEquals(paths(30), userInfo.getOtherClaims().get("groups"));

        AccessToken introspection = new AccessToken();
        mapper.transformIntrospectionToken(introspection, model, session(), userSession(user(31)), null);
        assertEquals(Map.of("groups", "src1"),
                introspection.getOtherClaims().get(SkyGroupOverageMapper.CLAIM_NAMES));
    }

    @Test
    void writesNothingIntoATokenTheMapperIsNotEnabledFor() {
        ProtocolMapperModel model = model(Map.of("access.token.claim", "false"));
        AccessToken token = accessToken(model, user(31));

        assertTrue(token.getOtherClaims().isEmpty());
    }

    @Test
    void refusesAThresholdThatIsNotANonNegativeWholeNumber() throws ProtocolMapperConfigException {
        SkyGroupOverageMapper mapper = new SkyGroupOverageMapper();
        for (String bad : List.of("many", "-1", "1.5", "")) {
            assertThrows(ProtocolMapperConfigException.class, () -> mapper.validateConfig(
                    null, null, null, model(Map.of(SkyGroupOverageMapper.THRESHOLD, bad))), bad);
        }
        for (String good : List.of("0", "30", "200")) {
            mapper.validateConfig(null, null, null, model(Map.of(SkyGroupOverageMapper.THRESHOLD, good)));
        }
        mapper.validateConfig(null, null, null, model(Map.of()));
    }

    @Test
    void isAnOidcMapperForEveryTokenWithItsOwnSettings() {
        SkyGroupOverageMapper mapper = new SkyGroupOverageMapper();

        assertEquals("sky-group-overage-mapper", mapper.getId());
        assertEquals("openid-connect", mapper.getProtocol());
        assertTrue(OIDCAccessTokenMapper.class.isInstance(mapper));
        assertTrue(OIDCIDTokenMapper.class.isInstance(mapper));
        assertTrue(UserInfoTokenMapper.class.isInstance(mapper));
        assertTrue(TokenIntrospectionTokenMapper.class.isInstance(mapper));
        List<String> names = mapper.getConfigProperties().stream().map(property -> property.getName()).toList();
        assertEquals(List.of("claim.name", "full.path", SkyGroupOverageMapper.THRESHOLD), names.subList(0, 3));
        assertTrue(names.containsAll(List.of("id.token.claim", "access.token.claim", "userinfo.token.claim",
                "introspection.token.claim")));
        assertEquals("groups", mapper.getConfigProperties().get(0).getDefaultValue());
        assertEquals("30", mapper.getConfigProperties().get(2).getDefaultValue());
    }

    @Test
    void isRegisteredAsAProtocolMapperProvider() throws IOException {
        try (InputStream services = SkyGroupOverageMapper.class.getClassLoader()
                .getResourceAsStream("META-INF/services/" + ProtocolMapper.class.getName())) {
            assertNotNull(services, "protocol mapper service registration is missing");
            String registered = new String(services.readAllBytes(), StandardCharsets.UTF_8);
            assertTrue(registered.lines().anyMatch(SkyGroupOverageMapper.class.getName()::equals),
                    "SkyGroupOverageMapper is not registered as a ProtocolMapper provider");
        }
    }

    private static AccessToken accessToken(ProtocolMapperModel model, UserModel user) {
        AccessToken token = new AccessToken();
        new SkyGroupOverageMapper().transformAccessToken(token, model, session(), userSession(user), null);
        return token;
    }

    private static ProtocolMapperModel model(Map<String, String> overrides) {
        ProtocolMapperModel model = new ProtocolMapperModel();
        model.setName("groups");
        model.setProtocol("openid-connect");
        model.setProtocolMapper(SkyGroupOverageMapper.PROVIDER_ID);
        Map<String, String> config = new HashMap<>();
        config.put("claim.name", "groups");
        config.put("full.path", "true");
        config.put("id.token.claim", "true");
        config.put("access.token.claim", "true");
        config.put("userinfo.token.claim", "true");
        config.put("introspection.token.claim", "true");
        config.putAll(overrides);
        model.setConfig(config);
        return model;
    }

    private static KeycloakSession session() {
        KeycloakSession session = mock(KeycloakSession.class);
        KeycloakContext context = mock(KeycloakContext.class);
        KeycloakUriInfo uri = mock(KeycloakUriInfo.class);
        ClientModel client = mock(ClientModel.class);
        when(session.getContext()).thenReturn(context);
        when(context.getClient()).thenReturn(client);
        when(context.getUri()).thenReturn(uri);
        when(uri.getBaseUri()).thenReturn(URI.create("https://e.yildizskylab.com/"));
        return session;
    }

    private static UserSessionModel userSession(UserModel user) {
        UserSessionModel userSession = mock(UserSessionModel.class);
        RealmModel realm = mock(RealmModel.class);
        when(realm.getName()).thenReturn(REALM);
        when(userSession.getUser()).thenReturn(user);
        when(userSession.getRealm()).thenReturn(realm);
        return userSession;
    }

    /** A person in COUNT groups G01, G02, … under /UYELER/OVERAGE. */
    private static UserModel user(int count) {
        GroupModel uyeler = group("UYELER", null);
        GroupModel overage = group("OVERAGE", uyeler);
        List<GroupModel> groups = new ArrayList<>();
        IntStream.rangeClosed(1, count).forEach(index -> groups.add(group(String.format("G%02d", index), overage)));
        UserModel user = mock(UserModel.class);
        when(user.getId()).thenReturn(USER_ID);
        when(user.getGroupsStream()).thenAnswer(invocation -> groups.stream());
        return user;
    }

    private static List<String> paths(int count) {
        return IntStream.rangeClosed(1, count).mapToObj(index -> String.format("/UYELER/OVERAGE/G%02d", index)).toList();
    }

    private static GroupModel group(String name, GroupModel parent) {
        String parentId = parent == null ? null : parent.getId();
        GroupModel group = mock(GroupModel.class);
        when(group.getId()).thenReturn(UUID.randomUUID().toString());
        when(group.getName()).thenReturn(name);
        when(group.getParent()).thenReturn(parent);
        when(group.getParentId()).thenReturn(parentId);
        return group;
    }
}
