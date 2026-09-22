package com.skylab.mail;

import com.fasterxml.jackson.databind.JsonNode;
import org.junit.jupiter.api.Test;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;
import org.keycloak.util.JsonSerialization;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class SkyMailMessageTest {

    static UserModel user(String firstName, String lastName, String username, String email) {
        UserModel user = mock(UserModel.class);
        when(user.getFirstName()).thenReturn(firstName);
        when(user.getLastName()).thenReturn(lastName);
        when(user.getUsername()).thenReturn(username);
        when(user.getEmail()).thenReturn(email);
        return user;
    }

    static RealmModel realm(String name, String displayName) {
        RealmModel realm = mock(RealmModel.class);
        when(realm.getName()).thenReturn(name);
        when(realm.getDisplayName()).thenReturn(displayName);
        return realm;
    }

    @Test
    void carriesEveryVariableSkyMailCanRenderWith() throws Exception {
        SkyMailMessage message = SkyMailMessage.of(
                SkyMailTemplates.VERIFY_EMAIL,
                SkyMailTemplates.VERIFY_EMAIL_SUBJECT_KEY,
                "https://e.yildizskylab.com/verify?key=abc",
                "60",
                user("Ada", "Yıldız", "ada", "ada@yildizskylab.com"),
                realm("e-skylab", "SKY LAB"));

        JsonNode body = JsonSerialization.mapper.readTree(
                message.toRequestBody("ada@yildizskylab.com"));
        JsonNode variables = body.get("body_variables");

        assertEquals("keycloak.verify-email", body.get("template_key").textValue());
        assertEquals("ada@yildizskylab.com", body.get("recipient_email").textValue());
        assertEquals("Ada Yıldız", body.get("recipient_full_name").textValue());
        assertEquals(SkyMailMessage.VARIABLE_NAMES.size(), variables.size());
        assertEquals("https://e.yildizskylab.com/verify?key=abc", variables.get("link").textValue());
        assertEquals("60", variables.get("linkExpirationMinutes").textValue());
        assertEquals("Ada", variables.get("firstName").textValue());
        assertEquals("ada", variables.get("username").textValue());
        assertEquals("SKY LAB", variables.get("realmDisplayName").textValue());
        assertEquals("emailVerificationSubject", variables.get("subjectKey").textValue());
    }

    @Test
    void sendsEveryVariableAsAnEmptyStringWhenKeycloakDoesNotKnowIt() throws Exception {
        SkyMailMessage message = SkyMailMessage.of(
                SkyMailTemplates.GENERIC, "eventUpdatePasswordSubject", null, null,
                user(null, null, "ada", "ada@yildizskylab.com"), realm("e-skylab", null));

        JsonNode variables = JsonSerialization.mapper
                .readTree(message.toRequestBody("ada@yildizskylab.com"))
                .get("body_variables");

        for (String name : SkyMailMessage.VARIABLE_NAMES) {
            assertTrue(variables.has(name), name + " must always be sent");
            assertTrue(variables.get(name).isTextual(), name + " must be a string");
        }
        assertEquals("", variables.get("link").textValue());
        assertEquals("", variables.get("linkExpirationMinutes").textValue());
        assertEquals("", variables.get("firstName").textValue());
        assertEquals("E-skylab", variables.get("realmDisplayName").textValue(),
                "Keycloak capitalises the realm name when there is no display name");
    }

    @Test
    void survivesAMailWithNeitherUserNorRealm() throws Exception {
        SkyMailMessage message = SkyMailMessage.of(
                SkyMailTemplates.GENERIC, "emailTestSubject", "", "", null, null);

        JsonNode body = JsonSerialization.mapper.readTree(message.toRequestBody(null));

        assertEquals("", body.get("recipient_email").textValue());
        assertEquals("", body.get("recipient_full_name").textValue());
        assertEquals(SkyMailMessage.VARIABLE_NAMES.size(), body.get("body_variables").size());
    }

    @Test
    void namesTheRecipientByUsernameWhenTheProfileHasNoName() {
        assertEquals("ada", SkyMailMessage.fullName(user(null, null, "ada", "ada@yildizskylab.com")));
        assertEquals("Ada", SkyMailMessage.fullName(user("Ada", null, "ada", "ada@yildizskylab.com")));
        assertEquals("", SkyMailMessage.fullName(null));
    }

    @Test
    void rendersTheLinkExpirationOnlyWhenKeycloakSetsOne() {
        assertEquals("60", SkyMailMessage.minutes(60L));
        assertEquals("", SkyMailMessage.minutes(0L));
        assertEquals("15", SkyMailMessage.minutes((Object) Integer.valueOf(15)));
        assertEquals("", SkyMailMessage.minutes((Object) null));
        assertEquals("", SkyMailMessage.minutes((Object) "soon"));
    }
}
