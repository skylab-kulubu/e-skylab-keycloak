package com.skylab.account;

import org.jboss.logging.Logger;

import java.util.Map;
import java.util.regex.Pattern;

/**
 * The operator settings of "E-postayla devam et" ({@link EmailCodeAuthenticatorFactory}), read once
 * at start-up.
 *
 * @param ytuIdpAlias the YTÜ identity provider's alias: a School e-mail is a sign-in identifier
 *                    and a code destination only while the account has this link
 * @param dailyLimit  the realm's Login codes a day before the operator alarm says "full"
 *                    ({@code SKY_EMAIL_CODE_DAILY_LIMIT}, default {@value #DEFAULT_DAILY_LIMIT});
 *                    the alarm says "half" at half of it. Sign-in codes still go past it.
 * @param alarmEmail  who gets the alarm ({@code SKY_EMAIL_CODE_ALARM_EMAIL}); without one the
 *                    alarm is a log line only
 */
record EmailCodeSettings(String ytuIdpAlias, int dailyLimit, String alarmEmail) {

    static final String DAILY_LIMIT_ENV = "SKY_EMAIL_CODE_DAILY_LIMIT";
    static final String ALARM_EMAIL_ENV = "SKY_EMAIL_CODE_ALARM_EMAIL";
    static final int DEFAULT_DAILY_LIMIT = RateLimiter.LOGIN_CODES_PER_DAY;
    static final int MAX_DAILY_LIMIT = 100_000;

    private static final Logger LOG = Logger.getLogger(EmailCodeSettings.class);
    private static final Pattern ADDRESS = Pattern.compile("^[^@\\s]{1,64}@[^@\\s]{1,190}$");

    /**
     * The settings from the environment. A malformed value is reported once with a fixed word and
     * replaced by its default (no limit override, no alarm address): a typo in an optional setting
     * must not keep Keycloak from starting.
     */
    static EmailCodeSettings from(String configuredYtuIdpAlias, Map<String, String> environment) {
        int dailyLimit = DEFAULT_DAILY_LIMIT;
        String limit = trimmed(environment.get(DAILY_LIMIT_ENV));
        if (limit != null) {
            try {
                dailyLimit = Integer.parseInt(limit);
            } catch (NumberFormatException malformed) {
                dailyLimit = -1;
            }
            if (dailyLimit < 1 || dailyLimit > MAX_DAILY_LIMIT) {
                LOG.warnf("sky_email_code_config reason=daily_limit_invalid default=%d", DEFAULT_DAILY_LIMIT);
                dailyLimit = DEFAULT_DAILY_LIMIT;
            }
        }
        String alarmEmail = trimmed(environment.get(ALARM_EMAIL_ENV));
        if (alarmEmail != null && !ADDRESS.matcher(alarmEmail).matches()) {
            LOG.warn("sky_email_code_config reason=alarm_email_invalid");
            alarmEmail = null;
        }
        return new EmailCodeSettings(LoginIdentifiers.ytuIdpAlias(configuredYtuIdpAlias), dailyLimit, alarmEmail);
    }

    private static String trimmed(String value) {
        return value == null || value.isBlank() ? null : value.trim();
    }
}
