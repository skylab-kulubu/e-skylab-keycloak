package com.skylab.handoff;

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

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

class HandoffStoreTest {

    private static final String REALM_ID = "realm-1";
    private static final HandoffGrant GRANT = new HandoffGrant(
            REALM_ID, "11111111-1111-4111-8111-111111111111", "offline-session-1", true, 1_780_000_000L,
            "account-center", "/profile?tab=security", "203.0.113.7");

    private final ExpiringStore store = new ExpiringStore();
    private final HandoffStore handoffs = new HandoffStore(store);

    @AfterEach
    void resetClock() {
        Time.setOffset(0);
    }

    @Test
    void mintsAn256BitCodeAndProofAndKeepsNeitherInTheStore() {
        HandoffStore.Minted minted = handoffs.mint(GRANT);

        assertTrue(minted.code().matches("^[A-Za-z0-9_-]{43}$"), "32 random bytes, base64url");
        assertTrue(minted.proof().matches("^[A-Za-z0-9_-]{43}$"), "32 random bytes, base64url");
        assertNotEquals(minted.code(), minted.proof());
        assertEquals(45, minted.expiresIn());
        assertNotEquals(minted.code(), handoffs.mint(GRANT).code(), "every code is fresh");
        store.entries.forEach((key, entry) -> {
            assertFalse(key.contains(minted.code()), "the store key must not be the code");
            assertFalse(entry.notes().containsValue(minted.code()), "the store must not hold the code");
            assertFalse(entry.notes().containsValue(minted.proof()), "the store must not hold the proof");
        });
    }

    @Test
    void redeemsOnceWithTheProofAndCarriesTheOriginalAuthenticationTime() {
        HandoffStore.Minted minted = handoffs.mint(GRANT);

        HandoffStore.Redeemed redeemed = assertInstanceOf(HandoffStore.Redeemed.class,
                handoffs.redeem(minted.code(), minted.proof(), REALM_ID));
        assertEquals(GRANT, redeemed.grant());
        assertEquals(1_780_000_000L, redeemed.grant().authTime());
        assertTrue(redeemed.grant().sourceOffline(), "the kind of source session travels with the code");

        HandoffStore.Refused again = assertInstanceOf(HandoffStore.Refused.class,
                handoffs.redeem(minted.code(), minted.proof(), REALM_ID));
        assertEquals(FailureReason.USED, again.reason());
        assertEquals(GRANT.userId(), again.userId(), "a refusal is attributed to the person for the audit event");
        assertEquals(GRANT.clientId(), again.clientId());
    }

    @Test
    void aGrantWithoutAKnownAddressOrFromAnOnlineSessionRoundTrips() {
        HandoffGrant online = new HandoffGrant(REALM_ID, GRANT.userId(), "online-session-1", false, 1_780_000_000L,
                "skyforms", "/", null);
        HandoffStore.Minted minted = handoffs.mint(online);

        assertEquals(online, assertInstanceOf(HandoffStore.Redeemed.class,
                handoffs.redeem(minted.code(), minted.proof(), REALM_ID)).grant());
    }

    @Test
    void theUsedTombstoneIsShortLivedAndThenTheCodeIsSimplyUnknown() {
        HandoffStore.Minted minted = handoffs.mint(GRANT);
        assertInstanceOf(HandoffStore.Redeemed.class, handoffs.redeem(minted.code(), minted.proof(), REALM_ID));

        Time.setOffset(HandoffStore.TOMBSTONE_SECONDS - 1);
        assertEquals(FailureReason.USED, reason(handoffs.redeem(minted.code(), minted.proof(), REALM_ID)));
        Time.setOffset(HandoffStore.TOMBSTONE_SECONDS + 1);
        assertEquals(FailureReason.INVALID, reason(handoffs.redeem(minted.code(), minted.proof(), REALM_ID)));
        store.entries.values().forEach(entry -> assertTrue(entry.expiresAt() <= Time.currentTime() + HandoffStore.TOMBSTONE_SECONDS,
                "every entry of the store has a finite lifespan"));
    }

    @Test
    void aMissingOrWrongProofIsInvalidAndDoesNotBurnTheCode() {
        HandoffStore.Minted minted = handoffs.mint(GRANT);

        assertEquals(FailureReason.INVALID, reason(handoffs.redeem(minted.code(), null, REALM_ID)));
        assertEquals(FailureReason.INVALID, reason(handoffs.redeem(minted.code(), "", REALM_ID)));
        assertEquals(FailureReason.INVALID, reason(handoffs.redeem(minted.code(), handoffs.mint(GRANT).proof(), REALM_ID)));
        assertEquals(FailureReason.INVALID, reason(handoffs.redeem(minted.code(), minted.proof() + "x", REALM_ID)));

        assertInstanceOf(HandoffStore.Redeemed.class, handoffs.redeem(minted.code(), minted.proof(), REALM_ID),
                "a link opened without its proof (a leaked URL, a prefetch) must not lock the app out");
    }

