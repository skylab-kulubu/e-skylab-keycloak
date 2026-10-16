package com.skylab.account;

import org.keycloak.Config;
import org.keycloak.authentication.AuthenticationFlowContext;
import org.keycloak.authentication.AuthenticationFlowError;
import org.keycloak.authentication.Authenticator;
import org.keycloak.authentication.AuthenticatorFactory;
import org.keycloak.authentication.authenticators.broker.AbstractIdpAuthenticator;
import org.keycloak.authentication.authenticators.broker.IdpReviewProfileAuthenticator;
import org.keycloak.authentication.authenticators.broker.util.SerializedBrokeredIdentityContext;
import org.keycloak.broker.provider.AbstractIdentityProvider;
import org.keycloak.broker.provider.BrokeredIdentityContext;
import org.keycloak.models.AuthenticationExecutionModel;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;
import org.keycloak.provider.ProviderConfigProperty;

import java.util.List;
import java.util.Map;

/** Factories for the three narrowly scoped first-broker-login additions. */
public class SkyExistingAccountPromptFactory implements AuthenticatorFactory {
    public static final String REVIEW_ID = "sky-broker-review-profile";
    public static final String PROVEN_ID = "sky-existing-account-proven";
    private volatile EmailCodeSettings settings = EmailCodeSettings.from(null, Map.of());

    @Override public Authenticator create(KeycloakSession session) {
        return new SkyExistingAccountPrompt(settings, new BackgroundLoginCodeMail(settings));
    }
    @Override public void init(Config.Scope config) {
        // The callback guard has no component configuration. Both halves intentionally use the
        // same realm-wide alias source (SKY_ACCOUNT_YTU_IDP_ALIAS, default OBS).
        settings = EmailCodeSettings.from(null, System.getenv());
    }
    @Override public String getId() { return SkyExistingAccountPrompt.PROVIDER_ID; }
    @Override public String getDisplayType() { return "SKY LAB existing-account protection"; }
    @Override public String getHelpText() { return "Asks for an existing account before a first Microsoft login creates one."; }
    @Override public String getReferenceCategory() { return null; }
    @Override public boolean isConfigurable() { return false; }
    @Override public boolean isUserSetupAllowed() { return false; }
    @Override public List<ProviderConfigProperty> getConfigProperties() { return List.of(); }
    @Override public void postInit(KeycloakSessionFactory factory) { }
    @Override public void close() { }
    @Override public AuthenticationExecutionModel.Requirement[] getRequirementChoices() {
        return new AuthenticationExecutionModel.Requirement[]{AuthenticationExecutionModel.Requirement.REQUIRED,
                AuthenticationExecutionModel.Requirement.DISABLED};
    }

    public static final class Review extends SkyExistingAccountPromptFactory {
        @Override public String getId() { return REVIEW_ID; }
        @Override public String getDisplayType() { return "SKY LAB broker profile review"; }
        @Override public Authenticator create(KeycloakSession session) {
            return new IdpReviewProfileAuthenticator() {
                @Override protected void authenticateImpl(AuthenticationFlowContext context,
                        SerializedBrokeredIdentityContext serialized, BrokeredIdentityContext broker) {
                    if (marked(context)) {
                        if (validated(context) != null) context.success();
                    } else super.authenticateImpl(context, serialized, broker);
                }
                @Override protected void actionImpl(AuthenticationFlowContext context,
                        SerializedBrokeredIdentityContext serialized, BrokeredIdentityContext broker) {
                    if (marked(context)) {
                        if (!restartIfRequested(context) && validated(context) != null) context.success();
                    } else super.actionImpl(context, serialized, broker);
                }
            };
        }
    }

    public static final class Proven extends SkyExistingAccountPromptFactory {
        @Override public String getId() { return PROVEN_ID; }
        @Override public String getDisplayType() { return "SKY LAB proven existing-account link"; }
        @Override public AuthenticationExecutionModel.Requirement[] getRequirementChoices() {
            return new AuthenticationExecutionModel.Requirement[]{AuthenticationExecutionModel.Requirement.ALTERNATIVE,
                    AuthenticationExecutionModel.Requirement.DISABLED};
        }
        @Override public Authenticator create(KeycloakSession session) {
            return new Authenticator() {
                @Override public void authenticate(AuthenticationFlowContext context) {
                    if (!marked(context)) { context.attempted(); return; }
                    UserModel target = validated(context);
                    if (target == null) return;
                    context.getAuthenticationSession().removeAuthNote(AbstractIdentityProvider.BROKER_REGISTERED_NEW_USER);
                    context.setUser(target);
                    context.success();
                }
                @Override public void action(AuthenticationFlowContext context) {
                    if (!restartIfRequested(context)) authenticate(context);
                }
                @Override public boolean requiresUser() { return false; }
                @Override public boolean configuredFor(KeycloakSession s, RealmModel r, UserModel u) { return true; }
                @Override public void setRequiredActions(KeycloakSession s, RealmModel r, UserModel u) { }
                @Override public void close() { }
            };
        }
    }

    static boolean marked(AuthenticationFlowContext context) {
        return context.getAuthenticationSession().getAuthNote(BrokerLinkState.REQUIRED) != null
                || context.getAuthenticationSession().getAuthNote(BrokerLinkState.PROOF) != null;
    }

    private static UserModel validated(AuthenticationFlowContext context) {
        BrokerLinkProofs.Proof proof = BrokerLinkState.proof(context.getSession(), context.getAuthenticationSession());
        UserModel target = proof == null ? null : context.getSession().users().getUserById(context.getRealm(),
                proof.binding().target());
        if (target != null && SkyExistingAccountPrompt.eligible(context, target)
                && proof.binding().equals(BrokerLinkState.binding(context, SkyExistingAccountPrompt.broker(context), target))
                && proof.otpCredentials().equals(BrokerLinkState.otpSnapshot(target))) return target;
        // An ALTERNATIVE exception/attempted result would let Create User If Unique run next.
        context.failureChallenge(AuthenticationFlowError.INVALID_CREDENTIALS, context.form()
                .setAttribute("skyExistingAccountStage", "unavailable")
                .setAttribute("skyExistingAccountError", "try_again").createForm(SkyExistingAccountPrompt.TEMPLATE));
        return null;
    }

    private static boolean restartIfRequested(AuthenticationFlowContext context) {
        if (!"new-account".equals(context.getHttpRequest().getDecodedFormParameters()
                .getFirst(SkyExistingAccountPrompt.ACTION))) return false;
        // Only the person's explicit escape clears a failed link and restarts creation.
        // resetFlow clears *all* auth notes before its listener runs. Restore/clean the old state
        // now, and capture the broker context before that reset, like native Confirm Link does.
        BrokerLinkState.clear(context);
        SerializedBrokeredIdentityContext broker = SkyExistingAccountPrompt.broker(context);
        if (broker == null) {
            context.failureChallenge(AuthenticationFlowError.IDENTITY_PROVIDER_ERROR, context.form()
                    .setAttribute("skyExistingAccountStage", "unavailable").createForm(SkyExistingAccountPrompt.TEMPLATE));
            return true;
        }
        context.resetFlow(() -> {
            broker.saveToAuthenticationSession(context.getAuthenticationSession(), AbstractIdpAuthenticator.BROKERED_CONTEXT_NOTE);
            context.getAuthenticationSession().setAuthNote(BrokerLinkState.STAGE, "new-account");
        });
        return true;
    }
}
