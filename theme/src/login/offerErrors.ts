// The error codes of the SPI's sky-personal-email-offer page (PersonalEmailOffer.Problem in
// spi/): each becomes one sentence; anything else is shown as no error at all.
export const personalEmailOfferErrors = [
  "invalid_address",
  "own_address",
  "email_school_domain",
  "email_taken",
  "rate_limited",
  "email_not_sent",
  "malformed_code",
  "wrong_code",
  "code_expired",
  "too_many_tries"
] as const;

export type PersonalEmailOfferError = (typeof personalEmailOfferErrors)[number];

export function toPersonalEmailOfferError(value: string | undefined): PersonalEmailOfferError | undefined {
  return (personalEmailOfferErrors as readonly string[]).includes(value ?? "")
    ? (value as PersonalEmailOfferError)
    : undefined;
}
