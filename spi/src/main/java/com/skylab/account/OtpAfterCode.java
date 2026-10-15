package com.skylab.account;

import org.keycloak.authentication.Authenticator;
import org.keycloak.authentication.AuthenticatorFactory;
import org.keycloak.authentication.authenticators.browser.OTPFormAuthenticatorFactory;
import org.keycloak.authentication.authenticators.conditional.ConditionalAuthenticator;
import org.keycloak.authentication.authenticators.conditional.ConditionalUserConfiguredAuthenticatorFactory;
import org.keycloak.models.AuthenticationExecutionModel;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;

import java.util.List;

/**
 * Whether Keycloak asks a person with OTP for it after the e-mail code (eskylab-login-ux 08, spec S6;
 * security review K1). The reconciler builds the subflow so that it does
 * ({@code KEYCLOAK_EMAIL_CODE_LOGIN=on}) and stops a release when it no longer does, but an Admin
 * Console change takes effect at once; this check makes the code itself refuse a person with OTP
 * until the subflow is right again (fail closed).
 *
 * <p>The shape that asks: after the code step, in the subflow that runs it, a CONDITIONAL subflow
 * whose only enabled condition is one REQUIRED {@code conditional-user-configured} and whose only
 * REQUIRED or CONDITIONAL step is one REQUIRED {@code auth-otp-form}. Keycloak's user configured
 * condition holds when the person has every such step configured, so with the OTP form alone it
 * holds exactly for a person with OTP, and the OTP form then runs. Conditions are recognised as
 * Keycloak recognises them (the authenticator its factory creates is a
 * {@link ConditionalAuthenticator}); a provider the server does not know counts as a step. This is
 * the reconciler's own rule for the reset OTP step ({@code ReconcileJson otp-guard}).
 */
final class OtpAfterCode {

    private OtpAfterCode() {
    }

    static boolean asked(KeycloakSession session, RealmModel realm, AuthenticationExecutionModel step) {
        if (step == null || step.getId() == null || step.getParentFlow() == null) {
            return false;
        }
        List<AuthenticationExecutionModel> siblings = sorted(realm, step.getParentFlow());
        int at = -1;
        for (int i = 0; i < siblings.size(); i++) {
            if (step.getId().equals(siblings.get(i).getId())) {
                at = i;
            }
        }
        if (at < 0) {
            return false;
        }
        for (AuthenticationExecutionModel next : siblings.subList(at + 1, siblings.size())) {
            if (next.isAuthenticatorFlow() && next.isConditional() && asksForOtp(session, realm, next.getFlowId())) {
                return true;
            }
        }
        return false;
    }

    private static boolean asksForOtp(KeycloakSession session, RealmModel realm, String flowId) {
        if (flowId == null) {
            return false;
        }
        int conditions = 0;
        boolean userConfigured = false;
        int steps = 0;
        boolean otpForm = false;
        for (AuthenticationExecutionModel part : sorted(realm, flowId)) {
            if (part.isDisabled()) {
                continue;
            }
            if (isCondition(session, part)) {
                conditions++;
                userConfigured = part.isRequired()
                        && ConditionalUserConfiguredAuthenticatorFactory.PROVIDER_ID.equals(part.getAuthenticator());
            } else if (part.isRequired() || part.isConditional()) {
                steps++;
                otpForm = part.isRequired() && !part.isAuthenticatorFlow()
                        && OTPFormAuthenticatorFactory.PROVIDER_ID.equals(part.getAuthenticator());
            }
        }
        return conditions == 1 && userConfigured && steps == 1 && otpForm;
    }

    private static boolean isCondition(KeycloakSession session, AuthenticationExecutionModel part) {
        if (part.isAuthenticatorFlow() || part.getAuthenticator() == null) {
            return false;
        }
        if (!(session.getKeycloakSessionFactory().getProviderFactory(Authenticator.class, part.getAuthenticator())
                instanceof AuthenticatorFactory factory)) {
            return false;
        }
        return factory.create(session) instanceof ConditionalAuthenticator;
    }

    private static List<AuthenticationExecutionModel> sorted(RealmModel realm, String flowId) {
        return realm.getAuthenticationExecutionsStream(flowId)
                .sorted(AuthenticationExecutionModel.ExecutionComparator.SINGLETON)
                .toList();
    }
}
