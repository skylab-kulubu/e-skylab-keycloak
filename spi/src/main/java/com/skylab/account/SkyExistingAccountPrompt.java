package com.skylab.account;

import com.skylab.broker.SkyMicrosoftIdentityProvider;
import jakarta.ws.rs.core.MultivaluedMap;
import jakarta.ws.rs.core.Response;
import org.keycloak.authentication.AuthenticationFlowContext;
import org.keycloak.authentication.Authenticator;
import org.keycloak.authentication.AuthenticatorUtil;
import org.keycloak.authentication.AuthenticationProcessor;
import org.keycloak.authentication.authenticators.broker.AbstractIdpAuthenticator;
import org.keycloak.authentication.authenticators.broker.IdpCreateUserIfUniqueAuthenticator;
import org.keycloak.authentication.authenticators.broker.IdpUsernamePasswordForm;
import org.keycloak.authentication.authenticators.broker.util.ExistingUserInfo;
import org.keycloak.authentication.authenticators.broker.util.SerializedBrokeredIdentityContext;
import org.keycloak.authentication.authenticators.browser.OTPFormAuthenticator;
import org.keycloak.authentication.authenticators.browser.AbstractUsernameFormAuthenticator;
import org.keycloak.authentication.authenticators.util.AuthenticatorUtils;
import org.keycloak.broker.provider.BrokeredIdentityContext;
import org.keycloak.broker.provider.IdpLinkAction;
import org.keycloak.common.util.Time;
import org.keycloak.forms.login.LoginFormsProvider;
import org.keycloak.models.FederatedIdentityModel;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.ModelDuplicateException;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;
import org.keycloak.services.resources.IdentityBrokerService;
import org.keycloak.sessions.AuthenticationSessionModel;

import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Proxy;
import java.util.Optional;

/** First Microsoft login: choosing an existing account never links it without all its factors. */
public final class SkyExistingAccountPrompt implements Authenticator {
    public static final String PROVIDER_ID = "sky-existing-account-prompt";
    static final String TEMPLATE = "sky-existing-account.ftl";
    static final String ACTION = "sky-existing-account-action";
    static final String ESCAPE_ATTRIBUTE = "skyExistingAccountEscape";
    private final EmailCodeSettings settings;
    private final LoginCodeMail mail;
    private final EmailCodeAuthenticator budgets;

    SkyExistingAccountPrompt(EmailCodeSettings settings, LoginCodeMail mail) {
        this.settings = settings;
        this.mail = mail;
        budgets = new EmailCodeAuthenticator(settings, mail, null);
    }

    @Override
    public void authenticate(AuthenticationFlowContext context) {
        SerializedBrokeredIdentityContext broker = broker(context);
        AuthenticationSessionModel auth = context.getAuthenticationSession();
        String stage = auth.getAuthNote(BrokerLinkState.STAGE);
        if ("new-account".equals(stage)) {
            auth.removeAuthNote(BrokerLinkState.STAGE);
            context.success();
            return;
        }
        if (stage == null && skip(context, broker)) {
            context.success();
            return;
        }
        if (!supported(context, broker)) {
            page(context, "unavailable", null);
            return;
        }
        if (stage == null) {
            auth.setAuthNote(BrokerLinkState.STAGE, "question");
            page(context, "question", null);
        } else if ("password".equals(stage)) {
            password(context).authenticate(nativeContext(context, () -> firstFactor(context, "password_or_passkey")));
        } else if ("otp".equals(stage)) {
            otp(context, false);
        } else {
            page(context, stage, null);
        }
    }

