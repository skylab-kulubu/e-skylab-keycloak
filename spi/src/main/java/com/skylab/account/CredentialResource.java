package com.skylab.account;

import com.fasterxml.jackson.databind.node.ObjectNode;
import jakarta.ws.rs.Consumes;
import jakarta.ws.rs.DELETE;
import jakarta.ws.rs.HeaderParam;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.PathParam;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;
import org.keycloak.WebAuthnConstants;
import org.keycloak.common.util.Base64Url;
import org.keycloak.common.util.SecretGenerator;
import org.keycloak.common.util.Time;
import org.keycloak.credential.CredentialModel;
import org.keycloak.events.Details;
import org.keycloak.events.Errors;
import org.keycloak.events.EventBuilder;
import org.keycloak.events.EventType;
import org.keycloak.models.ModelDuplicateException;
import org.keycloak.models.ModelException;
import org.keycloak.models.OTPPolicy;
import org.keycloak.models.RealmModel;
import org.keycloak.models.SingleUseObjectProvider;
import org.keycloak.models.UserCredentialModel;
import org.keycloak.models.UserModel;
import org.keycloak.models.UserSessionModel;
import org.keycloak.models.credential.OTPCredentialModel;
import org.keycloak.models.credential.PasswordCredentialModel;
import org.keycloak.models.utils.Base32;
import org.keycloak.models.utils.CredentialValidation;
import org.keycloak.models.utils.HmacOTP;
import org.keycloak.policy.PasswordPolicyManagerProvider;
import org.keycloak.policy.PolicyError;
import org.keycloak.services.managers.AuthenticationManager;
import org.keycloak.util.JsonSerialization;
import org.keycloak.utils.CredentialHelper;

import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;
import java.util.stream.Stream;

/**
 * {@code v1/credentials}: password change, authenticator-app setup, passkey registration and
 * credential removal (all under sudo).
 */
public final class CredentialResource {

    static final int TOTP_SETUP_TTL_SECONDS = 600;
    static final int MAX_LABEL_LENGTH = 64;

    private static final String TOTP_SETUP_KEY_PREFIX = "sky-account:totp-setup:";
    private static final String SECRET_NOTE = "secret";
    private static final Pattern OTP_CODE = Pattern.compile("^[0-9]{4,10}$");
    private static final Pattern SETUP_HANDLE = Pattern.compile("^[A-Za-z0-9_-]{43}$");
    private static final Pattern CREDENTIAL_ID = Pattern.compile("^[A-Za-z0-9-]{1,64}$");

    private final AccountRequest request;

    CredentialResource(AccountRequest request) {
        this.request = request;
    }

    @POST
    @Path("password")
    @Consumes(MediaType.APPLICATION_JSON)
    @Produces({MediaType.APPLICATION_JSON, Problem.MEDIA_TYPE})
    public Response changePassword(@HeaderParam(SudoTokens.HEADER) String sudoToken, String body) {
        return request.execute(() -> {
            Caller caller = request.authenticate();
            request.beginMutation(caller, RateLimiter.MUTATION);
            request.requireSudo(caller, sudoToken);
            RequestBody parsed = RequestBody.parse(body, Set.of("newPassword", "logoutOtherSessions"));
            String newPassword = parsed.requireString("newPassword", 1, 1024);
            boolean logoutOtherSessions = parsed.requireBoolean("logoutOtherSessions");

            RealmModel realm = request.realm();
            UserModel user = caller.user();
            EventBuilder event = request.event(caller)
                    .event(EventType.UPDATE_CREDENTIAL)
                    .detail(Details.CREDENTIAL_TYPE, PasswordCredentialModel.PASSWORD);
            EventBuilder deprecatedEvent = event.clone().event(EventType.UPDATE_PASSWORD);

            PolicyError policyError = request.session().getProvider(PasswordPolicyManagerProvider.class)
                    .validate(realm, user, newPassword);
            if (policyError != null) {
                rejectPassword(event, deprecatedEvent, policyError.getMessage());
                throw Problems.passwordPolicy(
                        policyError.getMessage(),
                        parameters(policyError.getParameters()),
                        request.policyMessages().render(policyError.getMessage(), policyError.getParameters()))
                        .exception();
            }
            final boolean updated;
            try {
                updated = user.credentialManager().updateCredential(UserCredentialModel.password(newPassword, false));
            } catch (ModelException exception) {
                rejectPassword(event, deprecatedEvent, exception.getMessage());
                throw Problems.passwordRejected(
                        request.policyMessages().render(exception.getMessage(), exception.getParameters()))
                        .exception();
            }
            if (!updated) {
                rejectPassword(event, deprecatedEvent, "not_updated");
                throw Problems.internalError().exception();
            }
            if (logoutOtherSessions) {
                logoutOtherSessions(caller, event);
            }
            event.success();
            deprecatedEvent.success();
            return AccountRequest.noContent();
        });
    }

