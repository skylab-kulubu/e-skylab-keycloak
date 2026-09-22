package com.skylab.account;

import com.fasterxml.jackson.databind.node.ObjectNode;
import jakarta.ws.rs.Consumes;
import jakarta.ws.rs.DELETE;
import jakarta.ws.rs.HeaderParam;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;
import org.jboss.logging.Logger;
import org.keycloak.common.util.Time;
import org.keycloak.connections.jpa.JpaConnectionProvider;
import org.keycloak.email.EmailTemplateProvider;
import org.keycloak.events.Details;
import org.keycloak.events.Errors;
import org.keycloak.events.EventBuilder;
import org.keycloak.events.EventType;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.ModelDuplicateException;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;
import org.keycloak.util.JsonSerialization;
import org.keycloak.validate.ValidationContext;
import org.keycloak.validate.validators.EmailValidator;

import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

/**
 * {@code v1/email}: the Personal e-mail a person adds and proves with a code mailed to it,
 * the Primary e-mail they choose between School and Personal, and the removal of the
 * personal address (ADR-0044).
 *
 * <p>The School e-mail is never written here: it belongs to the YTÜ Microsoft link. Keycloak
 * {@code email} is the Primary e-mail, so switching the primary is a plain
 * {@link UserModel#setEmail} and every token, core and SkyMail follow it on their own.
 */
public final class EmailResource {

    static final int MAX_ADDRESS_LENGTH = 255;
    /** Six digits, with room for the spaces people keep when they copy "123 456". */
    static final int MAX_CODE_INPUT_LENGTH = 12;
    static final String SCHOOL = "school";
    static final String PERSONAL = "personal";

    /** The message bundle key of the subject, resolved in the realm locale of the person. */
    static final String SUBJECT_KEY = "skyPersonalEmailConfirmSubject";
    /**
     * {@code theme-resources/templates/{text,html}/} of this extension; no theme change needed.
     * Public because the SkyMail mail provider routes this mail by exactly this name.
     */
    public static final String TEMPLATE = "sky-personal-email-confirm.ftl";

    private static final Logger LOG = Logger.getLogger(EmailResource.class);
    private static final String PROFILE_CONTEXT = "ACCOUNT";

    private final AccountRequest request;

    EmailResource(AccountRequest request) {
        this.request = request;
    }

    /**
     * Starts an addition or a change of the Personal e-mail: nothing is written to the person
     * yet, a six-digit code is mailed to the new address instead, and a new request replaces
     * any code still waiting. Its own tight budget
     * ({@link RateLimiter#EMAIL_CHANGE}, three per hour) bounds how much mail one person can
     * aim at addresses that are not theirs. That budget is claimed only after the sudo proof,
     * so a caller that cannot prove itself cannot spend the person's hour; the ordinary
     * {@link RateLimiter#MUTATION} budget bounds those attempts like every other change.
     */
    @POST
    @Path("change-request")
    @Consumes(MediaType.APPLICATION_JSON)
    @Produces({MediaType.APPLICATION_JSON, Problem.MEDIA_TYPE})
    public Response changeRequest(@HeaderParam(SudoTokens.HEADER) String sudoToken, String body) {
        return request.execute(() -> {
            Caller caller = request.authenticate();
            request.beginMutation(caller, RateLimiter.MUTATION);
            request.requireSudo(caller, sudoToken);
            request.limit(RateLimiter.EMAIL_CHANGE, caller);
            RequestBody parsed = RequestBody.parse(body, Set.of("address", "makePrimary"));
            String address = normalise(parsed.requireTrimmedString("address", 3, MAX_ADDRESS_LENGTH));
            boolean makePrimary = parsed.has("makePrimary") && parsed.requireBoolean("makePrimary");

            UserModel user = caller.user();
            if (!isValidAddress(request.session(), address) || isOwnAddress(user, address)) {
                throw Problems.invalidRequest("address").exception();
            }
            requireFreeAddress(user, address);

            PendingEmailChanges pending = new PendingEmailChanges(request.session().singleUseObjects());
            String code = pending.issue(user.getId(), address, makePrimary);
            try {
                send(caller, address, code);
            } catch (Exception exception) {
                pending.discard(user.getId());
                // Neither the address nor the code may reach the log; the SMTP diagnostics
                // (which quote the recipient) stay at DEBUG.
                LOG.errorf("sky-account could not send a personal e-mail confirmation for user %s", user.getId());
                LOG.debug("sky-account personal e-mail confirmation send failure", exception);
                request.event(caller).event(EventType.UPDATE_EMAIL).error(Errors.EMAIL_SEND_FAILED);
                throw Problems.emailNotSent().exception();
            }

            ObjectNode response = JsonSerialization.mapper.createObjectNode();
            response.put("expiresAt",
                    AccountRequest.isoSeconds(Time.currentTime() + PendingEmailChanges.TTL_SECONDS));
            return AccountRequest.ok(202, response);
        });
    }

