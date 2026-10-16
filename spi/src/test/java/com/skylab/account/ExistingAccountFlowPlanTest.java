package com.skylab.account;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import javax.tools.ToolProvider;
import java.io.ByteArrayOutputStream;
import java.io.PrintStream;
import java.lang.reflect.Method;
import java.net.URLClassLoader;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.*;

/** Exercises the actual Java reconciler planner without a server or Docker. */
class ExistingAccountFlowPlanTest {
    @TempDir static Path scratch;
    private static final ObjectMapper JSON = new ObjectMapper();
    private static Class<?> planner;
    private static Path nativeFile;
    private static ArrayNode nativeFlow;

    @BeforeAll
    static void compileActualPlanner() throws Exception {
        Path source = Path.of("../config/ReconcileJson.java").toAbsolutePath();
        assertTrue(Files.isRegularFile(source), source.toString());
        int compiled = ToolProvider.getSystemJavaCompiler().run(null, null, null, "-cp",
                System.getProperty("java.class.path"), "-d", scratch.toString(), source.toString());
        assertEquals(0, compiled);
        planner = new URLClassLoader(new java.net.URL[]{scratch.toUri().toURL()}, ExistingAccountFlowPlanTest.class.getClassLoader())
                .loadClass("ReconcileJson");
        nativeFlow = (ArrayNode) JSON.readTree("""
                [
                 {"id":"review","providerId":"idp-review-profile","priority":10,"level":0,"requirement":"REQUIRED","authenticationConfig":"native-config"},
                 {"id":"unique-exec","authenticationFlow":true,"flowId":"unique","priority":20,"level":0,"requirement":"REQUIRED"},
                 {"id":"create","providerId":"idp-create-user-if-unique","priority":10,"level":1,"requirement":"ALTERNATIVE"},
                 {"id":"handle-exec","authenticationFlow":true,"flowId":"handle","priority":20,"level":1,"requirement":"ALTERNATIVE"},
                 {"id":"confirm","providerId":"idp-confirm-link","priority":10,"level":2,"requirement":"REQUIRED"},
                 {"id":"verify","providerId":"idp-email-verification","priority":20,"level":2,"requirement":"DISABLED"},
                 {"id":"reauth","providerId":"idp-username-password-form","priority":30,"level":2,"requirement":"REQUIRED"},
                 {"id":"otp","providerId":"auth-otp-form","priority":40,"level":2,"requirement":"REQUIRED"}
                ]
                """);
        nativeFile = scratch.resolve("native.json");
        JSON.writeValue(nativeFile.toFile(), nativeFlow);
    }

    private record Plan(int status, String output) { }

    private Plan plan(String mode, ArrayNode flow) throws Exception {
        Method method = planner.getDeclaredMethod("existingAccountFlow", String[].class, JsonNode.class, PrintStream.class);
        method.setAccessible(true);
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        int status = (int) method.invoke(null, new String[]{"existing-account-flow", mode, "root", nativeFile.toString()},
                flow, new PrintStream(output));
        return new Plan(status, output.toString(java.nio.charset.StandardCharsets.UTF_8));
    }

    private ArrayNode initial() {
        ArrayNode flow = JSON.createArrayNode();
        flow.addObject().put("id", "ytu").put("providerId", "sky-ytu-first-login").put("priority", 9)
                .put("level", 0).put("requirement", "REQUIRED");
        nativeFlow.forEach(n -> flow.add(n.deepCopy()));
        return flow;
    }

    private ArrayNode complete() {
        ArrayNode flow = JSON.createArrayNode();
        flow.addObject().put("id", "ytu").put("providerId", "sky-ytu-first-login").put("priority", 8)
                .put("level", 0).put("requirement", "REQUIRED");
        flow.addObject().put("id", "prompt").put("providerId", "sky-existing-account-prompt").put("priority", 9)
                .put("level", 0).put("requirement", "REQUIRED");
        for (JsonNode n : nativeFlow) {
            var copy = n.deepCopy();
            if ("review".equals(copy.path("id").asText())) {
                ((com.fasterxml.jackson.databind.node.ObjectNode)copy).put("id", "wrapper")
                        .put("providerId", "sky-broker-review-profile").put("authenticationConfig", "own-config");
            }
            if ("create".equals(copy.path("id").asText())) {
                flow.addObject().put("id", "proven").put("providerId", "sky-existing-account-proven").put("priority", 9)
                        .put("level", 1).put("requirement", "ALTERNATIVE");
            }
            flow.add(copy);
        }
        return flow;
    }

    @Test
    void onAddsOnlyTheQuestionProofAlternativeAndConfigPreservingReviewWrapper() throws Exception {
        Plan plan = plan("on", initial());
        assertEquals(0, plan.status());
        assertTrue(plan.output().contains("review\t-\troot\tsky-broker-review-profile\t10\tnative-config\t-"));
        assertTrue(plan.output().contains("sky-existing-account-prompt\t9\tREQUIRED"));
        assertTrue(plan.output().contains("unique\tsky-existing-account-proven\t9\tALTERNATIVE"));
        assertFalse(plan.output().contains("remove\tcreate"));
        assertFalse(plan.output().contains("remove\tconfirm"));
        assertFalse(plan.output().contains("remove\totp"));
    }

    @Test
    void anAlreadyEnabledFlowHasNoMutationPlanned() throws Exception {
        Plan plan = plan("on", complete());
        assertEquals(0, plan.status());
        assertFalse(plan.output().contains("remove\t"));
        assertFalse(plan.output().contains("\tchange"));
        assertFalse(plan.output().lines().anyMatch(line -> line.split("\t")[1].equals("-")));
    }

    @Test
    void offRestoresTheNativeReviewAndRemovesOnlyOurTwoAdditionalExecutions() throws Exception {
        Plan plan = plan("off", complete());
        assertEquals(0, plan.status());
        assertTrue(plan.output().contains("remove\tprompt"));
        assertTrue(plan.output().contains("remove\tproven"));
        assertTrue(plan.output().contains("review\t-\troot\tidp-review-profile"));
        assertTrue(plan.output().contains("\town-config\t-"));
        assertFalse(plan.output().contains("remove\tcreate"));
    }

    @Test
    void unexpectedAutoLinkAndAChangedNativeOtpAreRefusedBeforeMutation() throws Exception {
        ArrayNode extra = initial();
        extra.addObject().put("id", "auto").put("providerId", "idp-auto-link").put("level", 1)
                .put("requirement", "ALTERNATIVE");
        assertEquals(4, plan("on", extra).status());
        ArrayNode changed = initial();
        changed.forEach(n -> { if (n.path("id").asText().equals("otp"))
            ((com.fasterxml.jackson.databind.node.ObjectNode)n).put("requirement", "DISABLED"); });
        assertEquals(4, plan("on", changed).status());
    }

    @Test
    void strictCopyShapeAcceptsOnlyTheKnownProtectionPositionsAndRequirements() throws Exception {
        Method method = planner.getDeclaredMethod("sameShape", String[].class, JsonNode.class);
        method.setAccessible(true);
        String[] args = {"same-shape", nativeFile.toString(), "sky-ytu-first-login"};
        assertEquals(0, method.invoke(null, args, complete()));
        ArrayNode changed = complete();
        changed.forEach(n -> { if (n.path("id").asText().equals("proven"))
            ((com.fasterxml.jackson.databind.node.ObjectNode)n).put("requirement", "REQUIRED"); });
        assertEquals(4, method.invoke(null, args, changed));
    }
}
