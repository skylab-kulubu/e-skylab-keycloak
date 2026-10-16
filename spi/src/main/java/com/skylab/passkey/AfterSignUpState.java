package com.skylab.passkey;

import com.skylab.account.EmailCodeSignUp;
import java.util.Set;
import java.util.List;
import java.util.HexFormat;
import java.security.MessageDigest;
import java.util.function.LongSupplier;
import org.keycloak.common.util.SecretGenerator;
import org.keycloak.common.util.Base64Url;
import org.keycloak.models.AccountRoles;
import org.keycloak.models.ClientModel;
import org.keycloak.models.IdentityProviderModel;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.RequiredActionProviderModel;
import org.keycloak.models.RoleModel;
import org.keycloak.models.UserModel;
import org.keycloak.sessions.AuthenticationSessionModel;
import org.keycloak.util.JsonSerialization;

/** A short, server-owned continuation inside the authentication session that opened the account. */
final class AfterSignUpState {
    static final String FEATURE_ATTRIBUTE = "skyAfterSignUpEnabled";
    static final String NOTE = "sky-after-sign-up.state";
    static final String YTU_ALIAS = "OBS";
    static final long TTL_SECONDS = 600;
    private static final Set<String> FIELDS = Set.of("stage", "realmId", "userId", "rootId", "tabId", "clientId", "nonce", "issuedAt", "expiresAt");

    enum Stage { SCHOOL, LINK_PENDING, CREDENTIALS, DONE }

    record State(Stage stage, String realmId, String userId, String rootId, String tabId,
                 String clientId, String nonce, long issuedAt, long expiresAt) { }

    private AfterSignUpState() { }

    static boolean enabled(RealmModel realm) {
        return realm != null && "true".equals(realm.getAttribute(FEATURE_ATTRIBUTE));
    }

    static boolean present(AuthenticationSessionModel auth) {
        return auth != null && auth.getAuthNote(NOTE) != null;
    }

    static State begin(KeycloakSession session, RealmModel realm, AuthenticationSessionModel auth, UserModel user, LongSupplier clock) {
        long now = clock.getAsLong();
        if (auth == null || present(auth)
                || !"true".equals(auth.getAuthNote(EmailCodeSignUp.SIGNED_UP_NOTE))
                || !boundModels(realm, auth, user) || !namesPresent(user) || now < 0 || now > Long.MAX_VALUE - TTL_SECONDS) {
            return null;
        }
        State state = new State(Stage.SCHOOL, realm.getId(), user.getId(), auth.getParentSession().getId(),
                auth.getTabId(), auth.getClient().getClientId(), Base64Url.encode(SecretGenerator.getInstance().randomBytes(32)), now, now + TTL_SECONDS);
        // Only one capsule may be initialized for this authentication-session binding.
        String beginKey = "sky-auth:after-sign-up:begin:" + digest(List.of(state.realmId(), state.userId(), state.rootId(), state.tabId(), state.clientId()));
        if (!claim(session, beginKey, state.expiresAt(), clock)) return null;
        store(auth, state);
        auth.removeAuthNote(EmailCodeSignUp.SIGNED_UP_NOTE);
        return state;
    }

    static State read(RealmModel realm, AuthenticationSessionModel auth, UserModel user, long now) {
        if (!boundModels(realm, auth, user) || !namesPresent(user)) return null;
        String raw = auth.getAuthNote(NOTE);
        if (raw == null || raw.length() > 2_048) return null;
        try {
            var tree = JsonSerialization.mapper.readTree(raw);
            if (tree == null || !tree.isObject() || tree.size() != FIELDS.size()) return null;
            var names = tree.fieldNames();
            while (names.hasNext()) if (!FIELDS.contains(names.next())) return null;
            for (String field : FIELDS) {
                if (field.equals("issuedAt") || field.equals("expiresAt")) {
                    if (!tree.get(field).isIntegralNumber() || !tree.get(field).canConvertToLong()) return null;
                } else if (!tree.get(field).isTextual()) return null;
            }
            State state = JsonSerialization.mapper.treeToValue(tree, State.class);
            if (state.stage() == null || !state.nonce().matches("[A-Za-z0-9_-]{43}") || state.issuedAt() < 0 || state.issuedAt() > now
                    || state.issuedAt() > Long.MAX_VALUE - TTL_SECONDS
                    || state.expiresAt() != state.issuedAt() + TTL_SECONDS || now >= state.expiresAt()
                    || !realm.getId().equals(state.realmId()) || !user.getId().equals(state.userId())
                    || !auth.getParentSession().getId().equals(state.rootId())
                    || !auth.getTabId().equals(state.tabId())
                    || !auth.getClient().getClientId().equals(state.clientId())) return null;
            return state;
        } catch (Exception invalid) {
            return null;
        }
    }