    @POST
    @Path("totp/setup")
    @Produces({MediaType.APPLICATION_JSON, Problem.MEDIA_TYPE})
    public Response setupTotp(@HeaderParam(SudoTokens.HEADER) String sudoToken) {
        return request.execute(() -> {
            Caller caller = request.authenticate();
            request.beginMutation(caller, RateLimiter.MUTATION);
            request.requireSudo(caller, sudoToken);

            RealmModel realm = request.realm();
            OTPPolicy policy = realm.getOTPPolicy();
            String secret = HmacOTP.generateSecret(20);
            String handle = Base64Url.encode(SecretGenerator.getInstance().randomBytes(32));
            request.session().singleUseObjects().put(
                    totpSetupKey(caller.user(), handle),
                    TOTP_SETUP_TTL_SECONDS,
                    Map.of(SECRET_NOTE, secret));

            ObjectNode body = JsonSerialization.mapper.createObjectNode();
            body.put("setupHandle", handle);
            body.put("secret", Base32.encode(secret.getBytes(StandardCharsets.UTF_8)));
            body.put("otpauthUri", policy.getKeyURI(realm, caller.user(), secret));
            body.put("expiresAt", AccountRequest.isoSeconds(Time.currentTime() + TOTP_SETUP_TTL_SECONDS));
            ObjectNode policyNode = body.putObject("policy");
            policyNode.put("type", policy.getType());
            policyNode.put("algorithm", policy.getAlgorithmKey());
            policyNode.put("digits", policy.getDigits());
            policyNode.put("period", policy.getPeriod());
            return AccountRequest.ok(200, body);
        });
    }

