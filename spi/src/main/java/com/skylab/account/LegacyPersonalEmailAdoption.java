package com.skylab.account;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;

import java.io.IOException;
import java.io.InputStream;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Instant;
import java.util.ArrayList;
import java.util.EnumMap;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Optional;

/**
 * A1c, once: a Keycloak {@code email} set before v2 that is neither the School e-mail nor a
 * Personal e-mail (a <em>legacy primary</em>) becomes the person's Personal e-mail when Keycloak
 * had already verified it by link ({@code emailVerified=true}). It is written exactly as
 * {@code email/confirm} writes a proven address ({@link PersonalEmailProof}) and stays the Primary
 * e-mail. An unverified legacy primary is left alone: the person proves it with the code on
 * {@code my./email}.
 *
 * <p>An address is never adopted when it is on a YTÜ domain ({@code yildiz.edu.tr} or any
 * subdomain: that is a school address, not a personal one), when another person already holds it
 * (as Keycloak {@code email}, {@code schoolEmail} or {@code personalEmail}, compared
 * case-insensitively, stricter than {@code email/confirm}'s exact attribute search) or when it
 * would become the Personal e-mail of two people. Service accounts are not people.
 *
 * <p>Keycloak-free: it reads Admin REST user representations, so
 * {@code config/adopt-legacy-personal-email.sh} runs it inside the image with the JDK and the
 * Jackson libraries Keycloak ships ({@link #main}). Nothing it prints to the terminal names a
 * person: addresses and ids only travel through the files the script hands it.
 */
public final class LegacyPersonalEmailAdoption {

    /** {@code adopt}: the account no longer qualifies (it changed since the scan). */
    static final int EXIT_NOT_ELIGIBLE = 3;
    static final String SCHOOL_DOMAIN_NAME = "yildiz.edu.tr";
    private static final String SERVICE_ACCOUNT_PREFIX = "service-account-";
    private static final ObjectMapper JSON = new ObjectMapper();

    /** What becomes of one person's account. */
    public enum Verdict {
        /** Has no legacy primary: no primary, the school address, or a Personal e-mail already. */
        NOT_LEGACY,
        /** Verified legacy primary, free: becomes the Personal e-mail. */
        ADOPT,
        /** Legacy primary Keycloak never verified: left for the code flow. */
        UNVERIFIED,
        /** Legacy primary on a YTÜ domain: a school address is never a Personal e-mail. */
        SCHOOL_DOMAIN,
        /** Another verified legacy primary is the same address: neither is adopted. */
        DUPLICATE,
        /** Another person already holds the address: not adopted. */
        TAKEN
    }

    public record Adoption(String userId, String address) {
    }

    /** The verdict for every person scanned (by id), the adoptions in scan order and the service accounts skipped. */
    public record Plan(Map<String, Verdict> verdicts, List<Adoption> adoptions, int serviceAccounts) {

        public int scanned() {
            return verdicts.size();
        }

        public int count(Verdict verdict) {
            return (int) verdicts.values().stream().filter(verdict::equals).count();
        }

        public int legacyPrimaries() {
            return scanned() - count(Verdict.NOT_LEGACY);
        }
    }

    private LegacyPersonalEmailAdoption() {
    }

    public static Plan plan(List<JsonNode> users) {
        List<JsonNode> people = new ArrayList<>();
        int serviceAccounts = 0;
        for (JsonNode user : users) {
            if (isServiceAccount(user)) {
                serviceAccounts++;
            } else {
                people.add(user);
            }
        }

        // Who holds which address, in any of the three places, by id.
        Map<String, List<String>> holders = new HashMap<>();
        for (JsonNode user : users) {
            String id = user.path("id").asText();
            addHolder(holders, text(user, "email"), id);
            for (String attribute : List.of(IdentityResource.SCHOOL_EMAIL_ATTRIBUTE, PersonalEmailProof.ADDRESS_ATTRIBUTE)) {
                for (JsonNode value : user.path("attributes").path(attribute)) {
                    addHolder(holders, value.asText(null), id);
                }
            }
        }

        Map<String, Verdict> verdicts = new LinkedHashMap<>();
        Map<String, String> candidates = new LinkedHashMap<>();
        Map<String, Integer> candidatesPerAddress = new HashMap<>();
        for (JsonNode user : people) {
            String id = user.path("id").asText();
            Optional<String> legacy = legacyPrimary(user);
            Verdict verdict;
            if (legacy.isEmpty()) {
                verdict = Verdict.NOT_LEGACY;
            } else if (isSchoolDomain(legacy.get())) {
                verdict = Verdict.SCHOOL_DOMAIN;
            } else if (!user.path("emailVerified").asBoolean(false)) {
                verdict = Verdict.UNVERIFIED;
            } else {
                verdict = Verdict.ADOPT;
                candidates.put(id, legacy.get());
                candidatesPerAddress.merge(legacy.get(), 1, Integer::sum);
            }
            verdicts.put(id, verdict);
        }

        List<Adoption> adoptions = new ArrayList<>();
        candidates.forEach((id, address) -> {
            if (candidatesPerAddress.get(address) > 1) {
                verdicts.put(id, Verdict.DUPLICATE);
            } else if (holders.getOrDefault(address, List.of()).stream().anyMatch(holder -> !holder.equals(id))) {
                verdicts.put(id, Verdict.TAKEN);
            } else {
                adoptions.add(new Adoption(id, address));
            }
        });
        return new Plan(verdicts, adoptions, serviceAccounts);
    }