    /**
     * Finishes the change with the code from the mail. No sudo: the person already proved
     * themselves for {@code change-request}, and the code proves the mailbox. The bearer is
     * what makes it safe: only this person's own pending change is ever compared, so a code
     * cannot attach the address to anybody else's account, whoever reads it.
     */
    @POST
    @Path("confirm")
    @Consumes(MediaType.APPLICATION_JSON)
    @Produces({MediaType.APPLICATION_JSON, Problem.MEDIA_TYPE})
    public Response confirm(String body) {
        return request.execute(() -> {
            Caller caller = request.authenticate();
            request.beginMutation(caller, RateLimiter.MUTATION);
            // Spaces are what people type when they copy "123 456" from a mail; nothing else is.
            String code = RequestBody.parse(body, Set.of("code"))
                    .requireTrimmedString("code", 6, MAX_CODE_INPUT_LENGTH)
                    .replace(" ", "");
            if (!PendingEmailChanges.CODE.matcher(code).matches()) {
                throw Problems.invalidRequest("code").exception();
            }

            UserModel user = caller.user();
            PendingEmailChanges.Outcome outcome =
                    new PendingEmailChanges(request.session().singleUseObjects()).confirm(user.getId(), code);
            switch (outcome.status()) {
                case NONE -> throw Problems.noPendingEmailChange().exception();
                case WRONG_CODE -> {
                    request.event(caller).event(EventType.UPDATE_PROFILE)
                            .detail(Details.CONTEXT, PROFILE_CONTEXT).error(Errors.INVALID_CODE);
                    throw Problems.invalidEmailCode(outcome.attemptsLeft()).exception();
                }
                case CONFIRMED -> { }
            }
            String address = outcome.change().address();
            // Ten minutes passed: somebody else may have taken the address meanwhile. The change
            // is already out of the store by now, so a person who loses this race asks for a new
            // code; that is the price of never letting two confirmations both see it.
            requireFreeAddress(user, address);

            EventBuilder event = request.event(caller)
                    .event(EventType.UPDATE_PROFILE)
                    .detail(Details.CONTEXT, PROFILE_CONTEXT);
            user.setSingleAttribute(IdentityResource.PERSONAL_EMAIL_ATTRIBUTE, address);
            user.setSingleAttribute(IdentityResource.PERSONAL_EMAIL_VERIFIED_AT_ATTRIBUTE,
                    AccountRequest.isoSeconds(Time.currentTime()));
            if (outcome.change().makePrimary() || isBlank(user.getEmail())) {
                applyPrimary(caller, user, address);
            }
            event.success();
            return AccountRequest.ok(200, IdentityResource.identityOf(request, user));
        });
    }

    /** Chooses which of the two proven addresses Keycloak, the tokens, core and SkyMail see. */
    @POST
    @Path("primary")
    @Consumes(MediaType.APPLICATION_JSON)
    @Produces({MediaType.APPLICATION_JSON, Problem.MEDIA_TYPE})
    public Response primary(@HeaderParam(SudoTokens.HEADER) String sudoToken, String body) {
        return request.execute(() -> {
            Caller caller = request.authenticate();
            request.beginMutation(caller, RateLimiter.MUTATION);
            request.requireSudo(caller, sudoToken);
            String which = RequestBody.parse(body, Set.of("which"))
                    .requireTrimmedString("which", 1, 16)
                    .toLowerCase(Locale.ROOT);
            if (!SCHOOL.equals(which) && !PERSONAL.equals(which)) {
                throw Problems.invalidRequest("which").exception();
            }

            UserModel user = caller.user();
            boolean school = SCHOOL.equals(which);
            String chosen = normaliseAttribute(user, school
                    ? IdentityResource.SCHOOL_EMAIL_ATTRIBUTE
                    : IdentityResource.PERSONAL_EMAIL_ATTRIBUTE);
            boolean proven = school ? request.isVerifiedYtu(user) : IdentityResource.isPersonalEmailVerified(user);
            switch (choosePrimary(chosen, proven, user.getEmail(), user.isEmailVerified())) {
                case MISSING -> throw Problems.invalidRequest("which").exception();
                case UNPROVEN -> throw Problems.emailNotVerified().exception();
                case APPLY -> applyPrimary(caller, user, chosen);
                case UNCHANGED -> { }
            }
            return AccountRequest.ok(200, IdentityResource.identityOf(request, user));
        });
    }

