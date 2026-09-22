package com.skylab.account;

import org.keycloak.common.util.Base64Url;
import org.keycloak.common.util.SecretGenerator;
import org.keycloak.common.util.Time;
import org.keycloak.models.SingleUseObjectProvider;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.security.SecureRandom;
import java.util.HashMap;
import java.util.HexFormat;
import java.util.Map;
import java.util.regex.Pattern;

/**
 * The personal e-mail change a person is waiting to prove, one per person, kept in Keycloak's
 * single-use object store so it is shared across cluster nodes and expires on its own.
 *
 * <p>The proof is a six-digit code mailed to the new address and typed back into the same
 * signed-in Account Center session that asked for it (ADR-0044 update). The entry is keyed by the
 * person, so a code is only ever compared with that person's own pending change: whoever reads
 * the code, it cannot attach the address to another account. A new request replaces the old one.
 *
 * <p>A six-digit code is guessable in principle, so it is bounded three ways: it lives ten
 * minutes, it dies after {@link #MAX_ATTEMPTS} wrong tries, and a person can ask for at most
 * three codes an hour ({@link RateLimiter#EMAIL_CHANGE}). The store holds a salted SHA-256 of the
 * code, never the code.
 *
 * <p>Every attempt takes the entry out with {@link SingleUseObjectProvider#remove}, which hands it
 * to exactly one caller in Infinispan, and a wrong attempt puts it back with one try fewer and
 * only the time it had left. Two racing attempts therefore cannot both spend the same try, and
 * the right code works at most once.
 */
final class PendingEmailChanges {

    static final int TTL_SECONDS = 10 * 60;
    static final int MAX_ATTEMPTS = 5;
    static final Pattern CODE = Pattern.compile("^[0-9]{6}$");

    private static final int SALT_BYTES = 16;
    private static final String KEY_PREFIX = "sky-account:email-change:";
    private static final String ADDRESS_NOTE = "address";
    private static final String MAKE_PRIMARY_NOTE = "makePrimary";
    private static final String SALT_NOTE = "salt";
    private static final String CODE_HASH_NOTE = "codeHash";
    private static final String EXPIRES_AT_NOTE = "expiresAt";
    private static final String ATTEMPTS_LEFT_NOTE = "attemptsLeft";
    private static final SecureRandom RANDOM = new SecureRandom();

    /** What the person asked for when the code was sent. */
    record Pending(String address, boolean makePrimary) {
    }

    /** What is waiting for a code, as the page may show it: never the code or its hash. */
    record Waiting(String address, int expiresAt, int attemptsLeft) {
    }

    /** What an attempt with a code came to. */
    record Outcome(Status status, Pending change, int attemptsLeft) {

        enum Status {
            /** The code was right: the change is the person's to apply, and is gone from the store. */
            CONFIRMED,
            /** The code was wrong; {@code attemptsLeft} more tries before the change dies. */
            WRONG_CODE,
            /** Nothing to confirm: never asked, already used, expired or out of tries. */
            NONE
        }

        static Outcome confirmed(Pending change) {
            return new Outcome(Status.CONFIRMED, change, 0);
        }

        static Outcome wrongCode(int attemptsLeft) {
            return new Outcome(Status.WRONG_CODE, null, attemptsLeft);
        }

        static Outcome none() {
            return new Outcome(Status.NONE, null, 0);
        }
    }

    private final SingleUseObjectProvider store;

    PendingEmailChanges(SingleUseObjectProvider store) {
        this.store = store;
    }

