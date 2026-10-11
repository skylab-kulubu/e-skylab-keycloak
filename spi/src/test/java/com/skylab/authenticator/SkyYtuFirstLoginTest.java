package com.skylab.authenticator;

import com.skylab.account.PersonalEmailOffer;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.keycloak.authentication.AuthenticationFlowContext;
import org.keycloak.authentication.authenticators.broker.AbstractIdpAuthenticator;
import org.keycloak.authentication.authenticators.broker.util.SerializedBrokeredIdentityContext;
import org.keycloak.models.AuthenticationExecutionModel;
import org.keycloak.models.IdentityProviderModel;
import org.keycloak.models.IdentityProviderStorageProvider;
import org.keycloak.models.IdentityProviderSyncMode;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.ModelDuplicateException;
import org.keycloak.models.RealmModel;
import org.keycloak.models.RequiredActionProviderModel;
import org.keycloak.models.UserModel;
import org.keycloak.models.UserProvider;
import org.keycloak.sessions.AuthenticationSessionModel;

import java.util.HashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyMap;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * The first step of the first broker login flow (eskylab-login-ux 07) against a brokered identity
 * kept in a real {@link SerializedBrokeredIdentityContext} note and a mocked user store. Every
 * outcome ends in {@code context.success()}; only the brokered e-mail and the review profile note
 * differ.
 */
class SkyYtuFirstLoginTest {

    private static final String NOTE = AbstractIdpAuthenticator.BROKERED_CONTEXT_NOTE;
    private static final String ENFORCE = AbstractIdpAuthenticator.ENFORCE_UPDATE_PROFILE;

    private final AuthenticationFlowContext context = mock(AuthenticationFlowContext.class);
    private final AuthenticationSessionModel authSession = mock(AuthenticationSessionModel.class);
    private final KeycloakSession session = mock(KeycloakSession.class);
    private final UserProvider users = mock(UserProvider.class);
    private final RealmModel realm = mock(RealmModel.class);
    private final IdentityProviderStorageProvider providers = mock(IdentityProviderStorageProvider.class);
    private final IdentityProviderModel obs = new IdentityProviderModel();
    private final Map<String, String> notes = new HashMap<>();
    /** Lowercased address to the attribute that holds it, as Keycloak's exact search sees it. */
    private final Map<String, String> attributeHolders = new HashMap<>();
    private final SkyYtuFirstLogin step = new SkyYtuFirstLogin();

    @BeforeEach
    void setUp() {
        when(context.getAuthenticationSession()).thenReturn(authSession);
        when(context.getSession()).thenReturn(session);
        when(context.getRealm()).thenReturn(realm);
        when(session.users()).thenReturn(users);
        when(session.identityProviders()).thenReturn(providers);
        obs.setAlias("OBS");
        obs.setSyncMode(IdentityProviderSyncMode.LEGACY);
        when(providers.getByAlias("OBS")).thenReturn(obs);
        when(authSession.getRealm()).thenReturn(realm);
        when(realm.isLoginWithEmailAllowed()).thenReturn(true);
        when(authSession.getAuthNote(anyString())).thenAnswer(call -> notes.get(call.<String>getArgument(0)));
        doAnswer(call -> notes.put(call.getArgument(0), call.getArgument(1)))
                .when(authSession).setAuthNote(anyString(), anyString());
        when(users.searchForUserStream(eq(realm), anyMap(), anyInt(), anyInt())).thenAnswer(call -> {
            Map<String, String> query = call.getArgument(1);
            return attributeHolders.entrySet().stream()
                    .filter(entry -> entry.getKey().equalsIgnoreCase(query.get(entry.getValue())))
                    .map(entry -> mock(UserModel.class));
        });
    }

