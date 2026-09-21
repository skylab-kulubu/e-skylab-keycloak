package com.skylab.account;

import com.fasterxml.jackson.databind.node.ObjectNode;
import jakarta.ws.rs.Consumes;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;
import org.keycloak.authentication.authenticators.util.AuthenticatorUtils;
import org.keycloak.credential.CredentialModel;
import org.keycloak.events.Details;
import org.keycloak.events.Errors;
import org.keycloak.events.EventBuilder;
import org.keycloak.events.EventType;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserCredentialModel;
import org.keycloak.models.UserModel;
import org.keycloak.models.credential.OTPCredentialModel;
import org.keycloak.models.credential.PasswordCredentialModel;
import org.keycloak.services.managers.BruteForceProtector;
import org.keycloak.util.JsonSerialization;

import java.util.List;
import java.util.Set;
import java.util.regex.Pattern;

/** {@code v1/sudo}: the person proves a credential and receives a five-minute sudo token. */
public final class SudoResource {

    static final String AUDIT_ACTION = "sky-sudo";
    static final String AUDIT_ACTION_DETAIL = "action";
    static final String AUDIT_METHOD_DETAIL = "method";

    private static final String AUTH_METHOD = "sky-account-sudo";
    private static final Pattern OTP_CODE = Pattern.compile("^[0-9]{4,10}$");

    private final AccountRequest request;

    SudoResource(AccountRequest request) {
        this.request = request;
    }

    @POST
    @Path("password")
    @Consumes(MediaType.APPLICATION_JSON)
    @Produces({MediaType.APPLICATION_JSON, Problem.MEDIA_TYPE})
    public Response withPassword(String body) {
        return prove(body, new Proof() {
            @Override
            public String read(RequestBody parsed) {
                return parsed.requireString("password", 1, 1024);
            }

            @Override
            public String credentialType() {
                return PasswordCredentialModel.TYPE;
            }

            @Override
            public SudoTokens.Method method() {
                return SudoTokens.Method.PASSWORD;
            }

            @Override
            public boolean configured(UserModel user) {
                return user.credentialManager().isConfiguredFor(PasswordCredentialModel.TYPE);
            }

            @Override
            public boolean valid(UserModel user, String secret) {
                return user.credentialManager().isValid(UserCredentialModel.password(secret));
            }

            @Override
            public Problem notConfigured() {
                return Problems.passwordNotConfigured();
            }

            @Override
            public Problem invalid() {
                return Problems.invalidPassword();
            }
        });
    }

    @POST
    @Path("totp")
    @Consumes(MediaType.APPLICATION_JSON)
    @Produces({MediaType.APPLICATION_JSON, Problem.MEDIA_TYPE})
    public Response withTotp(String body) {
        return prove(body, new Proof() {
            @Override
            public String read(RequestBody parsed) {
                String code = parsed.requireTrimmedString("code", 1, 16);
                if (!OTP_CODE.matcher(code).matches()) {
                    throw Problems.invalidRequest("code").exception();
                }
                return code;
            }

            @Override
            public String credentialType() {
                return OTPCredentialModel.TYPE;
            }

            @Override
            public SudoTokens.Method method() {
                return SudoTokens.Method.TOTP;
            }

            @Override
            public boolean configured(UserModel user) {
                return !otpCredentials(user).isEmpty();
            }

            @Override
            public boolean valid(UserModel user, String code) {
                return otpCredentials(user).stream().anyMatch(credential -> user.credentialManager()
                        .isValid(new UserCredentialModel(credential.getId(), OTPCredentialModel.TYPE, code)));
            }

            @Override
            public Problem notConfigured() {
                return Problems.totpNotConfigured();
            }

            @Override
            public Problem invalid() {
                return Problems.invalidTotp();
            }
        });
    }

    /** One way of proving it is the person: how to read, find, and check the credential. */
    private interface Proof {
        String read(RequestBody parsed);

        String credentialType();

        SudoTokens.Method method();

        boolean configured(UserModel user);

