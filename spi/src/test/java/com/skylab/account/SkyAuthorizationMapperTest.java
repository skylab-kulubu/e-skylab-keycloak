package com.skylab.account;

import org.junit.jupiter.api.Test;
import org.keycloak.models.ClientModel;
import org.keycloak.models.GroupModel;
import org.keycloak.models.KeycloakContext;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.ProtocolMapperModel;
import org.keycloak.models.RealmModel;
import org.keycloak.models.RoleModel;
import org.keycloak.models.UserModel;
import org.keycloak.models.UserSessionModel;
import org.keycloak.protocol.ProtocolMapper;
import org.keycloak.protocol.oidc.mappers.OIDCAccessTokenMapper;
import org.keycloak.protocol.oidc.mappers.OIDCIDTokenMapper;
import org.keycloak.protocol.oidc.mappers.TokenIntrospectionTokenMapper;
import org.keycloak.protocol.oidc.mappers.UserInfoTokenMapper;
import org.keycloak.representations.AccessToken;

import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.stream.IntStream;
import java.util.stream.Stream;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class SkyAuthorizationMapperTest {

    private static final String USER_ID = "11111111-1111-4111-8111-111111111111";

    @Test
    void groupsClientRolesByClientIdWithSortedNames() {
        ClientModel core = client("core");
        ClientModel forms = client("forms");
        UserModel user = user(List.of(
                clientRole(forms, "forms:read"),
                clientRole(core, "url:read"),
                clientRole(core, "url:create"),
                clientRole(forms, "forms:admin")));

        Map<String, Map<String, List<String>>> claim = SkyAuthorizationMapper.authorization(user);

        assertEquals(List.of("core", "forms"), new ArrayList<>(claim.keySet()));
        assertEquals(Map.of("roles", List.of("url:create", "url:read")), claim.get("core"));
        assertEquals(Map.of("roles", List.of("forms:admin", "forms:read")), claim.get("forms"));
    }

    @Test
    void expandsCompositeRolesAcrossClients() {
        ClientModel core = client("core");
        ClientModel forms = client("forms");
        RoleModel formsWrite = clientRole(forms, "forms:write");
        RoleModel formsRead = clientRole(forms, "forms:read", formsWrite);
        RoleModel coreAdmin = clientRole(core, "admin", formsRead);
        UserModel user = user(List.of(coreAdmin));

        Map<String, Map<String, List<String>>> claim = SkyAuthorizationMapper.authorization(user);

        assertEquals(Map.of("roles", List.of("admin")), claim.get("core"));
        assertEquals(Map.of("roles", List.of("forms:read", "forms:write")), claim.get("forms"));
    }

    @Test
    void includesRolesInheritedFromGroups() {
        ClientModel core = client("core");
        UserModel user = user(List.of(), List.of(group(clientRole(core, "url:create"))));

        assertEquals(Map.of("core", Map.of("roles", List.of("url:create"))),
                SkyAuthorizationMapper.authorization(user));
    }

    @Test
    void dropsRealmRolesAndKeycloakManagementClients() {
        ClientModel core = client("core");
        List<RoleModel> roles = new ArrayList<>();
        roles.add(clientRole(core, "url:create"));
        roles.add(realmRole("offline_access"));
        roles.add(realmRole("default-roles-e-skylab", clientRole(client("account"), "manage-account")));
        for (String excluded : List.of("realm-management", "broker", "account", "account-console",
                "security-admin-console", "admin-cli", "master-realm", "e-skylab-realm")) {
            roles.add(clientRole(client(excluded), "view-users"));
        }
        UserModel user = user(roles);

        assertEquals(Map.of("core", Map.of("roles", List.of("url:create"))),
                SkyAuthorizationMapper.authorization(user));
    }

    @Test
    void managementRolesReachedThroughCompositesAreDroppedToo() {
        ClientModel realmManagement = client("realm-management");
        RoleModel viewUsers = clientRole(realmManagement, "view-users");
        RoleModel realmAdmin = clientRole(realmManagement, "realm-admin", viewUsers);
        UserModel user = user(List.of(realmRole("admin", realmAdmin)));

        assertTrue(SkyAuthorizationMapper.authorization(user).isEmpty());
    }

    @Test
    void capsTheNumberOfClientsAtSixtyFourSortedByClientId() {
        List<RoleModel> roles = new ArrayList<>();
        IntStream.range(0, 70).forEach(index ->
                roles.add(clientRole(client(String.format("client-%02d", index)), "member")));
        UserModel user = user(roles);

        Map<String, Map<String, List<String>>> claim = SkyAuthorizationMapper.authorization(user);

        assertEquals(SkyAuthorizationMapper.MAX_CLIENTS, claim.size());
        assertEquals("client-00", claim.keySet().iterator().next());
        assertTrue(claim.containsKey("client-63"));
        assertFalse(claim.containsKey("client-64"));
    }

    @Test
    void capsTheRolesOfOneClientAtTwoHundredFiftySixSortedByName() {
        ClientModel core = client("core");
        List<RoleModel> roles = new ArrayList<>();
        IntStream.range(0, 300).forEach(index ->
                roles.add(clientRole(core, String.format("role-%03d", index))));
        roles.add(clientRole(client("forms"), "forms:read"));
        UserModel user = user(roles);

        Map<String, Map<String, List<String>>> claim = SkyAuthorizationMapper.authorization(user);

        List<String> kept = claim.get("core").get("roles");
        assertEquals(SkyAuthorizationMapper.MAX_ROLES_PER_CLIENT, kept.size());
        assertEquals("role-000", kept.get(0));
        assertEquals("role-255", kept.get(kept.size() - 1));
        assertEquals(Map.of("roles", List.of("forms:read")), claim.get("forms"));
    }

    @Test
    void omitsTheClaimWhenThePersonHoldsNoApplicationRole() {
        UserModel user = user(List.of(realmRole("offline_access"),
                clientRole(client("account"), "manage-account")));
        AccessToken token = new AccessToken();

        new SkyAuthorizationMapper().transformAccessToken(
                token, accessTokenModel(), session(), userSession(user), null);

        assertNull(token.getOtherClaims().get(SkyAuthorizationMapper.CLAIM_NAME));
    }

    @Test
    void writesTheClaimIntoTheAccessTokenOnlyWhenTheMapperIsEnabledForIt() {
        ClientModel core = client("core");
        UserModel user = user(List.of(clientRole(core, "url:create")));
        SkyAuthorizationMapper mapper = new SkyAuthorizationMapper();

        AccessToken token = new AccessToken();
        mapper.transformAccessToken(token, accessTokenModel(), session(), userSession(user), null);
        assertEquals(Map.of("core", Map.of("roles", List.of("url:create"))),
                token.getOtherClaims().get(SkyAuthorizationMapper.CLAIM_NAME));

        AccessToken introspection = new AccessToken();
        mapper.transformIntrospectionToken(introspection, accessTokenModel(), session(), userSession(user), null);
        assertEquals(Map.of("core", Map.of("roles", List.of("url:create"))),
                introspection.getOtherClaims().get(SkyAuthorizationMapper.CLAIM_NAME));

        ProtocolMapperModel disabled = accessTokenModel();
        disabled.getConfig().put("access.token.claim", "false");
        disabled.getConfig().put("introspection.token.claim", "false");
        AccessToken untouched = new AccessToken();
        mapper.transformAccessToken(untouched, disabled, session(), userSession(user), null);
        mapper.transformIntrospectionToken(untouched, disabled, session(), userSession(user), null);
        assertNull(untouched.getOtherClaims().get(SkyAuthorizationMapper.CLAIM_NAME));
    }

    @Test
    void isAnAccessTokenMapperAndNeverAnIdTokenOrUserinfoMapper() {
        SkyAuthorizationMapper mapper = new SkyAuthorizationMapper();

        assertEquals("sky-authorization-mapper", mapper.getId());
        assertEquals("openid-connect", mapper.getProtocol());
        assertTrue(OIDCAccessTokenMapper.class.isInstance(mapper));
        assertTrue(TokenIntrospectionTokenMapper.class.isInstance(mapper));
        assertFalse(OIDCIDTokenMapper.class.isAssignableFrom(SkyAuthorizationMapper.class));
        assertFalse(UserInfoTokenMapper.class.isAssignableFrom(SkyAuthorizationMapper.class));
        assertEquals(List.of("access.token.claim", "lightweight.claim", "introspection.token.claim"),
                mapper.getConfigProperties().stream().map(property -> property.getName()).toList());
    }

    @Test
    void isRegisteredAsAProtocolMapperProvider() throws IOException {
        try (InputStream services = SkyAuthorizationMapper.class.getClassLoader()
                .getResourceAsStream("META-INF/services/" + ProtocolMapper.class.getName())) {
            assertNotNull(services, "protocol mapper service registration is missing");
            String registered = new String(services.readAllBytes(), StandardCharsets.UTF_8);
            assertTrue(registered.lines().anyMatch(SkyAuthorizationMapper.class.getName()::equals),
                    "SkyAuthorizationMapper is not registered as a ProtocolMapper provider");
        }
    }

    private static ProtocolMapperModel accessTokenModel() {
        ProtocolMapperModel model = new ProtocolMapperModel();
        model.setName("account-api-sky-authorization");
        model.setProtocol("openid-connect");
        model.setProtocolMapper(SkyAuthorizationMapper.PROVIDER_ID);
        Map<String, String> config = new HashMap<>();
        config.put("access.token.claim", "true");
        config.put("id.token.claim", "false");
        config.put("userinfo.token.claim", "false");
        config.put("introspection.token.claim", "true");
        model.setConfig(config);
        return model;
    }

    private static KeycloakSession session() {
        KeycloakSession session = mock(KeycloakSession.class);
        KeycloakContext context = mock(KeycloakContext.class);
        ClientModel accountCenter = client("account-center");
        when(session.getContext()).thenReturn(context);
        when(context.getClient()).thenReturn(accountCenter);
        return session;
    }

    private static UserSessionModel userSession(UserModel user) {
        UserSessionModel userSession = mock(UserSessionModel.class);
        when(userSession.getUser()).thenReturn(user);
        return userSession;
    }

    private static UserModel user(List<RoleModel> directRoles) {
        return user(directRoles, List.of());
    }

    private static UserModel user(List<RoleModel> directRoles, List<GroupModel> groups) {
        UserModel user = mock(UserModel.class);
        when(user.getId()).thenReturn(USER_ID);
        when(user.getRoleMappingsStream()).thenAnswer(invocation -> directRoles.stream());
        when(user.getGroupsStream()).thenAnswer(invocation -> groups.stream());
        return user;
    }

    private static GroupModel group(RoleModel... roles) {
        GroupModel group = mock(GroupModel.class);
        when(group.getId()).thenReturn(UUID.randomUUID().toString());
        when(group.getRoleMappingsStream()).thenAnswer(invocation -> Stream.of(roles));
        when(group.getParentId()).thenReturn(null);
        return group;
    }

    private static ClientModel client(String clientId) {
        ClientModel client = mock(ClientModel.class);
        when(client.getId()).thenReturn(UUID.randomUUID().toString());
        when(client.getClientId()).thenReturn(clientId);
        return client;
    }

    private static RoleModel clientRole(ClientModel client, String name, RoleModel... composites) {
        RoleModel role = role(name, composites);
        when(role.isClientRole()).thenReturn(true);
        when(role.getContainer()).thenReturn(client);
        return role;
    }

    private static RoleModel realmRole(String name, RoleModel... composites) {
        RoleModel role = role(name, composites);
        when(role.isClientRole()).thenReturn(false);
        when(role.getContainer()).thenReturn(mock(RealmModel.class));
        return role;
    }

    private static RoleModel role(String name, RoleModel... composites) {
        RoleModel role = mock(RoleModel.class);
        when(role.getId()).thenReturn(UUID.randomUUID().toString());
        when(role.getName()).thenReturn(name);
        when(role.isComposite()).thenReturn(composites.length > 0);
        when(role.getCompositesStream()).thenAnswer(invocation -> Stream.of(composites));
        return role;
    }
}
