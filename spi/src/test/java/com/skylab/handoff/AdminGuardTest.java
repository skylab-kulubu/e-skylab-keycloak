package com.skylab.handoff;

import org.junit.jupiter.api.Test;
import org.keycloak.models.RoleModel;
import org.keycloak.models.UserModel;
import org.keycloak.models.UserSessionModel;
import org.keycloak.representations.AccessToken;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class AdminGuardTest {

    private static final String USER_ID = "33333333-3333-4333-8333-333333333333";
    private static final String SESSION_ID = "admin-session";

    @Test
    void admitsAPersonHoldingTheSuperAdminRoleWithALiveSessionFromAnyClient() {
        Fixture fixture = Fixture.valid();
        assertNull(AdminGuard.rejectionReason(fixture.token, fixture.user, fixture.userSession, fixture.role));

        fixture.token.issuedFor("any-client");
        assertNull(AdminGuard.rejectionReason(fixture.token, fixture.user, fixture.userSession, fixture.role),
                "the role is checked on the person, whichever client the token came from");
    }

    @Test
    void theRoleIsReadFromThePersonNotFromTheTokenClaims() {
        Fixture fixture = Fixture.valid();
        when(fixture.user.hasRole(fixture.role)).thenReturn(false);
        fixture.token.setRealmAccess(new AccessToken.Access().addRole("realm-admin"));
        fixture.token.addAccess("realm-management").addRole("realm-admin");

        assertEquals("not a super admin",
                AdminGuard.rejectionReason(fixture.token, fixture.user, fixture.userSession, fixture.role));
    }

    @Test
    void refusesWhenTheConfiguredRoleDoesNotExistInTheRealm() {
        Fixture fixture = Fixture.valid();
        assertEquals("super-admin role not found in the realm",
                AdminGuard.rejectionReason(fixture.token, fixture.user, fixture.userSession, null));
    }

    @Test
    void requiresALiveOnlineSessionBoundToTheToken() {
        Fixture fixture = Fixture.valid();
        assertEquals("no active user session",
                AdminGuard.rejectionReason(fixture.token, fixture.user, null, fixture.role));

        when(fixture.userSession.isOffline()).thenReturn(true);
        assertEquals("offline session",
                AdminGuard.rejectionReason(fixture.token, fixture.user, fixture.userSession, fixture.role));

        Fixture other = Fixture.valid();
        other.token.setSessionId("another-session");
        assertEquals("sid does not match the user session",
                AdminGuard.rejectionReason(other.token, other.user, other.userSession, other.role));

        Fixture serviceAccount = Fixture.valid();
        serviceAccount.token.setSessionId(null);
        assertEquals("sid does not match the user session",
                AdminGuard.rejectionReason(serviceAccount.token, serviceAccount.user, serviceAccount.userSession,
                        serviceAccount.role));
    }

    @Test
    void refusesDisabledPeopleForeignSessionsAndMissingTokens() {
        Fixture disabled = Fixture.valid();
        when(disabled.user.isEnabled()).thenReturn(false);
        assertEquals("user disabled",
                AdminGuard.rejectionReason(disabled.token, disabled.user, disabled.userSession, disabled.role));

        Fixture foreign = Fixture.valid();
        UserModel other = mock(UserModel.class);
        when(other.getId()).thenReturn("someone-else");
        when(foreign.userSession.getUser()).thenReturn(other);
        assertEquals("user session belongs to another user",
                AdminGuard.rejectionReason(foreign.token, foreign.user, foreign.userSession, foreign.role));

        Fixture fixture = Fixture.valid();
        assertNotNull(AdminGuard.rejectionReason(null, fixture.user, fixture.userSession, fixture.role));
        assertNotNull(AdminGuard.rejectionReason(fixture.token, null, fixture.userSession, fixture.role));
    }

    private static final class Fixture {
        private final AccessToken token = new AccessToken();
        private final UserModel user = mock(UserModel.class);
        private final UserSessionModel userSession = mock(UserSessionModel.class);
        private final RoleModel role = mock(RoleModel.class);

        static Fixture valid() {
            Fixture fixture = new Fixture();
            fixture.token.issuedFor("superadmin");
            fixture.token.subject(USER_ID);
            fixture.token.setSessionId(SESSION_ID);
            when(fixture.user.getId()).thenReturn(USER_ID);
            when(fixture.user.isEnabled()).thenReturn(true);
            when(fixture.user.hasRole(fixture.role)).thenReturn(true);
            when(fixture.userSession.getId()).thenReturn(SESSION_ID);
            when(fixture.userSession.getUser()).thenReturn(fixture.user);
            return fixture;
        }
    }
}