    @Override
    public void action(AuthenticationFlowContext context) {
        AuthenticationSessionModel auth = context.getAuthenticationSession();
        MultivaluedMap<String, String> form = context.getHttpRequest().getDecodedFormParameters();
        String action = form.getFirst(ACTION);
        if ("new-account".equals(action)) {
            // This is the only route that can abandon an unsuccessful link and create an account.
            BrokerLinkState.clear(context);
            context.success();
            return;
        }
        SerializedBrokeredIdentityContext broker = broker(context);
        if (!supported(context, broker)) {
            page(context, "unavailable", null);
            return;
        }
        if ("existing".equals(action) || "change".equals(action)) {
            BrokerLinkState.clear(context);
            auth.setAuthNote(BrokerLinkState.STAGE, "identifier");
            if ("existing".equals(action) && schoolCandidate(context) != null) {
                // Only suggest the school address Microsoft has just proved. Do not expose the
                // candidate's username, profile or primary, and do not treat the suggestion as proof.
                auth.setAuthNote(BrokerLinkState.IDENTIFIER,
                        BrokerLinkState.normal(broker(context).getFirstAttribute("schoolEmail")));
            }
            page(context, "identifier", null);
            return;
        }
        String stage = auth.getAuthNote(BrokerLinkState.STAGE);
        if ("send".equals(action) || "password".equals(action)) {
            select(context, form.getFirst("username"), "password".equals(action));
        } else if ("resend".equals(action) && "code".equals(stage)) {
            if (secondsUntilResend(context) > 0) page(context, "code", "resend_too_soon");
            else select(context, auth.getAuthNote(BrokerLinkState.IDENTIFIER), false);
        } else if ("verify".equals(action) && "code".equals(stage)) {
            verifyCode(context, form.getFirst("code"));
        } else if ("password".equals(stage)) {
            password(context).action(nativeContext(context, () -> firstFactor(context, "password_or_passkey")));
        } else if ("otp".equals(stage)) {
            otp(context, true);
        } else {
            authenticate(context);
        }
    }

    private boolean skip(AuthenticationFlowContext context, SerializedBrokeredIdentityContext broker) {
        AuthenticationSessionModel auth = context.getAuthenticationSession();
        if (broker == null || context.getUser() != null
                || !settings.ytuIdpAlias().equals(broker.getIdentityProviderId())
                || auth.getAuthNote(IdentityBrokerService.LINKING_IDENTITY_PROVIDER) != null
                || Boolean.parseBoolean(auth.getAuthNote(IdpLinkAction.KC_ACTION_LINKING_IDENTITY_PROVIDER))
                || auth.getAuthNote(AbstractIdpAuthenticator.EXISTING_USER_INFO) != null) return true;
        try {
            BrokeredIdentityContext live = broker.deserialize(context.getSession(), auth);
            return new NativeDuplicate().exists(context, broker, live);
        } catch (ModelDuplicateException ambiguous) {
            return false; // The prompt fails closed on the duplicate-email realm below.
        }
    }

    private boolean supported(AuthenticationFlowContext context, SerializedBrokeredIdentityContext broker) {
        if (broker == null || context.getRealm().isDuplicateEmailsAllowed()
                || !settings.ytuIdpAlias().equals(broker.getIdentityProviderId())
                || broker.getId() == null || broker.getId().isBlank()) return false;
        String school = BrokerLinkState.normal(broker.getFirstAttribute("schoolEmail"));
        if (school.length() > 255 || !org.keycloak.utils.EmailValidationUtil.isValidEmail(school)
                || school.indexOf('@') != school.lastIndexOf('@') || school.indexOf('"') >= 0
                || !(school.endsWith("@std.yildiz.edu.tr") || school.endsWith("@yildiz.edu.tr"))) return false;
        BrokeredIdentityContext live = broker.deserialize(context.getSession(), context.getAuthenticationSession());
        // The native callback must use our transaction guard. An ordinary oidc provider is not safe here.
        return live.getIdpConfig().isEnabled() && live.getIdp() instanceof SkyMicrosoftIdentityProvider
                && !BrokerLinkState.text(live.getFirstName()).isBlank()
                && !BrokerLinkState.text(live.getLastName()).isBlank();
    }

