package com.skylab.account;

import org.keycloak.models.SingleUseObjectProvider;

import java.util.Map;
import java.util.regex.Pattern;

/**
 * The Login code a sign-in session is waiting for (CONTEXT "Login code", ADR-0063,
 * eskylab-login-ux 08): one per sign-in session, kept in Keycloak's single-use object store.
 *
 * <p>The entry is keyed by a random handle that only the sign-in session (browser and tab) that
 * asked for the code holds, in an authentication note ({@link EmailCodeAuthenticator}): whoever
 * reads the mail, the code works nowhere else, and it dies with the session. Next to the code it
 * records whom the code signs in and the address it was mailed to, so the sign-in can check that
 * the address is still where that person's codes go. A session that asked for a code for an
 * identifier that names nobody holds a code too, for nobody ({@code userId} and {@code address}
 * empty) and never mailed, so that the page and its tries look the same either way.
 *
 * <p>The code's rules are {@link SingleUseCodes}': six digits, ten minutes, dead after five wrong
 * tries, single use, only a salted hash stored. A new code for the same session replaces the old
 * one.
 */
final class LoginCodes {

    static final int TTL_SECONDS = SingleUseCodes.TTL_SECONDS;
    static final int MAX_ATTEMPTS = SingleUseCodes.MAX_ATTEMPTS;
    static final Pattern CODE = SingleUseCodes.CODE;

    private static final String KEY_PREFIX = "sky-email-code:";
    private static final String USER_ID_NOTE = "userId";
    private static final String ADDRESS_NOTE = "address";

    /** Whom a code signs in and where it was mailed; both empty for nobody. */
    record Pending(String userId, String address) {
    }

    /** What a session waits for, as the page may know it: never the code, its hash or the address. */
    record Waiting(String userId, int expiresAt, int attemptsLeft) {
    }

    /** What an attempt with a code came to. {@code userId} is whom the code was for (empty for nobody). */
    record Outcome(Status status, Pending pending, String userId, int attemptsLeft) {

        enum Status {
            /** The code was right: the sign-in may go on, and the code is gone from the store. */
            CONFIRMED,
            /** The code was wrong; {@code attemptsLeft} more tries before the code dies. */
            WRONG_CODE,
            /** Nothing to confirm: never issued, already used, expired, out of tries or malformed. */
            NONE
        }

        static Outcome confirmed(Pending pending) {
            return new Outcome(Status.CONFIRMED, pending, pending.userId(), 0);
        }

        static Outcome wrongCode(String userId, int attemptsLeft) {
            return new Outcome(Status.WRONG_CODE, null, userId, attemptsLeft);
        }

        static Outcome none() {
            return new Outcome(Status.NONE, null, null, 0);
        }
    }

    private final SingleUseCodes codes;

    LoginCodes(SingleUseObjectProvider store) {
        this.codes = new SingleUseCodes(store, LoginCodes::isWellFormed);
    }

    /** Stores a code for this session's handle, replacing any earlier one, and returns it, once. */
    String issue(String handle, String userId, String address) {
        return codes.issue(key(handle), Map.of(USER_ID_NOTE, userId, ADDRESS_NOTE, address));
    }

    /** What this session's handle waits for, without consuming it, or {@code null}. */
    Waiting peek(String handle) {
        SingleUseCodes.Entry entry = handle == null ? null : codes.peek(key(handle));
        return entry == null ? null
                : new Waiting(entry.payload().get(USER_ID_NOTE), entry.expiresAt(), entry.attemptsLeft());
    }

    /** Drops this session's code, so it never works. */
    void discard(String handle) {
        if (handle != null) {
            codes.discard(key(handle));
        }
    }

    /**
     * Checks {@code code} against this session's code. A malformed code is refused without
     * touching the code, so a typo does not cost a try.
     */
    Outcome confirm(String handle, String code) {
        if (handle == null) {
            return Outcome.none();
        }
        SingleUseCodes.Result result = codes.confirm(key(handle), code);
        return switch (result.status()) {
            case CONFIRMED -> Outcome.confirmed(new Pending(
                    result.payload().get(USER_ID_NOTE), result.payload().get(ADDRESS_NOTE)));
            case WRONG_CODE -> Outcome.wrongCode(result.payload().get(USER_ID_NOTE), result.attemptsLeft());
            case NONE -> Outcome.none();
        };
    }

    /** The store key of a session's code. */
    static String key(String handle) {
        return KEY_PREFIX + handle;
    }

    private static boolean isWellFormed(Map<String, String> notes) {
        return notes.get(USER_ID_NOTE) != null && notes.get(ADDRESS_NOTE) != null;
    }
}
