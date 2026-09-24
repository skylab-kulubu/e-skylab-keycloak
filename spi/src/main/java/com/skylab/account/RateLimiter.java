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
 * instead of throwing a sky-account problem.
 */
public final class RateLimiter {

    /** A named budget: at most {@code maxAttempts} hits per {@code windowSeconds} window. */
    public record Limit(String name, int maxAttempts, int windowSeconds) {
    }

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

    /**
     * Claims a slot for the user against the limit.
     *
     * @return {@code 0} when a slot was claimed, otherwise the seconds until the window ends
     */
    public int claim(Limit limit, String userId) {
        int now = Time.currentTime();
        long window = now / limit.windowSeconds();
        long windowEnd = (window + 1) * limit.windowSeconds();
        int remainingSeconds = (int) Math.max(1, windowEnd - now);
        String prefix = KEY_PREFIX + limit.name() + ":" + userId + ":" + window + ":";
        for (int slot = 1; slot <= limit.maxAttempts(); slot++) {
            if (store.putIfAbsent(prefix + slot, remainingSeconds)) {
                return 0;
            }
        }
        return remainingSeconds;
    }
}