    private void select(AuthenticationFlowContext context, String raw, boolean password) {
        String identifier = raw == null ? "" : raw.strip();
        if (identifier.isBlank() || identifier.length() > 255) {
            page(context, "identifier", "invalid_identifier");
            return;
        }
        if (!EmailCodeAuthenticator.claimRequestBudgets(context)) {
            page(context, "identifier", "rate_limited");
            return;
        }
        AuthenticationSessionModel auth = context.getAuthenticationSession();
        BrokerLinkProofs proofs = new BrokerLinkProofs(context.getSession().singleUseObjects());
        proofs.discardCode(auth.getAuthNote(BrokerLinkState.CODE));
        proofs.discardProof(auth.getAuthNote(BrokerLinkState.PROOF));
        context.clearUser();
        auth.removeAuthNote(AuthenticationProcessor.AUTHN_CREDENTIALS);
        auth.removeAuthNote(AbstractUsernameFormAuthenticator.USER_SET_BEFORE_USERNAME_PASSWORD_AUTH);
        auth.removeAuthNote(org.keycloak.services.managers.AuthenticationManager.PASSWORD_VALIDATED);
        auth.removeAuthNote(AbstractIdpAuthenticator.EXISTING_USER_INFO);
        auth.removeAuthNote(BrokerLinkState.REQUIRED);
        auth.removeAuthNote(BrokerLinkState.PROOF);
        auth.removeAuthNote(BrokerLinkState.OTP);
        UserModel target = resolve(context, identifier);
        String primary = target == null ? "" : BrokerLinkState.normal(target.getEmail());
        auth.setAuthNote(BrokerLinkState.IDENTIFIER, identifier);
        auth.setAuthNote(BrokerLinkState.TARGET, target == null ? "" : target.getId());
        auth.setAuthNote(BrokerLinkState.PRIMARY, primary);
        auth.setAuthNote(BrokerLinkState.DEADLINE, Integer.toString(Time.currentTime() + LoginCodes.TTL_SECONDS));
        if (password) {
            auth.setAuthNote(BrokerLinkState.STAGE, "password");
            if (target != null) setCandidate(auth, target);
            password(context).authenticate(nativeContext(context, () -> firstFactor(context, "password_or_passkey")));
            return;
        }
        String addressKey = primary.isBlank() ? BrokerLinkState.normal(identifier) : primary;
        boolean within = EmailCodeAuthenticator.claimAddressBudgets(context, addressKey);
        String ceiling = target == null ? null : EmailCodeAuthenticator.accountCeilingKey(context, target.getId());
        boolean mailable = within && target != null && !primary.isBlank()
                && !budgets.pastCeiling(context, ceiling);
        BrokerLinkProofs.Binding binding = BrokerLinkState.binding(context, broker(context), mailable ? target : null);
        String handle = BrokerLinkState.handle();
        String code = proofs.issueCode(handle, binding);
        auth.setAuthNote(BrokerLinkState.CODE, handle);
        auth.setAuthNote(BrokerLinkState.SENT, Integer.toString(Time.currentTime()));
        auth.setAuthNote(BrokerLinkState.STAGE, "code");
        // A suppressed or unknown target holds a dummy code and is indistinguishable on the page.
        if (!mailable) auth.setAuthNote(BrokerLinkState.TARGET, "");
        if (mailable) {
            mail.sendCode(context, target, primary, code, "link");
            budgets.countTowardTheDailyBudget(context);
        }
        page(context, "code", null);
    }

    private UserModel resolve(AuthenticationFlowContext context, String identifier) {
        LoginIdentifiers.Match match = LoginIdentifiers.resolve(context.getSession(), context.getRealm(),
                settings.ytuIdpAlias(), identifier);
        UserModel target = match instanceof LoginIdentifiers.Person person ? person.user() : null;
        return eligible(context, target) ? target : null;
    }

