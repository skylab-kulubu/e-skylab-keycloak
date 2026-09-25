package com.skylab.mapper;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.jboss.logging.Logger;
import org.keycloak.broker.provider.AbstractIdentityProviderMapper;
import org.keycloak.broker.provider.BrokeredIdentityContext;
import org.keycloak.models.IdentityProviderMapperModel;
import org.keycloak.models.IdentityProviderSyncMode;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;
import org.keycloak.provider.ProviderConfigProperty;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.EnumSet;
import java.util.List;
import java.util.Optional;
import java.util.Set;

/**
 * Copies the person's department from Microsoft Graph into the {@code department} user
 * attribute. The mapper's sync mode decides when: at first login always; with {@code FORCE} on
 * every later login too, because people change department; with {@code LEGACY} (the identity
 * provider default that {@code INHERIT} follows) only while the attribute is still empty, which
 * is what this mapper did before it supported {@code FORCE}. A missing token, a failed Graph
 * call or an empty Graph value never clears a department that is already stored.
 */
public final class MicrosoftMapper extends AbstractIdentityProviderMapper {

    public static final String PROVIDER_ID = "microsoft-department-mapper";
    static final String DEPARTMENT_ATTRIBUTE = "department";
    static final String FEDERATED_ACCESS_TOKEN = "FEDERATED_ACCESS_TOKEN";
    private static final Logger LOG = Logger.getLogger(MicrosoftMapper.class);
    private static final String GRAPH_API_URL = "https://graph.microsoft.com/v1.0/me?$select=department";
    private static final ObjectMapper OBJECT_MAPPER = new ObjectMapper();
    private static final HttpClient HTTP_CLIENT = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(5))
            .build();
    private static final Set<IdentityProviderSyncMode> SYNC_MODES = EnumSet.of(
            IdentityProviderSyncMode.IMPORT,
            IdentityProviderSyncMode.LEGACY,
            IdentityProviderSyncMode.FORCE);

    /** Reads the department for a Microsoft access token; empty when Graph has none. */
    @FunctionalInterface
    interface DepartmentSource {
        Optional<String> department(String accessToken) throws Exception;
    }

    private final DepartmentSource departments;

    public MicrosoftMapper() {
        this(MicrosoftMapper::fetchDepartment);
    }

    MicrosoftMapper(DepartmentSource departments) {
        this.departments = departments;
    }

    @Override
    public String[] getCompatibleProviders() {
        return new String[] {"microsoft"};
    }

    @Override
    public String getId() {
        return PROVIDER_ID;
    }

    @Override
    public String getDisplayCategory() {
        return "Attribute Importer";
    }

    @Override
    public String getDisplayType() {
        return "Microsoft Graph Department Fetcher";
    }

    @Override
    public String getHelpText() {
        return "Reads department from Microsoft Graph and stores it as a user attribute: at first login, "
                + "on every login with sync mode FORCE, and only while it is empty with LEGACY.";
    }

    @Override
    public boolean supportsSyncMode(IdentityProviderSyncMode syncMode) {
        return SYNC_MODES.contains(syncMode);
    }

    @Override
    public List<ProviderConfigProperty> getConfigProperties() {
        return List.of();
    }

    @Override
    public void importNewUser(
            KeycloakSession session,
            RealmModel realm,
            UserModel user,
            IdentityProviderMapperModel mapperModel,
            BrokeredIdentityContext context
    ) {
        synchronizeDepartment(context, user);
    }

    @Override
    public void preprocessFederatedIdentity(
            KeycloakSession session,
            RealmModel realm,
            IdentityProviderMapperModel mapperModel,
            BrokeredIdentityContext context
    ) {
        context.setEmail(null);
    }

    /** Sync mode FORCE: the department follows Microsoft Graph on every login. */
    @Override
    public void updateBrokeredUser(
            KeycloakSession session,
            RealmModel realm,
            UserModel user,
            IdentityProviderMapperModel mapperModel,
            BrokeredIdentityContext context
    ) {
        synchronizeDepartment(context, user);
    }

    /** Sync mode LEGACY: only an empty department is filled. */
    @Override
    public void updateBrokeredUserLegacy(
            KeycloakSession session,
            RealmModel realm,
            UserModel user,
            IdentityProviderMapperModel mapperModel,
            BrokeredIdentityContext context
    ) {
        String existingDepartment = user.getFirstAttribute(DEPARTMENT_ATTRIBUTE);
        if (existingDepartment == null || existingDepartment.isBlank()) {
            synchronizeDepartment(context, user);
        }
    }

    private void synchronizeDepartment(BrokeredIdentityContext context, UserModel user) {
        Object tokenValue = context.getContextData().get(FEDERATED_ACCESS_TOKEN);
        if (!(tokenValue instanceof String token) || token.isBlank()) {
            LOG.warn("Microsoft access token is unavailable; department was not synchronized");
            return;
        }

        Optional<String> department;
        try {
            department = departments.department(token);
        } catch (Exception exception) {
            LOG.warn("Microsoft Graph department synchronization failed", exception);
            return;
        }
        department
                .filter(value -> !value.isBlank())
                .filter(value -> !value.equals(user.getFirstAttribute(DEPARTMENT_ATTRIBUTE)))
                .ifPresent(value -> user.setSingleAttribute(DEPARTMENT_ATTRIBUTE, value));
    }

    private static Optional<String> fetchDepartment(String token) throws Exception {
        HttpRequest request = HttpRequest.newBuilder()
                .uri(URI.create(GRAPH_API_URL))
                .timeout(Duration.ofSeconds(5))
                .header("Authorization", "Bearer " + token)
                .header("Accept", "application/json")
                .GET()
                .build();
        HttpResponse<String> response = HTTP_CLIENT.send(request, HttpResponse.BodyHandlers.ofString());
        if (response.statusCode() != 200) {
            LOG.warnf("Microsoft Graph department request returned HTTP %d", response.statusCode());
            return Optional.empty();
        }
        JsonNode departmentNode = OBJECT_MAPPER.readTree(response.body()).get(DEPARTMENT_ATTRIBUTE);
        if (departmentNode == null || departmentNode.isNull()) {
            return Optional.empty();
        }
        return Optional.of(departmentNode.asText());
    }
}
