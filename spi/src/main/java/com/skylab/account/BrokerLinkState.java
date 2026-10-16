package com.skylab.account;

import org.keycloak.authentication.AuthenticationFlowContext;
import org.keycloak.authentication.AuthenticationProcessor;
import org.keycloak.authentication.authenticators.broker.AbstractIdpAuthenticator;
import org.keycloak.authentication.authenticators.broker.util.SerializedBrokeredIdentityContext;
import org.keycloak.broker.provider.BrokeredIdentityContext;
import org.keycloak.common.util.Base64Url;
import org.keycloak.common.util.SecretGenerator;
import org.keycloak.credential.CredentialModel;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;
import org.keycloak.models.credential.OTPCredentialModel;
import org.keycloak.sessions.AuthenticationSessionModel;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Comparator;
import java.util.HexFormat;
import java.util.List;

/** Server-only state of the optional, explicitly chosen first-Microsoft-login linking path. */
final class BrokerLinkState {
    static final String PREFIX = "sky-existing-account.";
    static final String STAGE = PREFIX + "stage";
    static final String IDENTIFIER = PREFIX + "identifier";
    static final String TARGET = PREFIX + "target";
    static final String PRIMARY = PREFIX + "primary";
    static final String CODE = PREFIX + "code";
    static final String SENT = PREFIX + "sent";
    static final String DEADLINE = PREFIX + "deadline";
    static final String METHOD = PREFIX + "method";
    static final String OTP = PREFIX + "otp";
    static final String PROOF = PREFIX + "proof";
    static final String REQUIRED = PREFIX + "required";
    static final String ORIGINAL_EMAIL = PREFIX + "original-email";

    private BrokerLinkState() { }

    static String handle() { return Base64Url.encode(SecretGenerator.getInstance().randomBytes(32)); }

    static String normal(String value) { return value == null ? "" : PersonalEmailProof.normalise(value); }
    static String text(String value) { return value == null ? "" : value; }

    static BrokerLinkProofs.Binding binding(AuthenticationFlowContext context,
            SerializedBrokeredIdentityContext broker, UserModel target) {
        AuthenticationSessionModel auth = context.getAuthenticationSession();
        return new BrokerLinkProofs.Binding(context.getRealm().getId(), auth.getParentSession().getId(),
                auth.getTabId(), auth.getClient().getClientId(), broker.getIdentityProviderId(), broker.getId(),
                normal(broker.getFirstAttribute("schoolEmail")), target == null ? "" : target.getId(),
                target == null ? "" : normal(target.getEmail()), text(broker.getFirstName()), text(broker.getLastName()));
    }

    static BrokerLinkProofs.Binding binding(RealmModel realm, AuthenticationSessionModel auth,
            BrokeredIdentityContext broker, UserModel target, String primary) {
        return new BrokerLinkProofs.Binding(realm.getId(), auth.getParentSession().getId(), auth.getTabId(),
                auth.getClient().getClientId(), broker.getIdpConfig().getAlias(), broker.getId(),
                normal(broker.getUserAttribute("schoolEmail")), target.getId(), normal(primary),
                text(broker.getFirstName()), text(broker.getLastName()));
    }

    static String otpSnapshot(UserModel target) {
        List<String[]> values = target.credentialManager().getStoredCredentialsByTypeStream(OTPCredentialModel.TYPE)
                .sorted(Comparator.comparing(CredentialModel::getId))
                .map(c -> new String[]{c.getId(), text(c.getCredentialData()), text(c.getSecretData())}).toList();
        return otpSnapshot(values);
    }

    static String otpSnapshot(List<String[]> values) {
        if (values.isEmpty()) return "";
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            for (String[] credential : values) {
                for (String value : credential) {
                    byte[] bytes = text(value).getBytes(StandardCharsets.UTF_8);
                    digest.update(java.nio.ByteBuffer.allocate(4).putInt(bytes.length).array());
                    digest.update(bytes);
                }
            }
            return HexFormat.of().formatHex(digest.digest());
        } catch (NoSuchAlgorithmException impossible) {
            throw new IllegalStateException("SHA-256 unavailable", impossible);
        }
    }

    static void clear(AuthenticationFlowContext context) {
        AuthenticationSessionModel auth = context.getAuthenticationSession();
        String originalEmail = auth.getAuthNote(ORIGINAL_EMAIL);
        if (originalEmail != null) {
            SerializedBrokeredIdentityContext broker = SkyExistingAccountPrompt.broker(context);
            if (broker != null) {
                broker.setEmail(originalEmail.isEmpty() ? null : originalEmail);
                broker.saveToAuthenticationSession(auth, AbstractIdpAuthenticator.BROKERED_CONTEXT_NOTE);
            }
        }
        BrokerLinkProofs proofs = new BrokerLinkProofs(context.getSession().singleUseObjects());
        proofs.discardCode(auth.getAuthNote(CODE));
        proofs.discardProof(auth.getAuthNote(PROOF));
        for (String note : List.of(STAGE, IDENTIFIER, TARGET, PRIMARY, CODE, SENT, DEADLINE, METHOD, OTP, PROOF,
                REQUIRED, ORIGINAL_EMAIL)) {
            auth.removeAuthNote(note);
        }
        auth.removeAuthNote(AbstractIdpAuthenticator.EXISTING_USER_INFO);
        auth.removeAuthNote(AuthenticationProcessor.AUTHN_CREDENTIALS);
        auth.removeAuthNote(org.keycloak.authentication.authenticators.browser.AbstractUsernameFormAuthenticator
                .USER_SET_BEFORE_USERNAME_PASSWORD_AUTH);
        auth.removeAuthNote(org.keycloak.services.managers.AuthenticationManager.PASSWORD_VALIDATED);
        context.clearUser();
    }

    static BrokerLinkProofs.Proof proof(KeycloakSession session, AuthenticationSessionModel auth) {
        return new BrokerLinkProofs(session.singleUseObjects()).peekProof(auth.getAuthNote(PROOF));
    }
}
