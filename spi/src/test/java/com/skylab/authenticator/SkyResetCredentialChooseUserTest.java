package com.skylab.authenticator;

import jakarta.ws.rs.core.MultivaluedHashMap;
import jakarta.ws.rs.core.MultivaluedMap;
import jakarta.ws.rs.core.Response;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.keycloak.authentication.AuthenticationFlowContext;
import org.keycloak.authentication.AuthenticationFlowError;
import org.keycloak.authentication.authenticators.browser.AbstractUsernameFormAuthenticator;
import org.keycloak.authentication.authenticators.resetcred.ResetCredentialChooseUser;
import org.keycloak.events.Details;
import org.keycloak.events.Errors;
import org.keycloak.events.EventBuilder;
import org.keycloak.forms.login.LoginFormsProvider;
import org.keycloak.http.HttpRequest;
import org.keycloak.models.AuthenticationExecutionModel;
import org.keycloak.models.FederatedIdentityModel;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.ModelDuplicateException;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;
import org.keycloak.models.UserProvider;
import org.keycloak.models.utils.FormMessage;
import org.keycloak.sessions.AuthenticationSessionModel;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.stream.Stream;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyMap;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * The reset-password "choose user" step with the K4 lookup, run against Keycloak's own step and
 * the real {@code LoginIdentifiers} over a mocked user store. Every outcome ends in
 * {@code context.success()}: the next step (reset-credential-email) answers "e-mail sent" either
 * way and mails only a chosen, enabled person, at that person's Primary e-mail.
 */
class SkyResetCredentialChooseUserTest {

    private static final String YTU = "OBS";
    private static final String STAMP = "2026-09-21T14:13:20Z";
    private static final String ATTEMPTED = AbstractUsernameFormAuthenticator.ATTEMPTED_USERNAME;
    private static final String CHOSEN = ResetCredentialChooseUser.RESET_CREDENTIAL_USER_CHOSEN;

    private final AuthenticationFlowContext context = mock(AuthenticationFlowContext.class);
    private final AuthenticationSessionModel authSession = mock(AuthenticationSessionModel.class);
    private final KeycloakSession session = mock(KeycloakSession.class);
    private final UserProvider users = mock(UserProvider.class);
    private final RealmModel realm = mock(RealmModel.class);
    private final HttpRequest request = mock(HttpRequest.class);
    private final EventBuilder event = mock(EventBuilder.class);
    private final MultivaluedMap<String, String> form = new MultivaluedHashMap<>();
    /** The events logged through {@code event.clone()}: one recorder per clone. */
    private final List<RecordedEvent> events = new ArrayList<>();
    /** Attribute name to (lowercased value to holders), as Keycloak's exact search sees them. */
    private final Map<String, Map<String, List<UserModel>>> directory = new HashMap<>();
    private final SkyResetCredentialChooseUser step = new SkyResetCredentialChooseUser();

    @BeforeEach
    void setUp() {
        step.init(null);
        when(context.getAuthenticationSession()).thenReturn(authSession);
        when(context.getSession()).thenReturn(session);
        when(context.getRealm()).thenReturn(realm);
        when(context.getHttpRequest()).thenReturn(request);
        when(context.getEvent()).thenReturn(event);
        when(request.getDecodedFormParameters()).thenReturn(form);
        when(session.users()).thenReturn(users);
        when(realm.isLoginWithEmailAllowed()).thenReturn(true);
        when(event.clone()).thenAnswer(invocation -> {
            RecordedEvent recorded = new RecordedEvent();
            events.add(recorded);
            return recorded.builder;
        });
        when(users.searchForUserStream(eq(realm), anyMap(), eq(0), any(Integer.class)))
                .thenAnswer(invocation -> {
                    Map<String, String> params = invocation.getArgument(1);
                    for (String attribute : List.of("schoolEmail", "personalEmail")) {
                        if (params.containsKey(attribute)) {
                            return directory.getOrDefault(attribute, Map.of())
                                    .getOrDefault(params.get(attribute).toLowerCase(), List.of())
                                    .stream();
                        }
                    }
                    return Stream.empty();
                });
    }

    @Test
    void theUsernameIsKeycloaksOwnChoice() {
        UserModel ada = person("ada");
        when(users.getUserByUsername(realm, "ada")).thenReturn(ada);

        submit(" ada ");

        assertChosen(ada, "ada");
        assertTrue(events.isEmpty());
    }

    @Test
    void thePrimaryEmailIsKeycloaksOwnChoice() {
        UserModel ada = person("ada");
        when(users.getUserByEmail(realm, "ada@gmail.com")).thenReturn(ada);

        submit("ada@gmail.com");

        assertChosen(ada, "ada@gmail.com");
    }

