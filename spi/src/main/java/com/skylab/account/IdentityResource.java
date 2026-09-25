package com.skylab.account;

import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import jakarta.ws.rs.Consumes;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.HeaderParam;
import jakarta.ws.rs.PATCH;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;
import org.jboss.logging.Logger;
import org.keycloak.common.util.Time;
import org.keycloak.connections.jpa.JpaConnectionProvider;
import org.keycloak.credential.CredentialModel;
import org.keycloak.events.Details;
import org.keycloak.events.Errors;
import org.keycloak.events.EventBuilder;
import org.keycloak.events.EventType;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.ModelDuplicateException;
import org.keycloak.models.UserModel;
import org.keycloak.models.credential.PasswordCredentialModel;
import org.keycloak.userprofile.validator.PersonNameProhibitedCharactersValidator;
import org.keycloak.util.JsonSerialization;

import java.time.Instant;
import java.time.format.DateTimeParseException;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.regex.Pattern;

/** {@code v1/identity}: who the person is, and the name/username changes Account REST may not make. */
public final class IdentityResource {

    static final String SCHOOL_EMAIL_ATTRIBUTE = "schoolEmail";
    static final String PERSONAL_EMAIL_ATTRIBUTE = PersonalEmailProof.ADDRESS_ATTRIBUTE;
    /**
     * ISO-8601 UTC moment the person proved the current {@code personalEmail}; only
     * {@link PersonalEmailProof} shapes it (this SPI's confirm, and once the A1c adoption).
     */
    static final String PERSONAL_EMAIL_VERIFIED_AT_ATTRIBUTE = PersonalEmailProof.VERIFIED_AT_ATTRIBUTE;
    static final String USERNAME_CHANGED_AT_ATTRIBUTE = "usernameChangedAt";
    static final long USERNAME_COOLDOWN_SECONDS = 14L * 24 * 60 * 60;
    static final int MAX_NAME_LENGTH = 64;
    static final Pattern USERNAME = Pattern.compile("^[a-z0-9._]{3,30}$");

    private static final Logger LOG = Logger.getLogger(IdentityResource.class);
    private static final String PROFILE_CONTEXT = "ACCOUNT";
    private static final Pattern FORMAT_CHARACTERS = Pattern.compile("\\p{Cf}+");
    private static final Pattern SPACE_RUNS = Pattern.compile("[\\p{Z}\\s]+");

    private final AccountRequest request;

    IdentityResource(AccountRequest request) {
        this.request = request;
    }

    @GET
    @Produces({MediaType.APPLICATION_JSON, Problem.MEDIA_TYPE})
    public Response identity() {
        return request.execute(() -> {
            Caller caller = request.authenticate();
            return AccountRequest.ok(200, identityOf(request, caller.user()));
        });
    }

    @PATCH
    @Path("name")
    @Consumes(MediaType.APPLICATION_JSON)
    @Produces({MediaType.APPLICATION_JSON, Problem.MEDIA_TYPE})
    public Response changeName(String body) {
        return request.execute(() -> {
            Caller caller = request.authenticate();
            request.beginMutation(caller, RateLimiter.MUTATION);
            UserModel user = caller.user();
            if (request.isVerifiedYtu(user)) {
                throw Problems.nameLocked().exception();
            }
            RequestBody parsed = RequestBody.parse(body, Set.of("firstName", "lastName"));
            String firstName = requirePersonName(parsed, "firstName");
            String lastName = requirePersonName(parsed, "lastName");
            EventBuilder event = request.event(caller)
                    .event(EventType.UPDATE_PROFILE)
                    .detail(Details.CONTEXT, PROFILE_CONTEXT);
            String previousFirstName = user.getFirstName();
            String previousLastName = user.getLastName();
            if (!firstName.equals(previousFirstName)) {
                user.setFirstName(firstName);
                event.detail(Details.PREVIOUS_FIRST_NAME, previousFirstName)
                        .detail(Details.UPDATED_FIRST_NAME, firstName);
            }
            if (!lastName.equals(previousLastName)) {
                user.setLastName(lastName);
                event.detail(Details.PREVIOUS_LAST_NAME, previousLastName)
                        .detail(Details.UPDATED_LAST_NAME, lastName);
            }
            event.success();
            return AccountRequest.ok(200, identityOf(request, user));
        });
    }

