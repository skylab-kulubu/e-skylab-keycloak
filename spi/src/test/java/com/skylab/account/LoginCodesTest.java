package com.skylab.account;

import com.skylab.account.LoginCodes.Outcome;
import com.skylab.account.LoginCodes.Pending;
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
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * The Login code store (eskylab-login-ux 08, CONTEXT "Login code"), in the shape of
 * {@link PendingEmailChangesTest}: an entry per sign-in session handle, holding whom the code signs
 * in and where it was mailed.
 */
class LoginCodesTest {

    private final AtomicStore store = new AtomicStore();
    private final LoginCodes codes = new LoginCodes(store);

    @AfterEach
    void resetClock() {
        Time.setOffset(0);
    }

    @Test
    void issuesASixDigitCodeAndKeepsOnlyASaltedHashOfItForTenMinutes() {
        String code = codes.issue("handle-a", "user-a", "ada@example.com");

        assertTrue(LoginCodes.CODE.matcher(code).matches(), "the code must be six digits");
        assertEquals(10 * 60, LoginCodes.TTL_SECONDS);
        assertEquals(LoginCodes.TTL_SECONDS, store.lifespanOf(LoginCodes.key("handle-a")));
        Map<String, String> stored = store.get(LoginCodes.key("handle-a"));
        assertTrue(stored.values().stream().noneMatch(value -> value.contains(code)),
                "the store must not hold the code itself");
    }

    @Test
    void theRightCodeSignsInThePersonItWasIssuedForOnce() {
        String code = codes.issue("handle-a", "user-a", "ada@example.com");

        assertEquals(Outcome.confirmed(new Pending("user-a", "ada@example.com")), codes.confirm("handle-a", code));
        assertEquals(Outcome.none(), codes.confirm("handle-a", code), "a code must not work twice");
    }

    // The handle lives in one sign-in session's authentication note: a code read from the mail
    // cannot be used from another browser or tab, which holds another handle or none.
    @Test
    void aCodeOnlyWorksUnderTheHandleOfTheSessionThatAskedForIt() {
        String code = codes.issue("handle-a", "user-a", "ada@example.com");

        assertEquals(Outcome.none(), codes.confirm("handle-b", code));
        assertEquals(Outcome.none(), codes.confirm(null, code));
        assertEquals(Outcome.confirmed(new Pending("user-a", "ada@example.com")), codes.confirm("handle-a", code),
                "another session's attempt must not touch this session's code");
    }

    @Test
    void aWrongCodeCostsOneAttemptAndKeepsTheCode() {
        String code = codes.issue("handle-a", "user-a", "ada@example.com");

        assertEquals(Outcome.wrongCode("user-a", LoginCodes.MAX_ATTEMPTS - 1), codes.confirm("handle-a", other(code)));
        assertEquals(Outcome.confirmed(new Pending("user-a", "ada@example.com")), codes.confirm("handle-a", code));
    }

    @Test
    void theFifthWrongCodeKillsTheCode() {
        String code = codes.issue("handle-a", "user-a", "ada@example.com");

        for (int left = LoginCodes.MAX_ATTEMPTS - 1; left >= 0; left--) {
            assertEquals(Outcome.wrongCode("user-a", left), codes.confirm("handle-a", other(code)));
        }
        assertEquals(5, LoginCodes.MAX_ATTEMPTS);
        assertEquals(Outcome.none(), codes.confirm("handle-a", code), "the right code must not work after the last try");
    }

    @Test
    void aNewCodeForTheSameHandleReplacesTheOldOne() {
        String first = codes.issue("handle-a", "user-a", "ada@example.com");
        String second = codes.issue("handle-a", "user-b", "bob@example.com");

        if (!first.equals(second)) {
            assertEquals(Outcome.wrongCode("user-b", LoginCodes.MAX_ATTEMPTS - 1), codes.confirm("handle-a", first));
        }
        assertEquals(Outcome.confirmed(new Pending("user-b", "bob@example.com")), codes.confirm("handle-a", second));
    }

    @Test
    void aCodeOlderThanTenMinutesNoLongerWorks() {
        String code = codes.issue("handle-a", "user-a", "ada@example.com");

        Time.setOffset(LoginCodes.TTL_SECONDS + 1);
        assertEquals(Outcome.none(), codes.confirm("handle-a", code));
        assertNull(codes.peek("handle-a"));
    }

    @Test
    void aWrongAttemptDoesNotExtendTheDeadline() {
        String code = codes.issue("handle-a", "user-a", "ada@example.com");

        Time.setOffset(LoginCodes.TTL_SECONDS - 60);
        codes.confirm("handle-a", other(code));
        assertTrue(store.lifespanOf(LoginCodes.key("handle-a")) <= 60,
                "the store must keep the code only for the time it had left");
        Time.setOffset(LoginCodes.TTL_SECONDS + 1);
        assertEquals(Outcome.none(), codes.confirm("handle-a", code));
    }

