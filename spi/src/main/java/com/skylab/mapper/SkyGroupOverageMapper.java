package com.skylab.mapper;

import org.jboss.logging.Logger;
import org.keycloak.models.ClientSessionContext;
import org.keycloak.models.GroupModel;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.ProtocolMapperContainerModel;
import org.keycloak.models.ProtocolMapperModel;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;
import org.keycloak.models.UserSessionModel;
import org.keycloak.models.utils.ModelToRepresentation;
import org.keycloak.protocol.ProtocolMapperConfigException;
import org.keycloak.protocol.ProtocolMapperUtils;
import org.keycloak.protocol.oidc.mappers.AbstractOIDCProtocolMapper;
import org.keycloak.protocol.oidc.mappers.OIDCAccessTokenMapper;
import org.keycloak.protocol.oidc.mappers.OIDCAttributeMapperHelper;
import org.keycloak.protocol.oidc.mappers.OIDCIDTokenMapper;
import org.keycloak.protocol.oidc.mappers.TokenIntrospectionTokenMapper;
import org.keycloak.protocol.oidc.mappers.UserInfoTokenMapper;
import org.keycloak.provider.ProviderConfigProperty;
import org.keycloak.representations.IDToken;

import java.net.URI;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Function;

/**
 * Group overage (ADR-0059): Keycloak's Group Membership mapper with Microsoft Entra's cap. Up to
 * the threshold (default {@value #DEFAULT_THRESHOLD}) group paths it writes the claim exactly as
 * {@code oidc-group-membership-mapper} does. Above it the list is left out and the token carries
 * Entra's distributed-claim marker instead:
 *
 * <pre>
 * "_claim_names":   {"groups": "src1"},
 * "_claim_sources": {"src1": {"endpoint": "&lt;base&gt;/admin/realms/&lt;realm&gt;/users/&lt;id&gt;/groups"}}
 * </pre>
 *
 * <p>A service that reads groups asks Keycloak for the person's groups when it sees the marker
 * (core: {@code _claim_names.groups}); it looks only at the marker's presence and never calls the
 * endpoint it names. A list is never cut short: a partial list would read as "not in that group".
 * The access token, the ID token, userinfo and introspection all follow the same rule, each where
 * the mapper is enabled for it. The claim name names both the list and the marker's key, so a
 * service that reads {@code groups} needs the default.</p>
 */
