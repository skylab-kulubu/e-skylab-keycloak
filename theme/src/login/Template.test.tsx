import { cleanup, fireEvent, render, waitFor } from "@testing-library/react";
import { afterEach, beforeAll, describe, expect, it } from "vitest";
import { getDevKcContextForPage } from "../devKcContext";
import KcPage from "./KcPage";
import { themedPageIds, type ThemedPageId } from "./pageIds";

const mainIdByPage: Partial<Record<ThemedPageId, string>> = {
  "login.ftl": "sl-legacy-main",
  "passkey-offer.ftl": "sl-passkey-offer-main",
  "sky-personal-email-offer.ftl": "sl-personal-email-offer-main",
  "sky-email-code.ftl": "sl-email-code-main",
  "sky-existing-account.ftl": "sl-existing-account-main",
  "sky-after-sign-up-school.ftl": "sl-after-sign-up-school-main",
  "sky-after-sign-up-credentials.ftl": "sl-after-sign-up-credentials-main",
  "sky-stay-signed-in.ftl": "sl-stay-signed-in-main",
  "sky-email-code-sign-up.ftl": "sl-email-code-sign-up-main",
  "sky-handoff-failed.ftl": "sl-handoff-failed-main"
};

// The Web handoff failure page offers nothing to do, not even a language switch (HandoffFailed.test.tsx).
// Pages with the login flow's KVKK sentence (legacyChrome kvkk "login"); every other page says "Bu işlemi yaparak …".
const pagesWithLoginKvkkSentence: ThemedPageId[] = [
  "login.ftl",
  "passkey-offer.ftl",
  "sky-personal-email-offer.ftl",
  "sky-email-code-sign-up.ftl",
  "sky-stay-signed-in.ftl",
  "sky-email-code.ftl",
  "sky-existing-account.ftl",
  "sky-after-sign-up-school.ftl",
  "sky-after-sign-up-credentials.ftl"
];
const pagesWithoutLanguageMenu: ThemedPageId[] = ["sky-handoff-failed.ftl"];

async function renderPage(pageId: ThemedPageId, languageTag: "tr" | "en" = "tr") {
  const kcContext = getDevKcContextForPage(pageId, languageTag);
  const view = render(<KcPage kcContext={kcContext} />);

  // DefaultPage bodies and the Turkish base messages both load lazily.
  await waitFor(() => {
    expect(view.container.querySelector(".sl-legacy-shell")).toHaveAttribute("data-sl-translations", "ready");
    expect(view.container.querySelectorAll("h1")).toHaveLength(1);
  });

  return view;
}

