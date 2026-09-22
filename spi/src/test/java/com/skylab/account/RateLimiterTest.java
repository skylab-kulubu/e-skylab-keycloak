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
    void startsAFreshBudgetInTheNextWindow() {
        limiter.hit(LIMIT, "user-a");
        limiter.hit(LIMIT, "user-a");
        limiter.hit(LIMIT, "user-a");
        assertThrows(ProblemException.class, () -> limiter.hit(LIMIT, "user-a"));

        Time.setOffset(600);
        limiter.hit(LIMIT, "user-a");
    }

    /** Honours putIfAbsent exactly like Infinispan: atomic, first claim wins, lifespan kept. */
    private static final class AtomicStore implements SingleUseObjectProvider {
        private final ConcurrentHashMap<String, Long> entries = new ConcurrentHashMap<>();

        long claimed(String prefix) {
            return entries.keySet().stream().filter(key -> key.startsWith(prefix)).count();
        }

        List<Long> lifespans() {
            return new ArrayList<>(entries.values());
        }

        @Override
        public boolean putIfAbsent(String key, long lifespanInSeconds) {
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
            return entries.containsKey(key);
        }

        @Override
        public void close() {
            // no-op
        }
    }
}