    @POST
    @Path("totp/confirm")
    @Consumes(MediaType.APPLICATION_JSON)
    @Produces({MediaType.APPLICATION_JSON, Problem.MEDIA_TYPE})
    public Response confirmTotp(@HeaderParam(SudoTokens.HEADER) String sudoToken, String body) {
        return request.execute(() -> {
            Caller caller = request.authenticate();
            request.beginMutation(caller, RateLimiter.TOTP_CONFIRM);
            request.requireSudo(caller, sudoToken);
            RequestBody parsed = RequestBody.parse(body, Set.of("setupHandle", "code", "label"));
            String handle = parsed.requireString("setupHandle", 43, 43);
            String code = parsed.requireTrimmedString("code", 1, 16);
            String label = parsed.requireTrimmedString("label", 1, 64);
            if (!SETUP_HANDLE.matcher(handle).matches()) {
                throw Problems.invalidRequest("setupHandle").exception();
            }
            if (!OTP_CODE.matcher(code).matches()) {
                throw Problems.invalidRequest("code").exception();
            }

            RealmModel realm = request.realm();
            UserModel user = caller.user();
            SingleUseObjectProvider store = request.session().singleUseObjects();
            String key = totpSetupKey(user, handle);
            Map<String, String> notes = store.get(key);
            String secret = notes == null ? null : notes.get(SECRET_NOTE);
            if (secret == null || secret.isBlank()) {
                throw Problems.totpSetupExpired().exception();
            }

            EventBuilder event = request.event(caller)
                    .event(EventType.UPDATE_CREDENTIAL)
                    .detail(Details.CREDENTIAL_TYPE, OTPCredentialModel.TYPE)
                    .detail(Details.CREDENTIAL_USER_LABEL, label);
            EventBuilder deprecatedEvent = event.clone().event(EventType.UPDATE_TOTP);

            OTPPolicy policy = realm.getOTPPolicy();
            OTPCredentialModel credentialModel = OTPCredentialModel.createFromPolicy(realm, secret, label);
            if (!CredentialValidation.validOTP(code, credentialModel, policy.getLookAheadWindow())) {
                event.clone().error(Errors.INVALID_USER_CREDENTIALS);
                throw Problems.invalidTotpSetupCode().exception();
            }
            if (store.remove(key) == null) {
                throw Problems.totpSetupExpired().exception();
            }
            final boolean created;
            try {
                created = CredentialHelper.createOTPCredential(request.session(), realm, user, code, credentialModel);
            } catch (ModelDuplicateException exception) {
                event.clone().error(Errors.INVALID_INPUT);
                throw Problems.duplicateLabel().exception();
            }
            if (!created) {
                event.clone().error(Errors.INVALID_USER_CREDENTIALS);
                throw Problems.invalidTotpSetupCode().exception();
            }
            event.success();
            deprecatedEvent.success();

            CredentialModel stored = user.credentialManager()
                    .getStoredCredentialByNameAndType(label, OTPCredentialModel.TYPE);
            ObjectNode summary = stored != null
                    ? Credentials.summary(stored)
                    : JsonSerialization.mapper.createObjectNode()
                            .putNull("id")
                            .put("type", OTPCredentialModel.TYPE)
                            .put("label", label)
                            .putNull("createdAt");
            return AccountRequest.ok(201, summary);
        });
    }

    /** Creation options for {@code navigator.credentials.create()} from the realm passwordless policy. */
    @POST
    @Path("webauthn/options")
    @Produces({MediaType.APPLICATION_JSON, Problem.MEDIA_TYPE})
    public Response passkeyOptions(@HeaderParam(SudoTokens.HEADER) String sudoToken) {
        return request.execute(() -> {
            Caller caller = request.authenticate();
            request.beginMutation(caller, RateLimiter.MUTATION);
            request.requireSudo(caller, sudoToken);
            return AccountRequest.ok(200, request.passkeys().creationOptions(caller));
        });
    }

    /**
     * The {@code PublicKeyCredential} JSON the browser returned plus a label; verified and stored
     * exactly like Keycloak's {@code webauthn-register-passwordless} required action.
     */
    @POST
    @Path("webauthn/register")
    @Consumes(MediaType.APPLICATION_JSON)
    @Produces({MediaType.APPLICATION_JSON, Problem.MEDIA_TYPE})
    public Response registerPasskey(@HeaderParam(SudoTokens.HEADER) String sudoToken, String body) {
        return request.execute(() -> {
            Caller caller = request.authenticate();
            request.beginMutation(caller, RateLimiter.MUTATION);
            request.requireSudo(caller, sudoToken);
            Set<String> fields = new HashSet<>(Passkeys.CREDENTIAL_FIELDS);
            fields.add("label");
            RequestBody parsed = RequestBody.parse(body, fields, Passkeys.MAX_BODY_BYTES);
            String label = IdentityResource.normalisePersonName(parsed.requireString("label", 1, 256));
            if (label.isEmpty() || label.length() > MAX_LABEL_LENGTH) {
                throw Problems.invalidRequest("label").exception();
            }
            Passkeys.Attestation attestation = Passkeys.parseAttestation(parsed);

            EventBuilder event = request.event(caller)
                    .event(EventType.UPDATE_CREDENTIAL)
                    .detail(Details.CREDENTIAL_TYPE, Passkeys.CREDENTIAL_TYPE)
                    .detail(Details.CREDENTIAL_USER_LABEL, label);
            final Passkeys.Registered registered;
            try {
                registered = request.passkeys().register(caller, attestation, label);
            } catch (ProblemException exception) {
                if (exception.problem().status() < 500) {
                    event.clone()
                            .detail(WebAuthnConstants.REG_ERR_LABEL, exception.problem().code())
                            .error(Errors.INVALID_REGISTRATION);
                }
                throw exception;
            }
            event.detail(WebAuthnConstants.PUBKEY_CRED_ID_ATTR, registered.credentialId())
                    .detail(WebAuthnConstants.PUBKEY_CRED_LABEL_ATTR, label)
                    .detail(WebAuthnConstants.PUBKEY_CRED_AAGUID_ATTR, registered.aaguid())
                    .success();
            return AccountRequest.ok(201, Credentials.passkeySummary(registered.credential()));
        });
    }

