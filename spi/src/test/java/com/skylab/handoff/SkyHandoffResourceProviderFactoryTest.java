package com.skylab.handoff;

import org.junit.jupiter.api.Test;

import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class SkyHandoffResourceProviderFactoryTest {

    @Test
    void theAdminGroupDefaultsToSlashAdminAndIsConfigurable() {
        assertEquals("/ADMIN", SkyHandoffResourceProviderFactory.resolveAdminGroup(null, Map.of()));
        assertEquals("/ADMIN", SkyHandoffResourceProviderFactory.resolveAdminGroup(" ", Map.of()));
        assertEquals("/YK/web", SkyHandoffResourceProviderFactory.resolveAdminGroup(
                null, Map.of(SkyHandoffResourceProviderFactory.ADMIN_GROUP_ENV, " /YK/web ")));
        assertEquals("/Handoff", SkyHandoffResourceProviderFactory.resolveAdminGroup(
                "/Handoff", Map.of(SkyHandoffResourceProviderFactory.ADMIN_GROUP_ENV, "/ignored")));
        assertEquals("/ADMIN", SkyHandoffResourceProviderFactory.resolveAdminGroup("ADMIN/", Map.of()),
                "a group path gets its leading slash and loses a trailing one");
        assertThrows(IllegalStateException.class,
                () -> SkyHandoffResourceProviderFactory.resolveAdminGroup("/", Map.of()));
        assertThrows(IllegalStateException.class,
                () -> SkyHandoffResourceProviderFactory.resolveAdminGroup("/ADMIN\nX", Map.of()));
        assertThrows(IllegalStateException.class,
                () -> SkyHandoffResourceProviderFactory.resolveAdminGroup("/" + "g".repeat(1100), Map.of()));
    }

    @Test
    void theAdminClientDefaultsToSuperadminsClientAndIsConfigurable() {
        assertEquals("admin", SkyHandoffResourceProviderFactory.resolveAdminClient(null, Map.of()));
        assertEquals("admin", SkyHandoffResourceProviderFactory.resolveAdminClient(" ", Map.of()));
        assertEquals("superadmin", SkyHandoffResourceProviderFactory.resolveAdminClient(
                null, Map.of(SkyHandoffResourceProviderFactory.ADMIN_CLIENT_ENV, " superadmin ")));
        assertEquals("panel", SkyHandoffResourceProviderFactory.resolveAdminClient(
                "panel", Map.of(SkyHandoffResourceProviderFactory.ADMIN_CLIENT_ENV, "ignored")));
        assertThrows(IllegalStateException.class,
                () -> SkyHandoffResourceProviderFactory.resolveAdminClient("admin\nx", Map.of()));
        assertThrows(IllegalStateException.class,
                () -> SkyHandoffResourceProviderFactory.resolveAdminClient("c".repeat(300), Map.of()));
    }

    @Test
    void aMissingAdminGroupIsReportedOncePerDisappearanceAndRealm() {
        AdminAccess access = new AdminAccess("/ADMIN", "admin");
        assertFalse(access.warnOfMissingGroup("realm-a", true));
        assertTrue(access.warnOfMissingGroup("realm-a", false), "the first miss is reported");
        assertFalse(access.warnOfMissingGroup("realm-a", false), "later misses are not");
        assertTrue(access.warnOfMissingGroup("realm-b", false), "each realm is reported on its own");
        assertFalse(access.warnOfMissingGroup("realm-a", true));
        assertTrue(access.warnOfMissingGroup("realm-a", false), "a group that disappears again is reported again");
    }
}
