package com.skylab.account;

import org.jboss.logging.Logger;
import org.keycloak.models.ClientModel;
import org.keycloak.models.ClientSessionContext;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.ProtocolMapperModel;
import org.keycloak.models.RoleModel;
import org.keycloak.models.UserModel;
import org.keycloak.models.UserSessionModel;
import org.keycloak.models.utils.RoleUtils;
import org.keycloak.protocol.oidc.mappers.AbstractOIDCProtocolMapper;
import org.keycloak.protocol.oidc.mappers.OIDCAccessTokenMapper;
import org.keycloak.protocol.oidc.mappers.OIDCAttributeMapperHelper;
import org.keycloak.protocol.oidc.mappers.TokenIntrospectionTokenMapper;
import org.keycloak.provider.ProviderConfigProperty;
import org.keycloak.representations.IDToken;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;
import java.util.TreeSet;

/**
 * Emits the {@code sky_authorization} claim for Account Center: every application (client) role
 * the person effectively holds, grouped as {@code sky_authorization.<clientId>.roles}, in the
 * access token (and its introspection response) only, never in the ID token or userinfo.
 *
 * <p>Keycloak's own client-role mappers resolve against the client's scope, so listing every
 * application role with them would require {@code fullScopeAllowed=true} on the
 * {@code account-center} client. That flag must stay off: Keycloak Admin REST authorizes a
 * bearer token through {@code AdminAuth.hasAppRole}, which is
 * {@code user.hasRole(role) && client.hasScope(role)}, and {@code client.hasScope} is true for
 * every role once full scope is on. With full scope every {@code my.} token of a person who
 * holds {@code realm-management} roles would therefore be a valid Admin REST credential. This
 * mapper instead reads the person's effective role mappings directly (direct mappings, group
 * mappings, composites expanded), keeps client roles only and drops Keycloak's own management
 * clients, so the claim is a read-only permissions view and never widens what the token may
 * do.</p>
 *
 * <p>Clients are sorted by client id and role names are sorted within a client. The claim is
 * capped at {@link #MAX_CLIENTS} clients and {@link #MAX_ROLES_PER_CLIENT} roles per client;
 * anything beyond a cap is dropped and reported with one {@code WARN} line per token. When the
 * person holds no application role the claim is omitted.</p>
 */
public final class SkyAuthorizationMapper extends AbstractOIDCProtocolMapper
        implements OIDCAccessTokenMapper, TokenIntrospectionTokenMapper {

    public static final String PROVIDER_ID = "sky-authorization-mapper";
    public static final String CLAIM_NAME = "sky_authorization";
    static final String ROLES_KEY = "roles";
    static final int MAX_CLIENTS = 64;
    static final int MAX_ROLES_PER_CLIENT = 256;
    static final Set<String> EXCLUDED_CLIENT_IDS = Set.of(
            "realm-management",
            "broker",
            "account",
            "account-console",
            "security-admin-console",
            "admin-cli");
    /** Master-realm administration clients ({@code <realm>-realm}) are management clients too. */
    static final String REALM_CLIENT_SUFFIX = "-realm";

    private static final Logger LOG = Logger.getLogger(SkyAuthorizationMapper.class);
    private static final List<ProviderConfigProperty> CONFIG_PROPERTIES;

    static {
        List<ProviderConfigProperty> properties = new ArrayList<>();
        OIDCAttributeMapperHelper.addIncludeInTokensConfig(properties, SkyAuthorizationMapper.class);
        CONFIG_PROPERTIES = List.copyOf(properties);
    }

    @Override
    public String getId() {
        return PROVIDER_ID;
    }

    @Override
    public String getDisplayType() {
        return "SKY LAB authorization";
    }

    @Override
    public String getDisplayCategory() {
        return TOKEN_MAPPER_CATEGORY;
    }

    @Override
    public String getHelpText() {
        return "Adds sky_authorization.<clientId>.roles with every application role the person holds "
                + "(access token and introspection only; Keycloak management clients excluded).";
    }

    @Override
    public List<ProviderConfigProperty> getConfigProperties() {
        return CONFIG_PROPERTIES;
    }

    @Override
    protected void setClaim(IDToken token, ProtocolMapperModel mappingModel, UserSessionModel userSession,
                            KeycloakSession keycloakSession, ClientSessionContext clientSessionCtx) {
        UserModel user = userSession == null ? null : userSession.getUser();
        if (user == null) {
            return;
        }
        Map<String, Map<String, List<String>>> claim = authorization(user);
        if (claim.isEmpty()) {
            return;
        }
        token.getOtherClaims().put(CLAIM_NAME, claim);
    }

    /**
     * @return {@code {clientId: {"roles": [sorted role names]}}} for every non-management client
     *         the person effectively holds roles in, sorted by client id, capped at
     *         {@link #MAX_CLIENTS} clients and {@link #MAX_ROLES_PER_CLIENT} roles per client;
     *         empty when the person holds no application role.
     */
    static Map<String, Map<String, List<String>>> authorization(UserModel user) {
        TreeMap<String, TreeSet<String>> grouped = new TreeMap<>();
        for (RoleModel role : RoleUtils.getDeepUserRoleMappings(user)) {
            if (!role.isClientRole() || !(role.getContainer() instanceof ClientModel client)) {
                continue;
            }
            String clientId = client.getClientId();
            String roleName = role.getName();
            if (clientId == null || clientId.isEmpty() || isExcludedClient(clientId)
                    || roleName == null || roleName.isEmpty()) {
                continue;
            }
            grouped.computeIfAbsent(clientId, ignored -> new TreeSet<>()).add(roleName);
        }

        Map<String, Map<String, List<String>>> claim = new LinkedHashMap<>();
        int droppedClients = 0;
        int droppedRoles = 0;
        for (Map.Entry<String, TreeSet<String>> entry : grouped.entrySet()) {
            if (claim.size() >= MAX_CLIENTS) {
                droppedClients++;
                continue;
            }
            List<String> names = new ArrayList<>(MAX_ROLES_PER_CLIENT);
            for (String name : entry.getValue()) {
                if (names.size() >= MAX_ROLES_PER_CLIENT) {
                    droppedRoles++;
                    continue;
                }
                names.add(name);
            }
            claim.put(entry.getKey(), Map.of(ROLES_KEY, List.copyOf(names)));
        }
        if (droppedClients > 0 || droppedRoles > 0) {
            LOG.warnf("sky_authorization truncated for user %s: %d client(s) beyond the cap of %d "
                            + "and %d role(s) beyond the cap of %d per client were dropped",
                    user.getId(), droppedClients, MAX_CLIENTS, droppedRoles, MAX_ROLES_PER_CLIENT);
        }
        return claim;
    }

    static boolean isExcludedClient(String clientId) {
        return EXCLUDED_CLIENT_IDS.contains(clientId) || clientId.endsWith(REALM_CLIENT_SUFFIX);
    }
}
