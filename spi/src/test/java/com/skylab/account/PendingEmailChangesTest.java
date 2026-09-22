package com.skylab.account;

import com.skylab.account.PendingEmailChanges.Outcome;
import com.skylab.account.PendingEmailChanges.Pending;
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
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

class PendingEmailChangesTest {

    private final AtomicStore store = new AtomicStore();
    private final PendingEmailChanges pending = new PendingEmailChanges(store);

    @AfterEach
    void resetClock() {
        Time.setOffset(0);
    }

    @Test
    void issuesASixDigitCodeAndKeepsOnlyASaltedHashOfItForTenMinutes() {
        String code = pending.issue("user-a", "ada@example.com", true);

        assertTrue(PendingEmailChanges.CODE.matcher(code).matches(), "the code must be six digits");
        assertEquals(PendingEmailChanges.TTL_SECONDS, store.lifespanOf(PendingEmailChanges.key("user-a")));
        assertEquals(10 * 60, PendingEmailChanges.TTL_SECONDS);
        Map<String, String> stored = store.get(PendingEmailChanges.key("user-a"));
        assertTrue(stored.values().stream().noneMatch(value -> value.contains(code)),
                "the store must not hold the code itself");
    }

    @Test
    void theRightCodeConfirmsTheChangeOnce() {
        String code = pending.issue("user-a", "ada@example.com", true);

        assertEquals(Outcome.confirmed(new Pending("ada@example.com", true)), pending.confirm("user-a", code));
        assertEquals(Outcome.none(), pending.confirm("user-a", code), "a code must not work twice");
    }

    // The code is only ever checked against the pending change of the person asking, so it
    // cannot attach an address to anybody else's account, whoever reads it.
    @Test
    void aCodeOnlyWorksForThePersonWhoAskedForIt() {
        String code = pending.issue("user-a", "ada@example.com", false);

        assertEquals(Outcome.none(), pending.confirm("user-b", code));
        assertEquals(Outcome.confirmed(new Pending("ada@example.com", false)), pending.confirm("user-a", code),
                "another person's attempt must not touch this person's change");
    }

    @Test
    void aWrongCodeCostsOneAttemptAndKeepsTheChange() {
        String code = pending.issue("user-a", "ada@example.com", false);

        assertEquals(Outcome.wrongCode(PendingEmailChanges.MAX_ATTEMPTS - 1), pending.confirm("user-a", other(code)));
        assertEquals(Outcome.confirmed(new Pending("ada@example.com", false)), pending.confirm("user-a", code));
    }

    @Test
    void theLastWrongCodeKillsTheChange() {
        String code = pending.issue("user-a", "ada@example.com", false);

        for (int left = PendingEmailChanges.MAX_ATTEMPTS - 1; left >= 0; left--) {
            assertEquals(Outcome.wrongCode(left), pending.confirm("user-a", other(code)));
        }
        assertEquals(Outcome.none(), pending.confirm("user-a", code), "the right code must not work after the last try");
        assertEquals(5, PendingEmailChanges.MAX_ATTEMPTS);
    }

    @Test
    void aNewRequestReplacesThePreviousCode() {
        String first = pending.issue("user-a", "old@example.com", false);
        String second = pending.issue("user-a", "new@example.com", true);

        if (!first.equals(second)) {
            assertEquals(Outcome.wrongCode(PendingEmailChanges.MAX_ATTEMPTS - 1), pending.confirm("user-a", first));
        }
        assertEquals(Outcome.confirmed(new Pending("new@example.com", true)), pending.confirm("user-a", second));
    }

    @Test
    void aCodeOlderThanTenMinutesNoLongerWorks() {
        String code = pending.issue("user-a", "ada@example.com", false);

        Time.setOffset(PendingEmailChanges.TTL_SECONDS + 1);
        assertEquals(Outcome.none(), pending.confirm("user-a", code));
    }

    @Test
    void aCodeStillWorksJustBeforeItsTenMinutesAreUp() {
        String code = pending.issue("user-a", "ada@example.com", false);

        Time.setOffset(PendingEmailChanges.TTL_SECONDS - 1);
        assertEquals(Outcome.confirmed(new Pending("ada@example.com", false)), pending.confirm("user-a", code));
    }

    // A wrong attempt puts the change back for what is left of its ten minutes, not for a
    // fresh ten minutes, or guessing slowly would keep a change alive forever.
    @Test
    void aWrongAttemptDoesNotExtendTheDeadline() {
        String code = pending.issue("user-a", "ada@example.com", false);

        Time.setOffset(PendingEmailChanges.TTL_SECONDS - 60);
        pending.confirm("user-a", other(code));
        assertTrue(store.lifespanOf(PendingEmailChanges.key("user-a")) <= 60,
                "the store must keep the change only for the time it had left");
        Time.setOffset(PendingEmailChanges.TTL_SECONDS + 1);
        assertEquals(Outcome.none(), pending.confirm("user-a", code));
    }

