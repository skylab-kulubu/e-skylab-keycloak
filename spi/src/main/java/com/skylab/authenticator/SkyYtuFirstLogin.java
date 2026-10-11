package com.skylab.authenticator;

import com.skylab.account.PersonalEmailProof;
import org.jboss.logging.Logger;
import org.keycloak.Config;
import org.keycloak.authentication.AuthenticationFlowContext;
import org.keycloak.authentication.Authenticator;
import org.keycloak.authentication.AuthenticatorFactory;
import org.keycloak.authentication.authenticators.broker.AbstractIdpAuthenticator;
import org.keycloak.authentication.authenticators.broker.util.SerializedBrokeredIdentityContext;
import org.keycloak.models.AuthenticationExecutionModel;
import org.keycloak.models.IdentityProviderModel;
import org.keycloak.models.IdentityProviderSyncMode;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;
import org.keycloak.models.ModelDuplicateException;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;
import org.keycloak.models.UserProvider;
import org.keycloak.provider.ProviderConfigProperty;
import org.keycloak.sessions.AuthenticationSessionModel;
import org.keycloak.utils.EmailValidationUtil;

import java.util.List;
import java.util.Map;

/**
 * {@code sky-ytu-first-login}: the first step of the realm's first broker login flow
 * (eskylab-login-ux ticket 07, ADR-0063 decision 5). A new account opened by a first YTÜ login
 * starts with the School e-mail as its Primary e-mail (CONTEXT, Primary e-mail).
 *
 * <p>{@code MicrosoftMapper} empties the brokered e-mail on every YTÜ login, so that no login ever
 * changes the Primary e-mail of an account that already exists; it stays as it is. The School
 * e-mail reaches this step as the {@code schoolEmail} user attribute of the brokered identity
 * (Keycloak's attribute importers write it before the flow starts). This step only decides
 * whether that address becomes the brokered e-mail of the account about to be opened:
 *
 * <ul>
 *   <li>a person already known to the flow (an account being linked or re-verified), a brokered
 *       identity that already carries an e-mail or has no valid School e-mail (an address on a
 *       YTÜ school domain, ADR-0063): nothing changes;</li>
 *   <li>an address no account holds, or the verified Keycloak {@code email} of an account, or (while
 *       e-mail login is allowed) its username: it becomes the brokered e-mail, trimmed and lowercased. With {@code trustEmail}
 *       the new account takes it as a verified Primary e-mail and no verification mail is sent;
 *       an address Keycloak already knows sends the person down Keycloak's own "existing account"
 *       path (confirm, then re-authenticate) instead of opening a second account;</li>
 *   <li>an address that is only the School or Personal e-mail of another account, or another
 *       account's unverified {@code email} (which must not lock the real owner out): nothing is
 *       written and the review profile page is shown, as it was before this step (ticket 12 puts
 *       "Zaten bir SKY LAB hesabın var mı?" there);</li>
 *   <li>an address Keycloak already knows, or a brokered username it would find an account by,
 *       while the identity provider syncs with {@code FORCE}: the same, because Keycloak would copy
 *       the brokered e-mail onto the account being linked, and no YTÜ login may change the Primary
 *       e-mail of an existing account. A username typed on the review profile page is not
 *       covered: turn the step off before switching the identity provider to {@code FORCE}.</li>
 * </ul>
 *
 * <p>The flow always continues; the step never shows a page or tells whose address it is.
 * {@code config/reconcile-account-center.sh} puts it into the realm's first broker login flow
 * ({@code KEYCLOAK_YTU_FIRST_LOGIN}).
 */
public final class SkyYtuFirstLogin implements Authenticator, AuthenticatorFactory {

