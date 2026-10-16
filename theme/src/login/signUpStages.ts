// The SPI's sky-email-code-sign-up page (Self-registration, eskylab-login-ux 09; EmailCodeSignUp in
// spi/): its stages and the form's error codes. A stage the page does not know is the form; an
// error it does not know is shown as no error at all.
export const emailCodeSignUpStages = ["form", "ytu", "existing", "unavailable"] as const;

export type EmailCodeSignUpStage = (typeof emailCodeSignUpStages)[number];

export function toEmailCodeSignUpStage(value: string | undefined): EmailCodeSignUpStage {
  return (emailCodeSignUpStages as readonly string[]).includes(value ?? "") ? (value as EmailCodeSignUpStage) : "form";
}

export const emailCodeSignUpErrors = [
  "first_name_missing",
  "first_name_invalid",
  "last_name_missing",
  "last_name_invalid",
  "try_again"
] as const;

export type EmailCodeSignUpError = (typeof emailCodeSignUpErrors)[number];

export function toEmailCodeSignUpError(value: string | undefined): EmailCodeSignUpError | undefined {
  return (emailCodeSignUpErrors as readonly string[]).includes(value ?? "") ? (value as EmailCodeSignUpError) : undefined;
}