    @Test
    void theSchoolEmailOfAVerifiedYtuAccountChoosesThePersonIgnoringCase() {
        UserModel ada = person("ada");
        school(ada, "Ada.Kaya@STD.yildiz.edu.tr");
        ytuLinked(ada);

        submit("  ada.kaya@std.YILDIZ.edu.tr ");

        assertChosen(ada, "ada.kaya@std.YILDIZ.edu.tr");
        assertTrue(events.isEmpty());
    }

    @Test
    void aProvenPersonalEmailChoosesThePersonIgnoringCase() {
        UserModel ada = person("ada");
        personal(ada, "ada@gmail.com", STAMP);

        submit("ADA@Gmail.com");

        assertChosen(ada, "ADA@Gmail.com");
    }

    @Test
    void theStepNeverChangesWhereTheMailGoes() {
        UserModel ada = person("ada");
        when(ada.getEmail()).thenReturn("ada.kaya@std.yildiz.edu.tr");
        personal(ada, "ada@gmail.com", STAMP);

        submit("ada@gmail.com");

        assertChosen(ada, "ada@gmail.com");
        verify(ada, never()).setEmail(anyString());
        verify(ada, never()).setEmailVerified(any(Boolean.class));
        verify(ada, never()).setSingleAttribute(anyString(), anyString());
    }

    @Test
    void aPersonalEmailWithoutItsProofChoosesNobody() {
        UserModel ada = person("ada");
        personal(ada, "ada@gmail.com", null);

        submit("ada@gmail.com");

        assertNobody("ada@gmail.com", Errors.USER_NOT_FOUND, null);
    }

    @Test
    void aSchoolEmailWithoutTheYtuLinkChoosesNobody() {
        UserModel ada = person("ada");
        school(ada, "ada.kaya@std.yildiz.edu.tr");

        submit("ada.kaya@std.yildiz.edu.tr");

        assertNobody("ada.kaya@std.yildiz.edu.tr", Errors.USER_NOT_FOUND, null);
    }

    @Test
    void anUnknownInputIsKeycloaksOwnUserNotFound() {
        submit("nobody@example.com");

        assertNobody("nobody@example.com", Errors.USER_NOT_FOUND, null);
    }

    @Test
    void anAddressOfTwoPeopleChoosesNobodyEvenWhenKeycloakWouldFindOne() {
        UserModel ada = person("ada");
        // Keycloak's e-mail lookup ignores case; the mock answers the typed spelling.
        when(users.getUserByEmail(realm, "SHARED@std.yildiz.edu.tr")).thenReturn(ada);
        UserModel bob = person("bob");
        school(bob, "Shared@std.yildiz.edu.tr");
        ytuLinked(bob);

        submit("SHARED@std.yildiz.edu.tr");

        assertNobody("SHARED@std.yildiz.edu.tr", Errors.USER_NOT_FOUND, null);
    }

    @Test
    void aSchoolAndAPersonalEmailOfTwoPeopleChooseNobody() {
        UserModel ada = person("ada");
        school(ada, "shared@example.com");
        ytuLinked(ada);
        UserModel bob = person("bob");
        personal(bob, "shared@example.com", STAMP);

        submit("shared@example.com");

        assertNobody("shared@example.com", Errors.USER_NOT_FOUND, null);
    }

    @Test
    void duplicateKeycloakEmailsChooseNobodyInsteadOfFailing() {
        when(users.getUserByEmail(realm, "twice@example.com"))
                .thenThrow(new ModelDuplicateException("Multiple users with email", UserModel.EMAIL));

        submit("twice@example.com");

        assertNobody("twice@example.com", Errors.USER_NOT_FOUND, null);
    }

    @Test
    void aDisabledPersonFoundByAddressIsTreatedAsKeycloakTreatsADisabledUsername() {
        UserModel ada = person("ada");
        when(ada.isEnabled()).thenReturn(false);
        personal(ada, "ada@gmail.com", STAMP);

        submit("ada@gmail.com");

        assertNobody("ada@gmail.com", Errors.USER_DISABLED, ada);
    }

    @Test
    void aDisabledPersonFoundByUsernameKeepsKeycloaksAnswer() {
        UserModel ada = person("ada");
        when(ada.isEnabled()).thenReturn(false);
        when(users.getUserByUsername(realm, "ada")).thenReturn(ada);

        submit("ada");

        assertNobody("ada", Errors.USER_DISABLED, ada);
    }

    @Test
    void aMissingUsernameIsKeycloaksOwnFormError() {
        LoginFormsProvider forms = mock(LoginFormsProvider.class);
        Response page = mock(Response.class);
        when(context.form()).thenReturn(forms);
        when(forms.addError(any(FormMessage.class))).thenReturn(forms);
        when(forms.createPasswordReset()).thenReturn(page);

        submit(null);

        verify(event).error(Errors.USERNAME_MISSING);
        verify(context).failureChallenge(AuthenticationFlowError.INVALID_USER, page);
        verify(context, never()).success();
        verify(users, never()).searchForUserStream(any(), anyMap(), any(Integer.class), any(Integer.class));
    }