    private void brokered(String email, String schoolEmail) {
        SerializedBrokeredIdentityContext identity = new SerializedBrokeredIdentityContext();
        identity.setId("microsoft-object-id");
        identity.setBrokerUserId("OBS.microsoft-object-id");
        identity.setIdentityProviderId("OBS");
        identity.setUsername("new.student");
        identity.setModelUsername("new.student");
        identity.setFirstName("Yeni");
        identity.setLastName("Öğrenci");
        identity.setEmail(email);
        if (schoolEmail != null) {
            identity.setSingleAttribute(SkyYtuFirstLogin.SCHOOL_EMAIL_ATTRIBUTE, schoolEmail);
        }
        identity.setSingleAttribute("department", "Bilgisayar Mühendisliği");
        identity.saveToAuthenticationSession(authSession, NOTE);
    }

    private SerializedBrokeredIdentityContext stored() {
        return SerializedBrokeredIdentityContext.readFromAuthenticationSession(authSession, NOTE);
    }

    private void run() {
        step.authenticate(context);
        verify(context).success();
    }

    @Test
    void aNewYtuIdentityTakesItsSchoolEmailTrimmedAndLowercased() {
        brokered(null, "  Yeni.Ogrenci@STD.Yildiz.edu.tr ");

        run();

        assertEquals("yeni.ogrenci@std.yildiz.edu.tr", stored().getEmail());
        assertEquals("  Yeni.Ogrenci@STD.Yildiz.edu.tr ", stored().getFirstAttribute("schoolEmail"));
        assertEquals("Bilgisayar Mühendisliği", stored().getFirstAttribute("department"));
        assertNull(notes.get(ENFORCE));
    }

    private UserModel holderWithEmail(boolean verified) {
        UserModel holder = mock(UserModel.class);
        when(holder.isEmailVerified()).thenReturn(verified);
        return holder;
    }

    @Test
    void anAddressThatIsAnAccountsVerifiedEmailIsWrittenSoKeycloakFindsThatAccount() {
        brokered("", "taken@std.yildiz.edu.tr");
        UserModel holder = holderWithEmail(true);
        when(users.getUserByEmail(realm, "taken@std.yildiz.edu.tr")).thenReturn(holder);

        run();

        assertEquals("taken@std.yildiz.edu.tr", stored().getEmail());
        assertNull(notes.get(ENFORCE));
    }

    @Test
    void anAccountsUnverifiedEmailDoesNotSendTheOwnerToLinkThatAccount() {
        brokered(null, "squatted@std.yildiz.edu.tr");
        UserModel squatter = holderWithEmail(false);
        when(users.getUserByEmail(realm, "squatted@std.yildiz.edu.tr")).thenReturn(squatter);

        run();

        assertNull(stored().getEmail());
        assertEquals("true", notes.get(ENFORCE));
    }

    @Test
    void withSyncModeForceAnAddressKeycloakKnowsIsNotWrittenSoNoLinkChangesAPrimary() {
        obs.setSyncMode(IdentityProviderSyncMode.FORCE);
        brokered(null, "taken@std.yildiz.edu.tr");
        UserModel holder = holderWithEmail(true);
        when(users.getUserByEmail(realm, "taken@std.yildiz.edu.tr")).thenReturn(holder);

        run();

        assertNull(stored().getEmail());
        assertEquals("true", notes.get(ENFORCE));
    }

    @Test
    void withSyncModeForceAFreeAddressIsStillWritten() {
        obs.setSyncMode(IdentityProviderSyncMode.FORCE);
        brokered(null, "free.force@std.yildiz.edu.tr");

        run();

        assertEquals("free.force@std.yildiz.edu.tr", stored().getEmail());
    }

    @Test
    void withSyncModeForceAKnownBrokeredUsernameIsNotWrittenEither() {
        obs.setSyncMode(IdentityProviderSyncMode.FORCE);
        brokered(null, "upn.only@std.yildiz.edu.tr");
        when(users.getUserByUsername(realm, "new.student")).thenReturn(mock(UserModel.class));

        run();

        assertNull(stored().getEmail());
        assertEquals("true", notes.get(ENFORCE));
    }