    /**
     * Removes the Personal e-mail. When it was the Primary e-mail the School e-mail takes
     * over; a person whose only address is the personal one keeps it
     * ({@code 409 no_fallback_email}) instead of ending up unable to sign in.
     */
    @DELETE
    @Path("personal")
    @Produces({MediaType.APPLICATION_JSON, Problem.MEDIA_TYPE})
    public Response deletePersonal(@HeaderParam(SudoTokens.HEADER) String sudoToken) {
        return request.execute(() -> {
            Caller caller = request.authenticate();
            request.beginMutation(caller, RateLimiter.MUTATION);
            request.requireSudo(caller, sudoToken);

            UserModel user = caller.user();
            String personal = normaliseAttribute(user, IdentityResource.PERSONAL_EMAIL_ATTRIBUTE);
            if (personal == null) {
                return AccountRequest.ok(200, IdentityResource.identityOf(request, user));
            }
            String school = normaliseAttribute(user, IdentityResource.SCHOOL_EMAIL_ATTRIBUTE);
            boolean wasPrimary = personal.equalsIgnoreCase(user.getEmail());
            // The same rule as choosing the school address by hand: only a school address the
            // YTÜ link proves can take over, or the person would be handed an address nobody verified.
            if (wasPrimary && choosePrimary(school, request.isVerifiedYtu(user), user.getEmail(),
                    user.isEmailVerified()) != PrimaryChoice.APPLY) {
                throw Problems.noFallbackEmail().exception();
            }

            EventBuilder event = request.event(caller)
                    .event(EventType.UPDATE_PROFILE)
                    .detail(Details.CONTEXT, PROFILE_CONTEXT);
            if (wasPrimary) {
                applyPrimary(caller, user, school);
            }
            user.removeAttribute(IdentityResource.PERSONAL_EMAIL_ATTRIBUTE);
            user.removeAttribute(IdentityResource.PERSONAL_EMAIL_VERIFIED_AT_ATTRIBUTE);
            event.success();
            return AccountRequest.ok(200, IdentityResource.identityOf(request, user));
        });
    }

    /**
     * Mails the verification code through Keycloak's own e-mail template and sender providers.
     * The attribute map has to be mutable: Keycloak's FreeMarker template provider puts the
     * resolved locale into the very map it is handed.
     */
    private void send(Caller caller, String address, String code) throws Exception {
        Map<String, Object> attributes = new HashMap<>();
        attributes.put("code", code);
        attributes.put("codeExpiration", PendingEmailChanges.TTL_SECONDS / 60);
        attributes.put("newEmail", address);
        request.session().getProvider(EmailTemplateProvider.class)
                .setRealm(request.realm())
                .setUser(caller.user())
                .send(SUBJECT_KEY, List.of(), TEMPLATE, attributes, address);
    }

    /** What pointing Keycloak {@code email} at one of the two addresses would do. */
    enum PrimaryChoice {
        /** It already is the primary and Keycloak marks it verified: nothing to write. */
        UNCHANGED,
        /** It is proven and not yet the verified primary: write it. */
        APPLY,
        /** The person has no such address. */
        MISSING,
        /** It exists but nobody proved it: the personal code was never confirmed, or the school
         *  attribute has no YTÜ link behind it (CONTEXT, Verified YTÜ account). */
        UNPROVEN
    }

