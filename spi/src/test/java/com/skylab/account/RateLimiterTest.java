package com.skylab.account;

import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.keycloak.common.util.Time;
import org.keycloak.models.SingleUseObjectProvider;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.atomic.AtomicInteger;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class RateLimiterTest {

    private static final RateLimiter.Limit LIMIT = new RateLimiter.Limit("test", 3, 600);

    private final AtomicStore store = new AtomicStore();
    private final RateLimiter limiter = new RateLimiter(store);

    @AfterEach
    void resetClock() {
        Time.setOffset(0);
    }

    @Test
    void allowsTheBudgetThenAnswers429WithRetryAfterUntilTheWindowEnds() {
        Time.setOffset(-(Time.currentTime() % 600)); // align to the start of a window
        limiter.hit(LIMIT, "user-a");
        limiter.hit(LIMIT, "user-a");
        limiter.hit(LIMIT, "user-a");

        ProblemException exception = assertThrows(ProblemException.class, () -> limiter.hit(LIMIT, "user-a"));
        assertEquals(429, exception.problem().status());
        assertEquals("rate_limited", exception.problem().code());
        int retryAfter = (Integer) exception.problem().extensions().get("retryAfter");
        assertTrue(retryAfter >= 598 && retryAfter <= 600, "retryAfter must point at the end of the window");
        assertEquals(3, store.claimed("sky-account:rate:test:user-a:" + (Time.currentTime() / 600) + ":"));
        store.lifespans().forEach(lifespan ->
                assertTrue(Math.abs(lifespan - retryAfter) <= 1, "every slot expires with its window"));
    }

    @Test
    void parallelRequestsCannotShareASlot() throws Exception {
        RateLimiter.Limit limit = new RateLimiter.Limit("parallel", 10, 600);
        int requests = 50;
        ExecutorService pool = Executors.newFixedThreadPool(requests);
        try {
            CountDownLatch start = new CountDownLatch(1);
            AtomicInteger admitted = new AtomicInteger();
            AtomicInteger refused = new AtomicInteger();
            List<Future<?>> futures = new ArrayList<>();
            for (int i = 0; i < requests; i++) {
                futures.add(pool.submit(() -> {
                    start.await();
                    try {
                        limiter.hit(limit, "user-a");
                        admitted.incrementAndGet();
                    } catch (ProblemException exception) {
                        assertEquals(429, exception.problem().status());
                        refused.incrementAndGet();
                    }
                    return null;
                }));
            }
            start.countDown();
            for (Future<?> future : futures) {
                future.get();
            }
            assertEquals(10, admitted.get(), "exactly the budget is admitted");
            assertEquals(40, refused.get());
            assertEquals(10, store.claimed("sky-account:rate:parallel:user-a:"));
        } finally {
            pool.shutdownNow();
        }
    }

    @Test
    void countsUsersAndEndpointsSeparately() {
        RateLimiter.Limit other = new RateLimiter.Limit("other", 1, 600);
        limiter.hit(LIMIT, "user-a");
        limiter.hit(LIMIT, "user-a");
        limiter.hit(LIMIT, "user-a");

        limiter.hit(LIMIT, "user-b");
        limiter.hit(other, "user-a");
        assertThrows(ProblemException.class, () -> limiter.hit(other, "user-a"));
        assertThrows(ProblemException.class, () -> limiter.hit(LIMIT, "user-a"));
    }

    @Test
    void passkeyProofsHaveTheirOwnBudgetNextToPasswordAndTotpProofs() {
        for (int attempt = 0; attempt < RateLimiter.SUDO.maxAttempts(); attempt++) {
            limiter.hit(RateLimiter.SUDO, "user-a");
        }
        assertThrows(ProblemException.class, () -> limiter.hit(RateLimiter.SUDO, "user-a"));

        limiter.hit(RateLimiter.SUDO_PASSKEY, "user-a");
        limiter.hit(RateLimiter.SUDO_OPTIONS, "user-a");
        assertEquals(RateLimiter.SUDO.maxAttempts(), RateLimiter.SUDO_PASSKEY.maxAttempts());
        assertEquals(RateLimiter.SUDO.windowSeconds(), RateLimiter.SUDO_PASSKEY.windowSeconds());
    }

    @Test
    void claimReportsTheWaitUntilTheWindowEndsInsteadOfThrowing() {
        Time.setOffset(-(Time.currentTime() % 600)); // align to the start of a window
        assertEquals(0, limiter.claim(LIMIT, "user-c"));
        assertEquals(0, limiter.claim(LIMIT, "user-c"));
        assertEquals(0, limiter.claim(LIMIT, "user-c"));

        int retryAfter = limiter.claim(LIMIT, "user-c");
        assertTrue(retryAfter >= 598 && retryAfter <= 600, "the wait points at the end of the window");
        assertThrows(ProblemException.class, () -> limiter.hit(LIMIT, "user-c"), "hit and claim share one budget");
    }

    @Test
    void startsAFreshBudgetInTheNextWindow() {
        limiter.hit(LIMIT, "user-a");
        limiter.hit(LIMIT, "user-a");
        limiter.hit(LIMIT, "user-a");
        assertThrows(ProblemException.class, () -> limiter.hit(LIMIT, "user-a"));

        Time.setOffset(600);
        limiter.hit(LIMIT, "user-a");
    }

    // The Login code's overall budget alarms the operator at exactly one hit of the day (eskylab-login-ux
    // 08): the slot number says which hit a claim was, and no two claims of a window get the same one.
    @Test
    void claimSlotNumbersTheHitsOfAWindowAndAnswersZeroWhenNoneIsLeft() {
        Time.setOffset(-(Time.currentTime() % 600));
        assertEquals(1, limiter.claimSlot(LIMIT, "user-d"));
        assertEquals(2, limiter.claimSlot(LIMIT, "user-d"));
        assertEquals(3, limiter.claimSlot(LIMIT, "user-d"));
        assertEquals(0, limiter.claimSlot(LIMIT, "user-d"));
        assertTrue(limiter.claim(LIMIT, "user-d") > 0, "claim and claimSlot share one budget");

        Time.setOffset(Time.getOffset() + 600);
        assertEquals(1, limiter.claimSlot(LIMIT, "user-d"), "the next window counts from one again");
    }

    @Test
    void parallelClaimsGetEverySlotNumberExactlyOnce() throws Exception {
        RateLimiter.Limit limit = new RateLimiter.Limit("numbered", 10, 600);
        int requests = 40;
        ExecutorService pool = Executors.newFixedThreadPool(requests);
        try {
            CountDownLatch start = new CountDownLatch(1);
            List<Future<Integer>> futures = new ArrayList<>();
            for (int i = 0; i < requests; i++) {
                futures.add(pool.submit(() -> {
                    start.await();
                    return limiter.claimSlot(limit, "everybody");
                }));
            }
            start.countDown();
            List<Integer> slots = new ArrayList<>();
            for (Future<Integer> future : futures) {
                slots.add(future.get());
            }
            assertEquals(30, slots.stream().filter(slot -> slot == 0).count(), "everything past the budget is refused");
            assertEquals(List.of(1, 2, 3, 4, 5, 6, 7, 8, 9, 10),
                    slots.stream().filter(slot -> slot > 0).sorted().toList(), "each slot number is handed out once");
        } finally {
            pool.shutdownNow();
        }
    }

    // A day's overall budget has hundreds of slots; a claim late in the day must not walk all of
    // them (the claimed slots are always 1..n, so it looks for the first free one by halving).
    @Test
    void aClaimLateInALargeWindowLooksAtFewSlots() {
        RateLimiter.Limit large = new RateLimiter.Limit("large", 500, 24 * 60 * 60);
        for (int i = 1; i <= 400; i++) {
            assertEquals(i, limiter.claimSlot(large, "realm"));
        }
        store.resetCalls();
        assertEquals(401, limiter.claimSlot(large, "realm"));
        assertTrue(store.calls() <= 12, "a claim looked at " + store.calls() + " slots");
    }

    @Test
    void theLoginCodeBudgetsFollowTheSpec() {
        assertEquals(new RateLimiter.Limit("login-code-session", 5, 60 * 60), RateLimiter.LOGIN_CODE_SESSION);
        assertEquals(new RateLimiter.Limit("login-code-ip-class", 100, 60 * 60), RateLimiter.LOGIN_CODE_IP_CLASS);
        assertEquals(new RateLimiter.Limit("login-code-address", 3, 15 * 60), RateLimiter.LOGIN_CODE_ADDRESS);
        assertEquals(new RateLimiter.Limit("login-code-address-day", 10, 24 * 60 * 60), RateLimiter.LOGIN_CODE_ADDRESS_DAY);
        assertEquals(24 * 60 * 60, RateLimiter.loginCodesPerDay(500).windowSeconds());
        assertEquals(new RateLimiter.Limit("login-code-all", 500, 24 * 60 * 60), RateLimiter.loginCodesPerDay(500));
        // Security review K2: wrong codes per account a day, and the accounts that reached it.
        assertEquals(new RateLimiter.Limit("login-code-wrong-account", 10, 24 * 60 * 60),
                RateLimiter.loginCodeWrongPerAccount(10));
        assertEquals(new RateLimiter.Limit("login-code-ceiling-accounts", 100_000, 24 * 60 * 60),
                RateLimiter.LOGIN_CODE_CEILING_ACCOUNTS);
    }

    @Test
    void aBudgetIsSpentOnceItsLastSlotIsTakenAndLookingDoesNotSpendIt() {
        Time.setOffset(-(Time.currentTime() % 600));
        assertFalse(limiter.spent(LIMIT, "user-e"));
        limiter.claimSlot(LIMIT, "user-e");
        limiter.claimSlot(LIMIT, "user-e");
        assertFalse(limiter.spent(LIMIT, "user-e"));
        assertFalse(limiter.spent(LIMIT, "user-e"), "looking claims nothing");
        assertEquals(3, limiter.claimSlot(LIMIT, "user-e"));
        assertTrue(limiter.spent(LIMIT, "user-e"));
        assertFalse(limiter.spent(LIMIT, "user-f"));

        Time.setOffset(Time.getOffset() + 600);
        assertFalse(limiter.spent(LIMIT, "user-e"), "the next window starts unspent");
    }

    /** Honours putIfAbsent exactly like Infinispan: atomic, first claim wins, lifespan kept. */
    private static final class AtomicStore implements SingleUseObjectProvider {
        private final ConcurrentHashMap<String, Long> entries = new ConcurrentHashMap<>();
        private final AtomicInteger calls = new AtomicInteger();

        void resetCalls() {
            calls.set(0);
        }

        int calls() {
            return calls.get();
        }

        long claimed(String prefix) {
            return entries.keySet().stream().filter(key -> key.startsWith(prefix)).count();
        }

        List<Long> lifespans() {
            return new ArrayList<>(entries.values());
        }

        @Override
        public boolean putIfAbsent(String key, long lifespanInSeconds) {
            calls.incrementAndGet();
            if (lifespanInSeconds <= 0) {
                throw new IllegalArgumentException("lifespan must be positive");
            }
            return entries.putIfAbsent(key, lifespanInSeconds) == null;
        }

        @Override
        public void put(String key, long lifespanSeconds, Map<String, String> notes) {
            throw new UnsupportedOperationException("the limiter must only claim slots atomically");
        }

        @Override
        public Map<String, String> get(String key) {
            throw new UnsupportedOperationException("the limiter must only claim slots atomically");
        }

        @Override
        public Map<String, String> remove(String key) {
            throw new UnsupportedOperationException();
        }

        @Override
        public boolean replace(String key, Map<String, String> notes) {
            throw new UnsupportedOperationException();
        }

        @Override
        public boolean contains(String key) {
            calls.incrementAndGet();
            return entries.containsKey(key);
        }

        @Override
        public void close() {
            // no-op
        }
    }

    @Test
    void theChangeRequestBudgetIsThreeMailsPerHour() {
        assertEquals("email-change", RateLimiter.EMAIL_CHANGE.name());
        assertEquals(3, RateLimiter.EMAIL_CHANGE.maxAttempts());
        assertEquals(3600, RateLimiter.EMAIL_CHANGE.windowSeconds());
    }
}