    /**
     * The account as it is to be written back: the freshly read representation plus the proof for
     * {@code address}; empty when the account no longer has that verified, non-school legacy
     * primary (it changed since the scan). Everything else is sent back as it was read.
     */
    public static Optional<ObjectNode> adopted(JsonNode user, String address, long epochSeconds) {
        Optional<String> legacy = legacyPrimary(user);
        if (legacy.isEmpty() || !legacy.get().equals(PersonalEmailProof.normalise(address))
                || isSchoolDomain(legacy.get()) || !user.path("emailVerified").asBoolean(false)
                || isServiceAccount(user)) {
            return Optional.empty();
        }
        ObjectNode copy = user.deepCopy();
        ObjectNode attributes = copy.get("attributes") instanceof ObjectNode existing ? existing : copy.putObject("attributes");
        PersonalEmailProof.attributes(legacy.get(), epochSeconds)
                .forEach((name, value) -> attributes.putArray(name).add(value));
        return Optional.of(copy);
    }

    /** Whether the address is on {@code yildiz.edu.tr} or one of its subdomains (the part after the last {@code @}). */
    public static boolean isSchoolDomain(String address) {
        String domain = address.substring(address.lastIndexOf('@') + 1).trim().toLowerCase(Locale.ROOT);
        return domain.equals(SCHOOL_DOMAIN_NAME) || domain.endsWith("." + SCHOOL_DOMAIN_NAME);
    }

    /**
     * The normalised Keycloak {@code email} when it is a legacy primary: set, not the School e-mail
     * (case-insensitively), and the person has no Personal e-mail at all.
     */
    static Optional<String> legacyPrimary(JsonNode user) {
        String email = text(user, "email");
        if (email == null) {
            return Optional.empty();
        }
        String normalised = PersonalEmailProof.normalise(email);
        String school = firstAttribute(user, IdentityResource.SCHOOL_EMAIL_ATTRIBUTE);
        if (school != null && PersonalEmailProof.normalise(school).equals(normalised)) {
            return Optional.empty();
        }
        if (firstAttribute(user, PersonalEmailProof.ADDRESS_ATTRIBUTE) != null) {
            return Optional.empty();
        }
        return Optional.of(normalised);
    }

    private static boolean isServiceAccount(JsonNode user) {
        return text(user, "serviceAccountClientLink") != null
                || user.path("username").asText("").startsWith(SERVICE_ACCOUNT_PREFIX);
    }

    private static void addHolder(Map<String, List<String>> holders, String address, String id) {
        if (address != null && !address.isBlank()) {
            holders.computeIfAbsent(PersonalEmailProof.normalise(address), key -> new ArrayList<>()).add(id);
        }
    }

    private static String firstAttribute(JsonNode user, String name) {
        JsonNode values = user.path("attributes").path(name);
        if (!values.isArray() || values.isEmpty()) {
            return null;
        }
        String value = values.get(0).asText(null);
        return value == null || value.isBlank() ? null : value;
    }

    private static String text(JsonNode node, String field) {
        JsonNode value = node.get(field);
        if (value == null || !value.isTextual() || value.asText().isBlank()) {
            return null;
        }
        return value.asText();
    }

    /**
     * {@code count} (stdin: one Admin REST page, a JSON array) prints its length.
     * {@code plan ADOPTIONS PAGE...} reads every page, writes {@code id<TAB>address} per adoption
     * to ADOPTIONS and prints the counts only.
     * {@code adopt ADDRESS} (stdin: one freshly read user) prints the representation to write
     * back, or exits {@value #EXIT_NOT_ELIGIBLE} when the account no longer qualifies.
     */
    public static void main(String[] args) throws IOException {
        System.exit(run(args, System.in, new PrintStream(System.out, true, StandardCharsets.UTF_8)));
    }

    static int run(String[] args, InputStream in, PrintStream out) throws IOException {
        if (args.length == 0) {
            return usage();
        }
        switch (args[0]) {
            case "count" -> {
                out.println(JSON.readTree(in).size());
                return 0;
            }
            case "plan" -> {
                if (args.length < 2) {
                    return usage();
                }
                List<JsonNode> users = new ArrayList<>();
                for (int page = 2; page < args.length; page++) {
                    JSON.readTree(Path.of(args[page]).toFile()).forEach(users::add);
                }
                Plan plan = plan(users);
                StringBuilder adoptions = new StringBuilder();
                plan.adoptions().forEach(adoption ->
                        adoptions.append(adoption.userId()).append('\t').append(adoption.address()).append('\n'));
                Files.writeString(Path.of(args[1]), adoptions, StandardCharsets.UTF_8);
                Map<Verdict, Integer> counts = new EnumMap<>(Verdict.class);
                for (Verdict verdict : Verdict.values()) {
                    counts.put(verdict, plan.count(verdict));
                }
                out.printf("scanned=%d serviceAccounts=%d legacyPrimaries=%d%n",
                        plan.scanned(), plan.serviceAccounts(), plan.legacyPrimaries());
                out.printf("adopt=%d unverified=%d schoolDomain=%d duplicate=%d taken=%d%n",
                        counts.get(Verdict.ADOPT), counts.get(Verdict.UNVERIFIED), counts.get(Verdict.SCHOOL_DOMAIN),
                        counts.get(Verdict.DUPLICATE), counts.get(Verdict.TAKEN));
                return 0;
            }
            case "adopt" -> {
                if (args.length != 2) {
                    return usage();
                }
                Optional<ObjectNode> adopted = adopted(JSON.readTree(in), args[1], Instant.now().getEpochSecond());
                if (adopted.isEmpty()) {
                    return EXIT_NOT_ELIGIBLE;
                }
                out.println(JSON.writeValueAsString(adopted.get()));
                return 0;
            }
            default -> {
                return usage();
            }
        }
    }

    private static int usage() {
        System.err.println("usage: LegacyPersonalEmailAdoption count | plan ADOPTIONS PAGE... | adopt ADDRESS");
        return 2;
    }
}
