package com.skylab.passkey;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import java.io.ByteArrayOutputStream;
import java.io.PrintStream;
import java.lang.reflect.Method;
import java.net.URLClassLoader;
import java.nio.file.Path;
import javax.tools.ToolProvider;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import static org.junit.jupiter.api.Assertions.*;

/** Runs the actual email-flow planner used by keep/on/off, including a partially finished swap. */
class AfterSignUpFlowPlanTest {
    @TempDir static Path scratch;
    static final ObjectMapper JSON = new ObjectMapper();
    static Method planner;

    @BeforeAll static void compile() throws Exception {
        assertEquals(0, ToolProvider.getSystemJavaCompiler().run(null, null, null, "-cp",
                System.getProperty("java.class.path"), "-d", scratch.toString(), "../config/ReconcileJson.java"));
        Class<?> type = new URLClassLoader(new java.net.URL[]{scratch.toUri().toURL()},
                AfterSignUpFlowPlanTest.class.getClassLoader()).loadClass("ReconcileJson");
        planner = type.getDeclaredMethod("emailCodeFlow", String[].class, JsonNode.class, PrintStream.class);
        planner.setAccessible(true);
    }

    record Plan(int status, String text) { }
    Plan plan(ArrayNode flow) throws Exception {
        var bytes = new ByteArrayOutputStream();
        int status = (int) planner.invoke(null, new String[]{"email-code-flow", "sky-email-code", "sky email code",
                "sky email code conditional otp", "passkey-offer-authenticator,sky-after-login", "sky-username-password-form"},
                flow, new PrintStream(bytes));
        return new Plan(status, bytes.toString(java.nio.charset.StandardCharsets.UTF_8));
    }
    ArrayNode flow(String offer) throws Exception {
        ArrayNode nodes = (ArrayNode) JSON.readTree("""
          [{"id":"forms","flowId":"forms-flow","displayName":"forms","authenticationFlow":true,"requirement":"ALTERNATIVE","level":0,"priority":10},
           {"id":"password","flowId":"password-flow","displayName":"password","authenticationFlow":true,"requirement":"ALTERNATIVE","level":1,"priority":10},
           {"id":"password-form","providerId":"sky-username-password-form","requirement":"REQUIRED","level":2,"priority":10},
           {"id":"ordinary-offer","providerId":"passkey-offer-authenticator","requirement":"REQUIRED","level":2,"priority":20},
           {"id":"email","flowId":"email-flow","displayName":"sky email code","authenticationFlow":true,"requirement":"ALTERNATIVE","level":1,"priority":20},
           {"id":"code","providerId":"sky-email-code","requirement":"REQUIRED","level":2,"priority":10},
           {"id":"otp","flowId":"otp-flow","displayName":"sky email code conditional otp","authenticationFlow":true,"requirement":"CONDITIONAL","level":2,"priority":20},
           {"id":"condition","providerId":"conditional-user-configured","requirement":"REQUIRED","level":3,"priority":10},
           {"id":"otp-form","providerId":"auth-otp-form","requirement":"REQUIRED","level":3,"priority":20}]
          """);
        if (offer != null) nodes.addObject().put("id", "email-offer").put("providerId", offer)
                .put("requirement", "REQUIRED").put("level", 2).put("priority", 30);
        return nodes;
    }

    @Test void oldAndNewEachPlanWithoutChangingTheOrdinaryPasswordBranch() throws Exception {
        for (String provider : new String[]{"passkey-offer-authenticator", "sky-after-login"}) {
            Plan plan = plan(flow(provider));
            assertEquals(0, plan.status());
            assertTrue(plan.text().contains("offer\temail-offer\tREQUIRED\t30"));
            assertTrue(plan.text().contains("offer-provider\t" + provider));
            assertFalse(plan.text().contains("ordinary-offer"));
        }
    }
    @Test void duplicateOldAndNewIsRefusedWithNoPartialPlan() throws Exception {
        var flow = flow("passkey-offer-authenticator");
        flow.addObject().put("id", "duplicate").put("providerId", "sky-after-login")
                .put("requirement", "DISABLED").put("level", 2).put("priority", 40);
        Plan plan = plan(flow);
        assertEquals(4, plan.status()); assertEquals("", plan.text());
    }
    @Test void missingOfferCanBeCompletedAfterAnInterruptedDisabledSwap() throws Exception {
        var flow = flow(null);
        ((com.fasterxml.jackson.databind.node.ObjectNode)flow.get(4)).put("requirement", "DISABLED");
        Plan plan = plan(flow);
        assertEquals(0, plan.status()); assertTrue(plan.text().contains("offer\t-\t-\t-"));
    }
    @Test void foreignLeafAndWrongOrderAreRefused() throws Exception {
        assertEquals(4, plan(flow("unexpected-provider")).status());
        var flow = flow("sky-after-login");
        ((com.fasterxml.jackson.databind.node.ObjectNode)flow.get(flow.size() - 1)).put("priority", 15);
        assertEquals(4, plan(flow).status());
    }
}