    @Test
    void parallelConfirmationsOfOneCodeLeaveExactlyOneWinner() throws Exception {
        String code = pending.issue("user-a", "ada@example.com", false);
        int callers = 32;
        CountDownLatch start = new CountDownLatch(1);
        AtomicInteger winners = new AtomicInteger();
        ExecutorService pool = Executors.newFixedThreadPool(callers);
        try {
            List<Future<?>> futures = new ArrayList<>();
            for (int i = 0; i < callers; i++) {
                futures.add(pool.submit(() -> {
                    start.await();
                    if (pending.confirm("user-a", code).status() == Outcome.Status.CONFIRMED) {
                        winners.incrementAndGet();
                    }
                    return null;
                }));
            }
            start.countDown();
            for (Future<?> future : futures) {
                future.get(10, TimeUnit.SECONDS);
            }
        } finally {
            pool.shutdownNow();
        }
        assertEquals(1, winners.get(), "exactly one confirmation may win");
    }

    @Test
    void malformedCodesAreRefusedWithoutTouchingTheChange() {
        String code = pending.issue("user-a", "ada@example.com", false);

        for (String malformed : new String[] {null, "", "12345", "1234567", "12a456", " 123456"}) {
            assertEquals(Outcome.none(), pending.confirm("user-a", malformed), String.valueOf(malformed));
        }
        assertEquals(Outcome.confirmed(new Pending("ada@example.com", false)), pending.confirm("user-a", code),
                "malformed input must not cost the person an attempt");
    }

    @Test
    void anIncompleteEntryFailsClosed() {
        String key = PendingEmailChanges.key("user-a");
        for (Map<String, String> broken : List.<Map<String, String>>of(
                Map.of("address", "ada@example.com", "attemptsLeft", "5", "salt", "s", "codeHash", "h"),
                Map.of("address", "ada@example.com", "expiresAt", "9999999999", "salt", "s", "codeHash", "h"),
                Map.of("expiresAt", "9999999999", "attemptsLeft", "5", "salt", "s", "codeHash", "h"),
                Map.of("address", "ada@example.com", "expiresAt", "soon", "attemptsLeft", "5", "salt", "s", "codeHash", "h"))) {
            store.put(key, 60, broken);
            assertEquals(Outcome.none(), pending.confirm("user-a", "123456"), broken.toString());
        }
    }

    @Test
    void discardingAFailedMailMakesTheCodeUseless() {
        String code = pending.issue("user-a", "ada@example.com", false);
        pending.discard("user-a");
        assertEquals(Outcome.none(), pending.confirm("user-a", code));
    }

    @Test
    void codesAreNotAllTheSame() {
        String first = pending.issue("user-a", "ada@example.com", false);
        boolean differs = false;
        for (int i = 0; i < 20 && !differs; i++) {
            differs = !first.equals(pending.issue("user-b", "bob@example.com", false));
        }
        assertTrue(differs, "codes must come from a random source");
        assertNotEquals(PendingEmailChanges.key("user-a"), PendingEmailChanges.key("user-b"));
    }

    /** A six-digit code that is certainly not {@code code}. */
    private static String other(String code) {
        return code.equals("000000") ? "000001" : "000000";
    }

    /** Honours put/remove exactly like Infinispan: remove hands the entry to one caller. */
    private static final class AtomicStore implements SingleUseObjectProvider {
        private final ConcurrentHashMap<String, Map<String, String>> entries = new ConcurrentHashMap<>();
        private final ConcurrentHashMap<String, Long> lifespans = new ConcurrentHashMap<>();

        List<String> keys() {
            return new ArrayList<>(entries.keySet());
        }

        long lifespanOf(String key) {
            return lifespans.getOrDefault(key, -1L);
        }

        @Override
        public void put(String key, long lifespanSeconds, Map<String, String> notes) {
            entries.put(key, Map.copyOf(notes));
            lifespans.put(key, lifespanSeconds);
        }

        @Override
        public Map<String, String> get(String key) {
            return entries.get(key);
        }

        @Override
        public Map<String, String> remove(String key) {
            lifespans.remove(key);
            return entries.remove(key);
        }

        @Override
        public boolean replace(String key, Map<String, String> notes) {
            throw new UnsupportedOperationException();
        }

        @Override
        public boolean putIfAbsent(String key, long lifespanInSeconds) {
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