    @Test
    void withSyncModeForceABrokeredAddressUsernameThatIsAnAccountsEmailIsNotWritten() {
        obs.setSyncMode(IdentityProviderSyncMode.FORCE);
        brokered(null, "upn.only@std.yildiz.edu.tr");
        SerializedBrokeredIdentityContext identity = stored();
        identity.setModelUsername("graph.mail@std.yildiz.edu.tr");
        identity.saveToAuthenticationSession(authSession, NOTE);
        UserModel holder = holderWithEmail(true);
        when(users.getUserByEmail(realm, "graph.mail@std.yildiz.edu.tr")).thenReturn(holder);

        run();

        assertNull(stored().getEmail());
        assertEquals("true", notes.get(ENFORCE));
    }

    @Test
    void withoutForceAKnownBrokeredUsernameDoesNotStopTheWrite() {
        brokered(null, "upn.only@std.yildiz.edu.tr");
        when(users.getUserByUsername(realm, "new.student")).thenReturn(mock(UserModel.class));

        run();

        assertEquals("upn.only@std.yildiz.edu.tr", stored().getEmail());
    }

    @Test
    void anUnknownIdentityProviderCountsAsForce() {
        when(providers.getByAlias("OBS")).thenReturn(null);
        brokered(null, "named@std.yildiz.edu.tr");
        when(users.getUserByUsername(realm, "named@std.yildiz.edu.tr")).thenReturn(mock(UserModel.class));

        run();

        assertNull(stored().getEmail());
        assertEquals("true", notes.get(ENFORCE));
    }

    @Test
    void staffAddressesOnTheSchoolDomainCountToo() {
        brokered(null, "Hoca@Yildiz.edu.tr");

        run();

        assertEquals("hoca@yildiz.edu.tr", stored().getEmail());
    }

    @Test
    void anAddressThatIsAnAccountsUsernameIsWrittenWhileEmailLoginIsAllowed() {
        brokered(null, "named@std.yildiz.edu.tr");
        when(users.getUserByUsername(realm, "named@std.yildiz.edu.tr")).thenReturn(mock(UserModel.class));

        run();

        assertEquals("named@std.yildiz.edu.tr", stored().getEmail());
    }

    @Test
    void anAddressThatIsAnotherAccountsPersonalEmailIsNotWrittenAndTheProfilePageDecides() {
        brokered(null, "Shared@std.yildiz.edu.tr");
        attributeHolders.put("shared@std.yildiz.edu.tr", "personalEmail");

        run();

        assertNull(stored().getEmail());
        assertEquals("true", notes.get(ENFORCE));
    }

    @Test
    void anAddressThatIsAnotherAccountsSchoolEmailIsNotWrittenAndTheProfilePageDecides() {
        brokered(null, "old.link@std.yildiz.edu.tr");
        attributeHolders.put("OLD.Link@std.yildiz.edu.tr", "schoolEmail");

        run();

        assertNull(stored().getEmail());
        assertEquals("true", notes.get(ENFORCE));
    }

    @Test
    void anAmbiguousEmailLookupWritesNothing() {
        brokered(null, "twice@std.yildiz.edu.tr");
        when(users.getUserByEmail(realm, "twice@std.yildiz.edu.tr")).thenThrow(new ModelDuplicateException("two"));

        run();

        assertNull(stored().getEmail());
        assertEquals("true", notes.get(ENFORCE));
    }

    @Test
    void aPersonAlreadyKnownToTheFlowIsLeftAlone() {
        brokered(null, "linking@std.yildiz.edu.tr");
        when(context.getUser()).thenReturn(mock(UserModel.class));

        run();

        assertNull(stored().getEmail());
        verify(users, never()).getUserByEmail(any(), anyString());
    }

    @Test
    void anExistingAccountPathInProgressIsLeftAlone() {
        brokered(null, "existing@std.yildiz.edu.tr");
        notes.put(AbstractIdpAuthenticator.EXISTING_USER_INFO, "{}");

        run();

        assertNull(stored().getEmail());
    }

    @Test
    void aBrokeredEmailIsNeverReplaced() {
        brokered("someone@example.org", "someone@std.yildiz.edu.tr");

        run();

        assertEquals("someone@example.org", stored().getEmail());
        verify(users, never()).getUserByEmail(any(), anyString());
    }

