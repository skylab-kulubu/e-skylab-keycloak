package com.skylab.account;

import org.keycloak.models.SingleUseObjectProvider;

import java.util.Map;
import java.util.regex.Pattern;

/**
 * The personal e-mail change a person is waiting to prove, one per owner, kept in Keycloak's
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
 * <p>The code itself, its salted hash, its deadline and its tries are {@link SingleUseCodes}', the
 * store every mailed code of this extension shares (the Login code is {@link LoginCodes}).
 *
 * <p>Two places prove a Personal e-mail with this store, each in its own key space: Account
 * center keys the change by the person ({@link #PendingEmailChanges(SingleUseObjectProvider)}),
 * and the offer at the end of a first YTÜ login keys it by an opaque handle that only its own
 * sign-in session holds ({@link #forLoginSessions}), so that code works only in that browser tab.
 */
final class PendingEmailChanges {

    static final int TTL_SECONDS = SingleUseCodes.TTL_SECONDS;
    static final int MAX_ATTEMPTS = SingleUseCodes.MAX_ATTEMPTS;
    /** ADR-0044's code: six digits, with its own key space beside {@link LoginCodes}. */
    static final int DIGITS = 6;
    static final Pattern CODE = SingleUseCodes.pattern(DIGITS);

    private static final String KEY_PREFIX = "sky-account:email-change:";
    private static final String LOGIN_SESSION_KEY_PREFIX = "sky-account:login-email-offer:";
    private static final String ADDRESS_NOTE = "address";
    private static final String MAKE_PRIMARY_NOTE = "makePrimary";

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

    private final SingleUseCodes codes;
    private final String keyPrefix;

    /** Account center's changes, one per person (the owner is the user id). */
    PendingEmailChanges(SingleUseObjectProvider store) {
        this(store, KEY_PREFIX);
    }

    private PendingEmailChanges(SingleUseObjectProvider store, String keyPrefix) {
        this.codes = new SingleUseCodes(store, DIGITS, PendingEmailChanges::hasAddress);
        this.keyPrefix = keyPrefix;
    }

    /**
     * Changes asked for inside a sign-in session, one per handle: the owner is a random handle the
     * session keeps in an authentication note, never the user id, so a code from one sign-in
     * session cannot be confirmed from another one or from Account center.
     */
    static PendingEmailChanges forLoginSessions(SingleUseObjectProvider store) {
        return new PendingEmailChanges(store, LOGIN_SESSION_KEY_PREFIX);
    }

    /** Stores the change for this person, replacing any earlier one, and returns its code, once. */
    String issue(String userId, String address, boolean makePrimary) {
        return codes.issue(keyOf(userId), Map.of(
                ADDRESS_NOTE, address,
                MAKE_PRIMARY_NOTE, Boolean.toString(makePrimary)));
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
        SingleUseCodes.Entry entry = codes.peek(keyOf(userId));
        return entry == null ? null
                : new Waiting(entry.payload().get(ADDRESS_NOTE), entry.expiresAt(), entry.attemptsLeft());
    }

    /** Drops a change whose mail could not be sent, so its code never works. */
    void discard(String userId) {
        codes.discard(keyOf(userId));
    }

    /**
     * Checks {@code code} against this person's pending change. A malformed code is refused
     * without touching the change, so a typo does not cost a try.
     */
    Outcome confirm(String userId, String code) {
        if (userId == null) {
            return Outcome.none();
        }
        SingleUseCodes.Result result = codes.confirm(keyOf(userId), code);
        return switch (result.status()) {
            case CONFIRMED -> Outcome.confirmed(new Pending(result.payload().get(ADDRESS_NOTE),
                    Boolean.parseBoolean(result.payload().get(MAKE_PRIMARY_NOTE))));
            case WRONG_CODE -> Outcome.wrongCode(result.attemptsLeft());
            case NONE -> Outcome.none();
        };
    }

    /** The store key of Account center's change for a person. */
    static String key(String userId) {
        return KEY_PREFIX + userId;
    }

    /** The store key of this store's change for an owner. */
    String keyOf(String owner) {
        return keyPrefix + owner;
    }

    private static boolean hasAddress(Map<String, String> notes) {
        String address = notes.get(ADDRESS_NOTE);
        return address != null && !address.isBlank();
    }
}