    @DELETE
    @Path("{id}")
    @Produces({MediaType.APPLICATION_JSON, Problem.MEDIA_TYPE})
    public Response deleteCredential(
            @HeaderParam(SudoTokens.HEADER) String sudoToken,
            @PathParam("id") String credentialId) {
        return request.execute(() -> {
            Caller caller = request.authenticate();
            request.beginMutation(caller, RateLimiter.MUTATION);
            request.requireSudo(caller, sudoToken);
            if (credentialId == null || !CREDENTIAL_ID.matcher(credentialId).matches()) {
                throw Problems.credentialNotFound().exception();
            }
            UserModel user = caller.user();
            CredentialModel credential = user.credentialManager().getStoredCredentialById(credentialId);
            if (credential == null || !Credentials.isDeletable(credential.getType())) {
                throw Problems.credentialNotFound().exception();
            }
            if (!user.credentialManager().removeStoredCredentialById(credentialId)) {
                throw Problems.credentialNotFound().exception();
            }
            EventBuilder event = request.event(caller)
                    .event(EventType.REMOVE_CREDENTIAL)
                    .detail(Details.CREDENTIAL_TYPE, credential.getType())
                    .detail(Details.SELECTED_CREDENTIAL_ID, credential.getId())
                    .detail(Details.CREDENTIAL_USER_LABEL, credential.getUserLabel());
            if (Credentials.isTotp(credential.getType())) {
                event.clone().event(EventType.REMOVE_TOTP).success();
            }
            event.success();
            return AccountRequest.noContent();
        });
    }

    private static void rejectPassword(EventBuilder event, EventBuilder deprecatedEvent, String reason) {
        event.clone().detail(Details.REASON, reason).error(Errors.PASSWORD_REJECTED);
        deprecatedEvent.clone().detail(Details.REASON, reason).error(Errors.PASSWORD_REJECTED);
    }

    private void logoutOtherSessions(Caller caller, EventBuilder event) {
        RealmModel realm = request.realm();
        UserModel user = caller.user();
        String currentSessionId = caller.userSession().getId();
        List<UserSessionModel> others = Stream.concat(
                        request.session().sessions().getUserSessionsStream(realm, user),
                        request.session().sessions().getOfflineUserSessionsStream(realm, user))
                .filter(userSession -> !currentSessionId.equals(userSession.getId()))
                .toList();
        for (UserSessionModel other : others) {
            AuthenticationManager.backchannelLogout(request.session(), other, true);
            event.clone()
                    .event(EventType.LOGOUT)
                    .session(other)
                    .detail(Details.REASON, "sky_account_password_change")
                    .success();
        }
    }

    private static List<Object> parameters(Object[] parameters) {
        return parameters == null ? List.of() : Arrays.asList(parameters);
    }

    private static String totpSetupKey(UserModel user, String handle) {
        return TOTP_SETUP_KEY_PREFIX + user.getId() + ":" + handle;
    }
}
