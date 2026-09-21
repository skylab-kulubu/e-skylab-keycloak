package com.skylab.account;

import org.junit.jupiter.api.Test;
import org.keycloak.models.KeycloakSession;
import org.keycloak.representations.userprofile.config.UPConfig;
import org.keycloak.userprofile.UserProfileProvider;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class UserProfileGuardTest {

    private final KeycloakSession session = mock(KeycloakSession.class);
    private final UserProfileProvider profiles = mock(UserProfileProvider.class);

    UserProfileGuardTest() {
        when(session.getProvider(UserProfileProvider.class)).thenReturn(profiles);
    }

    @Test
    void allowsMutationsWhilePeopleCannotEditUnmanagedAttributes() {
        for (UPConfig.UnmanagedAttributePolicy policy : new UPConfig.UnmanagedAttributePolicy[] {
                null, UPConfig.UnmanagedAttributePolicy.ADMIN_VIEW, UPConfig.UnmanagedAttributePolicy.ADMIN_EDIT}) {
            UPConfig config = new UPConfig();
            config.setUnmanagedAttributePolicy(policy);
            when(profiles.getConfiguration()).thenReturn(config);

            UserProfileGuard.requireManagedAttributes(session);
        }
    }

    @Test
    void refusesMutationsWith503WhenPeopleCanEditUnmanagedAttributes() {
        UPConfig config = new UPConfig();
        config.setUnmanagedAttributePolicy(UPConfig.UnmanagedAttributePolicy.ENABLED);
        when(profiles.getConfiguration()).thenReturn(config);

        ProblemException exception = assertThrows(ProblemException.class,
                () -> UserProfileGuard.requireManagedAttributes(session));

        assertEquals(503, exception.problem().status());
        assertEquals("unmanaged_attributes_enabled", exception.problem().code());
    }

    @Test
    void failsClosedWhenTheConfigurationCannotBeRead() {
        when(profiles.getConfiguration()).thenReturn(null);
        assertEquals("unmanaged_attributes_enabled", assertThrows(ProblemException.class,
                () -> UserProfileGuard.requireManagedAttributes(session)).problem().code());

        when(session.getProvider(UserProfileProvider.class)).thenReturn(null);
        assertEquals(503, assertThrows(ProblemException.class,
                () -> UserProfileGuard.requireManagedAttributes(session)).problem().status());
    }
}
