package com.skylab.account;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.keycloak.authentication.Authenticator;
import org.keycloak.authentication.authenticators.browser.OTPFormAuthenticatorFactory;
import org.keycloak.authentication.authenticators.conditional.ConditionalRoleAuthenticatorFactory;
import org.keycloak.authentication.authenticators.conditional.ConditionalUserConfiguredAuthenticatorFactory;
import org.keycloak.models.AuthenticationExecutionModel;
import org.keycloak.models.AuthenticationExecutionModel.Requirement;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;
import org.keycloak.models.RealmModel;

import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * The run-time guard of eskylab-login-ux 08 (security review K1): the e-mail code signs in a person
 * with OTP only while the flow still asks for it after the code, whatever an Admin Console change did
 * to the subflow since the last reconciliation.
 */
class OtpAfterCodeTest {

    static final String CODE_FLOW = "code-flow";
    static final String OTP_FLOW = "otp-flow";

    private final KeycloakSession session = mock(KeycloakSession.class);
    private final RealmModel realm = mock(RealmModel.class);
    private final Map<String, List<AuthenticationExecutionModel>> flows = new HashMap<>();
    private AuthenticationExecutionModel step;

    static AuthenticationExecutionModel execution(String id, String flow, int priority, Requirement requirement,
            String provider) {
        AuthenticationExecutionModel model = new AuthenticationExecutionModel();
        model.setId(id);
        model.setParentFlow(flow);
        model.setPriority(priority);
        model.setRequirement(requirement);
        model.setAuthenticator(provider);
        return model;
    }

    static AuthenticationExecutionModel subflow(String id, String flow, int priority, Requirement requirement,
            String subflowId) {
        AuthenticationExecutionModel model = execution(id, flow, priority, requirement, null);
        model.setAuthenticatorFlow(true);
        model.setFlowId(subflowId);
        return model;
    }

    /**
     * The shape the reconciler builds (KEYCLOAK_EMAIL_CODE_LOGIN=on): the code, the CONDITIONAL OTP
     * subflow (user configured, then the OTP form), the passkey offer. Returns the code step.
     */
    static AuthenticationExecutionModel reconciledShape(Map<String, List<AuthenticationExecutionModel>> flows) {
        AuthenticationExecutionModel step = execution("step", CODE_FLOW, 10, Requirement.REQUIRED,
                EmailCodeAuthenticator.PROVIDER_ID);
        flows.put(CODE_FLOW, new ArrayList<>(List.of(step,
                subflow("otp", CODE_FLOW, 20, Requirement.CONDITIONAL, OTP_FLOW),
                execution("offer", CODE_FLOW, 30, Requirement.REQUIRED, "passkey-offer-authenticator"))));
        flows.put(OTP_FLOW, new ArrayList<>(List.of(
                execution("condition", OTP_FLOW, 10, Requirement.REQUIRED, ConditionalUserConfiguredAuthenticatorFactory.PROVIDER_ID),
                execution("otp-form", OTP_FLOW, 20, Requirement.REQUIRED, OTPFormAuthenticatorFactory.PROVIDER_ID))));
        return step;
    }

    /** Keycloak's own factories for the parts that matter, as the server finds them. */
    static void knownAuthenticators(KeycloakSession session) {
        KeycloakSessionFactory factories = mock(KeycloakSessionFactory.class);
        when(session.getKeycloakSessionFactory()).thenReturn(factories);
        when(factories.getProviderFactory(eq(Authenticator.class), anyString())).thenReturn(null);
        when(factories.getProviderFactory(Authenticator.class, ConditionalUserConfiguredAuthenticatorFactory.PROVIDER_ID))
                .thenReturn(new ConditionalUserConfiguredAuthenticatorFactory());
        when(factories.getProviderFactory(Authenticator.class, ConditionalRoleAuthenticatorFactory.PROVIDER_ID))
                .thenReturn(new ConditionalRoleAuthenticatorFactory());
        when(factories.getProviderFactory(Authenticator.class, OTPFormAuthenticatorFactory.PROVIDER_ID))
                .thenReturn(new OTPFormAuthenticatorFactory());
    }

