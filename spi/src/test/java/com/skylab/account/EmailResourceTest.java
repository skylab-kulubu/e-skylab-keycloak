package com.skylab.account;

import org.junit.jupiter.api.Test;
import org.keycloak.models.KeycloakContext;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;

import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class EmailResourceTest {

    private final KeycloakSession session = mock(KeycloakSession.class);

    EmailResourceTest() {
        KeycloakContext context = mock(KeycloakContext.class);
        RealmModel realm = mock(RealmModel.class);
        when(session.getContext()).thenReturn(context);
        when(context.getRealm()).thenReturn(realm);
        when(realm.getSmtpConfig()).thenReturn(Map.of());
    }

    @Test
    void addressesAreTrimmedAndLowercasedWithoutTheTurkishDotlessI() {
        assertEquals("ada@example.com", EmailResource.normalise("  Ada@Example.COM "));
        assertEquals("iris@example.com", EmailResource.normalise("IRIS@example.com"));
    }

    @Test
    void keycloaksOwnValidatorDecidesWhetherAnAddressIsAnAddress() {
        assertTrue(EmailResource.isValidAddress(session, "ada@example.com"));
        assertTrue(EmailResource.isValidAddress(session, "ada.lovelace+club@std.yildiz.edu.tr"));
        assertFalse(EmailResource.isValidAddress(session, "ada"));
        assertFalse(EmailResource.isValidAddress(session, "ada@"));
        assertFalse(EmailResource.isValidAddress(session, "ada@example .com"));
        assertFalse(EmailResource.isValidAddress(session, "ada lovelace@example.com"));
    }

    @Test
    void anAddressThePersonAlreadyOwnsIsNotAChange() {
        UserModel user = mock(UserModel.class);
        when(user.getEmail()).thenReturn("ada@std.yildiz.edu.tr");
        when(user.getFirstAttribute(IdentityResource.SCHOOL_EMAIL_ATTRIBUTE)).thenReturn("Ada@std.yildiz.edu.tr");
        when(user.getFirstAttribute(IdentityResource.PERSONAL_EMAIL_ATTRIBUTE)).thenReturn("ada@example.com");

        assertTrue(EmailResource.isOwnAddress(user, "ada@std.yildiz.edu.tr"), "the primary is already theirs");
        assertTrue(EmailResource.isOwnAddress(user, "ada@example.com"), "the personal address is already theirs");
        assertFalse(EmailResource.isOwnAddress(user, "ada.lovelace@example.com"));
    }

    @Test
    void anAccountWithoutAddressesOwnsNothing() {
        assertFalse(EmailResource.isOwnAddress(mock(UserModel.class), "ada@example.com"));
    }

    @Test
    void thePersonalAddressCountsAsVerifiedOnlyWithTheMomentThisExtensionRecorded() {
        UserModel user = mock(UserModel.class);
        assertFalse(IdentityResource.isPersonalEmailVerified(user), "no personal address, nothing verified");

        when(user.getFirstAttribute(IdentityResource.PERSONAL_EMAIL_ATTRIBUTE)).thenReturn("ada@example.com");
        assertFalse(IdentityResource.isPersonalEmailVerified(user), "an address written by an admin is not proven");

        when(user.getId()).thenReturn("user-a");
        when(user.getFirstAttribute(IdentityResource.PERSONAL_EMAIL_VERIFIED_AT_ATTRIBUTE)).thenReturn("yesterday");
        assertFalse(IdentityResource.isPersonalEmailVerified(user), "an unreadable moment fails closed");

        when(user.getFirstAttribute(IdentityResource.PERSONAL_EMAIL_VERIFIED_AT_ATTRIBUTE))
                .thenReturn("2026-09-21T13:10:41Z");
        assertTrue(IdentityResource.isPersonalEmailVerified(user));
    }

    @Test
    void aConfirmedAddressBecomesPrimaryWhenAskedOrWhenThereIsNoPrimaryYet() {
        assertTrue(EmailResource.confirmedBecomesPrimary(true, null, "ada@std.yildiz.edu.tr"));
        assertTrue(EmailResource.confirmedBecomesPrimary(false, null, ""));
        assertTrue(EmailResource.confirmedBecomesPrimary(false, null, null));
        assertFalse(EmailResource.confirmedBecomesPrimary(false, null, "ada@std.yildiz.edu.tr"));
    }

    // Replacing the personal address that is the primary must move the primary with it; otherwise
    // Keycloak email keeps pointing at an address the person no longer has (primary "none").
    @Test
    void replacingThePersonalAddressThatIsPrimaryMovesThePrimaryWithIt() {
        assertTrue(EmailResource.confirmedBecomesPrimary(false, "old@example.com", "OLD@example.com"));
        assertFalse(EmailResource.confirmedBecomesPrimary(false, "old@example.com", "ada@std.yildiz.edu.tr"),
                "replacing a personal address that is not primary leaves the primary alone");
    }

    @Test
    void anAddressBecomesPrimaryOnlyOnceItIsProven() {
        assertEquals(EmailResource.PrimaryChoice.APPLY,
                EmailResource.choosePrimary("ada@example.com", true, "ada@std.yildiz.edu.tr", true));
        assertEquals(EmailResource.PrimaryChoice.UNPROVEN,
                EmailResource.choosePrimary("ada@example.com", false, "ada@std.yildiz.edu.tr", true));
    }

    // A school attribute nobody linked to YTÜ is not a School e-mail (CONTEXT, Verified YTÜ
    // account), so it is refused exactly like an unproven personal address.
    @Test
    void aSchoolAttributeWithoutTheYtuLinkIsNotProven() {
        assertEquals(EmailResource.PrimaryChoice.UNPROVEN,
                EmailResource.choosePrimary("ada@std.yildiz.edu.tr", false, "ada@example.com", true));
    }

    @Test
    void choosingTheCurrentPrimaryChangesNothingWhetherOrNotItWasProvenHere() {
        assertEquals(EmailResource.PrimaryChoice.UNCHANGED,
                EmailResource.choosePrimary("ada@std.yildiz.edu.tr", false, "ADA@std.yildiz.edu.tr", true));
        assertEquals(EmailResource.PrimaryChoice.UNCHANGED,
                EmailResource.choosePrimary("ada@example.com", true, "ada@example.com", true));
    }

    // A primary Keycloak does not yet mark verified is repaired once the address is proven.
    @Test
    void aProvenCurrentPrimaryThatKeycloakDoesNotMarkVerifiedIsRepaired() {
        assertEquals(EmailResource.PrimaryChoice.APPLY,
                EmailResource.choosePrimary("ada@example.com", true, "ada@example.com", false));
    }

    // Only the chosen address has to exist: a person with a proven personal address and no
    // school address at all must still be able to point Keycloak email at it.
    @Test
    void theOtherAddressDoesNotHaveToExist() {
        assertEquals(EmailResource.PrimaryChoice.APPLY,
                EmailResource.choosePrimary("ada@example.com", true, null, false));
        assertEquals(EmailResource.PrimaryChoice.MISSING,
                EmailResource.choosePrimary(null, true, "ada@example.com", true));
    }
}
