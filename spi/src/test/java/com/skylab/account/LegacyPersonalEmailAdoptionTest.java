package com.skylab.account;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import org.junit.jupiter.api.Test;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;
import java.util.Optional;

import static com.skylab.account.LegacyPersonalEmailAdoption.Verdict.ADOPT;
import static com.skylab.account.LegacyPersonalEmailAdoption.Verdict.DUPLICATE;
import static com.skylab.account.LegacyPersonalEmailAdoption.Verdict.NOT_LEGACY;
import static com.skylab.account.LegacyPersonalEmailAdoption.Verdict.SCHOOL_DOMAIN;
import static com.skylab.account.LegacyPersonalEmailAdoption.Verdict.TAKEN;
import static com.skylab.account.LegacyPersonalEmailAdoption.Verdict.UNVERIFIED;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class LegacyPersonalEmailAdoptionTest {

    private static final ObjectMapper JSON = new ObjectMapper();
    private static final long NOW = 1_790_000_000L;

    private static ObjectNode user(String id, String email, boolean verified, Map<String, List<String>> attributes) {
        ObjectNode user = JSON.createObjectNode();
        user.put("id", id);
        user.put("username", "user-" + id);
        if (email != null) {
            user.put("email", email);
        }
        user.put("emailVerified", verified);
        user.put("enabled", true);
        user.set("attributes", JSON.valueToTree(attributes));
        return user;
    }

    private static ObjectNode legacy(String id, String email) {
        return user(id, email, true, Map.of("schoolEmail", List.of(id + "@std.yildiz.edu.tr")));
    }

    private static LegacyPersonalEmailAdoption.Verdict verdictOf(List<JsonNode> users, String id) {
        return LegacyPersonalEmailAdoption.plan(users).verdicts().get(id);
    }

    @Test
    void aVerifiedLegacyPrimaryIsAdoptedWithItsOwnLowercasedAddress() {
        LegacyPersonalEmailAdoption.Plan plan = LegacyPersonalEmailAdoption.plan(List.of(legacy("a", "Ada.Lovelace@Gmail.com")));

        assertEquals(ADOPT, plan.verdicts().get("a"));
        assertEquals(List.of(new LegacyPersonalEmailAdoption.Adoption("a", "ada.lovelace@gmail.com")), plan.adoptions());
    }

    @Test
    void aVerifiedLegacyPrimaryWithoutAnySchoolAddressIsAdoptedToo() {
        assertEquals(ADOPT, verdictOf(List.of(user("a", "ada@gmail.com", true, Map.of())), "a"));
    }

    @Test
    void anUnverifiedLegacyPrimaryIsLeftForTheCodeFlow() {
        assertEquals(UNVERIFIED, verdictOf(List.of(user("a", "ada@gmail.com", false, Map.of())), "a"));
        ObjectNode missingFlag = user("b", "bob@gmail.com", true, Map.of());
        missingFlag.remove("emailVerified");
        assertEquals(UNVERIFIED, verdictOf(List.of(missingFlag), "b"), "no emailVerified is not a verified address");
    }

    @Test
    void anAddressOnAnyYildizDomainIsNeverAdoptedAsPersonal() {
        assertEquals(SCHOOL_DOMAIN, verdictOf(List.of(legacy("a", "ada@yildiz.edu.tr")), "a"));
        assertEquals(SCHOOL_DOMAIN, verdictOf(List.of(legacy("a", "ada.other@std.yildiz.edu.tr")), "a"));
        assertEquals(SCHOOL_DOMAIN, verdictOf(List.of(legacy("a", "ada@ee.Yildiz.EDU.tr")), "a"));

        assertTrue(LegacyPersonalEmailAdoption.isSchoolDomain("ada@mail.dept.yildiz.edu.tr"));
        assertFalse(LegacyPersonalEmailAdoption.isSchoolDomain("ada@notyildiz.edu.tr"), "only the domain itself or its subdomains");
        assertFalse(LegacyPersonalEmailAdoption.isSchoolDomain("ada@yildiz.edu.tr.example.com"));
        assertFalse(LegacyPersonalEmailAdoption.isSchoolDomain("yildiz.edu.tr@example.com"), "the domain is what follows the last @");
    }

    @Test
    void anAccountThatAlreadyHasAPersonalAddressIsNotALegacyPrimary() {
        ObjectNode withPersonal = user("a", "ada@gmail.com", true, Map.of(
                "schoolEmail", List.of("ada@std.yildiz.edu.tr"),
                "personalEmail", List.of("ada.other@gmail.com")));
        assertEquals(NOT_LEGACY, verdictOf(List.of(withPersonal), "a"));
        ObjectNode primaryIsPersonal = user("b", "bob@gmail.com", true, Map.of("personalEmail", List.of("bob@gmail.com")));
        assertEquals(NOT_LEGACY, verdictOf(List.of(primaryIsPersonal), "b"));
    }

    @Test
    void aPrimaryThatIsTheSchoolAddressInAnyCaseIsNotALegacyPrimary() {
        ObjectNode school = user("a", "ada@std.yildiz.edu.tr", true, Map.of("schoolEmail", List.of("Ada@STD.yildiz.edu.tr")));
        assertEquals(NOT_LEGACY, verdictOf(List.of(school), "a"));
    }

    @Test
    void anAccountWithoutAPrimaryIsNotALegacyPrimary() {
        assertEquals(NOT_LEGACY, verdictOf(List.of(user("a", null, true, Map.of())), "a"));
        assertEquals(NOT_LEGACY, verdictOf(List.of(user("b", "  ", true, Map.of())), "b"));
    }

    @Test
    void serviceAccountsAreNeitherScannedNorAdopted() {
        ObjectNode linked = user("a", "robot@example.com", true, Map.of());
        linked.put("serviceAccountClientLink", "client-uuid");
        ObjectNode named = user("b", "robot2@example.com", true, Map.of());
        named.put("username", "service-account-core");

        LegacyPersonalEmailAdoption.Plan plan = LegacyPersonalEmailAdoption.plan(List.of(linked, named));
        assertTrue(plan.verdicts().isEmpty());
        assertEquals(2, plan.serviceAccounts());
        assertEquals(0, plan.scanned());
    }

    @Test
    void anAddressAnotherPersonAlreadyHoldsIsSkippedAsTaken() {
        ObjectNode legacy = legacy("a", "shared@gmail.com");
        ObjectNode personal = user("b", "bob@std.yildiz.edu.tr", true, Map.of(
                "schoolEmail", List.of("bob@std.yildiz.edu.tr"), "personalEmail", List.of("Shared@gmail.com")));
        assertEquals(TAKEN, verdictOf(List.of(legacy, personal), "a"));

        ObjectNode school = user("c", "carol@gmail.com", true, Map.of("schoolEmail", List.of("dana@gmail.com")));
        assertEquals(TAKEN, verdictOf(List.of(legacy("d", "dana@gmail.com"), school), "d"),
                "held as another person's school attribute");
        assertEquals(TAKEN, verdictOf(List.of(legacy("e", "eve@gmail.com"), user("f", "EVE@gmail.com", false, Map.of())), "e"),
                "held as another person's Keycloak email, whatever that person's verdict");
    }

    @Test
    void twoPeopleWhoWouldBothGetTheSameAddressAreBothSkipped() {
        LegacyPersonalEmailAdoption.Plan plan = LegacyPersonalEmailAdoption.plan(List.of(
                legacy("a", "twin@gmail.com"), legacy("b", "Twin@gmail.com"), legacy("c", "single@gmail.com")));

        assertEquals(DUPLICATE, plan.verdicts().get("a"));
        assertEquals(DUPLICATE, plan.verdicts().get("b"));
        assertEquals(List.of(new LegacyPersonalEmailAdoption.Adoption("c", "single@gmail.com")), plan.adoptions());
        assertEquals(2, plan.count(DUPLICATE));
    }

    @Test
    void theCountsAddUpToTheLegacyPrimaries() {
        LegacyPersonalEmailAdoption.Plan plan = LegacyPersonalEmailAdoption.plan(List.of(
                legacy("a", "a@gmail.com"),
                user("b", "b@hotmail.com", false, Map.of()),
                legacy("c", "c@yildiz.edu.tr"),
                user("d", "d@std.yildiz.edu.tr", true, Map.of("schoolEmail", List.of("d@std.yildiz.edu.tr")))));

        assertEquals(4, plan.scanned());
        assertEquals(3, plan.legacyPrimaries());
        assertEquals(1, plan.count(ADOPT));
        assertEquals(1, plan.count(UNVERIFIED));
        assertEquals(1, plan.count(SCHOOL_DOMAIN));
        assertEquals(0, plan.count(TAKEN));
    }

    @Test
    void adoptionAddsExactlyTheProofAndKeepsEverythingElse() {
        ObjectNode before = legacy("a", "ada@gmail.com");
        ((ObjectNode) before.get("attributes")).putArray("skyNumber").add("1234");

        Optional<ObjectNode> after = LegacyPersonalEmailAdoption.adopted(before, "ada@gmail.com", NOW);

        assertTrue(after.isPresent());
        ObjectNode expected = before.deepCopy();
        ((ObjectNode) expected.get("attributes")).putArray("personalEmail").add("ada@gmail.com");
        ((ObjectNode) expected.get("attributes")).putArray("personalEmailVerifiedAt").add("2026-09-21T14:13:20Z");
        assertEquals(expected, after.get());
        assertEquals("ada@gmail.com", after.get().get("email").asText(), "the primary stays where it is");
        assertFalse(before.get("attributes").has("personalEmail"), "the input is not modified");
    }

    @Test
    void adoptionWorksForAnAccountWithoutAnyAttributes() {
        ObjectNode bare = user("a", "ada@gmail.com", true, Map.of());
        bare.remove("attributes");
        ObjectNode after = LegacyPersonalEmailAdoption.adopted(bare, "ada@gmail.com", NOW).orElseThrow();
        assertEquals("ada@gmail.com", after.at("/attributes/personalEmail/0").asText());
    }

    @Test
    void anAccountThatChangedSinceTheScanIsNotAdopted() {
        assertTrue(LegacyPersonalEmailAdoption.adopted(legacy("a", "new@gmail.com"), "old@gmail.com", NOW).isEmpty(),
                "the primary moved to another address");
        ObjectNode proven = user("b", "bob@gmail.com", true, Map.of("personalEmail", List.of("bob@gmail.com")));
        assertTrue(LegacyPersonalEmailAdoption.adopted(proven, "bob@gmail.com", NOW).isEmpty(),
                "the person proved an address meanwhile");
        assertTrue(LegacyPersonalEmailAdoption.adopted(user("c", "c@gmail.com", false, Map.of()), "c@gmail.com", NOW).isEmpty(),
                "no longer verified");
        assertTrue(LegacyPersonalEmailAdoption.adopted(legacy("d", "d@yildiz.edu.tr"), "d@yildiz.edu.tr", NOW).isEmpty());
    }

    @Test
    void theCommandLinePlansFromPagesAndPrintsCountsOnly(@org.junit.jupiter.api.io.TempDir Path directory) throws Exception {
        Path page1 = directory.resolve("page-1.json");
        Path page2 = directory.resolve("page-2.json");
        Path adoptions = directory.resolve("adoptions.tsv");
        Files.writeString(page1, JSON.writeValueAsString(List.of(legacy("a", "ada@gmail.com"), user("b", "b@gmail.com", false, Map.of()))));
        Files.writeString(page2, JSON.writeValueAsString(List.of(legacy("c", "c@yildiz.edu.tr"))));

        String out = run(new String[] {"plan", adoptions.toString(), page1.toString(), page2.toString()}, "");

        assertEquals(String.join("\n",
                "scanned=3 serviceAccounts=0 legacyPrimaries=3",
                "adopt=1 unverified=1 schoolDomain=1 duplicate=0 taken=0",
                ""), out);
        assertFalse(out.contains("@"), "no address reaches the terminal");
        assertEquals("a\tada@gmail.com\n", Files.readString(adoptions));
    }

    @Test
    void theCommandLineCountsAPage() throws Exception {
        assertEquals("2\n", run(new String[] {"count"}, JSON.writeValueAsString(List.of(legacy("a", "a@x.com"), legacy("b", "b@x.com")))));
        assertEquals("0\n", run(new String[] {"count"}, "[]"));
    }

    @Test
    void theCommandLineAdoptsOneFreshlyReadAccount() throws Exception {
        String out = run(new String[] {"adopt", "ada@gmail.com"}, JSON.writeValueAsString(legacy("a", "ada@gmail.com")));
        JsonNode adopted = JSON.readTree(out);
        assertEquals("ada@gmail.com", adopted.at("/attributes/personalEmail/0").asText());
        assertTrue(adopted.at("/attributes/personalEmailVerifiedAt/0").asText().matches("\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z"));
    }

    @Test
    void theCommandLineRefusesAnAccountThatNoLongerQualifies() throws Exception {
        assertEquals(LegacyPersonalEmailAdoption.EXIT_NOT_ELIGIBLE,
                LegacyPersonalEmailAdoption.run(new String[] {"adopt", "old@gmail.com"},
                        new ByteArrayInputStream(JSON.writeValueAsBytes(legacy("a", "new@gmail.com"))),
                        new PrintStream(new ByteArrayOutputStream(), true, StandardCharsets.UTF_8)));
    }

    private static String run(String[] args, String stdin) throws Exception {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        int status = LegacyPersonalEmailAdoption.run(args,
                new ByteArrayInputStream(stdin.getBytes(StandardCharsets.UTF_8)),
                new PrintStream(out, true, StandardCharsets.UTF_8));
        assertEquals(0, status);
        return out.toString(StandardCharsets.UTF_8);
    }
}