    static State move(KeycloakSession session, AuthenticationSessionModel auth, State state, Stage next, LongSupplier clock) {
        boolean allowed = state.stage() == Stage.SCHOOL && (next == Stage.LINK_PENDING || next == Stage.CREDENTIALS)
                || state.stage() == Stage.LINK_PENDING && next == Stage.CREDENTIALS
                || state.stage() == Stage.CREDENTIALS && next == Stage.DONE;
        if (!allowed) throw new IllegalArgumentException("Invalid sign-up stage transition");
        if (!encoded(state).equals(auth.getAuthNote(NOTE))) return null;
        String key = "sky-auth:after-sign-up:claim:" + digest(List.of(state.realmId(), state.userId(), state.rootId(),
                state.tabId(), state.clientId(), state.nonce(), state.stage().name()));
        if (!claim(session, key, state.expiresAt(), clock) || !encoded(state).equals(auth.getAuthNote(NOTE))) return null;
        State moved = new State(next, state.realmId(), state.userId(), state.rootId(), state.tabId(),
                state.clientId(), state.nonce(), state.issuedAt(), state.expiresAt());
        store(auth, moved);
        return moved;
    }

    /** Credential offers are sign-up actions, independent of Account API and IdP-link scopes. */
    static boolean supportedRelyingParty(RealmModel realm, AuthenticationSessionModel auth, UserModel user) {
        return boundModels(realm, auth, user) && auth.getClient().isEnabled()
                && auth.getClient().isStandardFlowEnabled() && "openid-connect".equals(auth.getClient().getProtocol())
                && actionEnabled(realm, SignUpCredentialsRequiredAction.PROVIDER_ID);
    }

    /** Native linking alone needs the exact account role and scope checked by Keycloak's IdpLinkAction. */
    static boolean nativeLinkSupported(KeycloakSession session, RealmModel realm, AuthenticationSessionModel auth, UserModel user) {
        if (session == null || !supportedRelyingParty(realm, auth, user) || !actionEnabled(realm, "idp_link")) return false;
        IdentityProviderModel provider = session.identityProviders().getByAlias(YTU_ALIAS);
        if (provider == null || !provider.isEnabled()) return false;
        ClientModel account = realm.getClientByClientId("account");
        if (account == null) return false;
        return hasRoleAndScope(account.getRole(AccountRoles.MANAGE_ACCOUNT), user, auth.getClient())
                || hasRoleAndScope(account.getRole(AccountRoles.MANAGE_ACCOUNT_LINKS), user, auth.getClient());
    }

    static boolean actionEnabled(RealmModel realm, String alias) {
        RequiredActionProviderModel action = realm.getRequiredActionProviderByAlias(alias);
        return action != null && action.isEnabled() && alias.equals(action.getProviderId());
    }

    static void scheduleCredentials(AuthenticationSessionModel auth) {
        if (!auth.getRequiredActions().contains(SignUpCredentialsRequiredAction.PROVIDER_ID)) {
            auth.addRequiredAction(SignUpCredentialsRequiredAction.PROVIDER_ID);
        }
    }

    private static boolean hasRoleAndScope(RoleModel role, UserModel user, ClientModel client) {
        return role != null && user.hasRole(role) && client.hasScope(role);
    }

    private static boolean boundModels(RealmModel realm, AuthenticationSessionModel auth, UserModel user) {
        return realm != null && auth != null && user != null && user.isEnabled()
                && user.getServiceAccountClientLink() == null
                && auth.getParentSession() != null && auth.getClient() != null
                && id(realm.getId()) && id(user.getId()) && id(auth.getParentSession().getId())
                && id(auth.getTabId()) && id(auth.getClient().getClientId());
    }

    private static boolean namesPresent(UserModel user) {
        return user != null && user.getFirstName() != null && !user.getFirstName().isBlank()
                && user.getLastName() != null && !user.getLastName().isBlank();
    }

    private static boolean id(String value) {
        return value != null && !value.isBlank() && value.length() <= 255;
    }

    private static boolean claim(KeycloakSession session, String key, long expiresAt, LongSupplier clock) {
        long remaining = expiresAt - clock.getAsLong();
        if (session == null || remaining <= 0 || remaining > TTL_SECONDS || session.singleUseObjects() == null) return false;
        return session.singleUseObjects().putIfAbsent(key, remaining) && clock.getAsLong() < expiresAt;
    }

    private static String digest(List<String> binding) {
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
                    .digest(JsonSerialization.writeValueAsBytes(binding)));
        } catch (Exception unavailable) {
            throw new IllegalStateException("Cannot bind sign-up continuation", unavailable);
        }
    }

    private static String encoded(State state) {
        try {
            return JsonSerialization.writeValueAsString(state);
        } catch (java.io.IOException impossible) {
            throw new IllegalStateException("Cannot store sign-up continuation", impossible);
        }
    }

    private static void store(AuthenticationSessionModel auth, State state) {
        auth.setAuthNote(NOTE, encoded(state));
    }
}
