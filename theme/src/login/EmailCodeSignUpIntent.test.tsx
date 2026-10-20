import { cleanup, fireEvent, render, waitFor } from "@testing-library/react";
import { afterEach, beforeAll, describe, expect, it } from "vitest";
import { getDevKcContextForPage, getEmailCodePreview } from "../devKcContext";
import type { KcContext } from "./KcContext";
import { looksLikeEmailAddress } from "./EmailCode";
import KcPage from "./KcPage";

type EmailCodeContext = Extract<KcContext, { pageId: "sky-email-code.ftl" }>;

async function renderIntent(attributes: Record<string, unknown>, language: "tr" | "en" = "tr") {
  const kcContext = {
    ...getDevKcContextForPage("sky-email-code.ftl", language),
    ...attributes
  } as EmailCodeContext;
  const view = render(<KcPage kcContext={kcContext} />);
  await waitFor(() => expect(view.container.querySelector(".sl-legacy-shell")).toHaveAttribute("data-sl-translations", "ready"));
  return view;
}

const offered = {
  auth: {
    authenticationSelections: [
      { authExecId: "exec-password", displayName: "sky-username-password-form-display-name", helpText: "", iconCssClass: "" }
    ]
  }
};

describe("the sign-up intent on the shared e-mail code page", () => {
  beforeAll(() => window.history.replaceState(null, "", "/?viewMode=docs"));
  afterEach(cleanup);

  it.each(["true", true])("uses the registration heading only for explicit flag %s and sign-up intent", async flag => {
    const view = await renderIntent({ skyEmailCodeSignUp: flag, skyEmailCodeIntent: "sign-up" });

    expect(view.container.querySelector("h1")).toHaveTextContent("Hesap aç");
    // No explanatory sentence under the heading: the field and "Kod gönder" say it.
    expect(view.container.querySelector(".sl-legacy-intro p")).toBeNull();
    expect(view.container.querySelector("#kc-email-code-identifier-form")).toBeInTheDocument();
    expect(document.title).toBe("Hesap aç · SKY LAB");
  });

  it.each([undefined, false, "false", "on", "TRUE"])("ignores a forged sign-up intent when registration flag is %s", async flag => {
    const view = await renderIntent({ skyEmailCodeSignUp: flag, skyEmailCodeIntent: "sign-up" });

    expect(view.container.querySelector("h1")).toHaveTextContent("E-postayla devam et");
    expect(view.container.querySelector(".sl-legacy-intro p")).toBeNull();
  });

  it.each([undefined, "login", "unexpected"])("keeps ordinary sign-in copy without the explicit registration intent %s", async intent => {
    const view = await renderIntent({ skyEmailCodeSignUp: "true", skyEmailCodeIntent: intent });

    expect(view.container.querySelector("h1")).toHaveTextContent("E-postayla devam et");
    expect(view.container.querySelector(".sl-legacy-intro p")).toBeNull();
  });

  it.each(["sent", "wrong"])("keeps the generic code and error message before address proof (%s)", async state => {
    const view = await renderIntent({
      ...getEmailCodePreview(state),
      skyEmailCodeSignUp: "true",
      skyEmailCodeIntent: "sign-up"
    });

    expect(view.container.querySelector("h1")).toHaveTextContent("Hesap aç");
    expect(view.container.querySelector("#sky-email-code-sent")?.textContent).toBe("Kod 10 dakika geçerli.");
    expect(view.container.querySelector('input[name="code"]')).toHaveAttribute("autocomplete", "one-time-code");
    expect(view.container.querySelector("#kc-email-code-form")).toHaveAttribute("method", "post");
    expect(view.container.querySelector("#kc-email-code-sign-up-form")).toBeNull();
    expect(view.container).not.toHaveTextContent("Bu adresle zaten hesabın vardı");
    if (state === "wrong") {
      expect(view.container.querySelector("#sky-email-code-error")).toHaveTextContent("Kod yanlış. 4 deneme hakkın kaldı.");
    }
  });

  it("translates the registration heading into English, without a description", async () => {
    const view = await renderIntent({ skyEmailCodeSignUp: "true", skyEmailCodeIntent: "sign-up" }, "en");

    expect(view.container.querySelector("h1")).toHaveTextContent("Create an account");
    expect(view.container.querySelector(".sl-legacy-intro p")).toBeNull();
    expect(view.container).not.toHaveTextContent("emailCodeSignUpTitle");
  });

  it("asks for an e-mail address only: no username, no password switch, no passkey", async () => {
    const view = await renderIntent({
      ...offered,
      skyEmailCodeSignUp: "true",
      skyEmailCodeIntent: "sign-up",
      enableWebAuthnConditionalUI: true
    });

    const field = view.container.querySelector("#username");
    expect(view.container.querySelector('label[for="username"]')).toHaveTextContent(/^E-posta adresin$/);
    expect(field).toHaveAttribute("type", "email");
    expect(field).toHaveAttribute("autocomplete", "email");
    // The SPI's parameter stays the same.
    expect(field).toHaveAttribute("name", "username");
    expect(view.container).not.toHaveTextContent("kullanıcı adın");
    expect(view.container.querySelector("#sky-email-code-password")).toBeNull();
    expect(view.container.querySelector("#authenticateWebAuthnButton")).toBeNull();
    expect(view.container.querySelector("#webauth")).toBeNull();
    // "Geri dön" stays.
    expect(view.container.querySelector("#sl-back-to-choice")).not.toBeNull();
  });

  it("does not send a username or a malformed address, and says so on the field", async () => {
    const view = await renderIntent({ skyEmailCodeSignUp: "true", skyEmailCodeIntent: "sign-up" });
    const form = view.container.querySelector("#kc-email-code-identifier-form") as HTMLFormElement;
    const field = view.container.querySelector("#username") as HTMLInputElement;

    for (const typed of ["ada.lovelace", "ada@example", "ada @example.com", ""]) {
      fireEvent.input(field, { target: { value: typed } });
      expect(fireEvent.submit(form), typed).toBe(false);
      expect(view.container.querySelector("#sky-email-code-error")).toHaveTextContent("Geçerli bir e-posta adresi yaz.");
      expect(field).toHaveAttribute("aria-invalid", "true");
    }

    fireEvent.input(field, { target: { value: "ada@example.com" } });
    // Typing clears the error; a well-formed address is sent to the SPI as before.
    expect(view.container.querySelector("#sky-email-code-error")).toBeNull();
    expect(fireEvent.submit(form)).toBe(true);
  });

  it("words the SPI's empty-identifier error for an address", async () => {
    const view = await renderIntent({
      skyEmailCodeSignUp: "true",
      skyEmailCodeIntent: "sign-up",
      skyEmailCodeError: "invalid_identifier"
    });
    expect(view.container.querySelector("#sky-email-code-error")).toHaveTextContent("Geçerli bir e-posta adresi yaz.");
  });

  it("keeps the e-mail or username field, the password switch and the passkey on ordinary sign-in", async () => {
    const view = await renderIntent({ ...offered, skyEmailCodeSignUp: "true", enableWebAuthnConditionalUI: true });
    const field = view.container.querySelector("#username");
    expect(view.container.querySelector('label[for="username"]')).toHaveTextContent("E-posta adresin ya da kullanıcı adın");
    expect(field).toHaveAttribute("type", "text");
    expect(field).toHaveAttribute("autocomplete", "username webauthn");
    expect(view.container.querySelector("#sky-email-code-password")).not.toBeNull();
    expect(view.container.querySelector("#authenticateWebAuthnButton")).not.toBeNull();

    const form = view.container.querySelector("#kc-email-code-identifier-form") as HTMLFormElement;
    fireEvent.input(field as HTMLInputElement, { target: { value: "ada.lovelace" } });
    expect(fireEvent.submit(form)).toBe(true);
  });

  it("labels the address in English", async () => {
    const view = await renderIntent({ skyEmailCodeSignUp: "true", skyEmailCodeIntent: "sign-up" }, "en");
    expect(view.container.querySelector('label[for="username"]')).toHaveTextContent(/^Your email address$/);
  });

  it.each([
    ["ada@example.com", true],
    [" ada@sub.example.com.tr ", true],
    ["ada.lovelace", false],
    ["ada@example", false],
    ["@example.com", false],
    ["ada@@example.com", false]
  ])("checks the shape of %s", (value, expected) => {
    expect(looksLikeEmailAddress(value)).toBe(expected);
  });
});