public final class SkyGroupOverageMapper extends AbstractOIDCProtocolMapper
        implements OIDCAccessTokenMapper, OIDCIDTokenMapper, UserInfoTokenMapper, TokenIntrospectionTokenMapper {

    public static final String PROVIDER_ID = "sky-group-overage-mapper";
    public static final String THRESHOLD = "overage.threshold";
    public static final String FULL_PATH = "full.path";
    public static final String CLAIM_NAMES = "_claim_names";
    public static final String CLAIM_SOURCES = "_claim_sources";
    static final int DEFAULT_THRESHOLD = 30;
    static final String DEFAULT_CLAIM = "groups";
    static final String SOURCE = "src1";

    private static final Logger LOG = Logger.getLogger(SkyGroupOverageMapper.class);
    private static final List<ProviderConfigProperty> CONFIG_PROPERTIES;

    static {
        List<ProviderConfigProperty> properties = new ArrayList<>();
        OIDCAttributeMapperHelper.addTokenClaimNameConfig(properties);
        properties.get(0).setDefaultValue(DEFAULT_CLAIM);

        ProviderConfigProperty fullPath = new ProviderConfigProperty();
        fullPath.setName(FULL_PATH);
        fullPath.setLabel("Full group path");
        fullPath.setType(ProviderConfigProperty.BOOLEAN_TYPE);
        fullPath.setDefaultValue("true");
        fullPath.setHelpText("Include the full path of each group (/top/level1/level2); false writes the group name only.");
        properties.add(fullPath);

        ProviderConfigProperty threshold = new ProviderConfigProperty();
        threshold.setName(THRESHOLD);
        threshold.setLabel("Group overage threshold");
        threshold.setType(ProviderConfigProperty.STRING_TYPE);
        threshold.setDefaultValue(Integer.toString(DEFAULT_THRESHOLD));
        threshold.setHelpText("Most groups a token lists. Above it the token carries the Group overage marker "
                + "(_claim_names / _claim_sources) instead of the list, and services ask Keycloak for the groups.");
        properties.add(threshold);

        OIDCAttributeMapperHelper.addIncludeInTokensConfig(properties, SkyGroupOverageMapper.class);
        CONFIG_PROPERTIES = List.copyOf(properties);
    }

    @Override
    public String getId() {
        return PROVIDER_ID;
    }

    @Override
    public String getDisplayType() {
        return "SKY LAB group membership with overage";
    }

    @Override
    public String getDisplayCategory() {
        return TOKEN_MAPPER_CATEGORY;
    }

    @Override
    public String getHelpText() {
        return "Group Membership up to the threshold; above it the Microsoft-style Group overage marker "
                + "(_claim_names / _claim_sources) instead of the group list.";
    }

    @Override
    public List<ProviderConfigProperty> getConfigProperties() {
        return CONFIG_PROPERTIES;
    }

    @Override
    public void validateConfig(KeycloakSession session, RealmModel realm, ProtocolMapperContainerModel client,
                               ProtocolMapperModel mapperModel) throws ProtocolMapperConfigException {
        String raw = mapperModel.getConfig() == null ? null : mapperModel.getConfig().get(THRESHOLD);
        if (raw != null && parseThreshold(raw) < 0) {
            throw new ProtocolMapperConfigException("The group overage threshold must be a whole number of at least 0, not '"
                    + raw + "'");
        }
    }

    @Override
    protected void setClaim(IDToken token, ProtocolMapperModel mappingModel, UserSessionModel userSession,
                            KeycloakSession keycloakSession, ClientSessionContext clientSessionCtx) {
        UserModel user = userSession == null ? null : userSession.getUser();
        if (user == null) {
            return;
        }
        Function<GroupModel, String> toClaim = fullPath(mappingModel)
                ? ModelToRepresentation::buildGroupPath : GroupModel::getName;
        List<String> membership = user.getGroupsStream().map(toClaim).toList();
        int threshold = threshold(mappingModel);
        String claim = claimName(mappingModel);

        if (membership.size() <= threshold) {
            // Exactly what Keycloak's Group Membership mapper writes (no claim for no group).
            ProtocolMapperModel asGroupMembership = copyOf(mappingModel);
            asGroupMembership.getConfig().put(OIDCAttributeMapperHelper.TOKEN_CLAIM_NAME, claim);
            asGroupMembership.getConfig().put(ProtocolMapperUtils.MULTIVALUED, "true");
            OIDCAttributeMapperHelper.mapClaim(token, asGroupMembership, membership);
            return;
        }

        token.getOtherClaims().put(CLAIM_NAMES, Map.of(claim, SOURCE));
        token.getOtherClaims().put(CLAIM_SOURCES, Map.of(SOURCE, Map.of("endpoint",
                groupsEndpoint(keycloakSession, userSession, user))));
        LOG.debugf("Group overage for user %s: %d groups above the threshold of %d", user.getId(),
                membership.size(), threshold);
    }

    /** {@code <base>/admin/realms/<realm>/users/<id>/groups}: where the groups can be read. */
    static String groupsEndpoint(KeycloakSession session, UserSessionModel userSession, UserModel user) {
        URI base = session.getContext().getUri().getBaseUri();
        String root = base.toString().endsWith("/") ? base.toString() : base + "/";
        return root + "admin/realms/" + userSession.getRealm().getName() + "/users/" + user.getId() + "/groups";
    }

    static int threshold(ProtocolMapperModel model) {
        String raw = model.getConfig().get(THRESHOLD);
        if (raw == null) {
            return DEFAULT_THRESHOLD;
        }
        int parsed = parseThreshold(raw);
        if (parsed < 0) {
            LOG.warnf("Mapper '%s' has the unreadable group overage threshold '%s'; using %d", model.getName(), raw,
                    DEFAULT_THRESHOLD);
            return DEFAULT_THRESHOLD;
        }
        return parsed;
    }

    /** The threshold, or -1 when it is not a whole number of at least 0. */
    private static int parseThreshold(String raw) {
        String trimmed = raw.trim();
        if (trimmed.isEmpty() || !trimmed.chars().allMatch(Character::isDigit)) {
            return -1;
        }
        try {
            return Integer.parseInt(trimmed);
        } catch (NumberFormatException tooLarge) {
            return -1;
        }
    }

    private static boolean fullPath(ProtocolMapperModel model) {
        return !"false".equals(model.getConfig().get(FULL_PATH));
    }

    private static String claimName(ProtocolMapperModel model) {
        String claim = model.getConfig().get(OIDCAttributeMapperHelper.TOKEN_CLAIM_NAME);
        return claim == null || claim.isBlank() ? DEFAULT_CLAIM : claim;
    }

    private static ProtocolMapperModel copyOf(ProtocolMapperModel model) {
        ProtocolMapperModel copy = new ProtocolMapperModel();
        copy.setId(model.getId());
        copy.setName(model.getName());
        copy.setProtocol(model.getProtocol());
        copy.setProtocolMapper(model.getProtocolMapper());
        copy.setConfig(new HashMap<>(model.getConfig()));
        return copy;
    }
}
