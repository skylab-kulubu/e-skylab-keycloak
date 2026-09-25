package com.skylab.account;

import org.junit.jupiter.api.Test;

import java.time.Instant;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;

class PersonalEmailProofTest {

    @Test
    void theProofIsTheLowercasedAddressAndTheMomentInWholeUtcSeconds() {
        Map<String, String> attributes = PersonalEmailProof.attributes("  Ada.Lovelace@Example.COM ", 1_790_000_000L);

        assertEquals(List.of("personalEmail", "personalEmailVerifiedAt"), List.copyOf(attributes.keySet()),
                "the address first, then the moment, the order email/confirm writes them");
        assertEquals("ada.lovelace@example.com", attributes.get("personalEmail"));
        assertEquals("2026-09-21T14:13:20Z", attributes.get("personalEmailVerifiedAt"));
    }

    @Test
    void aMomentOnTheMinuteStillCarriesItsSeconds() {
        // Instant#toString drops nothing for whole seconds; the User Profile pattern needs ":SS".
        assertEquals("2026-09-25T00:00:00Z", PersonalEmailProof.verifiedAt(Instant.parse("2026-09-25T00:00:00Z").getEpochSecond()));
    }

    @Test
    void theAttributeNamesAreTheOnesIdentityReads() {
        assertEquals(IdentityResource.PERSONAL_EMAIL_ATTRIBUTE, PersonalEmailProof.ADDRESS_ATTRIBUTE);
        assertEquals(IdentityResource.PERSONAL_EMAIL_VERIFIED_AT_ATTRIBUTE, PersonalEmailProof.VERIFIED_AT_ATTRIBUTE);
    }

    @Test
    void theTurkishDotlessIDoesNotSneakIntoAnAddress() {
        assertEquals("iris@example.com", PersonalEmailProof.normalise("IRIS@example.com"));
    }
}