    static boolean eligible(AuthenticationFlowContext context, UserModel target) {
        if (target == null || !target.isEnabled() || target.getServiceAccountClientLink() != null
                || context.getRealm().isDuplicateEmailsAllowed()
                || AuthenticatorUtils.getDisabledByBruteForceEventError(context, target) != null) return false;
        SerializedBrokeredIdentityContext broker = broker(context);
        if (broker == null) return false;
        FederatedIdentityModel current = context.getSession().users().getFederatedIdentity(context.getRealm(), target,
                broker.getIdentityProviderId());
        if (current != null) return false; // No override/replacement of another Microsoft identity.
        UserModel owner = context.getSession().users().getUserByFederatedIdentity(context.getRealm(),
                new FederatedIdentityModel(broker.getIdentityProviderId(), broker.getId(), broker.getUsername()));
        return owner == null;
    }

    private UserModel target(AuthenticationFlowContext context) {
        AuthenticationSessionModel auth = context.getAuthenticationSession();
        String id = auth.getAuthNote(BrokerLinkState.TARGET);
        if (id == null || id.isBlank()) return null;
        UserModel target = resolve(context, auth.getAuthNote(BrokerLinkState.IDENTIFIER));
        return target != null && id.equals(target.getId())
                && BrokerLinkState.normal(target.getEmail()).equals(auth.getAuthNote(BrokerLinkState.PRIMARY))
                ? target : null;
    }

    private void verifyCode(AuthenticationFlowContext context, String typed) {
        String code = LoginCodes.codeFromInput(typed);
        if (code == null) { page(context, "code", "malformed_code"); return; }
        AuthenticationSessionModel auth = context.getAuthenticationSession();
        BrokerLinkProofs proofs = new BrokerLinkProofs(context.getSession().singleUseObjects());
        UserModel target = target(context);
        String ceiling = target == null ? null : EmailCodeAuthenticator.accountCeilingKey(context, target.getId());
        boolean pastCeiling = target != null && budgets.pastCeiling(context, ceiling);
        SingleUseCodes.Result result = pastCeiling ? proofs.spendTry(auth.getAuthNote(BrokerLinkState.CODE))
                : proofs.confirmCode(auth.getAuthNote(BrokerLinkState.CODE), code,
                BrokerLinkState.binding(context, broker(context), target));
        if (result.status() == SingleUseCodes.Status.CONFIRMED && target != null) {
            context.setUser(target);
            firstFactor(context, "email_code");
        } else {
            if (result.status() == SingleUseCodes.Status.WRONG_CODE && target != null) {
                if (context.getRealm().isBruteForceProtected()) context.getProtector().failedLogin(context.getRealm(),
                        target, context.getConnection(), context.getUriInfo(), null);
                if (!pastCeiling) budgets.countTowardTheCeiling(context, target, ceiling);
            }
            page(context, "code", result.status() == SingleUseCodes.Status.WRONG_CODE ? "wrong_code" : "code_expired");
        }
    }

    private void firstFactor(AuthenticationFlowContext context, String method) {
        UserModel selected = target(context);
        if (selected == null || context.getUser() == null || !selected.getId().equals(context.getUser().getId())) {
            context.clearUser();
            page(context, "identifier", "try_again");
            return;
        }
        AuthenticationSessionModel auth = context.getAuthenticationSession();
        auth.setAuthNote(BrokerLinkState.METHOD, method);
        String otp = BrokerLinkState.otpSnapshot(selected);
        auth.setAuthNote(BrokerLinkState.OTP, otp);
        if (!otp.isEmpty()) {
            auth.setAuthNote(BrokerLinkState.STAGE, "otp");
            otp(context, false);
        } else complete(context);
    }

    private void otp(AuthenticationFlowContext context, boolean action) {
        UserModel selected = target(context);
        if (selected == null || !BrokerLinkState.otpSnapshot(selected)
                .equals(context.getAuthenticationSession().getAuthNote(BrokerLinkState.OTP))) {
            page(context, "unavailable", "try_again");
            return;
        }
        context.setUser(selected);
        AuthenticationFlowContext delegated = nativeContext(context, () -> complete(context));
        OTPFormAuthenticator otp = new OTPFormAuthenticator();
        if (action) otp.action(delegated); else otp.authenticate(delegated);
    }

