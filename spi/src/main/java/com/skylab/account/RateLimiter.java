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
 */
final class RateLimiter {

    /** A named budget: at most {@code maxAttempts} hits per {@code windowSeconds} window. */
    record Limit(String name, int maxAttempts, int windowSeconds) {
    }

    static final Limit SUDO = new Limit("sudo", 10, 15 * 60);
    /** Passkey assertions cannot be guessed, so they have their own budget instead of eating the password/TOTP one. */
    static final Limit SUDO_PASSKEY = new Limit("sudo-passkey", 10, 15 * 60);
    static final Limit SUDO_OPTIONS = new Limit("sudo-options", 30, 15 * 60);
    static final Limit TOTP_CONFIRM = new Limit("totp-confirm", 10, 15 * 60);
    static final Limit MUTATION = new Limit("mutation", 30, 15 * 60);

    private static final String KEY_PREFIX = "sky-account:rate:";

    private final SingleUseObjectProvider store;

    RateLimiter(SingleUseObjectProvider store) {
        this.store = store;
    }

    /** Claims a slot for the user against the limit; throws the 429 problem when none is left. */
    void hit(Limit limit, String userId) {
        int now = Time.currentTime();
        long window = now / limit.windowSeconds();
        long windowEnd = (window + 1) * limit.windowSeconds();
        int remainingSeconds = (int) Math.max(1, windowEnd - now);
        String prefix = KEY_PREFIX + limit.name() + ":" + userId + ":" + window + ":";
        for (int slot = 1; slot <= limit.maxAttempts(); slot++) {
            if (store.putIfAbsent(prefix + slot, remainingSeconds)) {
                return;
            }
        }
        throw Problems.rateLimited(remainingSeconds).exception();
    }
}