    /** Stores the change for this person, replacing any earlier one, and returns its code, once. */
    String issue(String userId, String address, boolean makePrimary) {
        String code = String.format("%06d", RANDOM.nextInt(1_000_000));
        String salt = Base64Url.encode(SecretGenerator.getInstance().randomBytes(SALT_BYTES));
        store.put(key(userId), TTL_SECONDS, Map.of(
                ADDRESS_NOTE, address,
                MAKE_PRIMARY_NOTE, Boolean.toString(makePrimary),
                SALT_NOTE, salt,
                CODE_HASH_NOTE, hash(salt, code),
                // The store's lifespan is the first deadline. This one travels with the entry, so a
                // store that keeps it longer still cannot accept an old code, and a wrong attempt can
                // put the entry back for exactly the time it had left.
                EXPIRES_AT_NOTE, Integer.toString(Time.currentTime() + TTL_SECONDS),
                ATTEMPTS_LEFT_NOTE, Integer.toString(MAX_ATTEMPTS)));
        return code;
    }

    /**
     * What this person is waiting to prove, without consuming it, or {@code null}. Lets a page that
     * was reloaded between the mail and the code show the code box again instead of making the
     * person spend one of three codes an hour.
     */
    Waiting peek(String userId) {
        if (userId == null) {
            return null;
        }
        Map<String, String> notes = store.get(key(userId));
        if (notes == null) {
            return null;
        }
        String address = notes.get(ADDRESS_NOTE);
        Integer expiresAt = integer(notes.get(EXPIRES_AT_NOTE));
        Integer attemptsLeft = integer(notes.get(ATTEMPTS_LEFT_NOTE));
        if (address == null || address.isBlank() || expiresAt == null || attemptsLeft == null
                || expiresAt < Time.currentTime() || attemptsLeft <= 0) {
            return null;
        }
        return new Waiting(address, expiresAt, attemptsLeft);
    }

    /** Drops a change whose mail could not be sent, so its code never works. */
    void discard(String userId) {
        store.remove(key(userId));
    }

    /**
     * Checks {@code code} against this person's pending change. A malformed code is refused
     * without touching the change, so a typo does not cost a try.
     */
    Outcome confirm(String userId, String code) {
        if (userId == null || code == null || !CODE.matcher(code).matches()) {
            return Outcome.none();
        }
        String key = key(userId);
        Map<String, String> notes = store.remove(key);
        if (notes == null) {
            return Outcome.none();
        }
        String address = notes.get(ADDRESS_NOTE);
        String salt = notes.get(SALT_NOTE);
        String codeHash = notes.get(CODE_HASH_NOTE);
        Integer expiresAt = integer(notes.get(EXPIRES_AT_NOTE));
        Integer attemptsLeft = integer(notes.get(ATTEMPTS_LEFT_NOTE));
        if (address == null || address.isBlank() || salt == null || codeHash == null
                || expiresAt == null || attemptsLeft == null) {
            return Outcome.none();
        }
        int remainingSeconds = expiresAt - Time.currentTime();
        if (remainingSeconds < 0 || attemptsLeft <= 0) {
            return Outcome.none();
        }

        if (MessageDigest.isEqual(hash(salt, code).getBytes(StandardCharsets.US_ASCII),
                codeHash.getBytes(StandardCharsets.US_ASCII))) {
            return Outcome.confirmed(new Pending(address, Boolean.parseBoolean(notes.get(MAKE_PRIMARY_NOTE))));
        }

        int left = attemptsLeft - 1;
        if (left > 0) {
            Map<String, String> kept = new HashMap<>(notes);
            kept.put(ATTEMPTS_LEFT_NOTE, Integer.toString(left));
            store.put(key, Math.max(1, remainingSeconds), kept);
        }
        return Outcome.wrongCode(left);
    }

    static String key(String userId) {
        return KEY_PREFIX + userId;
    }

    private static Integer integer(String value) {
        if (value == null) {
            return null;
        }
        try {
            return Integer.parseInt(value);
        } catch (NumberFormatException malformed) {
            return null;
        }
    }

    private static String hash(String salt, String code) {
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
                    .digest((salt + ":" + code).getBytes(StandardCharsets.UTF_8)));
        } catch (NoSuchAlgorithmException exception) {
            throw new IllegalStateException("SHA-256 is unavailable", exception);
        }
    }
}
