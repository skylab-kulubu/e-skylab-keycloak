package com.skylab.account;

import com.fasterxml.jackson.databind.node.ObjectNode;
import jakarta.ws.rs.Consumes;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;
import org.keycloak.WebAuthnConstants;
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

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;

/**
 * {@code v1/sudo}: the person proves a credential and receives a five-minute sudo token.
 *
 * <p>Every credential proof first honours an existing brute-force lockout. Failed and successful
 * password and TOTP proofs are then reported to Keycloak's brute-force protector like a login.
 * Passkey proofs are reported too, but Keycloak 26.7.4's protector only counts the
 * {@code password}, {@code otp} and recovery-code categories, so a failed passkey assertion does
 * not advance the realm counter and a successful one clears nothing; the throttle for passkey
 * proofs is the SPI's own {@code sudo-passkey} budget (10 per 15 minutes).
 *
 * <p>A person with none of these proves a fresh Keycloak authentication instead
 * ({@code sudo/authentication}): the ID token the BFF received at its callback, verified against
 * the realm keys and bound to the bearer session. No credential is checked there, so the
 * brute-force protector is not involved; the {@code sudo} budget still counts every attempt.
 */
public final class SudoResource {

    static final String AUDIT_ACTION = "sky-sudo";
    static final String AUDIT_ACTION_DETAIL = "action";
    static final String AUDIT_METHOD_DETAIL = "method";
    /** For {@code method=authentication}: the verified {@code auth_time} (epoch seconds) of the ID token. */
    static final String AUDIT_AUTH_TIME_DETAIL = "auth_time";