    private void complete(AuthenticationFlowContext context) {
        AuthenticationSessionModel auth = context.getAuthenticationSession();
        UserModel selected = target(context);
        if (selected == null || !BrokerLinkState.otpSnapshot(selected).equals(auth.getAuthNote(BrokerLinkState.OTP))) {
            page(context, "unavailable", "try_again");
            return;
        }
        int deadline;
        try { deadline = Integer.parseInt(auth.getAuthNote(BrokerLinkState.DEADLINE)); }
        catch (RuntimeException invalid) { page(context, "unavailable", "try_again"); return; }
        if (deadline <= Time.currentTime()) { page(context, "unavailable", "try_again"); return; }
        String handle = BrokerLinkState.handle();
        new BrokerLinkProofs(context.getSession().singleUseObjects()).issueProof(handle,
                BrokerLinkState.binding(context, broker(context), selected), auth.getAuthNote(BrokerLinkState.OTP),
                auth.getAuthNote(BrokerLinkState.METHOD), deadline);
        auth.setAuthNote(BrokerLinkState.PROOF, handle);
        auth.setAuthNote(BrokerLinkState.REQUIRED, "true");
        auth.setAuthNote(BrokerLinkState.STAGE, "proven");
        setCandidate(auth, selected);
        // None of the following writes changes the account. Keycloak's callback performs the link.
        SerializedBrokeredIdentityContext broker = broker(context);
        auth.setAuthNote(BrokerLinkState.ORIGINAL_EMAIL, BrokerLinkState.text(broker.getEmail()));
        broker.setEmail(null);
        broker.saveToAuthenticationSession(auth, AbstractIdpAuthenticator.BROKERED_CONTEXT_NOTE);
        auth.removeAuthNote(PersonalEmailOffer.SCHEDULED_NOTE);
        auth.removeRequiredAction(PersonalEmailOffer.PROVIDER_ID);
        context.setUser(selected);
        context.success();
    }

    static void setCandidate(AuthenticationSessionModel auth, UserModel selected) {
        auth.setAuthNote(AbstractIdpAuthenticator.EXISTING_USER_INFO,
                new ExistingUserInfo(selected.getId(), UserModel.USERNAME, selected.getUsername()).serialize());
    }

    static SerializedBrokeredIdentityContext broker(AuthenticationFlowContext context) {
        return SerializedBrokeredIdentityContext.readFromAuthenticationSession(context.getAuthenticationSession(),
                AbstractIdpAuthenticator.BROKERED_CONTEXT_NOTE);
    }

    private int secondsUntilResend(AuthenticationFlowContext context) {
        try { return Math.max(0, Integer.parseInt(context.getAuthenticationSession().getAuthNote(BrokerLinkState.SENT))
                + 60 - Time.currentTime()); }
        catch (RuntimeException malformed) { return 0; }
    }

    private void page(AuthenticationFlowContext context, String stage, String error) {
        LoginFormsProvider form = context.form().setAttribute("skyExistingAccountStage", stage)
                .setAttribute("skyExistingAccountIdentifier",
                        BrokerLinkState.text(context.getAuthenticationSession().getAuthNote(BrokerLinkState.IDENTIFIER)))
                .setAttribute("skyExistingAccountResendAfter", Integer.toString(secondsUntilResend(context)));
        if (error != null) form.setAttribute("skyExistingAccountError", error);
        if ("question".equals(stage)) {
            form.setAttribute("skyExistingAccountSchoolCandidate", schoolCandidate(context) != null);
        }
        context.challenge(form.createForm(TEMPLATE));
    }

    private UserModel schoolCandidate(AuthenticationFlowContext context) {
        String school = BrokerLinkState.normal(broker(context).getFirstAttribute("schoolEmail"));
        UserModel candidate = resolve(context, school);
        return candidate != null && school.equals(BrokerLinkState.normal(candidate.getFirstAttribute("personalEmail")))
                ? candidate : null;
    }

