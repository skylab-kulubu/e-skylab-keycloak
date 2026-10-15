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
 * @param alarmGroup  the group whose members get the alarm ({@code SKY_EMAIL_CODE_ALARM_GROUP}, a
 *                    group path, default {@value #DEFAULT_ALARM_GROUP}: the administrators, Yusuf's
 *                    decision of 2026-10-15); {@code null} ({@code off}) leaves the alarm a log line
 * @param wrongCodesPerAccount the wrong Login codes one account may have in a (UTC) day
 *                    ({@code SKY_EMAIL_CODE_WRONG_CODES_PER_ACCOUNT}, 1 to
 *                    {@value #MAX_WRONG_CODES_PER_ACCOUNT}, default
 *                    {@value #DEFAULT_WRONG_CODES_PER_ACCOUNT}; security review K2, Yusuf's decision
 *                    of 2026-10-15): past it the account gets no code by mail that day
 */
record EmailCodeSettings(String ytuIdpAlias, int dailyLimit, String alarmGroup, int wrongCodesPerAccount) {

    static final String DAILY_LIMIT_ENV = "SKY_EMAIL_CODE_DAILY_LIMIT";
    static final String ALARM_GROUP_ENV = "SKY_EMAIL_CODE_ALARM_GROUP";
    static final String WRONG_CODES_PER_ACCOUNT_ENV = "SKY_EMAIL_CODE_WRONG_CODES_PER_ACCOUNT";
    static final int DEFAULT_WRONG_CODES_PER_ACCOUNT = 10;
    static final int MAX_WRONG_CODES_PER_ACCOUNT = 1000;
    static final String DEFAULT_ALARM_GROUP = "/ADMIN";
    static final String ALARM_OFF = "off";
    static final int DEFAULT_DAILY_LIMIT = RateLimiter.LOGIN_CODES_PER_DAY;
    static final int MAX_DAILY_LIMIT = 100_000;

    private static final Logger LOG = Logger.getLogger(EmailCodeSettings.class);
    /** A group path: segments of printable characters other than a slash, at most 255 in all. */
    private static final Pattern GROUP_PATH = Pattern.compile("^(/[^/\\p{Cntrl}]+)+$");

    /**
     * The settings from the environment. A malformed value is reported once with a fixed word and
     * replaced by its default: a typo in an optional setting must not keep Keycloak from starting.
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
        int wrongCodesPerAccount = DEFAULT_WRONG_CODES_PER_ACCOUNT;
        String ceiling = trimmed(environment.get(WRONG_CODES_PER_ACCOUNT_ENV));
        if (ceiling != null) {
            try {
                wrongCodesPerAccount = Integer.parseInt(ceiling);
            } catch (NumberFormatException malformed) {
                wrongCodesPerAccount = -1;
            }
            if (wrongCodesPerAccount < 1 || wrongCodesPerAccount > MAX_WRONG_CODES_PER_ACCOUNT) {
                LOG.warnf("sky_email_code_config reason=wrong_codes_per_account_invalid default=%d",
                        DEFAULT_WRONG_CODES_PER_ACCOUNT);
                wrongCodesPerAccount = DEFAULT_WRONG_CODES_PER_ACCOUNT;
            }
        }
        String alarmGroup = trimmed(environment.get(ALARM_GROUP_ENV));
        if (alarmGroup == null) {
            alarmGroup = DEFAULT_ALARM_GROUP;
        } else if (ALARM_OFF.equalsIgnoreCase(alarmGroup)) {
            alarmGroup = null;
        } else if (alarmGroup.length() > 255 || !GROUP_PATH.matcher(alarmGroup).matches()) {
            LOG.warnf("sky_email_code_config reason=alarm_group_invalid default=%s", DEFAULT_ALARM_GROUP);
            alarmGroup = DEFAULT_ALARM_GROUP;
        }
        return new EmailCodeSettings(LoginIdentifiers.ytuIdpAlias(configuredYtuIdpAlias), dailyLimit, alarmGroup,
                wrongCodesPerAccount);
    }

    private static String trimmed(String value) {
        return value == null || value.isBlank() ? null : value.trim();
    }
}