    @Test
    void withoutEmailLoginAnAddressIsNeverLookedUp() {
        when(realm.isLoginWithEmailAllowed()).thenReturn(false);
        UserModel ada = person("ada");
        personal(ada, "ada@gmail.com", STAMP);

        submit("ada@gmail.com");

        assertNobody("ada@gmail.com", Errors.USER_NOT_FOUND, null);
        verify(users, never()).searchForUserStream(any(), anyMap(), any(Integer.class), any(Integer.class));
    }

    @Test
    void theFactoryKeepsKeycloaksRequirementAndCategory() {
        assertEquals("sky-reset-credentials-choose-user", step.getId());
        assertNull(step.getReferenceCategory());
        assertEquals(List.of(AuthenticationExecutionModel.Requirement.REQUIRED), List.of(step.getRequirementChoices()));
        assertFalse(step.isConfigurable());
        assertFalse(step.isUserSetupAllowed());
        assertFalse(step.requiresUser());
        assertSame(step, step.create(session));
    }

    @Test
    void theYtuIdentityProviderAliasFollowsTheProviderConfig() {
        UserModel ada = person("ada");
        school(ada, "ada.kaya@std.yildiz.edu.tr");
        when(users.getFederatedIdentity(realm, ada, "YTU-TEST"))
                .thenReturn(new FederatedIdentityModel("YTU-TEST", "ms-ada", "ada"));
        org.keycloak.Config.Scope config = mock(org.keycloak.Config.Scope.class);
        when(config.get(SkyResetCredentialChooseUser.YTU_IDP_ALIAS_CONFIG)).thenReturn("YTU-TEST");
        step.init(config);

        submit("ada.kaya@std.yildiz.edu.tr");

        assertChosen(ada, "ada.kaya@std.yildiz.edu.tr");
    }

    private void submit(String username) {
        if (username != null) {
            form.putSingle("username", username);
        }
        step.action(context);
    }

    private void assertChosen(UserModel user, String attempted) {
        verify(authSession).setAuthNote(ATTEMPTED, attempted);
        verify(authSession).setAuthNote(CHOSEN, "true");
        verify(context).setUser(user);
        verify(context, never()).clearUser();
        verify(context).success();
    }

    /** Keycloak's answer when nobody may be mailed: the user is cleared, the flow still succeeds. */
    private void assertNobody(String attempted, String error, UserModel eventUser) {
        verify(authSession).setAuthNote(ATTEMPTED, attempted);
        verify(authSession, never()).setAuthNote(eq(CHOSEN), anyString());
        verify(context, never()).setUser(any());
        verify(context).clearUser();
        verify(context).success();
        assertEquals(1, events.size(), "exactly one event is logged");
        RecordedEvent recorded = events.get(0);
        verify(recorded.builder).detail(Details.USERNAME, attempted);
        verify(recorded.builder).error(error);
        if (eventUser == null) {
            verify(recorded.builder, never()).user(any(UserModel.class));
        } else {
            verify(recorded.builder).user(eventUser);
        }
    }

    private static UserModel person(String id) {
        UserModel user = mock(UserModel.class);
        when(user.getId()).thenReturn(id);
        when(user.getUsername()).thenReturn(id);
        when(user.isEnabled()).thenReturn(true);
        return user;
    }

    private void school(UserModel user, String address) {
        when(user.getFirstAttribute("schoolEmail")).thenReturn(address);
        directory.computeIfAbsent("schoolEmail", key -> new HashMap<>())
                .computeIfAbsent(address.toLowerCase(), key -> new ArrayList<>()).add(user);
    }

    private void personal(UserModel user, String address, String verifiedAt) {
        when(user.getFirstAttribute("personalEmail")).thenReturn(address);
        when(user.getFirstAttribute("personalEmailVerifiedAt")).thenReturn(verifiedAt);
        directory.computeIfAbsent("personalEmail", key -> new HashMap<>())
                .computeIfAbsent(address.toLowerCase(), key -> new ArrayList<>()).add(user);
    }

    private void ytuLinked(UserModel user) {
        String id = user.getId();
        when(users.getFederatedIdentity(realm, user, YTU)).thenReturn(new FederatedIdentityModel(YTU, "ms-" + id, id));
    }

    private static final class RecordedEvent {
        final EventBuilder builder = mock(EventBuilder.class);

        RecordedEvent() {
            when(builder.detail(anyString(), anyString())).thenReturn(builder);
            when(builder.user(any(UserModel.class))).thenReturn(builder);
        }
    }
}