    private static final String AUTH_METHOD = "sky-account-sudo";
    private static final String ID_TOKEN_FIELD = "idToken";
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
        return prove(body, new Proof<String>() {
            @Override
            public Set<String> fields() {
                return Set.of("password");
            }

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
            public Problem notConfigured(UserModel user) {
                return user.credentialManager().isConfiguredFor(PasswordCredentialModel.TYPE)
                        ? null
                        : Problems.passwordNotConfigured();
            }

            @Override
            public Problem check(UserModel user, String secret) {
                return user.credentialManager().isValid(UserCredentialModel.password(secret))
                        ? null
                        : Problems.invalidPassword();
            }
        });
    }

    @POST
    @Path("totp")
    @Consumes(MediaType.APPLICATION_JSON)
    @Produces({MediaType.APPLICATION_JSON, Problem.MEDIA_TYPE})
    public Response withTotp(String body) {
        return prove(body, new Proof<String>() {
            @Override
            public Set<String> fields() {
                return Set.of("code");
            }

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
            public Problem notConfigured(UserModel user) {
                return otpCredentials(user).isEmpty() ? Problems.totpNotConfigured() : null;
            }

            @Override
            public Problem check(UserModel user, String code) {
                boolean valid = otpCredentials(user).stream().anyMatch(credential -> user.credentialManager()
                        .isValid(new UserCredentialModel(credential.getId(), OTPCredentialModel.TYPE, code)));
                return valid ? null : Problems.invalidTotp();
            }
        });
    }

    /** Assertion options for {@code navigator.credentials.get()} with the person's own passkeys. */
    @POST
    @Path("webauthn/options")
    @Produces({MediaType.APPLICATION_JSON, Problem.MEDIA_TYPE})
    public Response passkeyOptions() {
        return request.execute(() -> {
            Caller caller = request.authenticate();
            request.limit(RateLimiter.SUDO_OPTIONS, caller);
            return AccountRequest.ok(200, request.passkeys().assertionOptions(caller));
        });
    }

    /** The {@code PublicKeyCredential} JSON the browser returned, verified like Keycloak's passkey login. */
    @POST
    @Path("webauthn/verify")
    @Consumes(MediaType.APPLICATION_JSON)
    @Produces({MediaType.APPLICATION_JSON, Problem.MEDIA_TYPE})
    public Response withPasskey(String body) {
        return prove(body, new Proof<Passkeys.Assertion>() {
            private String credentialId;

            @Override
            public Set<String> fields() {
                return Passkeys.CREDENTIAL_FIELDS;
            }

            @Override
            public RateLimiter.Limit limit() {
                return RateLimiter.SUDO_PASSKEY;
            }

            @Override
            public int maxBodyBytes() {
                return Passkeys.MAX_BODY_BYTES;
            }

            @Override
            public Passkeys.Assertion read(RequestBody parsed) {
                return Passkeys.parseAssertion(parsed);
            }

            @Override
            public String credentialType() {
                return Passkeys.CREDENTIAL_TYPE;
            }

            @Override
            public SudoTokens.Method method() {
                return SudoTokens.Method.PASSKEY;
            }

            @Override
            public Problem notConfigured(UserModel user) {
                return Passkeys.passkeysOf(user).isEmpty() ? Problems.passkeyNotRegistered() : null;
            }

            @Override
            public Problem check(UserModel user, Passkeys.Assertion assertion) {
                Passkeys.AssertionOutcome outcome = request.passkeys().verifyAssertion(caller(), assertion);
                if (!outcome.isVerified()) {
                    return outcome.refusal();
                }
                credentialId = outcome.credentialId();
                return null;
            }

            @Override
            public Map<String, String> auditDetails() {
                return credentialId == null ? Map.of() : Map.of(WebAuthnConstants.PUBKEY_CRED_ID_ATTR, credentialId);
            }
        });
    }

    /**
     * The fallback for a person without password, TOTP or passkey: the ID token of a Keycloak
     * authentication completed within the last five minutes, presented with the bearer of the same
     * session. The sudo token expires five minutes after that authentication, not after this call.
     */
    @POST
    @Path("authentication")
    @Consumes(MediaType.APPLICATION_JSON)
    @Produces({MediaType.APPLICATION_JSON, Problem.MEDIA_TYPE})
    public Response withAuthentication(String body) {
        return request.execute(() -> {
            Caller caller = request.authenticate();
            request.limit(RateLimiter.SUDO, caller);
            String idToken = RequestBody.parse(body, Set.of(ID_TOKEN_FIELD))
                    .requireString(ID_TOKEN_FIELD, 1, RequestBody.MAX_BYTES);
            AuthenticationProofs.Proof proof = request.authenticationProofs().verify(caller, idToken);
            SudoTokens.Issued issued = request.issueSudo(
                    caller, SudoTokens.Method.AUTHENTICATION, proof.expiresAt(), proof.amr());
            recordSudoSuccess(request.event(caller), SudoTokens.Method.AUTHENTICATION,
                    Map.of(AUDIT_AUTH_TIME_DETAIL, String.valueOf(proof.authTime())));
            return issuedResponse(issued);
        });
    }

    /** One way of proving it is the person: how to read, find, and check the credential. */
    private abstract class Proof<T> {
        private Caller caller;

        abstract Set<String> fields();

        RateLimiter.Limit limit() {
            return RateLimiter.SUDO;
        }

        int maxBodyBytes() {
            return RequestBody.MAX_BYTES;
        }

        abstract T read(RequestBody parsed);

        abstract String credentialType();

        abstract SudoTokens.Method method();

        /** @return the problem when the person has no such credential, otherwise {@code null}. */
        abstract Problem notConfigured(UserModel user);

        /**
         * @return {@code null} when the proof verified, otherwise the credential-failure problem;
         * it is recorded as a failed login attempt before being returned to the caller.
         */
        abstract Problem check(UserModel user, T proof);

        Map<String, String> auditDetails() {
            return Map.of();
        }

        Caller caller() {
            return caller;
        }
    }

    private <T> Response prove(String body, Proof<T> proof) {
        return request.execute(() -> {
            Caller caller = request.authenticate();
            proof.caller = caller;
            request.limit(proof.limit(), caller);
            T secret = proof.read(RequestBody.parse(body, proof.fields(), proof.maxBodyBytes()));
            UserModel user = caller.user();
            Problem notConfigured = proof.notConfigured(user);
            if (notConfigured != null) {
                throw notConfigured.exception();
            }
            requireNotLockedOut(caller, proof.credentialType());
            Problem failure = proof.check(user, secret);
            if (failure != null) {
                recordFailedAttempt(caller, proof.credentialType());
                throw failure.exception();
            }
            recordSuccessfulAttempt(caller, proof.credentialType());
            SudoTokens.Issued issued = request.issueSudo(caller, proof.method());
            recordSudoSuccess(request.event(caller), proof.method(), proof.auditDetails());
            return issuedResponse(issued);
        });
    }

    private static Response issuedResponse(SudoTokens.Issued issued) {
        ObjectNode response = JsonSerialization.mapper.createObjectNode();
        response.put("sudoToken", issued.token());
        response.put("expiresAt", AccountRequest.isoSeconds(issued.expiresAt()));
        return AccountRequest.ok(200, response);
    }

    private static List<CredentialModel> otpCredentials(UserModel user) {
        return user.credentialManager().getStoredCredentialsByTypeStream(OTPCredentialModel.TYPE).toList();
    }

    /**
     * Audit trail for a successful Sudo mode proof. Keycloak has no sudo event type, so the
     * generic {@code CUSTOM_REQUIRED_ACTION} carries {@code action=sky-sudo} and the method.
     */
    static void recordSudoSuccess(EventBuilder event, SudoTokens.Method method) {
        recordSudoSuccess(event, method, Map.of());
    }

    static void recordSudoSuccess(EventBuilder event, SudoTokens.Method method, Map<String, String> details) {
        event.event(EventType.CUSTOM_REQUIRED_ACTION)
                .detail(AUDIT_ACTION_DETAIL, AUDIT_ACTION)
                .detail(AUDIT_METHOD_DETAIL, method.auditName());
        new LinkedHashMap<>(details).forEach(event::detail);
        event.success();
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
