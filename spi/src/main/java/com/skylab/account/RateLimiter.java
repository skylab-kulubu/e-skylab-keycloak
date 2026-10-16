package com.skylab.account;

import org.keycloak.common.util.Time;
import org.keycloak.models.SingleUseObjectProvider;

/**
 * Per-user, per-endpoint fixed-window budgets kept in Keycloak's single-use object store,
 * so they are shared across cluster nodes and expire on their own.
 *
 * <p>A request claims one of {@code maxAttempts} slots of the current window with
 * {@link SingleUseObjectProvider#putIfAbsent}, which is atomic in Infinispan and applied
 * immediately (outside the request transaction): parallel requests cannot share a slot and a
 * refused attempt keeps its claim even when the response is an error. Every slot expires at
 * the end of its window, so the next window starts with a fresh budget.
 *
 * <p>The sky-handoff provider shares this limiter through {@link #claim}, which reports the wait
 * instead of throwing a sky-account problem; {@link #claimSlot} also says which hit of the window
 * a claim was, so an alarm can fire at exactly one of them.
 *
 * <p>The claimed slots of a window are always 1..n: every claim takes the lowest free slot at or
 * above the first free one it saw, and all of them expire together at the end of the window. A
 * claim therefore finds where to start by halving with {@link SingleUseObjectProvider#contains}
 * and claims from there, so a budget of hundreds per day stays a dozen store calls per request.
 */
public final class RateLimiter {

    /** A named budget: at most {@code maxAttempts} hits per {@code windowSeconds} window. */
    public record Limit(String name, int maxAttempts, int windowSeconds) {
    }

    static final Limit SUDO_EMAIL_SEND = new Limit("sudo-email-send", 3, 60 * 60);
    static final Limit SUDO = new Limit("sudo", 10, 15 * 60);
    /** Passkey assertions cannot be guessed, so they have their own budget instead of eating the password/TOTP one. */
    static final Limit SUDO_PASSKEY = new Limit("sudo-passkey", 10, 15 * 60);
    static final Limit SUDO_OPTIONS = new Limit("sudo-options", 30, 15 * 60);
    static final Limit TOTP_CONFIRM = new Limit("totp-confirm", 10, 15 * 60);
    static final Limit MUTATION = new Limit("mutation", 30, 15 * 60);
    /**
     * A change request sends mail to an address nobody proved yet, so it gets a much tighter
     * budget than the other mutations: three verification mails per person per hour.
     */
    static final Limit EMAIL_CHANGE = new Limit("email-change", 3, 60 * 60);
    /*
     * The Personal e-mail offer at the end of a first YTÜ login (PersonalEmailOffer) mails a code
     * to an address nobody proved yet as well, from a sign-in session instead of Account center, so
     * sending is limited per sign-in session, per address, per IP class and overall (ADR-0063's
     * Login code rules). Reaching the page at all takes a YTÜ Microsoft identity that never signed
     * in before, so the IP class and overall budgets leave room for a club fair on one campus network.
     * The windows are clock hours, so a session that spans the full hour may send 3 more.
     */
    static final Limit OFFER_SESSION = new Limit("offer-session", 3, 60 * 60);
    static final Limit OFFER_ADDRESS = new Limit("offer-address", 3, 60 * 60);
    static final Limit OFFER_IP_CLASS = new Limit("offer-ip-class", 100, 60 * 60);
    static final Limit OFFER_ALL = new Limit("offer-all", 200, 60 * 60);
    /*
     * The Login code of "E-postayla devam et" (eskylab-login-ux 08, spec §7.2): sending is limited per
     * sign-in session, per IP class, per address (a quarter of an hour and a day) and overall per
     * day (loginCodesPerDay; SKY_EMAIL_CODE_DAILY_LIMIT). The IP class budget leaves room for a club
     * fair on one campus network, as the offer's does; per address, at most ten codes a day reach
     * one mailbox, and with five tries each that would be fifty guesses at a 1-in-100-million code a
     * day; the per-account ceiling below cuts it to ten.
     */
    static final Limit LOGIN_CODE_SESSION = new Limit("login-code-session", 5, 60 * 60);
    static final Limit LOGIN_CODE_IP_CLASS = new Limit("login-code-ip-class", 100, 60 * 60);
    static final Limit LOGIN_CODE_ADDRESS = new Limit("login-code-address", 3, 15 * 60);
    static final Limit LOGIN_CODE_ADDRESS_DAY = new Limit("login-code-address-day", 10, 24 * 60 * 60);
    static final int LOGIN_CODES_PER_DAY = 500;
    /*
     * Security review K2 (Yusuf, 2026-10-15): wrong Login codes per account a day
     * (loginCodeWrongPerAccount; SKY_EMAIL_CODE_WRONG_CODES_PER_ACCOUNT, default 10), and how many
     * accounts reached that ceiling today, so the operator alarm goes once a day.
     */
    static final Limit LOGIN_CODE_CEILING_ACCOUNTS = new Limit("login-code-ceiling-accounts", 100_000, 24 * 60 * 60);

