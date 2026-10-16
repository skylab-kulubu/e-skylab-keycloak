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
 * The username of a Self-registration account (eskylab-login-ux 09): firstName.lastName from the
 * validated form, never the e-mail address (Yusuf, 2026-10-15). Turkish and accented letters fold
 * to ASCII in Account center's alphabet ({@link IdentityResource#USERNAME}: {@code [a-z0-9._]},
 * 3 to 30). Separators become dots; long names retain part of both names. Names without usable
 * ASCII letters get a neutral fallback, so Unicode names allowed by User Profile still work
 * without exposing any part of the address. A clash gets a number ({@code ada.lovelace2}, …);
 * after {@value #NUMBERED_TRIES} candidates a random six-digit suffix is tried. The person may
 * change it in Account center (the cooldown starts with the first change).
 *
 * <p>A chosen name is claimed in Keycloak's single-use store for a minute first
 * ({@link org.keycloak.models.SingleUseObjectProvider#putIfAbsent}, atomic across nodes), so
 * simultaneous sign-ups with the same names pick different usernames; the database's unique
 * username stays the last word.
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
     * A free name from the form, claimed for this sign-up.
     *
     * @throws IllegalStateException when not one of the candidates is free (practically never)
     */
    String choose(KeycloakSession session, RealmModel realm, String firstName, String lastName) {
        String base = base(firstName, lastName);
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

    /** Both names in the username alphabet, at most {@value #MAX_LENGTH} long. */
    static String base(String firstName, String lastName) {
        String first = part(firstName);
        String last = part(lastName);
        if (first.isEmpty() || last.isEmpty()) {
            String usable = first + last;
            return usable.isEmpty() ? FALLBACK : trim(usable.substring(0, Math.min(usable.length(), MAX_LENGTH)));
        }
        int available = MAX_LENGTH - 1; // The dot between the names.
        int firstBudget = Math.min(first.length(), Math.max(available - last.length(), (available + 1) / 2));
        first = trim(first.substring(0, firstBudget));
        last = trim(last.substring(0, Math.min(last.length(), available - first.length())));
        return first + "." + last;
    }

    private static String part(String raw) {
        String name = IdentityResource.normalisePersonName(raw == null ? "" : raw);
        String folded = MARKS.matcher(Normalizer.normalize(foldTurkish(name), Normalizer.Form.NFD)).replaceAll("")
                .toLowerCase(Locale.ROOT);
        return trim(DOT_RUNS.matcher(OUTSIDE_ALPHABET.matcher(folded).replaceAll(".")).replaceAll("."));
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
