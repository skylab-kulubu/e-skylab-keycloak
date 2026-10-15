package com.skylab.account;

import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;

import java.security.SecureRandom;
import java.text.Normalizer;
import java.util.Locale;
import java.util.regex.Pattern;
import java.util.stream.IntStream;
import java.util.stream.Stream;

/**
 * The username of an account opened by Self-registration (eskylab-login-ux 09). Faz 0 counted the
 * usernames of the realm (olgular-faz0 §2.2): 105 of 117 are not e-mail addresses, so the address
 * itself is never the username. It is derived from the address's local part instead, in the
 * Account center's username alphabet ({@link IdentityResource#USERNAME}: {@code [a-z0-9._]}, 3 to 30):
 * the {@code +tag} dropped, Turkish and accented letters folded to ASCII, anything else a dot, no
 * repeated or framing dots. A clash gets a number ({@code ada}, {@code ada2}, {@code ada3}, …; a base
 * shorter than three is padded: {@code a01}, {@code ab1}); after {@value #NUMBERED_TRIES} candidates
 * a random six-digit suffix is tried. The person may change it in Account center (the cooldown
 * starts with the first change).
 *
 * <p>A chosen name is claimed in Keycloak's single-use store for a minute first
 * ({@link org.keycloak.models.SingleUseObjectProvider#putIfAbsent}, atomic across nodes), so two
 * sign-ups at the same moment with the same local part never pick the same name; the database's
 * unique username stays the last word.
 */
final class SignUpUsernames {

    static final int MAX_LENGTH = 30;
    static final int MIN_LENGTH = 3;
    static final int NUMBERED_TRIES = 100;
    static final int RANDOM_TRIES = 10;
    static final int CLAIM_SECONDS = 60;
    static final String FALLBACK = "uye";

    private static final String CLAIM_PREFIX = "sky-email-code:username:";
    private static final Pattern MARKS = Pattern.compile("\\p{M}+");
    private static final Pattern OUTSIDE_ALPHABET = Pattern.compile("[^a-z0-9._]");
    private static final Pattern DOT_RUNS = Pattern.compile("\\.{2,}");
    private static final Pattern FRAME = Pattern.compile("^[._]+|[._]+$");
    private static final SecureRandom RANDOM = new SecureRandom();

    /**
     * A free name for {@code address}, claimed for this sign-up.
     *
     * @throws IllegalStateException when not one of the candidates is free (practically never)
     */
    String choose(KeycloakSession session, RealmModel realm, String address) {
        String base = base(address);
        for (String candidate : candidates(base).limit(NUMBERED_TRIES).toList()) {
            if (isFree(session, realm, candidate)) {
                return candidate;
            }
        }
        String stem = trim(base.substring(0, Math.min(base.length(), MAX_LENGTH - 6)));
        for (int i = 0; i < RANDOM_TRIES; i++) {
            String candidate = stem + String.format(Locale.ROOT, "%06d", RANDOM.nextInt(1_000_000));
            if (isFree(session, realm, candidate)) {
                return candidate;
            }
        }
        throw new IllegalStateException("no free username");
    }

    private static boolean isFree(KeycloakSession session, RealmModel realm, String candidate) {
        return session.users().getUserByUsername(realm, candidate) == null
                && session.singleUseObjects().putIfAbsent(CLAIM_PREFIX + realm.getId() + ":" + candidate, CLAIM_SECONDS);
    }

    /** The local part of {@code address} in the username alphabet, at most {@value #MAX_LENGTH} long. */
    static String base(String address) {
        String local = address == null ? "" : address.strip();
        int at = local.lastIndexOf('@');
        if (at >= 0) {
            local = local.substring(0, at);
        }
        int tag = local.indexOf('+');
        if (tag >= 0) {
            local = local.substring(0, tag);
        }
        String folded = MARKS.matcher(Normalizer.normalize(foldTurkish(local), Normalizer.Form.NFD)).replaceAll("")
                .toLowerCase(Locale.ROOT);
        String name = trim(DOT_RUNS.matcher(OUTSIDE_ALPHABET.matcher(folded).replaceAll(".")).replaceAll("."));
        if (name.length() > MAX_LENGTH) {
            name = trim(name.substring(0, MAX_LENGTH));
        }
        return name.isEmpty() ? FALLBACK : name;
    }

    /**
     * The names to try for {@code base}, in order: the base itself when it is long enough, then the
     * base with 2, 3, … (or, for a short base, 1, 2, … padded to the minimum length), each cut so
     * that it fits {@value #MAX_LENGTH}.
     */
    static Stream<String> candidates(String base) {
        if (base.length() >= MIN_LENGTH) {
            return Stream.concat(Stream.of(base), IntStream.iterate(2, n -> n + 1).mapToObj(n -> numbered(base, Integer.toString(n))));
        }
        int width = MIN_LENGTH - base.length();
        return IntStream.iterate(1, n -> n + 1)
                .mapToObj(n -> numbered(base, String.format(Locale.ROOT, "%0" + width + "d", n)));
    }

    private static String numbered(String base, String suffix) {
        String stem = base.length() + suffix.length() > MAX_LENGTH
                ? trim(base.substring(0, MAX_LENGTH - suffix.length()))
                : base;
        return stem + suffix;
    }

    private static String trim(String name) {
        return FRAME.matcher(name).replaceAll("");
    }

    /** Turkish letters that Unicode decomposition does not fold to ASCII (ı, İ) and the rest, explicitly. */
    private static String foldTurkish(String value) {
        StringBuilder out = new StringBuilder(value.length());
        for (char c : value.toCharArray()) {
            out.append(switch (c) {
                case 'ı', 'İ', 'I' -> 'i';
                case 'ş', 'Ş' -> 's';
                case 'ğ', 'Ğ' -> 'g';
                case 'ç', 'Ç' -> 'c';
                case 'ö', 'Ö' -> 'o';
                case 'ü', 'Ü' -> 'u';
                default -> c;
            });
        }
        return out.toString();
    }
}