        boolean valid(UserModel user, String secret);

        Problem notConfigured();

        Problem invalid();
    }

    private Response prove(String body, Proof proof) {
        return request.execute(() -> {
            Caller caller = request.authenticate();
            request.limit(RateLimiter.SUDO, caller);
            String secret = proof.read(RequestBody.parse(body, Set.of(bodyField(proof))));
            UserModel user = caller.user();
            if (!proof.configured(user)) {
                throw proof.notConfigured().exception();
            }
            requireNotLockedOut(caller, proof.credentialType());
            if (!proof.valid(user, secret)) {
                recordFailedAttempt(caller, proof.credentialType());
                throw proof.invalid().exception();
            }
            recordSuccessfulAttempt(caller, proof.credentialType());
            SudoTokens.Issued issued = request.issueSudo(caller, proof.method());
            recordSudoSuccess(request.event(caller), proof.method());
            ObjectNode response = JsonSerialization.mapper.createObjectNode();
            response.put("sudoToken", issued.token());
            response.put("expiresAt", AccountRequest.isoSeconds(issued.expiresAt()));
            return AccountRequest.ok(200, response);
        });
    }

    private static String bodyField(Proof proof) {
        return proof.method() == SudoTokens.Method.PASSWORD ? "password" : "code";
    }

    private static List<CredentialModel> otpCredentials(UserModel user) {
        return user.credentialManager().getStoredCredentialsByTypeStream(OTPCredentialModel.TYPE).toList();
    }

    /**
     * Audit trail for a successful Sudo mode proof. Keycloak has no sudo event type, so the
     * generic {@code CUSTOM_REQUIRED_ACTION} carries {@code action=sky-sudo} and the method.
     */
    static void recordSudoSuccess(EventBuilder event, SudoTokens.Method method) {
        event.event(EventType.CUSTOM_REQUIRED_ACTION)
                .detail(AUDIT_ACTION_DETAIL, AUDIT_ACTION)
                .detail(AUDIT_METHOD_DETAIL, method.auditName())
                .success();
    }

    private void requireNotLockedOut(Caller caller, String credentialType) {
        RealmModel realm = request.realm();
        if (!realm.isBruteForceProtected()) {
            SkyAccountResourceProviderFactory.warnOnceIfUnprotected(realm);
            return;
        }
        BruteForceProtector protector = request.session().getProvider(BruteForceProtector.class);
        String error = AuthenticatorUtils.getDisabledByBruteForceEventError(
                protector, request.session(), realm, caller.user());
        if (error == null) {
            return;
        }
        loginEvent(caller, credentialType).error(error);
        if (Errors.USER_TEMPORARILY_DISABLED.equals(error)) {
            throw Problems.temporarilyLocked().exception();
        }
        throw Problems.permanentlyLocked().exception();
    }

    private void recordFailedAttempt(Caller caller, String credentialType) {
        loginEvent(caller, credentialType).error(Errors.INVALID_USER_CREDENTIALS);
        RealmModel realm = request.realm();
        if (realm.isBruteForceProtected()) {
            request.session().getProvider(BruteForceProtector.class).failedLogin(
                    realm,
                    caller.user(),
                    request.session().getContext().getConnection(),
                    request.session().getContext().getUri(),
                    Set.of(credentialType));
        }
    }

    private void recordSuccessfulAttempt(Caller caller, String credentialType) {
        RealmModel realm = request.realm();
        if (realm.isBruteForceProtected()) {
            request.session().getProvider(BruteForceProtector.class).successfulLogin(
                    realm,
                    caller.user(),
                    request.session().getContext().getConnection(),
                    request.session().getContext().getUri(),
                    Set.of(credentialType));
        }
    }

    private EventBuilder loginEvent(Caller caller, String credentialType) {
        return request.event(caller)
                .event(EventType.LOGIN)
                .detail(Details.AUTH_METHOD, AUTH_METHOD)
                .detail(Details.CREDENTIAL_TYPE, credentialType);
    }
}
