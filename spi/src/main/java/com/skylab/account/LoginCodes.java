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
 * empty) and never mailed, so that the page and its tries look the same either way. With
 * Self-registration on (eskylab-login-ux 09), an e-mail address that names nobody gets a sign-up code
 * instead ({@link #issueSignUp}): for nobody too, but mailed to that address, marked
 * {@value #SIGN_UP_PURPOSE}; its right code proves the address. A Login code's record keeps its format.
 *
 * <p>The code's rules are {@link SingleUseCodes}': ten minutes, dead after five wrong tries, single
 * use, only a salted hash stored; a new code for the same session replaces the old one. A Login code
 * has {@value #DIGITS} digits (Yusuf's decision of 2026-10-16, replacing the earlier eight-digit
 * choice). The per-account wrong-code ceiling and all sending budgets remain in force.
 */
final class LoginCodes {

    static final int TTL_SECONDS = SingleUseCodes.TTL_SECONDS;
    static final int MAX_ATTEMPTS = SingleUseCodes.MAX_ATTEMPTS;
    static final int DIGITS = 6;
    static final Pattern CODE = SingleUseCodes.pattern(DIGITS);
    /** Longer input is refused before it is looked at: six digits with a space between each. */
    static final int MAX_CODE_INPUT_LENGTH = 2 * DIGITS + 8;

    private static final String KEY_PREFIX = "sky-email-code:";
    private static final String USER_ID_NOTE = "userId";
    private static final String ADDRESS_NOTE = "address";
    /** Only on a sign-up code ({@link #issueSignUp}); a Login code's record keeps the 08 format. */
    private static final String PURPOSE_NOTE = "purpose";
    static final String SIGN_UP_PURPOSE = "signup";

    /**
     * Whom a code signs in and where it was mailed; both empty for nobody. A sign-up code
     * ({@code signUp}) signs nobody in: its address is the one the right code proves.
     */
    record Pending(String userId, String address, boolean signUp) {

        Pending(String userId, String address) {
            this(userId, address, false);
        }
    }

    /**
     * What a session waits for, as the step may know it: never the code or its hash; the address
     * only of a sign-up code ({@code signUpAddress}, what the person typed; empty otherwise).
     */
    record Waiting(String userId, String signUpAddress, int expiresAt, int attemptsLeft) {
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
        this.codes = new SingleUseCodes(store, DIGITS, LoginCodes::isWellFormed);
    }

    /** Stores a code for this session's handle, replacing any earlier one, and returns it, once. */
    String issue(String handle, String userId, String address) {
        return codes.issue(key(handle), Map.of(USER_ID_NOTE, userId, ADDRESS_NOTE, address));
    }

    /**
     * Stores a sign-up code (Self-registration, eskylab-login-ux 09) for this session's handle: for
     * nobody, mailed to {@code address}, which the right code proves. Replaces any earlier code.
     */
    String issueSignUp(String handle, String address) {
        return codes.issue(key(handle), Map.of(USER_ID_NOTE, "", ADDRESS_NOTE, address, PURPOSE_NOTE, SIGN_UP_PURPOSE));
    }

    /** What this session's handle waits for, without consuming it, or {@code null}. */
    Waiting peek(String handle) {
        SingleUseCodes.Entry entry = handle == null ? null : codes.peek(key(handle));
        return entry == null ? null
                : new Waiting(entry.payload().get(USER_ID_NOTE), signUpAddress(entry.payload()), entry.expiresAt(),
                        entry.attemptsLeft());
    }

    private static boolean isSignUp(Map<String, String> payload) {
        return SIGN_UP_PURPOSE.equals(payload.get(PURPOSE_NOTE));
    }

    private static String signUpAddress(Map<String, String> payload) {
        return isSignUp(payload) ? payload.get(ADDRESS_NOTE) : "";
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
                    result.payload().get(USER_ID_NOTE), result.payload().get(ADDRESS_NOTE), isSignUp(result.payload())));
            case WRONG_CODE -> Outcome.wrongCode(result.payload().get(USER_ID_NOTE), result.attemptsLeft());
            case NONE -> Outcome.none();
        };
    }

    /**
     * Spends one try of this session's code without looking at what was typed (the person's wrong
     * codes reached the day's ceiling): it answers as a wrong code does, and the right code cannot win.
     */
    Outcome spendTry(String handle) {
        if (handle == null) {
            return Outcome.none();
        }
        SingleUseCodes.Result result = codes.spendTry(key(handle));
        return result.status() == SingleUseCodes.Status.WRONG_CODE
                ? Outcome.wrongCode(result.payload().get(USER_ID_NOTE), result.attemptsLeft())
                : Outcome.none();
    }

    /**
     * The code as typed, without the spaces people keep when they copy it; null when what is left
     * is not {@value #DIGITS} digits (such input never costs a try).
     */
    static String codeFromInput(String typed) {
        if (typed == null || typed.length() > MAX_CODE_INPUT_LENGTH) {
            return null;
        }
        String code = typed.strip().replace(" ", "");
        return CODE.matcher(code).matches() ? code : null;
    }

    /** The store key of a session's code. */
    static String key(String handle) {
        return KEY_PREFIX + handle;
    }

    private static boolean isWellFormed(Map<String, String> notes) {
        return notes.get(USER_ID_NOTE) != null && notes.get(ADDRESS_NOTE) != null;
    }
}
