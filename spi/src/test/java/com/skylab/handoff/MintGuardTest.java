package com.skylab.handoff;

import org.junit.jupiter.api.Test;
import org.keycloak.models.UserModel;
import org.keycloak.models.UserSessionModel;
import org.keycloak.representations.AccessToken;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class MintGuardTest {

    private static final String USER_ID = "11111111-1111-4111-8111-111111111111";
    private static final String SESSION_ID = "offline-session-a";

    @Test
    void admitsASkyappTokenBoundToItsLiveOrOfflineSession() {
        Fixture online = Fixture.valid();
        assertNull(MintGuard.rejectionReason(online.token, online.user, online.userSession));

        Fixture offline = Fixture.valid();
        when(offline.userSession.isOffline()).thenReturn(true);
        assertNull(MintGuard.rejectionReason(offline.token, offline.user, offline.userSession),
                "SkyApp signs in with offline_access; its offline session is a live source session");
    }

    @Test
    void refusesTokensOfAnyOtherClient() {
        Fixture fixture = Fixture.valid();
        fixture.token.issuedFor("account-center");
        assertEquals("azp is not skyapp", MintGuard.rejectionReason(fixture.token, fixture.user, fixture.userSession));

        fixture.token.issuedFor(null);
        assertEquals("azp is not skyapp", MintGuard.rejectionReason(fixture.token, fixture.user, fixture.userSession));
    }

    @Test
    void refusesTokensWithoutAMatchingSession() {
        Fixture fixture = Fixture.valid();
        assertEquals("no active user session", MintGuard.rejectionReason(fixture.token, fixture.user, null));

        fixture.token.setSessionId(null);
        assertEquals("sid does not match the user session",
                MintGuard.rejectionReason(fixture.token, fixture.user, fixture.userSession));

        fixture.token.setSessionId("another-session");
        assertEquals("sid does not match the user session",
                MintGuard.rejectionReason(fixture.token, fixture.user, fixture.userSession));
    }

    @Test
    void refusesDisabledPeopleForeignSessionsAndMissingTokens() {
        Fixture disabled = Fixture.valid();
        when(disabled.user.isEnabled()).thenReturn(false);
        assertEquals("user disabled", MintGuard.rejectionReason(disabled.token, disabled.user, disabled.userSession));

        Fixture foreign = Fixture.valid();
        UserModel other = mock(UserModel.class);
        when(other.getId()).thenReturn("someone-else");
        when(foreign.userSession.getUser()).thenReturn(other);
        assertEquals("user session belongs to another user",
                MintGuard.rejectionReason(foreign.token, foreign.user, foreign.userSession));

        Fixture fixture = Fixture.valid();
        assertNotNull(MintGuard.rejectionReason(null, fixture.user, fixture.userSession));
        assertNotNull(MintGuard.rejectionReason(fixture.token, null, fixture.userSession));
    }

    @Test
    void theOriginalAuthenticationTimeComesFromTheSourceSession() {
        Fixture fixture = Fixture.valid();
        when(fixture.userSession.getNote("AUTH_TIME")).thenReturn("1780000000");
        when(fixture.userSession.getStarted()).thenReturn(1_780_000_500);
        fixture.token.setAuth_time(1_780_000_100L);
        assertEquals(1_780_000_000L, MintGuard.originalAuthTime(fixture.userSession, fixture.token),
                "the session note is what Keycloak itself writes into auth_time");

        when(fixture.userSession.getNote("AUTH_TIME")).thenReturn(null);
        assertEquals(1_780_000_100L, MintGuard.originalAuthTime(fixture.userSession, fixture.token),
                "without the note, the verified token's auth_time");

        when(fixture.userSession.getNote("AUTH_TIME")).thenReturn("not-a-number");
        fixture.token.setAuth_time(null);
        assertEquals(1_780_000_500L, MintGuard.originalAuthTime(fixture.userSession, fixture.token),
                "without either, the session start: never a fresher time than the real one");
    }

    private static final class Fixture {
        private final AccessToken token = new AccessToken();
        private final UserModel user = mock(UserModel.class);
        private final UserSessionModel userSession = mock(UserSessionModel.class);

        static Fixture valid() {
            Fixture fixture = new Fixture();
            fixture.token.issuedFor("skyapp");
            fixture.token.subject(USER_ID);
            fixture.token.setSessionId(SESSION_ID);
            when(fixture.user.getId()).thenReturn(USER_ID);
            when(fixture.user.isEnabled()).thenReturn(true);
            when(fixture.userSession.getId()).thenReturn(SESSION_ID);
            when(fixture.userSession.getUser()).thenReturn(fixture.user);
            return fixture;
        }
    }
}
