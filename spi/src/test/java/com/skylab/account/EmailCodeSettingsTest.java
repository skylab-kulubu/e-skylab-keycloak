package com.skylab.account;

import org.junit.jupiter.api.Test;
import org.keycloak.authentication.AuthenticationFlowCallbackFactory;
import org.keycloak.authentication.AuthenticatorFactory;
import org.keycloak.models.AuthenticationExecutionModel;

import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

class EmailCodeSettingsTest {

    @Test
    void defaultsToFiveHundredCodesADayAndNoAlarmAddress() {
        EmailCodeSettings settings = EmailCodeSettings.from(null, Map.of());

        assertEquals(500, settings.dailyLimit());
        assertNull(settings.alarmEmail());
        assertEquals(LoginIdentifiers.ytuIdpAlias(null), settings.ytuIdpAlias());
    }

    @Test
    void readsTheLimitAndTheAlarmAddressFromTheEnvironment() {
        EmailCodeSettings settings = EmailCodeSettings.from("YTU", Map.of(
                EmailCodeSettings.DAILY_LIMIT_ENV, " 40 ",
                EmailCodeSettings.ALARM_EMAIL_ENV, " ops@example.org "));

        assertEquals(40, settings.dailyLimit());
        assertEquals("ops@example.org", settings.alarmEmail());
        assertEquals("YTU", settings.ytuIdpAlias());
    }

    // A typo in an optional setting must not keep Keycloak from starting: the default stands.
    @Test
    void aMalformedValueFallsBackToItsDefault() {
        for (String limit : List.of("many", "0", "-3", "100001", "5.5")) {
            assertEquals(500, EmailCodeSettings.from(null, Map.of(EmailCodeSettings.DAILY_LIMIT_ENV, limit)).dailyLimit(), limit);
        }
        for (String address : List.of("ops", "ops@", "@example.org", "ops@a@b", "ops @example.org")) {
            assertNull(EmailCodeSettings.from(null, Map.of(EmailCodeSettings.ALARM_EMAIL_ENV, address)).alarmEmail(), address);
        }
    }

    @Test
    void theFactoryOffersTheStepForASubflowAndHearsWhenItSucceeds() {
        EmailCodeAuthenticatorFactory factory = new EmailCodeAuthenticatorFactory();

        assertEquals("sky-email-code", factory.getId());
        assertTrue(factory instanceof AuthenticationFlowCallbackFactory);
        assertTrue(factory instanceof AuthenticatorFactory);
        assertEquals(List.of(AuthenticationExecutionModel.Requirement.REQUIRED,
                        AuthenticationExecutionModel.Requirement.ALTERNATIVE,
                        AuthenticationExecutionModel.Requirement.DISABLED),
                List.of(factory.getRequirementChoices()));
        assertFalse(factory.isConfigurable());
        assertFalse(factory.isUserSetupAllowed());
        factory.init(null);
        assertEquals(500, factory.settings().dailyLimit());
    }

    // The overall alarm mail names only the realm and the counts.
    @Test
    void theAlarmTextHoldsNoPersonalData() {
        String half = BackgroundLoginCodeMail.alarmText("e-skylab", false, 500);
        String full = BackgroundLoginCodeMail.alarmText("e-skylab", true, 500);

        assertTrue(half.contains("250") && half.contains("500"), half);
        assertTrue(full.contains("500"), full);
        assertFalse(half.contains("@") || full.contains("@"));
        assertTrue(BackgroundLoginCodeMail.alarmSubject(true).contains("ulaştı"));
    }
}