    private static final String KEY_PREFIX = "sky-account:rate:";

    private final SingleUseObjectProvider store;

    public RateLimiter(SingleUseObjectProvider store) {
        this.store = store;
    }

    /** Claims a slot for the user against the limit; throws the 429 problem when none is left. */
    void hit(Limit limit, String userId) {
        int retryAfterSeconds = claim(limit, userId);
        if (retryAfterSeconds > 0) {
            throw Problems.rateLimited(retryAfterSeconds).exception();
        }
    }

    /** The overall daily budget of Login codes, {@code perDay} of them. */
    static Limit loginCodesPerDay(int perDay) {
        return new Limit("login-code-all", perDay, 24 * 60 * 60);
    }

    /** The wrong Login codes one account may have in a day, {@code ceiling} of them. */
    static Limit loginCodeWrongPerAccount(int ceiling) {
        return new Limit("login-code-wrong-account", ceiling, 24 * 60 * 60);
    }

    /**
     * Whether the key's budget of the current window is used up, without claiming anything: the
     * claimed slots are always 1..n, so it is when the last one is taken.
     */
    boolean spent(Limit limit, String key) {
        return store.contains(prefix(limit, key, Time.currentTime()) + limit.maxAttempts());
    }

    /**
     * Claims a slot for the user against the limit.
     *
     * @return {@code 0} when a slot was claimed, otherwise the seconds until the window ends
     */
    public int claim(Limit limit, String userId) {
        return claimSlot(limit, userId) > 0 ? 0 : secondsLeftInWindow(limit, Time.currentTime());
    }

    /**
     * Claims a slot for the key against the limit.
     *
     * @return the slot claimed, from {@code 1} for the first hit of the window to
     *         {@code maxAttempts} for the last, or {@code 0} when none is left
     */
    int claimSlot(Limit limit, String key) {
        int now = Time.currentTime();
        int remainingSeconds = secondsLeftInWindow(limit, now);
        String prefix = prefix(limit, key, now);
        int low = 1;
        int high = limit.maxAttempts() + 1;
        while (low < high) {
            int middle = (low + high) >>> 1;
            if (store.contains(prefix + middle)) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        for (int slot = low; slot <= limit.maxAttempts(); slot++) {
            if (store.putIfAbsent(prefix + slot, remainingSeconds)) {
                return slot;
            }
        }
        return 0;
    }

    private static String prefix(Limit limit, String key, int now) {
        return KEY_PREFIX + limit.name() + ":" + key + ":" + (now / limit.windowSeconds()) + ":";
    }

    private static int secondsLeftInWindow(Limit limit, int now) {
        long windowEnd = (now / limit.windowSeconds() + 1) * limit.windowSeconds();
        return (int) Math.max(1, windowEnd - now);
    }
}