    @POST
    @Path("username")
    @Consumes(MediaType.APPLICATION_JSON)
    @Produces({MediaType.APPLICATION_JSON, Problem.MEDIA_TYPE})
    public Response changeUsername(@HeaderParam(SudoTokens.HEADER) String sudoToken, String body) {
        return request.execute(() -> {
            Caller caller = request.authenticate();
            request.beginMutation(caller, RateLimiter.MUTATION);
            request.requireSudo(caller, sudoToken);
            String requested = RequestBody.parse(body, Set.of("username"))
                    .requireTrimmedString("username", 1, 64)
                    .toLowerCase(Locale.ROOT);
            if (!USERNAME.matcher(requested).matches()) {
                throw Problems.invalidUsername().exception();
            }
            UserModel user = caller.user();
            String previous = user.getUsername();
            if (requested.equals(previous)) {
                return AccountRequest.ok(200, identityOf(request, user));
            }
            Long availableAt = usernameChangeAvailableAt(user);
            if (availableAt != null) {
                int retryAfter = (int) Math.max(1, availableAt - Time.currentTime());
                throw Problems.usernameCooldown(retryAfter, AccountRequest.isoSeconds(availableAt)).exception();
            }
            EventBuilder event = request.event(caller)
                    .event(EventType.UPDATE_PROFILE)
                    .detail(Details.CONTEXT, PROFILE_CONTEXT)
                    .detail(Details.PREF_PREVIOUS + Details.USERNAME, previous)
                    .detail(Details.PREF_UPDATED + Details.USERNAME, requested);
            UserModel existing = request.session().users().getUserByUsername(request.realm(), requested);
            if (existing != null && !existing.getId().equals(user.getId())) {
                event.clone().error(Errors.USERNAME_IN_USE);
                throw Problems.usernameTaken().exception();
            }
            applyUsername(request.session(), user, requested, event);
            user.setSingleAttribute(USERNAME_CHANGED_AT_ATTRIBUTE, AccountRequest.isoSeconds(Time.currentTime()));
            event.success();
            return AccountRequest.ok(200, identityOf(request, user));
        });
    }

    /**
     * Writes the username and flushes it to the database at once, so a concurrent change to
     * the same name surfaces here as {@link ModelDuplicateException} (a clean 409) instead of
     * failing the commit after the response was built.
     */
    static void applyUsername(KeycloakSession session, UserModel user, String username, EventBuilder event) {
        try {
            user.setUsername(username);
            JpaConnectionProvider jpa = session.getProvider(JpaConnectionProvider.class);
            if (jpa != null) {
                jpa.getEntityManager().flush();
            }
        } catch (ModelDuplicateException exception) {
            session.getTransactionManager().setRollbackOnly();
            if (event != null) {
                event.clone().error(Errors.USERNAME_IN_USE);
            }
            throw Problems.usernameTaken().exception();
        }
    }

    private static String requirePersonName(RequestBody body, String field) {
        String value = normalisePersonName(body.requireString(field, 0, 1024));
        if (value.isEmpty() || value.length() > MAX_NAME_LENGTH || !isAllowedPersonName(value)) {
            throw Problems.invalidName(field).exception();
        }
        return value;
    }

    /**
     * Drops zero-width and other format characters, collapses every kind of whitespace
     * (including NBSP) to one ASCII space and trims, so a name made only of such characters
     * is empty and refused.
     */
    static String normalisePersonName(String raw) {
        String withoutFormat = FORMAT_CHARACTERS.matcher(raw).replaceAll("");
        return SPACE_RUNS.matcher(withoutFormat).replaceAll(" ").trim();
    }

    /** Keycloak's own {@code person-name-prohibited-characters} rule, applied outside User Profile. */
    static boolean isAllowedPersonName(String value) {
        return PersonNameProhibitedCharactersValidator.INSTANCE.validate(value, "name").isValid();
    }

