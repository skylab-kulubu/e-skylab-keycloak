package com.skylab.account;

import org.junit.jupiter.api.Test;
import org.keycloak.models.KeycloakContext;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.ThemeManager;
import org.keycloak.theme.Theme;

import java.io.IOException;
import java.util.Properties;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class PolicyMessagesTest {

    private final KeycloakSession session = mock(KeycloakSession.class);
    private final KeycloakContext context = mock(KeycloakContext.class);
    private final RealmModel realm = mock(RealmModel.class);
    private final ThemeManager themes = mock(ThemeManager.class);
    private final Theme theme = mock(Theme.class);

    PolicyMessagesTest() throws IOException {
        when(session.getContext()).thenReturn(context);
        when(context.getRealm()).thenReturn(realm);
        when(session.theme()).thenReturn(themes);
        when(themes.getTheme(Theme.Type.LOGIN)).thenReturn(theme);
        Properties messages = new Properties();
        messages.setProperty("invalidPasswordMinLengthMessage", "Geçersiz parola: en az {0} karakter olmalı.");
        messages.setProperty("invalidPasswordNotUsernameMessage", "Parola kullanıcı adı ile aynı olamaz.");
        when(theme.getEnhancedMessages(eq(realm), any())).thenReturn(messages);
    }

    @Test
    void rendersTheLoginThemeMessageWithItsParameters() {
        assertEquals("Geçersiz parola: en az 12 karakter olmalı.",
                new PolicyMessages(session).render("invalidPasswordMinLengthMessage", new Object[] {12}));
        assertEquals("Parola kullanıcı adı ile aynı olamaz.",
                new PolicyMessages(session).render("invalidPasswordNotUsernameMessage", null));
    }

    @Test
    void fallsBackToAGenericTurkishSentence() throws IOException {
        assertEquals(PolicyMessages.GENERIC_DETAIL,
                new PolicyMessages(session).render("unknownPolicyKey", new Object[0]));
        assertEquals(PolicyMessages.GENERIC_DETAIL, new PolicyMessages(session).render(null, null));

        when(themes.getTheme(Theme.Type.LOGIN)).thenThrow(new IOException("theme missing"));
        assertEquals(PolicyMessages.GENERIC_DETAIL,
                new PolicyMessages(session).render("invalidPasswordMinLengthMessage", new Object[] {12}));
    }
}
