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

    // Yusuf's decision (2026-10-15): the alarm goes to the administrators, the members of /ADMIN.
    @Test
    void defaultsToFiveHundredCodesADayAndTheAdminGroup() {
        EmailCodeSettings settings = EmailCodeSettings.from(null, Map.of());

        assertEquals(500, settings.dailyLimit());
        assertEquals("/ADMIN", settings.alarmGroup());
        assertEquals(10, settings.wrongCodesPerAccount(), "security review K2: ten wrong codes per account a day");
        assertEquals(LoginIdentifiers.ytuIdpAlias(null), settings.ytuIdpAlias());
    }

    @Test
    void readsTheLimitAndTheAlarmGroupFromTheEnvironment() {
        EmailCodeSettings settings = EmailCodeSettings.from("YTU", Map.of(
                EmailCodeSettings.DAILY_LIMIT_ENV, " 40 ",
                EmailCodeSettings.ALARM_GROUP_ENV, " /UYELER/YK ",
                EmailCodeSettings.WRONG_CODES_PER_ACCOUNT_ENV, " 15 "));

        assertEquals(40, settings.dailyLimit());
        assertEquals(15, settings.wrongCodesPerAccount());
        assertEquals("/UYELER/YK", settings.alarmGroup());
        assertEquals("YTU", settings.ytuIdpAlias());
        assertNull(EmailCodeSettings.from(null, Map.of(EmailCodeSettings.ALARM_GROUP_ENV, "off")).alarmGroup(),
                "off leaves the alarm a log line");
    }

    // A typo in an optional setting must not keep Keycloak from starting: the default stands.
    @Test
    void aMalformedValueFallsBackToItsDefault() {
        for (String limit : List.of("many", "0", "-3", "100001", "5.5")) {
            assertEquals(500, EmailCodeSettings.from(null, Map.of(EmailCodeSettings.DAILY_LIMIT_ENV, limit)).dailyLimit(), limit);
        }
        for (String ceiling : List.of("many", "0", "-1", "1001", "2.5")) {
            assertEquals(10, EmailCodeSettings.from(null, Map.of(EmailCodeSettings.WRONG_CODES_PER_ACCOUNT_ENV, ceiling))
                    .wrongCodesPerAccount(), ceiling);
        }
        for (String group : List.of("ADMIN", "//", "/ADMIN\n", "ops@example.org")) {
            assertEquals("/ADMIN", EmailCodeSettings.from(null, Map.of(EmailCodeSettings.ALARM_GROUP_ENV, group)).alarmGroup(), group);
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
        assertFalse(factory.isUserSetupAllowed());
        factory.init(null);
        assertEquals(500, factory.settings().dailyLimit());
    }

    // Self-registration (eskylab-login-ux 09) is the execution's one setting, per realm, off by default.
    @Test
    void selfRegistrationIsTheStepsOneSettingAndOffByDefault() {
        EmailCodeAuthenticatorFactory factory = new EmailCodeAuthenticatorFactory();

        assertTrue(factory.isConfigurable());
        assertEquals(List.of("sign-up"), factory.getConfigProperties().stream().map(property -> property.getName()).toList());
        assertEquals("boolean", factory.getConfigProperties().get(0).getType());
        assertEquals("false", factory.getConfigProperties().get(0).getDefaultValue());
        assertFalse(EmailCodeSignUp.isOn((org.keycloak.models.AuthenticatorConfigModel) null));
        for (String value : List.of("", "false", "off", "yes", "1")) {
            assertFalse(EmailCodeSignUp.isOn(config(value)), value);
        }
        assertTrue(EmailCodeSignUp.isOn(config("true")));
        assertTrue(EmailCodeSignUp.isOn(config(" TRUE ")));
    }

    private static org.keycloak.models.AuthenticatorConfigModel config(String signUp) {
        org.keycloak.models.AuthenticatorConfigModel config = new org.keycloak.models.AuthenticatorConfigModel();
        config.setConfig(Map.of("sign-up", signUp));
        return config;
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

    // The ceiling alarm (security review K2) says how many accounts and the ceiling, nobody's name.
    @Test
    void theCeilingAlarmTextHoldsTheCountsAndNoPersonalData() {
        String text = BackgroundLoginCodeMail.ceilingText("e-skylab", 10, 1);

        assertTrue(text.contains("e-skylab") && text.contains("10") && text.contains("1 hesap"), text);
        assertTrue(text.contains("sky_email_code_wrong_ceiling"), "where the later accounts are counted");
        assertFalse(text.contains("@"));
        assertTrue(BackgroundLoginCodeMail.ceilingSubject().contains("tavan"));
    }
}