describe("every Keycloak page renders inside the login page chrome", () => {
  beforeAll(() => {
    // Keycloakify reloads the page when its Template mounts twice in one window
    // (a server-rendered page never does); the Storybook escape hatch keeps jsdom quiet.
    window.history.replaceState(null, "", "/?viewMode=docs");
  });

  afterEach(() => {
    cleanup();
    document.body.className = "";
    document.documentElement.className = "";
  });

  it.each(themedPageIds)("%s uses the animated logo, glass card and KVKK footer", async pageId => {
    const { container } = await renderPage(pageId);

    const animation = container.querySelector('[data-skylab-logo-animation="draw"]');
    expect(animation).not.toBeNull();
    expect(animation?.querySelectorAll("path")).toHaveLength(19);
    expect(container.querySelector(".sl-legacy-logo img")).toBeNull();
    expect(container.querySelector(".sl-site-header, .sl-brand, .sl-brand__mark, .sl-atmosphere")).toBeNull();

    expect(container.querySelector("main")).toHaveAttribute("id", mainIdByPage[pageId] ?? "sl-main-content");
    expect(container.querySelector("main")).toHaveAttribute("tabindex", "-1");
    expect(container.querySelector(".sl-legacy-card")).toHaveAttribute(
      "aria-labelledby",
      container.querySelector("h1")?.id
    );

    const footer = container.querySelector("footer.sl-legacy-footer");
    expect(footer).toHaveAttribute("role", "contentinfo");
    expect(footer?.querySelector('a[href="https://yildizskylab.com/kvkk-metni.pdf"]')).toHaveTextContent(
      pagesWithLoginKvkkSentence.includes(pageId) ? "KVKK Aydınlatma Metni" : "KVKK Metni"
    );
    expect(footer).toHaveTextContent("e-skylab by WEBLAB");
    // Linked to LinkedIn, except on the Web handoff failure page, which offers as little to click as possible.
    const creditSelector =
      pageId === "sky-handoff-failed.ftl"
        ? "span.sl-legacy-credit"
        : 'a.sl-legacy-credit[href="https://www.linkedin.com/in/yusuf-acmaci/"]';
    expect(footer?.querySelector(creditSelector)).toHaveTextContent("Developed by Yusuf Açmacı");
    if (pagesWithoutLanguageMenu.includes(pageId)) {
      expect(footer?.querySelector("nav.sl-legacy-languages")).toBeNull();
    } else {
      expect(footer?.querySelectorAll("nav.sl-legacy-languages a")).toHaveLength(2);
      // Türkçe on the left although Keycloak (and the preview context) lists English first.
      expect(Array.from(footer?.querySelectorAll("nav.sl-legacy-languages a") ?? [], link => link.getAttribute("lang"))).toEqual([
        "tr",
        "en"
      ]);
      expect(footer?.querySelector('nav.sl-legacy-languages a[aria-current="page"]')).toHaveAttribute("lang", "tr");
    }

    expect(document.documentElement).toHaveClass("sl-html");
    expect(document.body).toHaveClass("sl-body");
    expect(document.documentElement.lang).toBe("tr");
  });

  it("keeps the Keycloak element ids the flows and specs depend on", async () => {
    const expectations: Array<[ThemedPageId, string[]]> = [
      ["login.ftl", ["#authenticateWebAuthnButton", "form#webauth"]],
      ["login-username.ftl", ["#kc-form-login", "#username", "#rememberMe", "#authenticateWebAuthnButton", "form#webauth"]],
      ["login-password.ftl", ["#kc-form-login", "#password", "#kc-attempted-username", "#reset-login", "#try-another-way"]],
      ["login-update-password.ftl", ["#kc-passwd-update-form", "#password-new", "#password-confirm", 'button[name="cancel-aia"]']],
      ["login-config-totp.ftl", ["#kc-totp-settings-form", "#totp", "#userLabel", "#saveTOTPBtn", "#cancelTOTPBtn", "#mode-manual"]],
      ["login-otp.ftl", ["#kc-otp-login-form", "#otp", "#kc-otp-credential-0", "#kc-login"]],
      ["webauthn-register.ftl", ["form#register", "#authenticateWebAuthnButton", "#authenticatorAttachment", "#cancelWebAuthnAIA"]],
      ["webauthn-authenticate.ftl", ["form#webauth", "form#authn_select", "#authenticateWebAuthnButton", "#kc-webauthn-authenticator-item-0"]],
      ["webauthn-error.ftl", ["#kc-error-credential-form", "#executionValue", "#isSetRetry", "#kc-try-again", "#cancelWebAuthnAIA"]],
      ["login-passkeys-conditional-authenticate.ftl", ["form#webauth", "form#authn_select", "#authenticateWebAuthnButton", "#kc-form-login"]],
      ["select-authenticator.ftl", ["#kc-select-credential-form", 'button[name="authenticationExecution"]']],
      ["login-reset-password.ftl", ["#kc-reset-password-form", "#username"]],
      ["login-update-profile.ftl", ["#kc-update-profile-form", "#firstName", "#lastName", 'button[name="cancel-aia"]']],
      ["update-email.ftl", ["#kc-update-email-form", "#email", "#logout-sessions"]],
      ["login-page-expired.ftl", ["#loginRestartLink", "#loginContinueLink"]],
      ["error.ftl", ["#kc-error-message", "#backToApplication"]],
      ["info.ftl", ["#kc-info-message"]],
      ["logout-confirm.ftl", ["#kc-logout-confirm", "#kc-logout", 'input[name="session_code"]']],
      ["delete-credential.ftl", ["#kc-accept", "#kc-decline"]],
      ["terms.ftl", ["#kc-terms-text", "#kc-accept", "#kc-decline"]],
      ["idp-review-user-profile.ftl", ["#kc-idp-review-profile-form", "#firstName"]],
      ["login-idp-link-confirm.ftl", ["#kc-register-form", "#updateProfile", "#linkAccount"]],
      ["login-idp-link-email.ftl", ["#instruction1", "#instruction2", "#instruction3"]],
      ["passkey-offer.ftl", ["#kc-passkey-offer-form", 'button[name="passkey-choice"][value="yes"]', 'button[name="passkey-choice"][value="no"]']],
      [
        "sky-personal-email-offer.ftl",
        [
          "#kc-personal-email-offer-form",
          'input#sky-offer-address[name="address"]',
          'button[name="sky-offer-action"][value="send"]',
          'button[name="sky-offer-action"][value="skip"]'
        ]
      ],
      [
        "sky-email-code.ftl",
        [
          "#kc-email-code-identifier-form",
          'input#username[name="username"]',
          'button[name="sky-email-code-action"][value="send"]'
        ]
      ],
      [
        "sky-stay-signed-in.ftl",
        [
          "#kc-stay-signed-in-form",
          'button[name="sky-stay-signed-in"][value="yes"]',
          'button[name="sky-stay-signed-in"][value="no"]'
        ]
      ]
    ];

    for (const [pageId, selectors] of expectations) {
      const { container, unmount } = await renderPage(pageId);
      for (const selector of selectors) {
        expect(container.querySelector(selector), `${pageId} lost ${selector}`).not.toBeNull();
      }
      unmount();
    }

    // The login page reveals the password form (and the remember-me bridge source) on demand.
    const login = await renderPage("login.ftl");
    fireEvent.click(login.getByRole("button", { name: "E-postayla devam et" }));
    for (const selector of ["#kc-form-login", "#username", "#password", "#rememberMe", "#kc-login"]) {
      expect(login.container.querySelector(selector), `login.ftl lost ${selector}`).not.toBeNull();
    }
    login.unmount();
  });

  it("speaks Turkish first and English second from i18n.ts, without hardcoded copy", async () => {
    const turkish = await renderPage("login-update-password.ftl");
    expect(turkish.container.querySelector("h1")).toHaveTextContent("Parolanı yenile");
    expect(turkish.container.querySelector(".sl-legacy-intro p")).toHaveTextContent("yeni bir parola belirle");
    expect(turkish.container.querySelector('label[for="logout-sessions"], #logout-sessions')?.closest("label")).toHaveTextContent(
      "Diğer cihazlardaki oturumları kapat"
    );
    turkish.unmount();

    const english = await renderPage("login-update-password.ftl", "en");
    expect(english.container.querySelector("h1")).toHaveTextContent("Update your password");
    expect(english.container.querySelector("footer.sl-legacy-footer")).toHaveTextContent("KVKK Policy");
    expect(document.documentElement.lang).toBe("en");
  });

  it("derives the document title from the page heading, the login page keeps its own", async () => {
    const logout = await renderPage("logout-confirm.ftl");
    expect(document.title).toBe("Oturumu kapat · SKY LAB");
    logout.unmount();

    const password = await renderPage("login-update-password.ftl");
    expect(document.title).toBe("Parolanı yenile · SKY LAB");
    password.unmount();

    const credential = await renderPage("delete-credential.ftl");
    expect(document.title).toBe("MacBook Touch ID silinsin mi? · SKY LAB");
    credential.unmount();

    const login = await renderPage("login.ftl");
    expect(document.title).toBe("SKY LAB hesabına giriş yap");
    login.unmount();

    const offer = await renderPage("passkey-offer.ftl");
    expect(document.title).toBe("Erişim anahtarı ekle · SKY LAB");
  });

  it("keeps the login KVKK sentence on login and passkey offer, neutral wording elsewhere", async () => {
    // "Okuyabilirsin", not "kabul ettiğinizi onaylıyorsunuz" (eskylab-login-ux spec §9).
    const login = await renderPage("login.ftl");
    expect(login.container.querySelector("footer.sl-legacy-footer p")).toHaveTextContent(
      "Kişisel verilerinin nasıl işlendiğini KVKK Aydınlatma Metni'nde okuyabilirsin."
    );
    login.unmount();

    const offer = await renderPage("passkey-offer.ftl");
    expect(offer.container.querySelector("footer.sl-legacy-footer p")).toHaveTextContent(
      "Kişisel verilerinin nasıl işlendiğini KVKK Aydınlatma Metni'nde okuyabilirsin."
    );
    offer.unmount();

    const totp = await renderPage("login-config-totp.ftl");
    expect(totp.container.querySelector("footer.sl-legacy-footer p")).toHaveTextContent(
      "Bu işlemi yaparak KVKK Metni'ni okuduğunu ve kabul ettiğini onaylıyorsun."
    );
  });

  it("shows Keycloak messages as login-style alerts and honours the app-initiated warning rule", async () => {
    const error = await renderPage("webauthn-error.ftl");
    const alert = error.container.querySelector(".sl-legacy-alert");
    expect(alert).toHaveClass("sl-legacy-alert--error");
    expect(alert).toHaveAttribute("role", "alert");
    expect(alert).toHaveTextContent("Erişim anahtarı kaydedilemedi");
    error.unmount();

    const kcContext = getDevKcContextForPage("login-update-password.ftl");
    kcContext.message = { type: "warning", summary: "Bu uyarı AIA akışında gizlenir." };
    kcContext.isAppInitiatedAction = true;
    const warning = render(<KcPage kcContext={kcContext} />);
    await waitFor(() => expect(warning.container.querySelector("#kc-passwd-update-form")).not.toBeNull());
    expect(warning.container.querySelector(".sl-legacy-alert")).toBeNull();
  });

  it("shows the brand panel's copy on the login page only; every other page keeps the logo", async () => {
    const login = await renderPage("login.ftl");
    expect(login.container.querySelector(".sl-legacy-card--brand .sl-legacy-brand__copy")).not.toBeNull();
    expect(login.container.querySelector("aside")).toBeNull();
    login.unmount();

    for (const pageId of ["login-otp.ftl", "error.ftl", "logout-confirm.ftl"] as const) {
      const view = await renderPage(pageId);
      expect(view.container.querySelector(".sl-legacy-card--brand"), pageId).toBeNull();
      expect(view.container.querySelector(".sl-legacy-brand__copy"), pageId).toBeNull();
      expect(view.container.querySelector('.sl-legacy-brand [data-skylab-logo-animation="draw"]'), pageId).not.toBeNull();
      view.unmount();
    }
  });

  it("shows the team strips on the login and e-mail code pages", async () => {
    for (const pageId of ["login.ftl", "sky-email-code.ftl"] as const) {
      const view = await renderPage(pageId);
      expect(view.container.querySelectorAll(".sl-legacy-teams")).toHaveLength(2);
      view.unmount();
    }

    for (const pageId of ["login-otp.ftl", "error.ftl", "logout-confirm.ftl", "passkey-offer.ftl", "sky-personal-email-offer.ftl", "sky-stay-signed-in.ftl", "sky-handoff-failed.ftl"] as const) {
      const view = await renderPage(pageId);
      expect(view.container.querySelector(".sl-legacy-teams"), pageId).toBeNull();
      view.unmount();
    }
  });
});
