// @vitest-environment node
import { describe, expect, it } from "vitest";
import { findI18nFile, LOGIN_SRC_DIR, readCustomTranslations } from "../../scripts/custom-translations.mjs";
import { previewStates } from "../devKcContext";

const i18nFile = findI18nFile(LOGIN_SRC_DIR);
// What `keycloakify build` writes into messages_tr/en.properties; it throws when the build
// could not read the translations (tests/check-theme-contract.sh checks the built JAR).
const translations = readCustomTranslations(i18nFile) as { tr: Record<string, string>; en: Record<string, string> };

// Messages Keycloak resolves on the server (page-wide notices, field errors, info pages, the
// password policy sentences Account Center shows): only the theme's message bundle reaches them.
const serverMessageKeys = [
  "emailSentMessage",
  "emailSendErrorMessage",
  "emailVerifySendCooldown",
  "emailVerifiedMessage",
  "emailVerifiedMessageHeader",
  "emailVerifiedAlreadyMessage",
  "emailVerifiedAlreadyMessageHeader",
  "staleEmailVerificationLink",
  "confirmEmailAddressVerification",
  "confirmEmailAddressVerificationHeader",
  "invalidUserMessage",
  "invalidUsernameMessage",
  "invalidUsernameOrEmailMessage",
  "invalidPasswordMessage",
  "missingUsernameMessage",
  "missingPasswordMessage",
  "accountDisabledMessage",
  "accountTemporarilyDisabledMessage",
  "accountPermanentlyDisabledMessage",
  "resetCredentialNotAllowedMessage",
  "invalidTotpMessage",
  "missingTotpMessage",
  "missingTotpDeviceNameMessage",
  "notMatchPasswordMessage",
  "invalidPasswordConfirmMessage",
  "invalidPasswordExistingMessage",
  "accountPasswordUpdatedMessage",
  "invalidPasswordMinLengthMessage",
  "invalidPasswordMaxLengthMessage",
  "invalidPasswordMinDigitsMessage",
  "invalidPasswordMinLowerCaseCharsMessage",
  "invalidPasswordMinUpperCaseCharsMessage",
  "invalidPasswordMinSpecialCharsMessage",
  "invalidPasswordNotUsernameMessage",
  "invalidPasswordNotContainsUsernameMessage",
  "invalidPasswordNotEmailMessage",
  "invalidPasswordRegexPatternMessage",
  "invalidPasswordHistoryMessage",
  "invalidPasswordBlacklistedMessage",
  "invalidPasswordGenericMessage",
  "updatePasswordMessage",
  "verifyEmailMessage",
  "updateEmailMessage",
  "configureTotpMessage",
  "updateProfileMessage",
  "confirmExecutionOfActions",
  "requiredAction.UPDATE_PASSWORD",
  "requiredAction.VERIFY_EMAIL",
  "requiredAction.CONFIGURE_TOTP",
  "requiredAction.UPDATE_PROFILE",
  "requiredAction.UPDATE_EMAIL",
  "requiredAction.TERMS_AND_CONDITIONS",
  "expiredCodeMessage",
  "expiredActionMessage",
  "expiredActionTokenNoSessionMessage",
  "expiredActionTokenSessionExistsMessage",
  "loginTimeout",
  "staleCodeMessage",
  "invalidCodeMessage",
  "cookieNotFoundMessage",
  "alreadyLoggedIn",
  "sessionNotActiveMessage",
  "successLogout",
  "failedLogout",
  "identityProviderUnexpectedErrorMessage",
  "identityProviderAuthenticationFailedMessage",
  "identityProviderAlreadyLinkedMessage"
];