    @Test
    void malformedCodesAreRefusedWithoutCostingATry() {
        String code = codes.issue("handle-a", "user-a", "ada@example.com");

        for (String malformed : new String[] {null, "", "12345", "1234567", "12a456", " 123456"}) {
            assertEquals(Outcome.none(), codes.confirm("handle-a", malformed), String.valueOf(malformed));
        }
        assertEquals(LoginCodes.MAX_ATTEMPTS, codes.peek("handle-a").attemptsLeft());
        assertEquals(Outcome.confirmed(new Pending("user-a", "ada@example.com")), codes.confirm("handle-a", code));
    }

    // When the typed identifier names nobody, the session still gets a code page and a stored code,
    // so that the page, the store traffic and the tries look the same; that code is never mailed.
    @Test
    void aDecoyForNobodyBehavesLikeAnyOtherCode() {
        String code = codes.issue("handle-a", "", "");

        assertEquals("", codes.peek("handle-a").userId());
        assertEquals(Outcome.wrongCode("", LoginCodes.MAX_ATTEMPTS - 1), codes.confirm("handle-a", other(code)));
        assertEquals(Outcome.confirmed(new Pending("", "")), codes.confirm("handle-a", code));
    }

    @Test
    void peekingShowsWhoAndHowManyTriesAreLeftWithoutTheCodeOrTheAddress() {
        String code = codes.issue("handle-a", "user-a", "ada@example.com");

        LoginCodes.Waiting waiting = codes.peek("handle-a");
        assertEquals("user-a", waiting.userId());
        assertEquals(LoginCodes.MAX_ATTEMPTS, waiting.attemptsLeft());
        assertTrue(waiting.expiresAt() > Time.currentTime());
        assertFalse(waiting.toString().contains(code), "peeking must never reveal the code");
        assertFalse(waiting.toString().contains("ada@example.com"), "the page never learns where the code went");

        codes.confirm("handle-a", other(code));
        assertEquals(LoginCodes.MAX_ATTEMPTS - 1, codes.peek("handle-a").attemptsLeft());
        assertEquals(Outcome.confirmed(new Pending("user-a", "ada@example.com")), codes.confirm("handle-a", code),
                "peeking must not consume the code");
        assertNull(codes.peek("handle-a"));
    }

    @Test
    void discardingMakesTheCodeUseless() {
        String code = codes.issue("handle-a", "user-a", "ada@example.com");
        codes.discard("handle-a");
        assertEquals(Outcome.none(), codes.confirm("handle-a", code));
        codes.discard(null);
    }

    @Test
    void anIncompleteEntryFailsClosed() {
        String key = LoginCodes.key("handle-a");
        for (Map<String, String> broken : List.<Map<String, String>>of(
                Map.of("address", "ada@example.com", "expiresAt", "9999999999", "attemptsLeft", "5", "salt", "s", "codeHash", "h"),
                Map.of("userId", "user-a", "expiresAt", "9999999999", "attemptsLeft", "5", "salt", "s", "codeHash", "h"),
                Map.of("userId", "user-a", "address", "ada@example.com", "attemptsLeft", "5", "salt", "s", "codeHash", "h"),
                Map.of("userId", "user-a", "address", "ada@example.com", "expiresAt", "soon", "attemptsLeft", "5", "salt", "s", "codeHash", "h"))) {
            store.put(key, 60, broken);
            assertEquals(Outcome.none(), codes.confirm("handle-a", "123456"), broken.toString());
        }
    }

    // Account center's code, the first-login offer's code and the Login code live side by side in
    // the single-use store; none of them can confirm another.
    @Test
    void loginCodesHaveTheirOwnKeySpace() {
        assertNotEquals(LoginCodes.key("same"), PendingEmailChanges.key("same"));
        assertNotEquals(LoginCodes.key("same"), PendingEmailChanges.forLoginSessions(store).keyOf("same"));
        String code = codes.issue("same", "user-a", "ada@example.com");
        assertEquals(PendingEmailChanges.Outcome.none(), PendingEmailChanges.forLoginSessions(store).confirm("same", code));
        assertEquals(Outcome.confirmed(new Pending("user-a", "ada@example.com")), codes.confirm("same", code));
    }

    @Test
    void parallelConfirmationsOfOneCodeLeaveExactlyOneWinner() throws Exception {
        String code = codes.issue("handle-a", "user-a", "ada@example.com");
        int callers = 32;
        CountDownLatch start = new CountDownLatch(1);
        AtomicInteger winners = new AtomicInteger();
        ExecutorService pool = Executors.newFixedThreadPool(callers);
        try {
            List<Future<?>> futures = new ArrayList<>();
            for (int i = 0; i < callers; i++) {
                futures.add(pool.submit(() -> {
                    start.await();
                    if (codes.confirm("handle-a", code).status() == Outcome.Status.CONFIRMED) {
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

    /** A six-digit code that is certainly not {@code code}. */
    private static String other(String code) {
        return code.equals("000000") ? "000001" : "000000";
    }

    /** Honours put/remove exactly like Infinispan: remove hands the entry to one caller. */
    private static final class AtomicStore implements SingleUseObjectProvider {
        private final ConcurrentHashMap<String, Map<String, String>> entries = new ConcurrentHashMap<>();
        private final ConcurrentHashMap<String, Long> lifespans = new ConcurrentHashMap<>();

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