    private IdpUsernamePasswordForm password(AuthenticationFlowContext context) {
        return new IdpUsernamePasswordForm(context.getSession()) {
            @Override
            protected boolean validateForm(AuthenticationFlowContext current, MultivaluedMap<String, String> data) {
                UserModel selected = target(current);
                if (selected == null) {
                    current.clearUser();
                    current.getAuthenticationSession().removeAuthNote(AbstractIdpAuthenticator.EXISTING_USER_INFO);
                } else setCandidate(current.getAuthenticationSession(), selected);
                // The native form's default re-lookup only understands email/username, not a
                // proven personalEmail alias. Pin the already resolved target for native password
                // validation; a missing target still runs native dummy hashing and generic error.
                current.getAuthenticationSession().setAuthNote(USER_SET_BEFORE_USERNAME_PASSWORD_AUTH, "true");
                return super.validateForm(current, data);
            }

            @Override
            public void authenticate(AuthenticationFlowContext current) {
                // Until a credential proves the target, passkey discovery stays unidentified and
                // must not expose that target's registered credential names or canonical username.
                current.clearUser();
                super.authenticate(current);
            }

            @Override
            protected LoginFormsProvider setupForm(AuthenticationFlowContext current, MultivaluedMap<String, String> data,
                                                   Optional<UserModel> existing) {
                UserModel failedTarget = current.getUser();
                current.clearUser();
                LoginFormsProvider form = super.setupForm(current, data, Optional.empty());
                // The stock form fills the canonical username. Only echo the person's own input.
                data.putSingle("username", BrokerLinkState.text(current.getAuthenticationSession()
                        .getAuthNote(BrokerLinkState.IDENTIFIER)));
                // The form provider captured a null user, so it cannot expose target credentials.
                // Restore only the selected target in the flow context for native logFailure/BF.
                if (failedTarget != null && failedTarget.getId().equals(current.getAuthenticationSession()
                        .getAuthNote(BrokerLinkState.TARGET))) current.setUser(failedTarget);
                return form.setFormData(data);
            }
        };
    }

    /** Native credential/OTP validation stays native; only completion is held for the next factor. */
    private AuthenticationFlowContext nativeContext(AuthenticationFlowContext delegate, Runnable success) {
        return (AuthenticationFlowContext) Proxy.newProxyInstance(AuthenticationFlowContext.class.getClassLoader(),
                new Class<?>[]{AuthenticationFlowContext.class}, (proxy, method, args) -> {
                    if (method.getName().equals("success")) {
                        UserModel authenticated = delegate.getUser();
                        boolean sameTarget = authenticated != null && authenticated.getId().equals(
                                delegate.getAuthenticationSession().getAuthNote(BrokerLinkState.TARGET));
                        if (sameTarget && args != null && args.length == 1 && args[0] instanceof String category) {
                            AuthenticatorUtil.addAuthCredential(delegate.getAuthenticationSession(), category);
                        }
                        success.run();
                        return null;
                    }
                    if (method.getName().equals("form")) return delegate.form().setAttribute(ESCAPE_ATTRIBUTE, true);
                    try { return method.invoke(delegate, args); }
                    catch (InvocationTargetException wrapped) { throw wrapped.getCause(); }
                });
    }

    private static final class NativeDuplicate extends IdpCreateUserIfUniqueAuthenticator {
        boolean exists(AuthenticationFlowContext context, SerializedBrokeredIdentityContext serialized,
                       BrokeredIdentityContext live) {
            String username = getUsername(context, serialized, live);
            return username != null && checkExistingUser(context, username, serialized, live) != null;
        }
    }

    @Override public boolean requiresUser() { return false; }
    @Override public boolean configuredFor(KeycloakSession session, RealmModel realm, UserModel user) { return true; }
    @Override public void setRequiredActions(KeycloakSession session, RealmModel realm, UserModel user) { }
    @Override public void close() { }
}