    @BeforeEach
    void setUp() {
        knownAuthenticators(session);
        when(realm.getAuthenticationExecutionsStream(anyString()))
                .thenAnswer(call -> flows.getOrDefault(call.<String>getArgument(0), List.of()).stream());
        step = reconciledShape(flows);
    }

    private boolean asked() {
        return OtpAfterCode.asked(session, realm, step);
    }

    private AuthenticationExecutionModel part(String flow, String id) {
        return flows.get(flow).stream().filter(model -> model.getId().equals(id)).findFirst().orElseThrow();
    }

    @Test
    void theReconciledShapeAsksForTheOtp() {
        assertTrue(asked());
    }

    @Test
    void theStoreOrderDoesNotMatterOnlyThePriorities() {
        Collections.reverse(flows.get(CODE_FLOW));
        Collections.reverse(flows.get(OTP_FLOW));
        assertTrue(asked());
    }

    @Test
    void aDisabledOtpSubflowAsksForNothing() {
        part(CODE_FLOW, "otp").setRequirement(Requirement.DISABLED);
        assertFalse(asked());
    }

    @Test
    void anOtpSubflowThatIsNotConditionalIsRefused() {
        // REQUIRED would ask everyone, ALTERNATIVE nobody next to the REQUIRED code: neither is the shape.
        part(CODE_FLOW, "otp").setRequirement(Requirement.REQUIRED);
        assertFalse(asked());
        part(CODE_FLOW, "otp").setRequirement(Requirement.ALTERNATIVE);
        assertFalse(asked());
    }

    @Test
    void anOtpSubflowBeforeTheCodeAsksTooEarly() {
        part(CODE_FLOW, "otp").setPriority(5);
        assertFalse(asked());
    }

    @Test
    void anOtpSubflowInAnotherFlowDoesNotCount() {
        part(CODE_FLOW, "otp").setParentFlow("elsewhere");
        flows.put("elsewhere", new ArrayList<>(List.of(part(CODE_FLOW, "otp"))));
        flows.get(CODE_FLOW).removeIf(model -> model.getId().equals("otp"));
        assertFalse(asked());
    }

    @Test
    void aDisabledConditionOrOtpFormIsRefused() {
        part(OTP_FLOW, "condition").setRequirement(Requirement.DISABLED);
        assertFalse(asked());
        part(OTP_FLOW, "condition").setRequirement(Requirement.REQUIRED);
        part(OTP_FLOW, "otp-form").setRequirement(Requirement.DISABLED);
        assertFalse(asked());
        part(OTP_FLOW, "otp-form").setRequirement(Requirement.ALTERNATIVE);
        assertFalse(asked());
    }

    @Test
    void anotherConditionNextToUserConfiguredIsRefused() {
        // Conditions are ANDed: a role condition would let everyone without the role skip the OTP.
        flows.get(OTP_FLOW).add(execution("role", OTP_FLOW, 15, Requirement.REQUIRED,
                ConditionalRoleAuthenticatorFactory.PROVIDER_ID));
        assertFalse(asked());
    }

    @Test
    void anotherRequiredStepNextToTheOtpFormIsRefused() {
        // User configured would then need both: a person with OTP alone skips the subflow.
        flows.get(OTP_FLOW).add(execution("webauthn", OTP_FLOW, 30, Requirement.REQUIRED, "webauthn-authenticator"));
        assertFalse(asked());
    }

    @Test
    void anUnknownProviderInTheOtpSubflowIsRefused() {
        flows.get(OTP_FLOW).add(execution("unknown", OTP_FLOW, 30, Requirement.CONDITIONAL, "nobody-knows"));
        assertFalse(asked());
    }

    @Test
    void disabledOrAlternativeExtrasInTheOtpSubflowChangeNothing() {
        flows.get(OTP_FLOW).add(execution("off", OTP_FLOW, 30, Requirement.DISABLED, "webauthn-authenticator"));
        flows.get(OTP_FLOW).add(execution("alt", OTP_FLOW, 40, Requirement.ALTERNATIVE, "webauthn-authenticator"));
        assertTrue(asked());
    }

    @Test
    void withoutItsOwnExecutionTheStepIsRefused() {
        assertFalse(OtpAfterCode.asked(session, realm, null));
        flows.get(CODE_FLOW).removeIf(model -> model.getId().equals("step"));
        assertFalse(asked());
    }
}
