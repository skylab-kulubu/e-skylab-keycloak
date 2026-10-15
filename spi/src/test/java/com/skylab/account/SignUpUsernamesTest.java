package com.skylab.account;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.SingleUseObjectProvider;
import org.keycloak.models.UserModel;
import org.keycloak.models.UserProvider;

import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * The username of an account opened by Self-registration (eskylab-login-ux 09): derived from the
 * local part of the proven address, in the Account center's username alphabet, a number added on a
 * clash. Faz 0 (olgular-faz0 §2.2): 105 of 117 YTÜ usernames are not e-mail addresses, so the
 * address itself is never the username.
 */
class SignUpUsernamesTest {

    private final KeycloakSession session = mock(KeycloakSession.class);
    private final RealmModel realm = mock(RealmModel.class);
    private final UserProvider users = mock(UserProvider.class);
    private final Set<String> taken = new HashSet<>();
    private final Map<String, Boolean> store = new ConcurrentHashMap<>();

    @BeforeEach
    void setUp() {
        when(session.users()).thenReturn(users);
        when(realm.getId()).thenReturn("realm-id");
        when(users.getUserByUsername(eq(realm), anyString()))
                .thenAnswer(call -> taken.contains(call.<String>getArgument(1)) ? mock(UserModel.class) : null);
        SingleUseObjectProvider singleUse = mock(SingleUseObjectProvider.class);
        when(singleUse.putIfAbsent(anyString(), org.mockito.ArgumentMatchers.anyLong()))
                .thenAnswer(call -> store.putIfAbsent(call.getArgument(0), Boolean.TRUE) == null);
        when(session.singleUseObjects()).thenReturn(singleUse);
    }

    @Test
    void theBaseIsTheLocalPartInTheAccountCentersAlphabet() {
        assertEquals("ada.lovelace", SignUpUsernames.base("Ada.Lovelace@example.com"));
        assertEquals("ada", SignUpUsernames.base("ada+skylab@example.com"), "a +tag is not part of the name");
        assertEquals("sukru.ozcelik", SignUpUsernames.base("Şükrü.Özçelik@example.com"), "Turkish letters fold to ASCII");
        assertEquals("igdir", SignUpUsernames.base("IĞDIR@example.com"), "dotless and dotted I both fold to i");
        assertEquals("jose", SignUpUsernames.base("José@example.com"));
        assertEquals("ada.lovelace", SignUpUsernames.base("ada-lovelace@example.com"), "a hyphen becomes a dot");
        assertEquals("ada.l", SignUpUsernames.base("..ada...l..@example.com"), "dots never repeat or frame the name");
        assertEquals("a_b", SignUpUsernames.base("a_b@example.com"));
        assertEquals("uye", SignUpUsernames.base("+tag@example.com"), "nothing usable left: a neutral word");
        assertEquals(30, SignUpUsernames.base("a".repeat(64) + "@example.com").length());
    }

    @Test
    void everyCandidateFitsTheAccountCentersRule() {
        for (String address : List.of("a@x.io", "ab@x.io", "Şükrü.Özçelik@example.com", "x".repeat(64) + "@x.io",
                "+tag@x.io", "a.@x.io", "1@x.io")) {
            for (String candidate : SignUpUsernames.candidates(SignUpUsernames.base(address)).limit(150).toList()) {
                assertTrue(IdentityResource.USERNAME.matcher(candidate).matches(), address + " -> " + candidate);
                assertTrue(candidate.indexOf('@') < 0);
            }
        }
    }

    @Test
    void aShortBaseIsPaddedWithANumberAndALongOneMakesRoomForIt() {
        assertEquals(List.of("a01", "a02", "a03"), SignUpUsernames.candidates("a").limit(3).toList());
        assertEquals(List.of("ab1", "ab2"), SignUpUsernames.candidates("ab").limit(2).toList());
        assertEquals(List.of("ada", "ada2", "ada3"), SignUpUsernames.candidates("ada").limit(3).toList());
        String longBase = "b".repeat(30);
        List<String> long3 = SignUpUsernames.candidates(longBase).limit(3).toList();
        assertEquals(longBase, long3.get(0));
        assertEquals("b".repeat(29) + "2", long3.get(1));
        assertEquals("b".repeat(28) + "10", SignUpUsernames.candidates(longBase).skip(9).findFirst().orElseThrow());
    }

    @Test
    void theFirstFreeCandidateIsChosen() {
        taken.add("ada");
        taken.add("ada2");

        assertEquals("ada3", new SignUpUsernames().choose(session, realm, "ada@example.com"));
    }

    // Two sign-ups at once with the same local part (ada@gmail.com, ada@outlook.com) never get the same
    // name: the choice is claimed in the single-use store first.
    @Test
    void aNameAnotherSignUpJustClaimedIsNotChosenAgain() {
        SignUpUsernames usernames = new SignUpUsernames();
        String first = usernames.choose(session, realm, "ada@gmail.com");
        String second = usernames.choose(session, realm, "ada@outlook.com");

        assertEquals("ada", first);
        assertNotEquals(first, second);
        assertEquals("ada2", second);
    }

    @Test
    void whenEveryNumberedNameIsTakenARandomOneIsTried() {
        SignUpUsernames.candidates("ada").limit(SignUpUsernames.NUMBERED_TRIES).forEach(taken::add);

        String chosen = new SignUpUsernames().choose(session, realm, "ada@example.com");

        assertTrue(chosen.matches("^ada[0-9]{6}$"), chosen);
    }
}
