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
 * its sentence in both languages, and the code box takes a whole six-digit code.
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
            assertTrue(properties.getProperty("emailCodeError.malformed_code").contains("6"), locale);
            assertFalse(properties.getProperty("sky-email-code-help-text").matches(".*\\b8\\b.*|.*eight.*"), locale);
        }
    }
}