    /**
     * @return the epoch second from which the username may be changed again, or {@code null}
     * when a change is allowed now. A missing or unreadable attribute never blocks the person.
     */
    static Long usernameChangeAvailableAt(UserModel user) {
        String changedAt = user.getFirstAttribute(USERNAME_CHANGED_AT_ATTRIBUTE);
        if (changedAt == null || changedAt.isBlank()) {
            return null;
        }
        final long availableAt;
        try {
            availableAt = Instant.parse(changedAt.trim()).getEpochSecond() + USERNAME_COOLDOWN_SECONDS;
        } catch (DateTimeParseException exception) {
            LOG.warnf("sky-account ignored an unreadable %s attribute of user %s",
                    USERNAME_CHANGED_AT_ATTRIBUTE, user.getId());
            return null;
        }
        return availableAt > Time.currentTime() ? availableAt : null;
    }

    static String primaryOf(String email, String schoolEmail, String personalEmail) {
        if (email == null || email.isBlank()) {
            return "none";
        }
        if (schoolEmail != null && email.equalsIgnoreCase(schoolEmail)) {
            return "school";
        }
        if (personalEmail != null && email.equalsIgnoreCase(personalEmail)) {
            return "personal";
        }
        return "none";
    }

    /**
     * The Personal e-mail counts as proven only while this extension recorded the moment it
     * was proven; an address written straight into the attribute (admin, import) is not.
     */
    static boolean isPersonalEmailVerified(UserModel user) {
        if (blankToNull(user.getFirstAttribute(PERSONAL_EMAIL_ATTRIBUTE)) == null) {
            return false;
        }
        String verifiedAt = user.getFirstAttribute(PERSONAL_EMAIL_VERIFIED_AT_ATTRIBUTE);
        if (verifiedAt == null || verifiedAt.isBlank()) {
            return false;
        }
        try {
            Instant.parse(verifiedAt.trim());
            return true;
        } catch (DateTimeParseException exception) {
            LOG.warnf("sky-account ignored an unreadable %s attribute of user %s",
                    PERSONAL_EMAIL_VERIFIED_AT_ATTRIBUTE, user.getId());
            return false;
        }
    }

    /** The {@code GET identity} document, also returned by every endpoint that changes it. */
    static ObjectNode identityOf(AccountRequest request, UserModel user) {
        boolean verifiedYtu = request.isVerifiedYtu(user);
        String schoolEmail = blankToNull(user.getFirstAttribute(SCHOOL_EMAIL_ATTRIBUTE));
        String personalEmail = blankToNull(user.getFirstAttribute(PERSONAL_EMAIL_ATTRIBUTE));
        Long usernameAvailableAt = usernameChangeAvailableAt(user);

        ObjectNode body = JsonSerialization.mapper.createObjectNode();
        body.put("sub", user.getId());
        body.put("username", user.getUsername());
        body.put("firstName", user.getFirstName());
        body.put("lastName", user.getLastName());
        body.put("email", user.getEmail());
        body.put("emailVerified", user.isEmailVerified());
        body.put("schoolEmail", schoolEmail);
        body.put("personalEmail", personalEmail);
        body.put("personalEmailVerified", isPersonalEmailVerified(user));
        body.put("primary", primaryOf(user.getEmail(), schoolEmail, personalEmail));
        body.put("verifiedYtu", verifiedYtu);
        body.put("nameLocked", verifiedYtu);
        body.put("usernameChangeAvailableAt",
                usernameAvailableAt == null ? null : AccountRequest.isoSeconds(usernameAvailableAt));

        List<CredentialModel> credentials = user.credentialManager().getStoredCredentialsStream().toList();
        ObjectNode credentialsNode = body.putObject("credentials");
        credentialsNode.put("password", user.credentialManager().isConfiguredFor(PasswordCredentialModel.TYPE));
        ArrayNode totp = credentialsNode.putArray("totp");
        ArrayNode passkeys = credentialsNode.putArray("passkeys");
        for (CredentialModel credential : credentials) {
            if (Credentials.isTotp(credential.getType())) {
                totp.add(Credentials.summary(credential));
            } else if (Credentials.isPasskey(credential.getType())) {
                passkeys.add(Credentials.passkeySummary(credential));
            }
        }
        return body;
    }

    private static String blankToNull(String value) {
        return value == null || value.isBlank() ? null : value;
    }
}