    /**
     * The one rule both {@code email/primary} and the fallback of {@code DELETE email/personal}
     * follow. Only the chosen address has to exist, so a person with a proven personal address
     * and no school address can still choose it. Choosing the current verified primary changes
     * nothing and is therefore allowed even when this extension cannot prove it, which keeps
     * members whose school address was imported before the YTÜ link from being refused a no-op.
     */
    static PrimaryChoice choosePrimary(String chosen, boolean proven, String currentEmail, boolean emailVerified) {
        if (chosen == null) {
            return PrimaryChoice.MISSING;
        }
        if (chosen.equalsIgnoreCase(currentEmail) && emailVerified) {
            return PrimaryChoice.UNCHANGED;
        }
        return proven ? PrimaryChoice.APPLY : PrimaryChoice.UNPROVEN;
    }

    /**
     * Writes Keycloak {@code email} (the Primary e-mail) and flushes it at once, so a
     * concurrent claim on the same address surfaces here as {@link ModelDuplicateException}
     * (a clean 409) instead of failing the commit after the response was built.
     */
    private void applyPrimary(Caller caller, UserModel user, String address) {
        String previous = user.getEmail();
        if (address.equalsIgnoreCase(previous) && user.isEmailVerified()) {
            return;
        }
        EventBuilder event = request.event(caller)
                .event(EventType.UPDATE_EMAIL)
                .detail(Details.CONTEXT, PROFILE_CONTEXT)
                .detail(Details.PREVIOUS_EMAIL, previous)
                .detail(Details.UPDATED_EMAIL, address);
        KeycloakSession session = request.session();
        try {
            user.setEmail(address);
            user.setEmailVerified(true);
            JpaConnectionProvider jpa = session.getProvider(JpaConnectionProvider.class);
            if (jpa != null) {
                jpa.getEntityManager().flush();
            }
        } catch (ModelDuplicateException exception) {
            session.getTransactionManager().setRollbackOnly();
            event.clone().error(Errors.EMAIL_IN_USE);
            throw Problems.emailTaken().exception();
        }
        event.success();
    }

    /**
     * Fails closed when any other person already uses the address: as their Keycloak
     * {@code email} (Keycloak's own case-insensitive lookup, authoritative while the realm
     * keeps {@code duplicateEmailsAllowed=false}) or as their School or Personal e-mail
     * attribute. Both attributes are stored lowercased by this extension, so the exact
     * attribute search finds them.
     */
    private void requireFreeAddress(UserModel user, String address) {
        KeycloakSession session = request.session();
        RealmModel realm = request.realm();
        UserModel byEmail = session.users().getUserByEmail(realm, address);
        if (byEmail != null && !byEmail.getId().equals(user.getId())) {
            throw Problems.emailTaken().exception();
        }
        for (String attribute : List.of(
                IdentityResource.SCHOOL_EMAIL_ATTRIBUTE, IdentityResource.PERSONAL_EMAIL_ATTRIBUTE)) {
            boolean taken = session.users()
                    .searchForUserByUserAttributeStream(realm, attribute, address)
                    .anyMatch(other -> !other.getId().equals(user.getId()));
            if (taken) {
                throw Problems.emailTaken().exception();
            }
        }
    }

    /** Whether the address is already one of this person's own addresses. */
    static boolean isOwnAddress(UserModel user, String address) {
        return address.equalsIgnoreCase(user.getEmail())
                || address.equalsIgnoreCase(user.getFirstAttribute(IdentityResource.SCHOOL_EMAIL_ATTRIBUTE))
                || address.equalsIgnoreCase(user.getFirstAttribute(IdentityResource.PERSONAL_EMAIL_ATTRIBUTE));
    }

    /** Keycloak's own e-mail validator, with the realm this request runs in. */
    static boolean isValidAddress(KeycloakSession session, String address) {
        return EmailValidator.INSTANCE
                .validate(address, "address", new ValidationContext(session))
                .isValid();
    }

    /** Trims and lowercases with {@link Locale#ROOT}, so a Turkish locale cannot fold {@code I} to {@code ı}. */
    static String normalise(String raw) {
        return raw.trim().toLowerCase(Locale.ROOT);
    }

    private static String normaliseAttribute(UserModel user, String attribute) {
        String value = user.getFirstAttribute(attribute);
        return value == null || value.isBlank() ? null : normalise(value);
    }

    private static boolean isBlank(String value) {
        return value == null || value.isBlank();
    }
}
