// Every Keycloak login page that the SKY LAB theme styles on purpose.
// Kept free of imports so the dev preview, the unit tests and the Playwright
// visual regression spec can share one list.
export const themedPageIds = [
  "login.ftl",
  "login-username.ftl",
  "login-password.ftl",
  "login-update-password.ftl",
  "login-config-totp.ftl",
  "login-otp.ftl",
  "webauthn-register.ftl",
  "webauthn-authenticate.ftl",
  "webauthn-error.ftl",
  "login-passkeys-conditional-authenticate.ftl",
  "select-authenticator.ftl",
  "login-reset-password.ftl",
  "login-verify-email.ftl",
  "login-update-profile.ftl",
  "update-email.ftl",
  "login-page-expired.ftl",
  "error.ftl",
  "info.ftl",
  "logout-confirm.ftl",
  "delete-credential.ftl",
  "terms.ftl",
  "idp-review-user-profile.ftl",
  "login-idp-link-confirm.ftl",
  "login-idp-link-email.ftl",
  "passkey-offer.ftl"
] as const;

export type ThemedPageId = (typeof themedPageIds)[number];

export function isThemedPageId(value: string): value is ThemedPageId {
  return (themedPageIds as readonly string[]).includes(value);
}
