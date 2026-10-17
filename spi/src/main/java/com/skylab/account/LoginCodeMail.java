package com.skylab.account;

import org.keycloak.authentication.AuthenticationFlowContext;
import org.keycloak.models.UserModel;

/**
 * What {@link EmailCodeAuthenticator} mails. The real one ({@link BackgroundLoginCodeMail}) sends
 * after the request, in the background, so the page answers in the same time whether or not a mail
 * goes out (spec §7.4); a unit test keeps what it was handed.
 */
interface LoginCodeMail {

    /** The overall daily budget reached its half. */
    String HALF = "half";
    /** The overall daily budget was used up. */
    String FULL = "full";

    /**
     * Mails {@code code} to {@code address} for {@code user}. {@code purpose} is what the code is
     * for ({@code login} here; {@code link} in a later ticket; {@code signup} is
     * {@link #sendSignUpCode}), so the mail can say it. Never throws: a mail that cannot be sent is
     * logged by user id only.
     */
    void sendCode(AuthenticationFlowContext context, UserModel user, String address, String code, String purpose);

    /**
     * Mails a sign-up code (Self-registration, eskylab-login-ux 09) to {@code address}, which has no
     * account: purpose {@code signup}, in the language of the request that asked for it. Never
     * throws: a mail that cannot be sent is logged with a fixed word only.
     */
    void sendSignUpCode(AuthenticationFlowContext context, String address, String code);

    /**
     * Tells the operator that the realm's Login codes reached {@code level} ({@link #HALF} or
     * {@link #FULL}) of {@code dailyLimit} today. Never throws.
     */
    void alarm(AuthenticationFlowContext context, String level, int dailyLimit);

    /**
     * Tells the operator that an account reached the day's ceiling of {@code ceiling} wrong codes,
     * the {@code accounts}-th today (security review K2). No person, no address. Never throws.
     */
    void ceilingAlarm(AuthenticationFlowContext context, int ceiling, int accounts);

    /** One account reached the persistent consecutive limit; deliver only after this transaction commits. */
    void consecutiveAlarm(AuthenticationFlowContext context, int limit);
}