    public static final String PROVIDER_ID = "sky-ytu-first-login";
    static final String SCHOOL_EMAIL_ATTRIBUTE = "schoolEmail";
    static final String PERSONAL_EMAIL_ATTRIBUTE = PersonalEmailProof.ADDRESS_ATTRIBUTE;
    static final int MAX_ADDRESS_LENGTH = 255;
    /** The YTÜ school domains (ADR-0063); only an address on one of them becomes a verified Primary e-mail. */
    static final List<String> SCHOOL_DOMAINS = List.of("std.yildiz.edu.tr", "yildiz.edu.tr");
    private static final Logger LOG = Logger.getLogger(SkyYtuFirstLogin.class);
    private static final AuthenticationExecutionModel.Requirement[] REQUIREMENTS = {
            AuthenticationExecutionModel.Requirement.REQUIRED
    };

    /** Who holds the School e-mail already. */
    enum Holder {
        /** Nobody: the address is free. */
        NOBODY,
        /** Keycloak's own duplicate check finds it (an account's verified {@code email}, or its username). */
        KEYCLOAK,
        /**
         * Another account's School or Personal e-mail attribute or unverified {@code email} (or an
         * ambiguous lookup).
         */
        ATTRIBUTE
    }

    @Override
    public void authenticate(AuthenticationFlowContext context) {
        AuthenticationSessionModel authSession = context.getAuthenticationSession();
        SerializedBrokeredIdentityContext brokered = SerializedBrokeredIdentityContext
                .readFromAuthenticationSession(authSession, AbstractIdpAuthenticator.BROKERED_CONTEXT_NOTE);
        if (brokered == null
                || context.getUser() != null
                || authSession.getAuthNote(AbstractIdpAuthenticator.EXISTING_USER_INFO) != null
                || !isBlank(brokered.getEmail())) {
            context.success();
            return;
        }
        String address = schoolAddress(brokered.getFirstAttribute(SCHOOL_EMAIL_ATTRIBUTE));
        if (address == null) {
            context.success();
            return;
        }
        Holder holder = holder(context.getSession(), context.getRealm(), address);
        boolean force = syncsWithForce(context.getSession(), brokered);
        if (force && holder == Holder.NOBODY && usernameKnown(context.getSession(), context.getRealm(), brokered, address)) {
            // Keycloak would still find an account by the brokered username and link it.
            holder = Holder.KEYCLOAK;
        }
        if (holder == Holder.NOBODY || (holder == Holder.KEYCLOAK && !force)) {
            brokered.setEmail(address);
            brokered.saveToAuthenticationSession(authSession, AbstractIdpAuthenticator.BROKERED_CONTEXT_NOTE);
        } else {
            LOG.debug("The School e-mail of a first YTÜ login belongs to another account; the profile page decides");
            authSession.setAuthNote(AbstractIdpAuthenticator.ENFORCE_UPDATE_PROFILE, Boolean.TRUE.toString());
        }
        context.success();
    }

    /**
     * The School e-mail as the Primary e-mail is stored: trimmed, lowercased; null when it is not a
     * plain address (one {@code @}, no quoted local part) on a YTÜ school domain.
     */
    static String schoolAddress(String raw) {
        if (isBlank(raw)) {
            return null;
        }
        String address = PersonalEmailProof.normalise(raw);
        if (address.length() > MAX_ADDRESS_LENGTH || !EmailValidationUtil.isValidEmail(address)
                || address.indexOf('@') != address.lastIndexOf('@') || address.indexOf('"') >= 0
                || SCHOOL_DOMAINS.stream().noneMatch(domain -> address.endsWith("@" + domain))) {
            return null;
        }
        return address;
    }

