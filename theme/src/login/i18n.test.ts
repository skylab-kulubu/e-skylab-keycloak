import { describe, expect, it } from "vitest";
import { translations } from "./i18n";

describe("theme copy", () => {
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
});
