package com.skylab.mapper;

import org.junit.jupiter.api.Test;
import org.keycloak.broker.provider.BrokeredIdentityContext;
import org.keycloak.broker.provider.IdentityProviderMapperSyncModeDelegate;
import org.keycloak.models.IdentityProviderMapperModel;
import org.keycloak.models.IdentityProviderMapperSyncMode;
import org.keycloak.models.IdentityProviderModel;
import org.keycloak.models.IdentityProviderSyncMode;
import org.keycloak.models.UserModel;

import java.io.IOException;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.atomic.AtomicInteger;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class MicrosoftMapperTest {

    private static final String TOKEN = "microsoft-access-token";

    @Test
    void forceRefreshesAStoredDepartmentOnEveryLogin() {
        MicrosoftMapper mapper = new MicrosoftMapper(token -> Optional.of("Bilgisayar Mühendisliği"));
        Map<String, String> attributes = new HashMap<>(Map.of("department", "Elektrik Mühendisliği"));

        login(mapper, IdentityProviderMapperSyncMode.FORCE, user(attributes), TOKEN);

        assertEquals("Bilgisayar Mühendisliği", attributes.get("department"));
    }

    @Test
    void inheritFromTheLegacyProviderOnlyFillsAnEmptyDepartment() {
        MicrosoftMapper mapper = new MicrosoftMapper(token -> Optional.of("Bilgisayar Mühendisliği"));
        Map<String, String> stored = new HashMap<>(Map.of("department", "Elektrik Mühendisliği"));
        Map<String, String> empty = new HashMap<>();

        login(mapper, IdentityProviderMapperSyncMode.INHERIT, user(stored), TOKEN);
        login(mapper, IdentityProviderMapperSyncMode.INHERIT, user(empty), TOKEN);

        assertEquals("Elektrik Mühendisliği", stored.get("department"));
        assertEquals("Bilgisayar Mühendisliği", empty.get("department"));
    }

    @Test
    void importNewUserStoresTheGraphDepartment() {
        MicrosoftMapper mapper = new MicrosoftMapper(token -> Optional.of("Matematik"));
        Map<String, String> attributes = new HashMap<>();

        mapper.importNewUser(null, null, user(attributes), mapperModel(IdentityProviderMapperSyncMode.FORCE),
                context(IdentityProviderSyncMode.LEGACY, TOKEN));

        assertEquals("Matematik", attributes.get("department"));
    }

    @Test
    void anUnchangedDepartmentIsNotRewritten() {
        MicrosoftMapper mapper = new MicrosoftMapper(token -> Optional.of("Matematik"));
        UserModel user = user(new HashMap<>(Map.of("department", "Matematik")));

        login(mapper, IdentityProviderMapperSyncMode.FORCE, user, TOKEN);

        verify(user, never()).setSingleAttribute(anyString(), anyString());
    }

    @Test
    void aFailedEmptyOrUnauthenticatedLookupKeepsTheStoredDepartment() {
        List<MicrosoftMapper.DepartmentSource> sources = List.of(
                token -> {
                    throw new IOException("Graph is unreachable");
                },
                token -> Optional.empty(),
                token -> Optional.of("  "));
        for (MicrosoftMapper.DepartmentSource source : sources) {
            Map<String, String> attributes = new HashMap<>(Map.of("department", "Fizik"));
            login(new MicrosoftMapper(source), IdentityProviderMapperSyncMode.FORCE, user(attributes), TOKEN);
            assertEquals("Fizik", attributes.get("department"));
        }

        AtomicInteger calls = new AtomicInteger();
        Map<String, String> attributes = new HashMap<>(Map.of("department", "Fizik"));
        login(new MicrosoftMapper(token -> {
            calls.incrementAndGet();
            return Optional.of("Kimya");
        }), IdentityProviderMapperSyncMode.FORCE, user(attributes), null);
        assertEquals(0, calls.get());
        assertEquals("Fizik", attributes.get("department"));
    }

    @Test
    void declaresForceSoKeycloakDoesNotWarnOnEveryLogin() {
        MicrosoftMapper mapper = new MicrosoftMapper();

        assertTrue(mapper.supportsSyncMode(IdentityProviderSyncMode.FORCE));
        assertTrue(mapper.supportsSyncMode(IdentityProviderSyncMode.LEGACY));
        assertTrue(mapper.supportsSyncMode(IdentityProviderSyncMode.IMPORT));
        assertEquals(MicrosoftMapper.PROVIDER_ID, mapper.getId());
    }

    @Test
    void importSyncModeNeverTouchesAnExistingUser() {
        AtomicInteger calls = new AtomicInteger();
        MicrosoftMapper mapper = new MicrosoftMapper(token -> {
            calls.incrementAndGet();
            return Optional.of("Kimya");
        });
        Map<String, String> attributes = new HashMap<>();

        login(mapper, IdentityProviderMapperSyncMode.IMPORT, user(attributes), TOKEN);

        assertEquals(0, calls.get());
        assertNull(attributes.get("department"));
        assertFalse(attributes.containsKey("department"));
    }

    /** A returning login, dispatched by Keycloak's own sync mode delegate for an IdP in LEGACY. */
    private static void login(MicrosoftMapper mapper, IdentityProviderMapperSyncMode mapperSyncMode,
                              UserModel user, String token) {
        IdentityProviderMapperSyncModeDelegate.delegateUpdateBrokeredUser(
                null, null, user, mapperModel(mapperSyncMode), context(IdentityProviderSyncMode.LEGACY, token), mapper);
    }

    private static IdentityProviderMapperModel mapperModel(IdentityProviderMapperSyncMode syncMode) {
        IdentityProviderMapperModel model = new IdentityProviderMapperModel();
        model.setName("department mapper");
        model.setIdentityProviderAlias("OBS");
        model.setIdentityProviderMapper(MicrosoftMapper.PROVIDER_ID);
        model.setConfig(new HashMap<>());
        model.setSyncMode(syncMode);
        return model;
    }

    private static BrokeredIdentityContext context(IdentityProviderSyncMode providerSyncMode, String token) {
        IdentityProviderModel provider = new IdentityProviderModel();
        provider.setAlias("OBS");
        provider.setProviderId("microsoft");
        provider.setEnabled(true);
        provider.setSyncMode(providerSyncMode);
        BrokeredIdentityContext context = new BrokeredIdentityContext("microsoft-object-id", provider);
        if (token != null) {
            context.getContextData().put(MicrosoftMapper.FEDERATED_ACCESS_TOKEN, token);
        }
        return context;
    }

    private static UserModel user(Map<String, String> attributes) {
        UserModel user = mock(UserModel.class);
        when(user.getFirstAttribute("department")).thenAnswer(invocation -> attributes.get("department"));
        doAnswer(invocation -> {
            attributes.put(invocation.getArgument(0), invocation.getArgument(1));
            return null;
        }).when(user).setSingleAttribute(anyString(), anyString());
        return user;
    }
}