    @Test
    void aCodeIsExpiredAfter45SecondsWhetherOrNotTheStoreStillHoldsIt() {
        HandoffStore.Minted evicted = handoffs.mint(GRANT);
        Time.setOffset(46);
        assertEquals(FailureReason.EXPIRED, reason(handoffs.redeem(evicted.code(), evicted.proof(), REALM_ID)));

        Time.setOffset(0);
        ExpiringStore lingering = new ExpiringStore();
        lingering.neverExpire = true;
        HandoffStore slowStore = new HandoffStore(lingering);
        HandoffStore.Minted kept = slowStore.mint(GRANT);
        Time.setOffset(46);
        assertEquals(FailureReason.EXPIRED, reason(slowStore.redeem(kept.code(), kept.proof(), REALM_ID)),
                "the store only promises a minimum lifespan, the code carries its own expiry");
        assertEquals(FailureReason.EXPIRED, reason(slowStore.redeem(kept.code(), kept.proof(), REALM_ID)));

        Time.setOffset(44);
        HandoffStore.Minted fresh = handoffs.mint(GRANT);
        Time.setOffset(44 + 44);
        assertInstanceOf(HandoffStore.Redeemed.class, handoffs.redeem(fresh.code(), fresh.proof(), REALM_ID));
    }

    @Test
    void anUnknownMalformedOrForeignRealmCodeIsInvalid() {
        HandoffStore.Minted minted = handoffs.mint(GRANT);

        HandoffStore.Refused unknown = assertInstanceOf(HandoffStore.Refused.class,
                handoffs.redeem("A".repeat(43), minted.proof(), REALM_ID));
        assertEquals(FailureReason.INVALID, unknown.reason());
        assertEquals(null, unknown.userId(), "nobody to attribute an unknown code to");

        assertEquals(FailureReason.INVALID, reason(handoffs.redeem(null, minted.proof(), REALM_ID)));
        assertEquals(FailureReason.INVALID, reason(handoffs.redeem("", minted.proof(), REALM_ID)));
        assertEquals(FailureReason.INVALID, reason(handoffs.redeem(minted.code() + "=", minted.proof(), REALM_ID)));
        assertEquals(FailureReason.INVALID, reason(handoffs.redeem(minted.code().substring(1), minted.proof(), REALM_ID)));
        assertEquals(FailureReason.INVALID, reason(handoffs.redeem(minted.code(), minted.proof(), "realm-2")));

        assertInstanceOf(HandoffStore.Redeemed.class, handoffs.redeem(minted.code(), minted.proof(), REALM_ID),
                "a refusal in another realm does not consume the code");
    }

    @Test
    void concurrentOpensRedeemTheCodeExactlyOnce() throws Exception {
        HandoffStore.Minted minted = handoffs.mint(GRANT);
        int requests = 24;
        ExecutorService pool = Executors.newFixedThreadPool(requests);
        try {
            CountDownLatch start = new CountDownLatch(1);
            List<Future<HandoffStore.Redemption>> futures = new ArrayList<>();
            for (int i = 0; i < requests; i++) {
                futures.add(pool.submit(() -> {
                    start.await();
                    return handoffs.redeem(minted.code(), minted.proof(), REALM_ID);
                }));
            }
            start.countDown();
            int redeemed = 0;
            for (Future<HandoffStore.Redemption> future : futures) {
                HandoffStore.Redemption redemption = future.get();
                if (redemption instanceof HandoffStore.Redeemed) {
                    redeemed++;
                } else {
                    assertEquals(FailureReason.USED, reason(redemption));
                }
            }
            assertEquals(1, redeemed);
        } finally {
            pool.shutdownNow();
        }
    }

    private static FailureReason reason(HandoffStore.Redemption redemption) {
        return assertInstanceOf(HandoffStore.Refused.class, redemption).reason();
    }

    /**
     * Honours the SingleUseObjectProvider contract like Infinispan: atomic remove, lifespans on
     * Keycloak's clock ({@link Time}), and a copy of the notes on every read.
     */
    static final class ExpiringStore implements SingleUseObjectProvider {
        record Entry(Map<String, String> notes, long expiresAt) {
        }

        final ConcurrentHashMap<String, Entry> entries = new ConcurrentHashMap<>();
        boolean neverExpire;

        private Entry live(String key) {
            Entry entry = entries.get(key);
            if (entry != null && !neverExpire && Time.currentTime() >= entry.expiresAt()) {
                entries.remove(key, entry);
                return null;
            }
            return entry;
        }

        @Override
        public void put(String key, long lifespanSeconds, Map<String, String> notes) {
            if (lifespanSeconds <= 0) {
                throw new IllegalArgumentException("lifespan must be positive");
            }
            notes.values().forEach(value -> {
                if (value == null) {
                    throw new NullPointerException("Infinispan refuses null notes");
                }
            });
            entries.put(key, new Entry(Map.copyOf(notes), Time.currentTime() + lifespanSeconds));
        }

        @Override
        public Map<String, String> get(String key) {
            Entry entry = live(key);
            return entry == null ? null : Map.copyOf(entry.notes());
        }

        @Override
        public Map<String, String> remove(String key) {
            Entry entry = live(key);
            if (entry == null || !entries.remove(key, entry)) {
                return null;
            }
            return Map.copyOf(entry.notes());
        }

        /** Infinispan's replace writes with the cache default metadata: the entry would never expire. */
        @Override
        public boolean replace(String key, Map<String, String> notes) {
            throw new UnsupportedOperationException("replace drops the lifespan in Infinispan; the store must use put");
        }

        @Override
        public boolean putIfAbsent(String key, long lifespanInSeconds) {
            return entries.putIfAbsent(key, new Entry(Map.of(), Time.currentTime() + lifespanInSeconds)) == null;
        }

        @Override
        public boolean contains(String key) {
            return live(key) != null;
        }

        @Override
        public void close() {
            // no-op
        }
    }
}