describe("theme copy", () => {
  it("is read by the theme build from i18n.ts as one static object", () => {
    expect(i18nFile.replace(/\\/g, "/")).toMatch(/\/src\/login\/i18n\.ts$/);
    expect(Object.keys(translations.tr).length).toBeGreaterThan(100);
  });

  it("is written in Turkish first and English second", () => {
    expect(Object.keys(translations)).toEqual(["tr", "en"]);
  });

  it("defines every key in both languages so no page falls back to Keycloak's English", () => {
    const turkishKeys = Object.keys(translations.tr);
    const englishKeys = Object.keys(translations.en);
    expect(turkishKeys.filter(key => !englishKeys.includes(key))).toEqual([]);
    expect(englishKeys.filter(key => !turkishKeys.includes(key))).toEqual([]);
  });

  it("covers the Turkish keys that Keycloakify's default set lacks", () => {
    for (const key of [
      "logoutOtherSessions",
      "doTryAnotherWay",
      "requiredFields",
      "loginChooseAuthenticator",
      "webauthn-login-title",
      "deleteCredentialTitle",
      "logoutConfirmTitle",
      "updateEmailTitle",
      "loginTotpDeviceName",
      "otp-display-name",
      "webauthn-passwordless-help-text",
      "showPassword",
      "hidePassword",
      "skylabLoading"
    ]) {
      expect(translations.tr, key).toHaveProperty(key);
    }
  });

  it("calls a passkey an erişim anahtarı everywhere in Turkish", () => {
    const turkish = Object.entries(translations.tr).filter(([key]) => !key.startsWith("skylabPageDesc.") || true);
    for (const [key, value] of turkish) {
      // "(passkey)" is allowed only as the parenthesised first mention.
      const stripped = value.replace(/\(passkey\)/g, "");
      expect(stripped.toLowerCase(), key).not.toContain("passkey");
    }
    expect(translations.tr.passkeyChoice).toBe("Erişim anahtarı ile giriş yap");
    expect(translations.tr["passkey-doAuthenticate"]).toBe(translations.tr.passkeyChoice);
  });

  it("rewords the server-side messages in both languages, with parola for a password", () => {
    for (const key of serverMessageKeys) {
      expect(translations.tr, key).toHaveProperty(key);
      expect(translations.en, key).toHaveProperty(key);
      expect(translations.tr[key].toLocaleLowerCase("tr"), key).not.toMatch(/şifre|lütfen|(ınız|iniz|unuz|ünüz)\b/);
    }
  });

  it("keeps Keycloak's placeholders in the server-side messages", () => {
    const placeholders = (text: string) => (text.match(/\{\d\}/g) ?? []).sort().join();
    expect(translations.tr.emailVerifySendCooldown).toContain("{0}");
    for (const key of serverMessageKeys) {
      expect(placeholders(translations.tr[key]), key).toBe(placeholders(translations.en[key]));
    }
  });

  it("does not tell whether a reset request matched an account", () => {
    // Keycloak shows emailSentMessage whatever was typed (SkyResetCredentialChooseUser).
    expect(translations.tr.emailSentMessage).toMatch(/^Bu bilgiler bir hesaba aitse/);
    expect(translations.en.emailSentMessage).toMatch(/^If these details belong to an account/);
    // A locked or disabled account must not be told apart from a wrong password.
    expect(translations.tr.accountPermanentlyDisabledMessage).toBe(translations.tr.invalidUserMessage);
    expect(translations.en.accountPermanentlyDisabledMessage).toBe(translations.en.invalidUserMessage);
  });

  it("previews the server-side states with the bundle's own wording", () => {
    const login = previewStates["login.ftl"];
    for (const lang of ["tr", "en"] as const) {
      expect(login["reset-email-sent"].message.summary[lang]).toBe(translations[lang].emailSentMessage);
      expect(login["invalid-credentials"].message.summary[lang]).toBe(translations[lang].invalidUserMessage);
      expect(login["idp-error"].message.summary[lang]).toBe(translations[lang].identityProviderUnexpectedErrorMessage);
      expect(previewStates["login-reset-password.ftl"]["missing-username"].message.summary[lang]).toBe(
        translations[lang].missingUsernameMessage
      );
    }
  });
});
