package com.skylab.account;

import com.fasterxml.jackson.databind.JsonNode;
import org.junit.jupiter.api.Test;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;
import org.keycloak.models.UserProvider;
import org.keycloak.util.JsonSerialization;

import java.util.stream.Stream;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyMap;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/** The rules Account center and the first-login offer share for a Personal e-mail. */
class PersonalEmailVerificationTest {

    @Test
    void universityAddressesAndEverySubdomainAreSchoolDomains() {
        for (String address : new String[] {
                "ada@std.yildiz.edu.tr", "ada@yildiz.edu.tr", "Ada@YILDIZ.EDU.TR", "ada@ce.yildiz.edu.tr",
                "ada@a.b.yildiz.edu.tr", "ada@std.yildiz.edu.tr.", "ada@Std.Yildiz.Edu.Tr..", "\"a@b\"@yildiz.edu.tr"}) {
            assertTrue(PersonalEmailVerification.isSchoolDomain(address), address);
        }
        for (String address : new String[] {
                "ada@notyildiz.edu.tr", "ada@yildiz.edu.tr.example.org", "ada@yildiz.edu", "ada@example.org",
                "ada@yildizedu.tr", "yildiz.edu.tr", "", null}) {
            assertFalse(PersonalEmailVerification.isSchoolDomain(address), String.valueOf(address));
        }
    }

    @Test
    void anAddressThatIsAnotherPersonsUsernameIsTaken() {
        KeycloakSession session = mock(KeycloakSession.class);
        RealmModel realm = mock(RealmModel.class);
        UserProvider users = mock(UserProvider.class);
        when(session.users()).thenReturn(users);
        when(users.searchForUserStream(eq(realm), anyMap(), anyInt(), anyInt())).thenAnswer(call -> Stream.empty());
        UserModel person = mock(UserModel.class);
        when(person.getId()).thenReturn("person");
        UserModel other = mock(UserModel.class);
        when(other.getId()).thenReturn("other");

        when(users.getUserByUsername(realm, "old.address@example.org")).thenReturn(other);
        assertTrue(PersonalEmailVerification.isTakenByAnother(session, realm, person, "old.address@example.org"));

        when(users.getUserByUsername(realm, "own.username@example.org")).thenReturn(person);
        assertFalse(PersonalEmailVerification.isTakenByAnother(session, realm, person, "own.username@example.org"),
                "the person's own username is not someone else's");
        assertFalse(PersonalEmailVerification.isTakenByAnother(session, realm, person, "free@example.org"));
    }

    @Test
    void accountCenterAnswersAUniversityAddressWith400OnTheAddressField() throws Exception {
        JsonNode body = JsonSerialization.mapper.readTree(Problems.emailSchoolDomain().body());
        assertEquals(400, body.get("status").intValue());
        assertEquals("email_school_domain", body.get("code").textValue());
        assertEquals("address", body.get("field").textValue());
        assertEquals("Okul adresi mezun olunca kapanabilir; okul dışı bir adres gir.", body.get("detail").textValue());
    }
}
