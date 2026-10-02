package com.skylab.authenticator;

import com.skylab.account.LoginIdentifiers;
import jakarta.ws.rs.core.MultivaluedHashMap;
import jakarta.ws.rs.core.MultivaluedMap;
import jakarta.ws.rs.core.UriInfo;
import org.junit.jupiter.api.Test;
import org.keycloak.authentication.AuthenticationFlowContext;
import org.keycloak.authentication.AuthenticationFlowError;
import org.keycloak.authentication.Authenticator;
import org.keycloak.authentication.FlowStatus;
import org.keycloak.authentication.authenticators.browser.AbstractUsernameFormAuthenticator;
import org.keycloak.common.ClientConnection;
import org.keycloak.events.Details;
import org.keycloak.events.EventBuilder;
import org.keycloak.http.HttpRequest;
import org.keycloak.models.AuthenticationExecutionModel;
import org.keycloak.models.KeycloakContext;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;
import org.keycloak.models.UserProvider;
import org.keycloak.services.managers.BruteForceProtector;
import org.keycloak.sessions.AuthenticationSessionModel;

import java.util.ArrayList;
import java.util.List;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class SkyUsernamePasswordFormTest {

    private static final String ATTEMPTED = AbstractUsernameFormAuthenticator.ATTEMPTED_USERNAME;

    @Test
    void keycloaksOwnRoutesReachTheStockFormUntouched() {
        Fixture fixture = new Fixture(new LoginIdentifiers.Person(user("ada"), true));
        MultivaluedMap<String, String> form = form("ada@example.com", "secret");

        assertTrue(fixture.validate(form));

        assertEquals(1, fixture.stockCalls.size());
        assertSame(form, fixture.stockCalls.get(0));
        verify(fixture.authSession, never()).setAuthNote(any(), any());
        assertEquals(0, fixture.failuresRecorded);
    }

    @Test
    void nobodyReachesTheStockFormSoATypoIsKeycloaksOwnAnswer() {
        Fixture fixture = new Fixture(new LoginIdentifiers.Nobody());
        MultivaluedMap<String, String> form = form("typo@example.com", "secret");
        fixture.stockResult = false;

        assertFalse(fixture.validate(form));

        assertSame(form, fixture.stockCalls.get(0));
        assertEquals(0, fixture.refusals);
    }

    @Test
    void anAddressSignsInWithTheUsernameAndTheTypedAddressStaysTheAttemptedUsername() {
        UserModel ada = user("ada");
        Fixture fixture = new Fixture(new LoginIdentifiers.Person(ada, false));
        MultivaluedMap<String, String> form = form(" Ada@Gmail.com ", "secret");
        form.putSingle("rememberMe", "on");

        assertTrue(fixture.validate(form));

        MultivaluedMap<String, String> sent = fixture.stockCalls.get(0);
        assertEquals("ada", sent.getFirst("username"));
        assertEquals("secret", sent.getFirst("password"));
        assertEquals("on", sent.getFirst("rememberMe"));
        assertEquals(" Ada@Gmail.com ", form.getFirst("username"), "the request's own form data is not rewritten");
        verify(fixture.authSession).setAuthNote(ATTEMPTED, "Ada@Gmail.com");
        verify(fixture.event).detail(Details.USERNAME, "Ada@Gmail.com");
        assertEquals(0, fixture.failuresRecorded);
    }

    @Test
    void aWrongPasswordForAnAddressIsCountedOnceForThePerson() {
        Fixture fixture = new Fixture(new LoginIdentifiers.Person(user("ada"), false));
        fixture.stockResult = false;
        when(fixture.context.getStatus()).thenReturn(FlowStatus.FAILURE_CHALLENGE);
        when(fixture.context.getError()).thenReturn(AuthenticationFlowError.INVALID_CREDENTIALS);

        assertFalse(fixture.validate(form("ada@gmail.com", "wrong")));

        assertEquals(1, fixture.failuresRecorded);
        verify(fixture.authSession).setAuthNote(ATTEMPTED, "ada@gmail.com");
    }

    @Test
    void aLockedOrDisabledPersonIsNotCountedAgain() {
        Fixture fixture = new Fixture(new LoginIdentifiers.Person(user("ada"), false));
        fixture.stockResult = false;
        when(fixture.context.getStatus()).thenReturn(FlowStatus.FORCE_CHALLENGE);

        assertFalse(fixture.validate(form("ada@gmail.com", "secret")));

        assertEquals(0, fixture.failuresRecorded);
        verify(fixture.authSession).setAuthNote(ATTEMPTED, "ada@gmail.com");
    }

    @Test
    void anAmbiguousInputIsRefusedLikeAnUnknownUsername() {
        Fixture fixture = new Fixture(new LoginIdentifiers.Ambiguous());

        assertFalse(fixture.validate(form("shared@example.com", "secret")));

        assertTrue(fixture.stockCalls.isEmpty());
        assertEquals(1, fixture.refusals);
    }

    @Test
    void anAddressWhoseUsernameKeycloakResolvesElsewhereIsRefused() {
        Fixture fixture = new Fixture(new LoginIdentifiers.Person(user("x@example.com"), false));
        fixture.usernameFindsTheSamePerson = false;

        assertFalse(fixture.validate(form("ada@gmail.com", "secret")));

        assertTrue(fixture.stockCalls.isEmpty());
        assertEquals(1, fixture.refusals);
    }

    @Test
    void aUserSetBeforeTheFormIsNeverLookedUp() {
        Fixture fixture = new Fixture(new LoginIdentifiers.Ambiguous());
        when(fixture.authSession.getAuthNote(AbstractUsernameFormAuthenticator.USER_SET_BEFORE_USERNAME_PASSWORD_AUTH))
                .thenReturn("true");
        MultivaluedMap<String, String> form = form("shared@example.com", "secret");

        assertTrue(fixture.validate(form));

        assertSame(form, fixture.stockCalls.get(0));
        assertEquals(0, fixture.resolutions);
    }

    @Test
    void aFailedLoginIsRecordedWithTheExecutionsCategory() {
        KeycloakSession session = mock(KeycloakSession.class);
        RealmModel realm = mock(RealmModel.class);
        AuthenticationFlowContext context = mock(AuthenticationFlowContext.class);
        BruteForceProtector protector = mock(BruteForceProtector.class);
        KeycloakSessionFactory factory = mock(KeycloakSessionFactory.class);
        KeycloakContext keycloakContext = mock(KeycloakContext.class);
        HttpRequest request = mock(HttpRequest.class);
        UriInfo uri = mock(UriInfo.class);
        ClientConnection connection = mock(ClientConnection.class);
        AuthenticationExecutionModel execution = new AuthenticationExecutionModel();
        execution.setAuthenticator(SkyUsernamePasswordFormFactory.PROVIDER_ID);
        when(context.getSession()).thenReturn(session);
        when(context.getRealm()).thenReturn(realm);
        when(context.getExecution()).thenReturn(execution);
        when(context.getConnection()).thenReturn(connection);
        when(realm.isBruteForceProtected()).thenReturn(true);
        when(session.getKeycloakSessionFactory()).thenReturn(factory);
        when(factory.getProviderFactory(Authenticator.class, SkyUsernamePasswordFormFactory.PROVIDER_ID))
                .thenReturn(new SkyUsernamePasswordFormFactory());
        when(session.getProvider(BruteForceProtector.class)).thenReturn(protector);
        when(session.getContext()).thenReturn(keycloakContext);
        when(keycloakContext.getHttpRequest()).thenReturn(request);
        when(request.getUri()).thenReturn(uri);
        UserModel ada = user("ada");

        new SkyUsernamePasswordForm("OBS").recordFailedLogin(context, ada);

        verify(protector).failedLogin(realm, ada, connection, uri, Set.of("password"));
    }

    @Test
    void noFailureIsRecordedWithoutBruteForceProtection() {
        KeycloakSession session = mock(KeycloakSession.class);
        RealmModel realm = mock(RealmModel.class);
        AuthenticationFlowContext context = mock(AuthenticationFlowContext.class);
        when(context.getSession()).thenReturn(session);
        when(context.getRealm()).thenReturn(realm);

        new SkyUsernamePasswordForm("OBS").recordFailedLogin(context, user("ada"));

        verify(session, never()).getProvider(BruteForceProtector.class);
    }

    @Test
    void theFactoryKeepsKeycloaksCategoriesAndRequirement() {
        SkyUsernamePasswordFormFactory factory = new SkyUsernamePasswordFormFactory();

        assertEquals("sky-username-password-form", factory.getId());
        assertEquals("password", factory.getReferenceCategory());
        assertEquals(List.of(AuthenticationExecutionModel.Requirement.REQUIRED), List.of(factory.getRequirementChoices()));
        assertFalse(factory.isConfigurable());
        assertFalse(factory.isUserSetupAllowed());
    }

    private static MultivaluedMap<String, String> form(String username, String password) {
        MultivaluedMap<String, String> form = new MultivaluedHashMap<>();
        form.putSingle("username", username);
        form.putSingle("password", password);
        return form;
    }

    private static UserModel user(String username) {
        UserModel user = mock(UserModel.class);
        when(user.getId()).thenReturn("id-" + username);
        when(user.getUsername()).thenReturn(username);
        return user;
    }

    /** The form with Keycloak's own parts replaced by recorders; the lookup result is fixed. */
    private static final class Fixture {
        final AuthenticationFlowContext context = mock(AuthenticationFlowContext.class);
        final AuthenticationSessionModel authSession = mock(AuthenticationSessionModel.class);
        final EventBuilder event = mock(EventBuilder.class);
        final KeycloakSession session = mock(KeycloakSession.class);
        final RealmModel realm = mock(RealmModel.class);
        final List<MultivaluedMap<String, String>> stockCalls = new ArrayList<>();
        boolean stockResult = true;
        boolean usernameFindsTheSamePerson = true;
        int refusals;
        int resolutions;
        int failuresRecorded;
        private final SkyUsernamePasswordForm form;

        Fixture(LoginIdentifiers.Match match) {
            UserProvider users = mock(UserProvider.class);
            when(context.getAuthenticationSession()).thenReturn(authSession);
            when(context.getEvent()).thenReturn(event);
            when(context.getSession()).thenReturn(session);
            when(context.getRealm()).thenReturn(realm);
            when(session.users()).thenReturn(users);
            when(realm.isLoginWithEmailAllowed()).thenReturn(true);
            when(event.detail(anyString(), anyString())).thenReturn(event);
            form = new SkyUsernamePasswordForm("OBS") {
                @Override
                LoginIdentifiers.Match resolve(AuthenticationFlowContext ignored, String identifier) {
                    resolutions++;
                    return match;
                }

                @Override
                boolean keycloakForm(AuthenticationFlowContext ignored, MultivaluedMap<String, String> formData) {
                    stockCalls.add(formData);
                    return stockResult;
                }

                @Override
                boolean usernameFindsTheSamePerson(AuthenticationFlowContext ignored, UserModel user) {
                    return usernameFindsTheSamePerson;
                }

                @Override
                boolean refuseAsUnknown(AuthenticationFlowContext ignored, String identifier) {
                    refusals++;
                    return false;
                }

                @Override
                void recordFailedLogin(AuthenticationFlowContext ignored, UserModel user) {
                    failuresRecorded++;
                }
            };
        }

        boolean validate(MultivaluedMap<String, String> formData) {
            return form.validateForm(context, formData);
        }
    }
}
