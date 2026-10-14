package com.skylab.account;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.util.Properties;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;

/** Every error the e-mail code page can show has its sentence in both languages of the fallback page. */
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
}