    @Test
    void noOrAnInvalidSchoolEmailChangesNothing() {
        for (String school : new String[] {null, "   ", "not an address", "a".repeat(250) + "@std.yildiz.edu.tr",
                "guest@gmail.com", "someone@notyildiz.edu.tr", "a@std.yildiz.edu.tr.evil.org", "x@sub.std.yildiz.edu.tr",
                "\"x@evil.com\"@std.yildiz.edu.tr", "\"quoted\"@std.yildiz.edu.tr"}) {
            notes.clear();
            brokered(null, school);
            step.authenticate(context);
            assertNull(stored().getEmail(), String.valueOf(school));
            assertNull(notes.get(ENFORCE));
        }
        verify(users, never()).getUserByEmail(any(), anyString());
    }

    @Test
    void withoutABrokeredIdentityTheStepOnlyContinues() {
        run();

        assertFalse(notes.containsKey(NOTE));
    }

    @Test
    void theUsernameIsNotAnAddressRouteWhenEmailLoginIsOff() {
        brokered(null, "free@std.yildiz.edu.tr");
        when(realm.isLoginWithEmailAllowed()).thenReturn(false);
        when(users.getUserByUsername(realm, "free@std.yildiz.edu.tr")).thenReturn(mock(UserModel.class));

        run();

        assertEquals("free@std.yildiz.edu.tr", stored().getEmail());
        verify(users, never()).getUserByUsername(any(), anyString());
    }

    @Test
    void theFactoryOffersOnlyRequiredAndNoConfig() {
        assertEquals("sky-ytu-first-login", step.getId());
        assertArrayEquals(new AuthenticationExecutionModel.Requirement[] {
                AuthenticationExecutionModel.Requirement.REQUIRED}, step.getRequirementChoices());
        assertFalse(step.isConfigurable());
        assertFalse(step.requiresUser());
        assertEquals(List.of(), step.getConfigProperties());
    }

    // ------------------------------------------------------------------ ticket 21

    private void offerEnabled(boolean enabled) {
        RequiredActionProviderModel model = new RequiredActionProviderModel();
        model.setAlias(PersonalEmailOffer.PROVIDER_ID);
        model.setProviderId(PersonalEmailOffer.PROVIDER_ID);
        model.setEnabled(enabled);
        when(realm.getRequiredActionProviderByAlias(PersonalEmailOffer.PROVIDER_ID)).thenReturn(model);
    }

    @Test
    void aNewAccountWithTheSchoolPrimaryGetsThePersonalEmailOfferWhenTheRealmEnablesIt() {
        offerEnabled(true);
        brokered(null, "Yeni.Ogrenci@STD.Yildiz.edu.tr");

        run();

        verify(authSession).addRequiredAction(PersonalEmailOffer.PROVIDER_ID);
        assertEquals("yeni.ogrenci@std.yildiz.edu.tr", notes.get("sky-personal-email-offer.primary"));
    }

    @Test
    void theOfferIsNotScheduledWhileTheRealmHasItOffOrUnregistered() {
        offerEnabled(false);
        brokered(null, "yeni.ogrenci@std.yildiz.edu.tr");
        run();
        when(realm.getRequiredActionProviderByAlias(PersonalEmailOffer.PROVIDER_ID)).thenReturn(null);
        step.authenticate(context);

        verify(authSession, never()).addRequiredAction(anyString());
    }

    @Test
    void theOfferIsNotScheduledWhenKeycloakWillLinkAnExistingAccountOrTheAddressIsNotWritten() {
        offerEnabled(true);
        brokered("", "taken@std.yildiz.edu.tr");
        UserModel holder = holderWithEmail(true);
        when(users.getUserByEmail(realm, "taken@std.yildiz.edu.tr")).thenReturn(holder);
        run();
        verify(authSession, never()).addRequiredAction(anyString());

        brokered(null, "shared@std.yildiz.edu.tr");
        attributeHolders.put("shared@std.yildiz.edu.tr", "personalEmail");
        step.authenticate(context);
        verify(authSession, never()).addRequiredAction(anyString());
    }
}
