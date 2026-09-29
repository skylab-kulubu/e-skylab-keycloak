package com.skylab.account;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.keycloak.models.FederatedIdentityModel;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.ModelDuplicateException;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;
import org.keycloak.models.UserProvider;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.stream.IntStream;
import java.util.stream.Stream;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyMap;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class LoginIdentifiersTest {

    private static final String YTU = "OBS";
    private static final String STAMP = "2026-09-21T14:13:20Z";

    private final KeycloakSession session = mock(KeycloakSession.class);
    private final UserProvider users = mock(UserProvider.class);
    private final RealmModel realm = mock(RealmModel.class);
    /** Attribute name to (lowercased value to holders), as Keycloak's exact search sees them. */
    private final Map<String, Map<String, List<UserModel>>> directory = new HashMap<>();
    private final List<Map<String, String>> searches = new ArrayList<>();

    @BeforeEach
    void setUp() {
        when(session.users()).thenReturn(users);
        when(realm.isLoginWithEmailAllowed()).thenReturn(true);
        when(users.searchForUserStream(eq(realm), anyMap(), eq(0), eq(LoginIdentifiers.CANDIDATE_LIMIT)))
                .thenAnswer(invocation -> {
                    Map<String, String> params = invocation.getArgument(1);
                    searches.add(params);
                    assertEquals("true", params.get(UserModel.EXACT));
                    assertEquals("false", params.get(UserModel.INCLUDE_SERVICE_ACCOUNT));
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
    void theUsernameIsKeycloaksOwnRoute() {
        UserModel ada = person("ada");
        when(users.getUserByUsername(realm, "ada")).thenReturn(ada);

        LoginIdentifiers.Person match = assertPerson(resolve("  ada "));

        assertSame(ada, match.user());
        assertTrue(match.byKeycloakLookup());
        assertTrue(searches.isEmpty(), "an input without @ is never an address");
    }

    @Test
    void thePrimaryEmailIsKeycloaksOwnRoute() {
        UserModel ada = person("ada");
        when(users.getUserByEmail(realm, "Ada@Example.com")).thenReturn(ada);

        LoginIdentifiers.Person match = assertPerson(resolve("Ada@Example.com"));

        assertSame(ada, match.user());
        assertTrue(match.byKeycloakLookup());
    }

    @Test
    void theSchoolEmailOfAVerifiedYtuAccountSignsInIgnoringCase() {
        UserModel ada = person("ada");
        school(ada, "Ada.Kaya@STD.yildiz.edu.tr");
        ytuLinked(ada);

        LoginIdentifiers.Person match = assertPerson(resolve("ada.kaya@std.YILDIZ.edu.tr"));

        assertSame(ada, match.user());
        assertFalse(match.byKeycloakLookup());
        assertEquals("ada.kaya@std.yildiz.edu.tr", searches.get(0).get("schoolEmail"));
    }

    @Test
    void aSchoolEmailWithoutTheYtuLinkIsNotAnIdentifier() {
        UserModel ada = person("ada");
        school(ada, "ada.kaya@std.yildiz.edu.tr");

        assertInstanceOf(LoginIdentifiers.Nobody.class, resolve("ada.kaya@std.yildiz.edu.tr"));
    }

    @Test
    void aProvenPersonalEmailSignsIn() {
        UserModel ada = person("ada");
        personal(ada, "ada@gmail.com", STAMP);

        LoginIdentifiers.Person match = assertPerson(resolve("ADA@gmail.com"));

        assertSame(ada, match.user());
        assertFalse(match.byKeycloakLookup());
    }

    @Test
    void aPersonalEmailWithoutItsProofIsNotAnIdentifier() {
        UserModel written = person("written");
        personal(written, "written@gmail.com", null);
        UserModel garbled = person("garbled");
        personal(garbled, "garbled@gmail.com", "yesterday");

        assertInstanceOf(LoginIdentifiers.Nobody.class, resolve("written@gmail.com"));
        assertInstanceOf(LoginIdentifiers.Nobody.class, resolve("garbled@gmail.com"));
    }

    @Test
    void anAddressFoundByTheDatabaseIsCheckedAgainOnTheStoredValue() {
        UserModel ada = person("ada");
        when(ada.getFirstAttribute("personalEmail")).thenReturn("someone-else@gmail.com");
        when(ada.getFirstAttribute("personalEmailVerifiedAt")).thenReturn(STAMP);
        directory.computeIfAbsent("personalEmail", key -> new HashMap<>())
                .computeIfAbsent("ada@gmail.com", key -> new ArrayList<>()).add(ada);

        assertInstanceOf(LoginIdentifiers.Nobody.class, resolve("ada@gmail.com"));
    }

    @Test
    void oneAddressOfTwoPeopleIsAmbiguous() {
        UserModel ada = person("ada");
        when(users.getUserByEmail(realm, "shared@std.yildiz.edu.tr")).thenReturn(ada);
        UserModel bob = person("bob");
        school(bob, "shared@std.yildiz.edu.tr");
        ytuLinked(bob);

        assertInstanceOf(LoginIdentifiers.Ambiguous.class, resolve("shared@std.yildiz.edu.tr"));
    }

    @Test
    void aSchoolAndAPersonalEmailOfTwoPeopleAreAmbiguous() {
        UserModel ada = person("ada");
        school(ada, "shared@example.com");
        ytuLinked(ada);
        UserModel bob = person("bob");
        personal(bob, "shared@example.com", STAMP);

        assertInstanceOf(LoginIdentifiers.Ambiguous.class, resolve("shared@example.com"));
    }

    @Test
    void aUsernameThatIsAnotherPersonsEmailIsAmbiguous() {
        UserModel legacy = person("legacy");
        when(users.getUserByUsername(realm, "x@example.com")).thenReturn(legacy);
        UserModel bob = person("bob");
        when(users.getUserByEmail(realm, "x@example.com")).thenReturn(bob);

        assertInstanceOf(LoginIdentifiers.Ambiguous.class, resolve("x@example.com"));
    }

    @Test
    void onePersonFoundByEveryRouteIsNotAmbiguous() {
        UserModel ada = person("ada");
        when(users.getUserByEmail(realm, "ada@std.yildiz.edu.tr")).thenReturn(ada);
        school(ada, "ada@std.yildiz.edu.tr");
        ytuLinked(ada);

        LoginIdentifiers.Person match = assertPerson(resolve("ada@std.yildiz.edu.tr"));

        assertSame(ada, match.user());
        assertTrue(match.byKeycloakLookup());
    }

    @Test
    void duplicateKeycloakEmailsAreAmbiguous() {
        when(users.getUserByEmail(realm, "twice@example.com"))
                .thenThrow(new ModelDuplicateException("Multiple users with email", UserModel.EMAIL));

        assertInstanceOf(LoginIdentifiers.Ambiguous.class, resolve("twice@example.com"));
    }

    @Test
    void reachingTheCandidateBoundIsAmbiguous() {
        IntStream.range(0, LoginIdentifiers.CANDIDATE_LIMIT).forEach(i -> {
            UserModel holder = person("holder" + i);
            personal(holder, "crowd@example.com", STAMP);
        });

        assertInstanceOf(LoginIdentifiers.Ambiguous.class, resolve("crowd@example.com"));
    }

    @Test
    void withoutEmailLoginOnlyTheUsernameCounts() {
        when(realm.isLoginWithEmailAllowed()).thenReturn(false);
        UserModel ada = person("ada");
        school(ada, "ada@std.yildiz.edu.tr");
        ytuLinked(ada);

        assertInstanceOf(LoginIdentifiers.Nobody.class, resolve("ada@std.yildiz.edu.tr"));
        verify(users, never()).getUserByEmail(any(), anyString());
        verify(users, never()).searchForUserStream(any(), anyMap(), anyInt(), anyInt());
    }

    @Test
    void anInputLongerThanAnyStoredAddressIsNotSearched() {
        String longAddress = "a".repeat(LoginIdentifiers.MAX_ADDRESS_LENGTH) + "@example.com";

        assertInstanceOf(LoginIdentifiers.Nobody.class, resolve(longAddress));
        assertTrue(searches.isEmpty());
    }

    @Test
    void blankInputNamesNobody() {
        assertInstanceOf(LoginIdentifiers.Nobody.class, resolve("   "));
        assertInstanceOf(LoginIdentifiers.Nobody.class, resolve(null));
        verify(users, never()).getUserByUsername(any(), anyString());
    }

    private LoginIdentifiers.Match resolve(String typed) {
        return LoginIdentifiers.resolve(session, realm, YTU, typed);
    }

    private static LoginIdentifiers.Person assertPerson(LoginIdentifiers.Match match) {
        return assertInstanceOf(LoginIdentifiers.Person.class, match);
    }

    private static UserModel person(String id) {
        UserModel user = mock(UserModel.class);
        when(user.getId()).thenReturn(id);
        when(user.getUsername()).thenReturn(id);
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
        FederatedIdentityModel link = new FederatedIdentityModel(YTU, "ms-" + id, id);
        when(users.getFederatedIdentity(realm, user, YTU)).thenReturn(link);
    }
}
