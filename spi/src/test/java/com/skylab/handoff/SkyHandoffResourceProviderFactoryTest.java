package com.skylab.handoff;

import org.junit.jupiter.api.Test;

import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

class SkyHandoffResourceProviderFactoryTest {

    @Test
    void theSuperAdminRoleDefaultsToKeycloaksRealmAdministratorAndIsConfigurable() {
        assertEquals("realm-management.realm-admin", SkyHandoffResourceProviderFactory.resolveAdminRole(null, Map.of()));
        assertEquals("realm-management.realm-admin", SkyHandoffResourceProviderFactory.resolveAdminRole(" ", Map.of()));
        assertEquals("sky-super-admin", SkyHandoffResourceProviderFactory.resolveAdminRole(
                null, Map.of(SkyHandoffResourceProviderFactory.ADMIN_ROLE_ENV, " sky-super-admin ")));
        assertEquals("superadmin.handoff-admin", SkyHandoffResourceProviderFactory.resolveAdminRole(
                "superadmin.handoff-admin", Map.of(SkyHandoffResourceProviderFactory.ADMIN_ROLE_ENV, "ignored")));
        assertThrows(IllegalStateException.class,
                () -> SkyHandoffResourceProviderFactory.resolveAdminRole("role\nwith-newline", Map.of()));
        assertThrows(IllegalStateException.class,
                () -> SkyHandoffResourceProviderFactory.resolveAdminRole("r".repeat(300), Map.of()));
    }
}
