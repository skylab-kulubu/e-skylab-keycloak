package com.skylab.account;

import com.webauthn4j.converter.util.ObjectConverter;
import org.keycloak.authentication.authenticators.browser.WebAuthnMetadataService;
import org.keycloak.common.util.Time;
import org.keycloak.credential.CredentialInput;
import org.keycloak.credential.CredentialModel;
import org.keycloak.credential.CredentialProvider;
import org.keycloak.credential.WebAuthnPasswordlessCredentialProvider;
import org.keycloak.credential.WebAuthnPasswordlessCredentialProviderFactory;
import org.keycloak.models.ClientModel;
import org.keycloak.models.KeycloakContext;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakUriInfo;
import org.keycloak.models.ModelDuplicateException;
import org.keycloak.models.RealmModel;
import org.keycloak.models.SingleUseObjectProvider;
import org.keycloak.models.SubjectCredentialManager;
import org.keycloak.models.UserModel;
import org.keycloak.models.UserSessionModel;
import org.keycloak.models.WebAuthnPolicy;
import org.keycloak.representations.AccessToken;

import java.net.URI;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * A Keycloak session for passkey tests: the real {@link WebAuthnPasswordlessCredentialProvider}
 * over an in-memory credential store (with the JPA store's duplicate-label rule), a realm whose
 * passwordless policy allows one extra origin, and a single-use object store kept in memory.
 */
final class PasskeyFixture {

    static final String USER_ID = "11111111-1111-4111-8111-111111111111";
    static final String SESSION_ID = "session-a";
    static final String KEYCLOAK_ORIGIN = "http://localhost:18080";
    static final String EXTRA_ORIGIN = "http://localhost:18081";
    static final String OTHER_ORIGIN = "http://localhost:18082";

    final KeycloakSession session = mock(KeycloakSession.class);
    final KeycloakContext context = mock(KeycloakContext.class);
    final RealmModel realm = mock(RealmModel.class);
    final KeycloakUriInfo uriInfo = mock(KeycloakUriInfo.class);
    final WebAuthnPolicy policy = new WebAuthnPolicy(new ArrayList<>(List.of("ES256", "RS256")));
    final MemoryStore store = new MemoryStore();
    final List<CredentialModel> credentials = new ArrayList<>();
    final UserModel user = mock(UserModel.class);
    final SubjectCredentialManager credentialManager = mock(SubjectCredentialManager.class);
    final WebAuthnPasswordlessCredentialProvider provider;
    final Caller caller;

    PasskeyFixture() {
        when(session.getContext()).thenReturn(context);
        when(context.getRealm()).thenReturn(realm);
        when(context.getUri()).thenReturn(uriInfo);
        when(uriInfo.getBaseUri()).thenReturn(URI.create(KEYCLOAK_ORIGIN + "/"));
        when(realm.getName()).thenReturn("e-skylab-test");
        when(realm.getWebAuthnPolicyPasswordless()).thenReturn(policy);
        policy.setRpEntityName("SKY LAB");
        policy.setRpId("");
        policy.setResidentKey("required");
        policy.setRequireResidentKey("not specified");
        policy.setUserVerificationRequirement("required");
        policy.setAttestationConveyancePreference("not specified");
        policy.setAuthenticatorAttachment("not specified");
        policy.setCreateTimeout(0);
        policy.setAvoidSameAuthenticatorRegister(false);
        policy.setAcceptableAaguids(List.of());
        policy.setExtraOrigins(List.of(EXTRA_ORIGIN));
        when(session.singleUseObjects()).thenReturn(store);

        provider = new WebAuthnPasswordlessCredentialProvider(session, new WebAuthnMetadataService(), new ObjectConverter());
        when(session.getProvider(CredentialProvider.class, WebAuthnPasswordlessCredentialProviderFactory.PROVIDER_ID))
                .thenReturn(provider);

        when(user.getId()).thenReturn(USER_ID);
        when(user.getUsername()).thenReturn("account-fixture");
        when(user.getFirstName()).thenReturn("Ada");
        when(user.getLastName()).thenReturn("Lovelace");
        when(user.credentialManager()).thenReturn(credentialManager);
        when(credentialManager.getStoredCredentialsStream()).thenAnswer(invocation -> new ArrayList<>(credentials).stream());
        when(credentialManager.getStoredCredentialsByTypeStream(anyString())).thenAnswer(invocation -> {
            String type = invocation.getArgument(0);
            return new ArrayList<>(credentials).stream().filter(credential -> type.equals(credential.getType()));
        });
        when(credentialManager.getStoredCredentialById(anyString())).thenAnswer(invocation -> {
            String id = invocation.getArgument(0);
            return credentials.stream().filter(credential -> id.equals(credential.getId())).findFirst().orElse(null);
        });
        when(credentialManager.getStoredCredentialByNameAndType(anyString(), anyString())).thenAnswer(invocation -> {
            String name = invocation.getArgument(0);
            String type = invocation.getArgument(1);
            return credentials.stream()
                    .filter(credential -> type.equals(credential.getType()) && name.equals(credential.getUserLabel()))
                    .findFirst().orElse(null);
        });
        when(credentialManager.createStoredCredential(any(CredentialModel.class))).thenAnswer(invocation -> {
            CredentialModel model = invocation.getArgument(0);
            boolean duplicate = model.getUserLabel() != null && credentials.stream().anyMatch(existing ->
                    existing.getUserLabel() != null
                            && existing.getUserLabel().equalsIgnoreCase(model.getUserLabel().trim())
                            && existing.getType().equals(model.getType()));
            if (duplicate) {
                throw new ModelDuplicateException("Device already exists with the same name", CredentialModel.USER_LABEL);
            }
            if (model.getId() == null) {
                model.setId(UUID.randomUUID().toString());
            }
            if (model.getCreatedDate() == null) {
                model.setCreatedDate(Time.currentTimeMillis());
            }
            credentials.add(model);
            return model;
        });
        doAnswer(invocation -> {
            CredentialModel updated = invocation.getArgument(0);
            credentials.replaceAll(existing -> existing.getId().equals(updated.getId()) ? updated : existing);
            return null;
        }).when(credentialManager).updateStoredCredential(any(CredentialModel.class));
        when(credentialManager.isValid(any(CredentialInput.class)))
                .thenAnswer(invocation -> provider.isValid(realm, user, invocation.getArgument(0)));

        UserSessionModel userSession = mock(UserSessionModel.class);
        when(userSession.getId()).thenReturn(SESSION_ID);
        AccessToken bearer = new AccessToken();
        bearer.issuer(KEYCLOAK_ORIGIN + "/realms/e-skylab-test");
        caller = new Caller(user, userSession, bearer, mock(ClientModel.class));
    }

    Passkeys passkeys() {
        return new Passkeys(session);
    }

    /** The one passkey credential stored, read back as Keycloak would from the database. */
    CredentialModel onlyPasskey() {
        List<CredentialModel> passkeys = credentials.stream()
                .filter(credential -> Passkeys.CREDENTIAL_TYPE.equals(credential.getType())).toList();
        if (passkeys.size() != 1) {
            throw new AssertionError("expected exactly one passkey, found " + passkeys.size());
        }
        return passkeys.get(0);
    }

    /** In-memory single-use objects: put/remove/putIfAbsent with recorded lifespans. */
    static final class MemoryStore implements SingleUseObjectProvider {
        private final Map<String, Map<String, String>> entries = new ConcurrentHashMap<>();
        private final Map<String, Long> lifespans = new ConcurrentHashMap<>();

        Map<String, String> peek(String key) {
            return entries.get(key);
        }

        Long lifespan(String key) {
            return lifespans.get(key);
        }

        @Override
        public void put(String key, long lifespanSeconds, Map<String, String> notes) {
            if (lifespanSeconds <= 0) {
                throw new IllegalArgumentException("lifespan must be positive");
            }
            entries.put(key, Map.copyOf(notes));
            lifespans.put(key, lifespanSeconds);
        }

        @Override
        public Map<String, String> get(String key) {
            return entries.get(key);
        }

        @Override
        public Map<String, String> remove(String key) {
            lifespans.remove(key);
            return entries.remove(key);
        }

        @Override
        public boolean replace(String key, Map<String, String> notes) {
            return entries.replace(key, Map.copyOf(notes)) != null;
        }

        @Override
        public boolean putIfAbsent(String key, long lifespanInSeconds) {
            return entries.putIfAbsent(key, Map.of()) == null;
        }

        @Override
        public boolean contains(String key) {
            return entries.containsKey(key);
        }

        @Override
        public void close() {
            // no-op
        }
    }
}
