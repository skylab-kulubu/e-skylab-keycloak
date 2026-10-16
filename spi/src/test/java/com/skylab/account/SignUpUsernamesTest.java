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
 * names on the form, in the Account center's username alphabet, a number added on a clash.
 * The proven address is never an input, including when the names have no ASCII letters.
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
    void theBaseComesFromBothNamesAndFoldsTurkishAndAccents() {
        assertEquals("ada.lovelace", SignUpUsernames.base("Ada", "Lovelace"));
        assertEquals("sukru.ozcelik", SignUpUsernames.base("Şükrü", "Özçelik"));
        assertEquals("igdir.isik", SignUpUsernames.base("IĞDIR", "Işık"));
        assertEquals("jose.nunez", SignUpUsernames.base("José", "Núñez"));
        assertEquals("ayse.nur.yilmaz", SignUpUsernames.base(" Ayşe\u00a0  Nur ", "Yılmaz"));
        assertEquals("anne.marie.o.neill", SignUpUsernames.base("Anne-Marie", "O'Neill"));
        assertEquals("ada.lovelace", SignUpUsernames.base("..ada...", "..lovelace.."));
        assertEquals("ayse.yilmaz", SignUpUsernames.base("Ay\u200bşe", "Yılmaz"));
    }

    @Test
    void namesWithoutAsciiUseANeutralFallbackOrTheOtherName() {
        assertEquals("uye", SignUpUsernames.base("李", "王"));
        assertEquals("uye", SignUpUsernames.base("---", "..."));
        assertEquals("uye", SignUpUsernames.base("\u00a0\u200b", " "));
        assertEquals("uye", SignUpUsernames.base(null, null));
        assertEquals("kaya", SignUpUsernames.base("李", "Kaya"));
        assertEquals("ada", SignUpUsernames.base("Ada", "王"));
    }

    @Test
    void longNamesKeepSomethingOfBothNames() {
        assertEquals("a".repeat(15) + "." + "b".repeat(14), SignUpUsernames.base("a".repeat(64), "b".repeat(64)));
        assertEquals("a".repeat(26) + ".koc", SignUpUsernames.base("a".repeat(64), "Koç"));
        assertEquals("ada." + "b".repeat(26), SignUpUsernames.base("Ada", "b".repeat(64)));
    }

    @Test
    void everyCandidateFitsTheAccountCentersRule() {
        for (List<String> names : List.of(List.of("A", "B"), List.of("Şükrü", "Özçelik"),
                List.of("a".repeat(64), "b".repeat(64)), List.of("李", "王"), List.of("---", "..."))) {
            for (String candidate : SignUpUsernames.candidates(SignUpUsernames.base(names.get(0), names.get(1))).limit(150).toList()) {
                assertTrue(IdentityResource.USERNAME.matcher(candidate).matches(), candidate);
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
        taken.add("ada.lovelace");
        taken.add("ada.lovelace2");

        assertEquals("ada.lovelace3", new SignUpUsernames().choose(session, realm, "Ada", "Lovelace"));
    }

    // Two sign-ups at once with the same names never get the same
    // name: the choice is claimed in the single-use store first.
    @Test
    void aNameAnotherSignUpJustClaimedIsNotChosenAgain() {
        SignUpUsernames usernames = new SignUpUsernames();
        String first = usernames.choose(session, realm, "Ada", "Lovelace");
        String second = usernames.choose(session, realm, "Ada", "Lovelace");

        assertEquals("ada.lovelace", first);
        assertNotEquals(first, second);
        assertEquals("ada.lovelace2", second);
    }

    @Test
    void whenEveryNumberedNameIsTakenARandomOneIsTried() {
        SignUpUsernames.candidates("ada.lovelace").limit(SignUpUsernames.NUMBERED_TRIES).forEach(taken::add);

        String chosen = new SignUpUsernames().choose(session, realm, "Ada", "Lovelace");

        assertTrue(chosen.matches("^ada\\.lovelace[0-9]{6}$"), chosen);
    }
}
