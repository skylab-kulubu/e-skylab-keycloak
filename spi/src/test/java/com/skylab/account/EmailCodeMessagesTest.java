package com.skylab.account;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.util.Properties;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * The SPI's fallback e-mail code page (the SKY LAB theme draws its own): every error it can show has
 * its sentence in both languages, and the code box takes a whole eight-digit code.
 */
class EmailCodeMessagesTest {

    private static Properties messages(String locale) throws IOException {
        Properties properties = new Properties();
        try (InputStream in = EmailCodeMessagesTest.class.getResourceAsStream(
                "/theme-resources/messages/messages_" + locale + ".properties")) {
            assertNotNull(in, locale);
            properties.load(new InputStreamReader(in, StandardCharsets.UTF_8));
        }
        return properties;
    }

    @Test
    void everyProblemHasATurkishAndAnEnglishSentence() throws IOException {
        for (String locale : new String[] {"tr", "en"}) {
            Properties properties = messages(locale);
            for (EmailCodeAuthenticator.Problem problem : EmailCodeAuthenticator.Problem.values()) {
                String sentence = properties.getProperty("emailCodeError." + problem.value);
                assertNotNull(sentence, locale + ": emailCodeError." + problem.value);
                assertFalse(sentence.isBlank(), locale + ": emailCodeError." + problem.value);
            }
        }
    }

    // Self-registration (eskylab-login-ux 09): the fallback sign-up page words every error and stage,
    // and the code mail says what a sign-up code is for, in both languages.
    @Test
    void theSignUpPageAndMailHaveTheirSentencesInBothLanguages() throws IOException {
        for (String locale : new String[] {"tr", "en"}) {
            Properties properties = messages(locale);
            for (EmailCodeSignUp.Problem problem : EmailCodeSignUp.Problem.values()) {
                assertFalse(properties.getProperty("emailCodeSignUpError." + problem.value, "").isBlank(),
                        locale + ": emailCodeSignUpError." + problem.value);
            }
            for (String key : new String[] {"emailCodeSignUpTitle", "emailCodeSignUpYtuTitle", "emailCodeSignUpExistingTitle",
                    "emailCodeSignUpUnavailableTitle", "emailCodeSignUpExistingText", "emailCodeSignUpKvkk",
                    "skySignUpCodeSubject", "skySignUpCodeIntro", "skySignUpCodeIgnore"}) {
                assertFalse(properties.getProperty(key, "").isBlank(), locale + ": " + key);
            }
            assertFalse(properties.getProperty("skySignUpCodeSubject").matches(".*[0-9]{6,}.*"), "no code in the subject");
        }
        assertTrue(messages("tr").getProperty("emailCodeSignUpExistingText").contains("Bu adresle zaten hesabın vardı, giriş yaptın"),
                "ticket 09's sentence");
        String page = resource("/theme-resources/templates/sky-email-code-sign-up.ftl");
        for (EmailCodeSignUp.Stage stage : EmailCodeSignUp.Stage.values()) {
            assertTrue(stage == EmailCodeSignUp.Stage.FORM || page.contains("stage == \"" + stage.value + "\""), stage.value);
        }
        assertFalse(page.contains("type=\"checkbox\""), "no consent box: the KVKK line only informs (spec §9)");
        for (String mail : new String[] {"/theme-resources/templates/text/sky-login-code.ftl",
                "/theme-resources/templates/html/sky-login-code.ftl"}) {
            String template = resource(mail);
            assertTrue(template.contains("skySignUpCodeIntro") && template.contains("skySignUpCodeIgnore"), mail);
        }
    }

    private static String resource(String path) throws IOException {
        try (InputStream in = EmailCodeMessagesTest.class.getResourceAsStream(path)) {
            assertNotNull(in, path);
            return new String(in.readAllBytes(), StandardCharsets.UTF_8);
        }
    }

    @Test
    void theCodeBoxTakesAWholeCodeWithItsSpacesAndOffersTheMailedOne() throws IOException {
        String page;
        try (InputStream in = EmailCodeMessagesTest.class.getResourceAsStream("/theme-resources/templates/sky-email-code.ftl")) {
            assertNotNull(in);
            page = new String(in.readAllBytes(), StandardCharsets.UTF_8);
        }
        String box = page.substring(page.indexOf("<input id=\"sky-email-code\""));
        box = box.substring(0, box.indexOf("/>"));
        assertTrue(box.contains("inputmode=\"numeric\""), box);
        assertTrue(box.contains("autocomplete=\"one-time-code\""), box);
        assertTrue(box.contains("maxlength=\"" + LoginCodes.MAX_CODE_INPUT_LENGTH + "\""), box);
        for (String locale : new String[] {"tr", "en"}) {
            Properties properties = messages(locale);
            assertTrue(properties.getProperty("emailCodeError.malformed_code").contains("8"), locale);
            assertFalse(properties.getProperty("sky-email-code-help-text").matches(".*\\b6\\b.*|.*six.*"), locale);
        }
    }
}
