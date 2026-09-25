package com.skylab.account;

import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;

/**
 * What a proven Personal e-mail leaves on a person: the address in {@code personalEmail} and the
 * moment it was proven in {@code personalEmailVerifiedAt} (ISO-8601 UTC, whole seconds). Only a
 * stamped address counts as proven ({@link IdentityResource#isPersonalEmailVerified}).
 *
 * <p>The one place that shapes this record. {@code email/confirm} writes it after the code, and
 * the A1c operator adoption ({@link LegacyPersonalEmailAdoption}, run by
 * {@code config/adopt-legacy-personal-email.sh}) writes the very same record for a primary
 * address Keycloak had already verified by link before v2. Keycloak-free on purpose, so the
 * operator script can call it with the JDK and Jackson of the image alone.
 */
public final class PersonalEmailProof {

    public static final String ADDRESS_ATTRIBUTE = "personalEmail";
    public static final String VERIFIED_AT_ATTRIBUTE = "personalEmailVerifiedAt";

    private PersonalEmailProof() {
    }

    /** Trims and lowercases with {@link Locale#ROOT}, so a Turkish locale cannot fold {@code I} to {@code ı}. */
    public static String normalise(String raw) {
        return raw.trim().toLowerCase(Locale.ROOT);
    }

    /** The stamp for a moment, e.g. {@code 2026-09-21T14:13:20Z}; the User Profile pattern accepts exactly this. */
    public static String verifiedAt(long epochSeconds) {
        return Instant.ofEpochSecond(epochSeconds).toString();
    }

    /** Attribute name to its single value, in the order {@code email/confirm} writes them. */
    public static Map<String, String> attributes(String address, long epochSeconds) {
        Map<String, String> attributes = new LinkedHashMap<>();
        attributes.put(ADDRESS_ATTRIBUTE, normalise(address));
        attributes.put(VERIFIED_AT_ATTRIBUTE, verifiedAt(epochSeconds));
        return attributes;
    }
}
