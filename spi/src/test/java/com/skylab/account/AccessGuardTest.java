package com.skylab.account;

import org.junit.jupiter.api.Test;
import org.keycloak.models.UserModel;
import org.keycloak.models.UserSessionModel;
import org.keycloak.representations.AccessToken;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class AccessGuardTest {

    private static final String USER_ID = "11111111-1111-4111-8111-111111111111";
    private static final String SESSION_ID = "session-a";

    @Test
    void admitsAnAccountCenterTokenWithTheAccountAudienceAndManageAccountRole() {
        Fixture fixture = Fixture.valid();

        assertNull(AccessGuard.rejectionReason(fixture.token, fixture.user, fixture.userSession));
    }

    @Test
    void rejectsTokensIssuedToAnotherClient() {
        Fixture fixture = Fixture.valid();
        fixture.token.issuedFor("skyapp");

        assertEquals("azp is not account-center",
                AccessGuard.rejectionReason(fixture.token, fixture.user, fixture.userSession));
    }

    @Test
    void rejectsTokensWithoutTheAccountAudience() {
        Fixture fixture = Fixture.valid();
        fixture.token.audience("core");

        assertEquals("aud lacks account",
                AccessGuard.rejectionReason(fixture.token, fixture.user, fixture.userSession));
    }

    @Test
    void rejectsTokensWithoutTheManageAccountRole() {
        Fixture fixture = Fixture.valid();
        fixture.token.getResourceAccess().clear();
        fixture.token.addAccess("account").addRole("view-profile");

        assertEquals("manage-account role missing",
                AccessGuard.rejectionReason(fixture.token, fixture.user, fixture.userSession));

        fixture.token.getResourceAccess().clear();
        assertEquals("manage-account role missing",
                AccessGuard.rejectionReason(fixture.token, fixture.user, fixture.userSession));
    }

    @Test
    void rejectsTokensWithoutALiveUserSession() {
        Fixture fixture = Fixture.valid();

        assertEquals("no active user session",
                AccessGuard.rejectionReason(fixture.token, fixture.user, null));

        fixture.token.setSessionId("another-session");
        assertEquals("sid does not match the user session",
                AccessGuard.rejectionReason(fixture.token, fixture.user, fixture.userSession));
    }

    @Test
    void rejectsDisabledUsersAndForeignSessions() {
        Fixture fixture = Fixture.valid();
        when(fixture.user.isEnabled()).thenReturn(false);
        assertEquals("user disabled",
                AccessGuard.rejectionReason(fixture.token, fixture.user, fixture.userSession));

        Fixture foreign = Fixture.valid();
        UserModel other = mock(UserModel.class);
        when(other.getId()).thenReturn("someone-else");
        when(foreign.userSession.getUser()).thenReturn(other);
        assertEquals("user session belongs to another user",
                AccessGuard.rejectionReason(foreign.token, foreign.user, foreign.userSession));
    }

    @Test
    void rejectsMissingTokens() {
        Fixture fixture = Fixture.valid();

        assertNotNull(AccessGuard.rejectionReason(null, fixture.user, fixture.userSession));
        assertNotNull(AccessGuard.rejectionReason(fixture.token, null, fixture.userSession));
    }

    private static final class Fixture {
        private final AccessToken token = new AccessToken();
        private final UserModel user = mock(UserModel.class);
        private final UserSessionModel userSession = mock(UserSessionModel.class);

        static Fixture valid() {
            Fixture fixture = new Fixture();
            fixture.token.issuedFor(AccessGuard.ACCOUNT_CENTER_CLIENT_ID);
            fixture.token.audience("account", "core");
            fixture.token.subject(USER_ID);
            fixture.token.setSessionId(SESSION_ID);
            fixture.token.addAccess("account").addRole("manage-account").addRole("view-profile");
            when(fixture.user.getId()).thenReturn(USER_ID);
            when(fixture.user.isEnabled()).thenReturn(true);
            when(fixture.userSession.getId()).thenReturn(SESSION_ID);
            when(fixture.userSession.getUser()).thenReturn(fixture.user);
            return fixture;
        }
    }
}
