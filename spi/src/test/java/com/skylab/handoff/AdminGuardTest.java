package com.skylab.handoff;

import org.junit.jupiter.api.Test;
import org.keycloak.models.GroupModel;
import org.keycloak.models.UserModel;
import org.keycloak.models.UserSessionModel;
import org.keycloak.models.utils.RoleUtils;
import org.keycloak.representations.AccessToken;

import java.util.List;
import java.util.stream.Stream;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class AdminGuardTest {

    private static final String USER_ID = "33333333-3333-4333-8333-333333333333";
    private static final String SESSION_ID = "admin-session";
    private static final String ADMIN_CLIENT = "admin";

    @Test
    void admitsAnAdminGroupMemberWithATokenOfTheAdminClientOnALiveSession() {
        Fixture fixture = Fixture.valid();
        assertNull(fixture.rejection());
    }

    @Test
    void refusesAnAdminGroupMemberWithATokenOfAnyOtherClient() {
        for (String client : new String[] {"account-center", "skyapp", "admin-cli", "Admin", ""}) {
            Fixture fixture = Fixture.valid();
            fixture.token.issuedFor(client);
            assertEquals("token not issued to the admin client", fixture.rejection(), client);
        }
        Fixture noAzp = Fixture.valid();
        noAzp.token.issuedFor(null);
        assertEquals("token not issued to the admin client", noAzp.rejection());
    }

    @Test
    void refusesANonMemberWithATokenOfTheAdminClient() {
        Fixture fixture = Fixture.valid();
        when(fixture.user.isMemberOf(fixture.adminGroup)).thenReturn(false);
        assertEquals("not a member of the admin group", fixture.rejection());
    }

    @Test
    void membershipIsReadFromThePersonNotFromTheTokenClaims() {
        Fixture fixture = Fixture.valid();
        when(fixture.user.isMemberOf(fixture.adminGroup)).thenReturn(false);
        fixture.token.setOtherClaims("groups", List.of("/ADMIN", "ADMIN"));
        fixture.token.setRealmAccess(new AccessToken.Access().addRole("ADMIN"));

        assertEquals("not a member of the admin group", fixture.rejection());
    }

    @Test
    void admitsAMemberOfASubgroupOfTheAdminGroup() {
        // Keycloak's user adapters answer isMemberOf with RoleUtils.isMember, which walks up
        // from each of the person's groups; the guard relies on that, not on direct membership.
        Fixture fixture = Fixture.valid();
        GroupModel subgroup = mock(GroupModel.class);
        when(subgroup.getParent()).thenReturn(fixture.adminGroup);
        when(fixture.user.isMemberOf(fixture.adminGroup))
                .thenAnswer(invocation -> RoleUtils.isMember(Stream.of(subgroup), fixture.adminGroup));
        assertNull(fixture.rejection());

        GroupModel unrelated = mock(GroupModel.class);
        when(fixture.user.isMemberOf(fixture.adminGroup))
                .thenAnswer(invocation -> RoleUtils.isMember(Stream.of(unrelated), fixture.adminGroup));
        assertEquals("not a member of the admin group", fixture.rejection());
    }

    @Test
    void refusesEveryoneWhenTheAdminGroupDoesNotExistInTheRealm() {
        Fixture fixture = Fixture.valid();
        assertEquals("admin group not found in the realm",
                AdminGuard.rejectionReason(fixture.token, fixture.user, fixture.userSession, null, ADMIN_CLIENT));
    }

    @Test
    void requiresALiveOnlineSessionBoundToTheToken() {
        Fixture fixture = Fixture.valid();
        assertEquals("no active user session",
                AdminGuard.rejectionReason(fixture.token, fixture.user, null, fixture.adminGroup, ADMIN_CLIENT));

        when(fixture.userSession.isOffline()).thenReturn(true);
        assertEquals("offline session", fixture.rejection());

        Fixture other = Fixture.valid();
        other.token.setSessionId("another-session");
        assertEquals("sid does not match the user session", other.rejection());

        Fixture serviceAccount = Fixture.valid();
        serviceAccount.token.setSessionId(null);
        assertEquals("sid does not match the user session", serviceAccount.rejection());
    }

    @Test
    void refusesDisabledPeopleForeignSessionsAndMissingTokens() {
        Fixture disabled = Fixture.valid();
        when(disabled.user.isEnabled()).thenReturn(false);
        assertEquals("user disabled", disabled.rejection());

        Fixture foreign = Fixture.valid();
        UserModel other = mock(UserModel.class);
        when(other.getId()).thenReturn("someone-else");
        when(foreign.userSession.getUser()).thenReturn(other);
        assertEquals("user session belongs to another user", foreign.rejection());

        Fixture fixture = Fixture.valid();
        assertNotNull(AdminGuard.rejectionReason(null, fixture.user, fixture.userSession, fixture.adminGroup, ADMIN_CLIENT));
        assertNotNull(AdminGuard.rejectionReason(fixture.token, null, fixture.userSession, fixture.adminGroup, ADMIN_CLIENT));
        assertNotNull(AdminGuard.rejectionReason(fixture.token, fixture.user, fixture.userSession, fixture.adminGroup, null));
    }

    private static final class Fixture {
        private final AccessToken token = new AccessToken();
        private final UserModel user = mock(UserModel.class);
        private final UserSessionModel userSession = mock(UserSessionModel.class);
        private final GroupModel adminGroup = mock(GroupModel.class);

        static Fixture valid() {
            Fixture fixture = new Fixture();
            fixture.token.issuedFor(ADMIN_CLIENT);
            fixture.token.subject(USER_ID);
            fixture.token.setSessionId(SESSION_ID);
            when(fixture.user.getId()).thenReturn(USER_ID);
            when(fixture.user.isEnabled()).thenReturn(true);
            when(fixture.user.isMemberOf(fixture.adminGroup)).thenReturn(true);
            when(fixture.userSession.getId()).thenReturn(SESSION_ID);
            when(fixture.userSession.getUser()).thenReturn(fixture.user);
            return fixture;
        }

        String rejection() {
            return AdminGuard.rejectionReason(token, user, userSession, adminGroup, ADMIN_CLIENT);
        }
    }
}
