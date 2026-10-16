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
import java.util.function.Predicate;
import java.util.regex.Pattern;

/**
 * The mailed codes of ADR-0044 (six digits) and CONTEXT's Login code (six digits), kept in
 * Keycloak's single-use object store so they are shared across cluster nodes and expire on their
 * own. Every code this extension mails is one of these: Account center's Personal e-mail proof and
 * the first-login offer's ({@link PendingEmailChanges}) and the Login code ({@link LoginCodes});
 * each keeps its own key space, its own length and its own payload (what the code proves) next to
 * the code's fields.
 *
 * <p>A short code is guessable in principle, so it is bounded: it lives ten minutes, it dies
 * after {@link #MAX_ATTEMPTS} wrong tries, and its callers limit how many codes are sent. The
 * store holds a salted SHA-256 of the code, never the code, and the comparison takes constant time.
 *
 * <p>Every attempt takes the entry out with {@link SingleUseObjectProvider#remove}, which hands it
 * to exactly one caller in Infinispan, and a wrong attempt puts it back with one try fewer and
 * only the time it had left. Two racing attempts therefore cannot both spend the same try, and
 * the right code works at most once.
 */
final class SingleUseCodes {

    static final int TTL_SECONDS = 10 * 60;
    static final int MAX_ATTEMPTS = 5;

    private static final int SALT_BYTES = 16;
    private static final String SALT_NOTE = "salt";
    private static final String CODE_HASH_NOTE = "codeHash";
    private static final String EXPIRES_AT_NOTE = "expiresAt";
    private static final String ATTEMPTS_LEFT_NOTE = "attemptsLeft";
    private static final SecureRandom RANDOM = new SecureRandom();

    enum Status {
        /** The code was right: the payload is the caller's to act on, and is gone from the store. */
        CONFIRMED,
        /** The code was wrong; {@code attemptsLeft} more tries before the code dies. */
        WRONG_CODE,
        /** Nothing to confirm: never issued, already used, expired, out of tries or malformed. */
        NONE
    }

    /** What is waiting for a code: the payload and the code's deadline and tries, never the code. */
    record Entry(Map<String, String> payload, int expiresAt, int attemptsLeft) {
    }

    /** What an attempt came to; the payload is there for CONFIRMED and WRONG_CODE. */
    record Result(Status status, Map<String, String> payload, int attemptsLeft) {

        static final Result NONE = new Result(Status.NONE, null, 0);
    }

    private final SingleUseObjectProvider store;
    private final int digits;
    private final Pattern code;
    private final Predicate<Map<String, String>> wellFormed;

    /**
     * @param digits     how many digits a code has (6 to 9)
     * @param wellFormed whether a stored entry carries the payload its caller wrote; an entry that
     *                   does not is treated as no entry at all (fails closed)
     */
    SingleUseCodes(SingleUseObjectProvider store, int digits, Predicate<Map<String, String>> wellFormed) {
        if (digits < 6 || digits > 9) {
            throw new IllegalArgumentException("a code has 6 to 9 digits, not " + digits);
        }
        this.store = store;
        this.digits = digits;
        this.code = pattern(digits);
        this.wellFormed = wellFormed;
    }

    /** What a code of {@code digits} digits looks like: digits only, exactly that many. */
    static Pattern pattern(int digits) {
        return Pattern.compile("^[0-9]{" + digits + "}$");
    }

    /** Stores the payload under {@code key}, replacing whatever was there, and returns its code, once. */
    String issue(String key, Map<String, String> payload) {
        int bound = 1;
        for (int i = 0; i < digits; i++) {
            bound *= 10;
        }
        String code = String.format("%0" + digits + "d", RANDOM.nextInt(bound));
        String salt = Base64Url.encode(SecretGenerator.getInstance().randomBytes(SALT_BYTES));
        Map<String, String> notes = new HashMap<>(payload);
        notes.put(SALT_NOTE, salt);
        notes.put(CODE_HASH_NOTE, hash(salt, code));
        // The store's lifespan is the first deadline. This one travels with the entry, so a store
        // that keeps it longer still cannot accept an old code, and a wrong attempt can put the
        // entry back for exactly the time it had left.
        notes.put(EXPIRES_AT_NOTE, Integer.toString(Time.currentTime() + TTL_SECONDS));
        notes.put(ATTEMPTS_LEFT_NOTE, Integer.toString(MAX_ATTEMPTS));
        store.put(key, TTL_SECONDS, notes);
        return code;
    }

    /** What waits under {@code key}, without consuming it, or {@code null}. */
    Entry peek(String key) {
        Map<String, String> notes = key == null ? null : store.get(key);
        if (notes == null || !wellFormed.test(notes)) {
            return null;
        }
        Integer expiresAt = integer(notes.get(EXPIRES_AT_NOTE));
        Integer attemptsLeft = integer(notes.get(ATTEMPTS_LEFT_NOTE));
        if (expiresAt == null || attemptsLeft == null || expiresAt < Time.currentTime() || attemptsLeft <= 0) {
            return null;
        }
        return new Entry(Map.copyOf(notes), expiresAt, attemptsLeft);
    }

    /** Drops the code under {@code key}, so it never works. */
    void discard(String key) {
        if (key != null) {
            store.remove(key);
        }
    }

    /**
     * Checks {@code code} against the code under {@code key}. A malformed code is refused without
     * touching the entry, so a typo does not cost a try.
     */
    Result confirm(String key, String code) {
        if (key == null || code == null || !this.code.matcher(code).matches()) {
            return Result.NONE;
        }
        return attempt(key, code);
    }

    /**
     * Spends one try of the code under {@code key} without looking at any code: the entry fares
     * exactly as after a wrong code (one try fewer, dead after the last), and the right code cannot
     * win this try. For a caller that must refuse every code for now and still answer as for a
     * wrong one (the Login code's per-account ceiling, security review K2).
     */
    Result spendTry(String key) {
        return key == null ? Result.NONE : attempt(key, null);
    }

    /** One attempt: {@code code} null spends the try without comparing. */
    private Result attempt(String key, String code) {
        Map<String, String> notes = store.remove(key);
        if (notes == null || !wellFormed.test(notes)) {
            return Result.NONE;
        }
        String salt = notes.get(SALT_NOTE);
        String codeHash = notes.get(CODE_HASH_NOTE);
        Integer expiresAt = integer(notes.get(EXPIRES_AT_NOTE));
        Integer attemptsLeft = integer(notes.get(ATTEMPTS_LEFT_NOTE));
        if (salt == null || codeHash == null || expiresAt == null || attemptsLeft == null) {
            return Result.NONE;
        }
        int remainingSeconds = expiresAt - Time.currentTime();
        if (remainingSeconds < 0 || attemptsLeft <= 0) {
            return Result.NONE;
        }

        if (code != null && MessageDigest.isEqual(hash(salt, code).getBytes(StandardCharsets.US_ASCII),
                codeHash.getBytes(StandardCharsets.US_ASCII))) {
            return new Result(Status.CONFIRMED, Map.copyOf(notes), 0);
        }

        int left = attemptsLeft - 1;
        if (left > 0) {
            Map<String, String> kept = new HashMap<>(notes);
            kept.put(ATTEMPTS_LEFT_NOTE, Integer.toString(left));
            store.put(key, Math.max(1, remainingSeconds), kept);
        }
        return new Result(Status.WRONG_CODE, Map.copyOf(notes), left);
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