    /**
     * Keycloak's duplicate check first (the routes {@code IdpCreateUserIfUniqueAuthenticator}
     * uses: {@code email}, and the username while e-mail login is allowed), then the two
     * address attributes, compared ignoring case as the login form compares them. Only a verified
     * {@code email} sends the person to "link existing account": an unproven one is treated like
     * an attribute, so it cannot lock the address's real owner out.
     */
    static Holder holder(KeycloakSession session, RealmModel realm, String address) {
        UserProvider users = session.users();
        try {
            UserModel byEmail = users.getUserByEmail(realm, address);
            if (byEmail != null) {
                return byEmail.isEmailVerified() ? Holder.KEYCLOAK : Holder.ATTRIBUTE;
            }
            if (realm.isLoginWithEmailAllowed() && users.getUserByUsername(realm, address) != null) {
                return Holder.KEYCLOAK;
            }
        } catch (ModelDuplicateException duplicate) {
            return Holder.ATTRIBUTE;
        }
        for (String attribute : List.of(SCHOOL_EMAIL_ATTRIBUTE, PERSONAL_EMAIL_ATTRIBUTE)) {
            boolean held = users.searchForUserStream(realm, Map.of(
                            attribute, address,
                            UserModel.EXACT, Boolean.TRUE.toString(),
                            UserModel.INCLUDE_SERVICE_ACCOUNT, Boolean.FALSE.toString()),
                    0, 1).findAny().isPresent();
            if (held) {
                return Holder.ATTRIBUTE;
            }
        }
        return Holder.NOBODY;
    }

    /**
     * Whether the brokered identity's provider syncs with {@code FORCE}: Keycloak then copies the
     * brokered e-mail onto an existing account that the person links ({@code updateEmail}).
     */
    static boolean syncsWithForce(KeycloakSession session, SerializedBrokeredIdentityContext brokered) {
        IdentityProviderModel provider = brokered.getIdentityProviderId() == null
                ? null : session.identityProviders().getByAlias(brokered.getIdentityProviderId());
        return provider == null || provider.getSyncMode() == IdentityProviderSyncMode.FORCE;
    }

    /**
     * Keycloak's own username routes ({@code IdpCreateUserIfUniqueAuthenticator.checkExistingUser}):
     * the address as a username, the brokered username, and a brokered {@code @}-username as an
     * {@code email} while e-mail login is allowed.
     */
    static boolean usernameKnown(KeycloakSession session, RealmModel realm, SerializedBrokeredIdentityContext brokered,
            String address) {
        UserProvider users = session.users();
        String username = brokered.getModelUsername();
        return users.getUserByUsername(realm, address) != null
                || (username != null && (users.getUserByUsername(realm, username) != null
                        || (realm.isLoginWithEmailAllowed() && username.indexOf('@') > 0
                                && users.getUserByEmail(realm, username) != null)));
    }

    private static boolean isBlank(String value) {
        return value == null || value.isBlank();
    }

    @Override
    public void action(AuthenticationFlowContext context) {
        context.success();
    }

    @Override
    public boolean requiresUser() {
        return false;
    }

    @Override
    public boolean configuredFor(KeycloakSession session, RealmModel realm, UserModel user) {
        return true;
    }

    @Override
    public void setRequiredActions(KeycloakSession session, RealmModel realm, UserModel user) {
        // no-op
    }

    @Override
    public Authenticator create(KeycloakSession session) {
        return this;
    }

    @Override
    public String getId() {
        return PROVIDER_ID;
    }

    @Override
    public String getDisplayType() {
        return "SKY LAB YTÜ First Login";
    }

    @Override
    public String getHelpText() {
        return "In the first broker login flow, makes the School e-mail of a new YTÜ account its Primary e-mail "
                + "unless another account already uses it.";
    }

    @Override
    public String getReferenceCategory() {
        return null;
    }

    @Override
    public boolean isConfigurable() {
        return false;
    }

    @Override
    public AuthenticationExecutionModel.Requirement[] getRequirementChoices() {
        return REQUIREMENTS.clone();
    }

    @Override
    public boolean isUserSetupAllowed() {
        return false;
    }

    @Override
    public List<ProviderConfigProperty> getConfigProperties() {
        return List.of();
    }

    @Override
    public void init(Config.Scope config) {
        // no-op
    }

    @Override
    public void postInit(KeycloakSessionFactory factory) {
        // no-op
    }

    @Override
    public void close() {
        // no-op
    }
}
