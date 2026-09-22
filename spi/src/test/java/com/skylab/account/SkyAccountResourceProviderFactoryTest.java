package com.skylab.account;

import org.junit.jupiter.api.Test;

import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

class SkyAccountResourceProviderFactoryTest {

    @Test
    void ytuIdpAliasDefaultsToObsAndAcceptsConfigOrEnvironment() {
        assertEquals("OBS", SkyAccountResourceProviderFactory.resolveYtuIdpAlias(null, Map.of()));
        assertEquals("OBS", SkyAccountResourceProviderFactory.resolveYtuIdpAlias(" ", Map.of()));
        assertEquals("microsoft", SkyAccountResourceProviderFactory.resolveYtuIdpAlias(
                null, Map.of(SkyAccountResourceProviderFactory.YTU_IDP_ALIAS_ENV, "microsoft")));
        assertEquals("configured", SkyAccountResourceProviderFactory.resolveYtuIdpAlias(
                "configured", Map.of(SkyAccountResourceProviderFactory.YTU_IDP_ALIAS_ENV, "microsoft")));
        assertThrows(IllegalStateException.class,
                () -> SkyAccountResourceProviderFactory.resolveYtuIdpAlias("bad alias", Map.of()));
    }
}
