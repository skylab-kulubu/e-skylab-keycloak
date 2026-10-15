package com.skylab.account;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.keycloak.models.AuthenticationExecutionModel;
import org.keycloak.models.AuthenticationFlowModel;
import org.keycloak.models.AuthenticatorConfigModel;
import org.keycloak.models.RealmModel;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * Whether a realm offers Self-registration (eskylab-login-ux 09): the password form tells the theme,
 * so "Hesabın yok mu? E-postayla hesap aç" shows only where the "E-postayla devam et" step has its
 * sign-up setting on.
 */
class EmailCodeSignUpTest {

    private final RealmModel realm = mock(RealmModel.class);
    private final Map<String, List<AuthenticationExecutionModel>> flows = new HashMap<>();
    private final Map<String, AuthenticatorConfigModel> configs = new HashMap<>();
    private AuthenticationExecutionModel subflow;
    private AuthenticationExecutionModel step;

    @BeforeEach
    void setUp() {
        AuthenticationFlowModel browser = new AuthenticationFlowModel();
        browser.setId("browser");
        when(realm.getBrowserFlow()).thenReturn(browser);
        when(realm.getAuthenticationExecutionsStream(anyString()))
                .thenAnswer(call -> flows.getOrDefault(call.<String>getArgument(0), List.of()).stream());
        when(realm.getAuthenticatorConfigById(anyString())).thenAnswer(call -> configs.get(call.<String>getArgument(0)));
        // browser -> forms -> (password flow, sky email code -> sky-email-code)
        flow("browser", "forms", AuthenticationExecutionModel.Requirement.ALTERNATIVE);
        flow("forms", "password", AuthenticationExecutionModel.Requirement.ALTERNATIVE);
        subflow = flow("forms", "email-code", AuthenticationExecutionModel.Requirement.ALTERNATIVE);
        step = execution("email-code", EmailCodeAuthenticator.PROVIDER_ID, AuthenticationExecutionModel.Requirement.REQUIRED);
    }

    private AuthenticationExecutionModel flow(String parent, String id, AuthenticationExecutionModel.Requirement requirement) {
        AuthenticationExecutionModel execution = new AuthenticationExecutionModel();
        execution.setId("exec-" + id);
        execution.setParentFlow(parent);
        execution.setAuthenticatorFlow(true);
        execution.setFlowId(id);
        execution.setRequirement(requirement);
        flows.computeIfAbsent(parent, key -> new ArrayList<>()).add(execution);
        return execution;
    }

    private AuthenticationExecutionModel execution(String parent, String provider, AuthenticationExecutionModel.Requirement requirement) {
        AuthenticationExecutionModel execution = new AuthenticationExecutionModel();
        execution.setId("exec-" + provider);
        execution.setParentFlow(parent);
        execution.setAuthenticator(provider);
        execution.setRequirement(requirement);
        flows.computeIfAbsent(parent, key -> new ArrayList<>()).add(execution);
        return execution;
    }

    private void signUp(String value) {
        AuthenticatorConfigModel config = new AuthenticatorConfigModel();
        config.setId("config-1");
        config.setConfig(Map.of(EmailCodeSignUp.CONFIG, value));
        configs.put("config-1", config);
        step.setAuthenticatorConfig("config-1");
    }

    @Test
    void offeredOnlyWhereTheStepHasTheSettingOn() {
        assertFalse(EmailCodeSignUp.isOffered(realm), "no config: off");
        signUp("false");
        assertFalse(EmailCodeSignUp.isOffered(realm));
        signUp("true");
        assertTrue(EmailCodeSignUp.isOffered(realm));
    }

    @Test
    void notOfferedWhenTheStepOrItsSubflowIsDisabled() {
        signUp("true");
        subflow.setRequirement(AuthenticationExecutionModel.Requirement.DISABLED);
        assertFalse(EmailCodeSignUp.isOffered(realm), "KEYCLOAK_EMAIL_CODE_LOGIN=off turns the sign-up off too");
        subflow.setRequirement(AuthenticationExecutionModel.Requirement.ALTERNATIVE);
        step.setRequirement(AuthenticationExecutionModel.Requirement.DISABLED);
        assertFalse(EmailCodeSignUp.isOffered(realm));
    }

    @Test
    void notOfferedWithoutABrowserFlowOrARealm() {
        signUp("true");
        when(realm.getBrowserFlow()).thenReturn(null);
        assertFalse(EmailCodeSignUp.isOffered(realm));
        assertFalse(EmailCodeSignUp.isOffered(null));
    }

    @Test
    void anotherStepsConfigDoesNotCount() {
        AuthenticationExecutionModel other = execution("email-code", "auth-otp-form", AuthenticationExecutionModel.Requirement.REQUIRED);
        AuthenticatorConfigModel config = new AuthenticatorConfigModel();
        config.setConfig(Map.of(EmailCodeSignUp.CONFIG, "true"));
        configs.put("config-2", config);
        other.setAuthenticatorConfig("config-2");
        assertFalse(EmailCodeSignUp.isOffered(realm));
    }
}
