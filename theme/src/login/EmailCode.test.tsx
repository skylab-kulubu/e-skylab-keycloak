import { act, cleanup, fireEvent, render, waitFor } from "@testing-library/react";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import { getDevKcContextForPage, getEmailCodePreview } from "../devKcContext";
import type { KcContext } from "./KcContext";
import KcPage from "./KcPage";
import { emailCodeErrors, takePasswordChoice, toEmailCodeError } from "./emailCodeChoice";

type EmailCodeContext = Extract<KcContext, { pageId: "sky-email-code.ftl" }>;

const passwordSelection = { authExecId: "exec-password", displayName: "sky-username-password-form-display-name" };

async function renderEmailCode(attributes: Record<string, unknown>, languageTag: "tr" | "en" = "tr") {
  const kcContext = {
    ...getDevKcContextForPage("sky-email-code.ftl", languageTag),
    ...attributes
  } as EmailCodeContext;
  const view = render(<KcPage kcContext={kcContext} />);
  await waitFor(() => {
    expect(view.container.querySelector(".sl-legacy-shell")).toHaveAttribute("data-sl-translations", "ready");
    expect(view.container.querySelector("form.sl-email-code")).not.toBeNull();
  });
  return { ...view, kcContext };
}

describe("E-postayla devam et (sky-email-code.ftl)", () => {
  beforeAll(() => {
    window.history.replaceState(null, "", "/?viewMode=docs");
  });

  afterEach(() => {
    cleanup();
    vi.useRealTimers();
    vi.restoreAllMocks();
    window.sessionStorage.clear();
  });

  it("asks for the address or username and posts it with Kod gönder", async () => {
    const { container, kcContext } = await renderEmailCode(getEmailCodePreview("identifier"));

    expect(container.querySelector("h1")).toHaveTextContent("E-postayla devam et");
    const form = container.querySelector("form#kc-email-code-identifier-form");
    expect(form).toHaveAttribute("method", "post");
    expect(form).toHaveAttribute("action", kcContext.url.loginAction);
    const field = container.querySelector("input#username");
    expect(field).toHaveAttribute("name", "username");
    expect(field).toHaveAttribute("autocomplete", "username");
    expect(container.querySelector('label[for="username"]')).toHaveTextContent("E-posta adresin ya da kullanıcı adın");
    const send = container.querySelector('button[name="sky-email-code-action"][value="send"]');
    expect(send).toHaveTextContent("Kod gönder");
    expect(send).toHaveAttribute("type", "submit");
    expect(container.querySelector("input#sky-email-code")).toBeNull();
    expect(container.querySelector("#sky-email-code-error")).toBeNull();
    expect(document.title).toBe("E-postayla devam et · SKY LAB");
  });

  it("shows the code stage with a one-time-code field and keeps the resend closed for its minute", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    const { container } = await renderEmailCode(getEmailCodePreview("sent"));

    expect(container.querySelector("#sky-email-code-sent")).toHaveTextContent(
      "Kodu gönderdik. Bu adresle bir hesabın varsa kod, hesabının birincil e-posta adresine gider."
    );
    expect(container.querySelector("#sky-email-code-sent")).toHaveTextContent("Kod 10 dakika geçerli.");
    expect(container.querySelector("#sky-email-code-identifier")).toHaveTextContent("Yazdığın: ada.lovelace@example.org");
    const code = container.querySelector("input#sky-email-code");
    expect(code).toHaveAttribute("name", "code");
    expect(code).toHaveAttribute("autocomplete", "one-time-code");
    expect(code).toHaveAttribute("inputmode", "numeric");
    // Six digits (Yusuf 2026-10-16), with the spaces people keep when they copy them; the SPI
    // takes 20 characters at most (LoginCodes.MAX_CODE_INPUT_LENGTH).
    expect(code).toHaveAttribute("maxlength", "20");
    expect(container.querySelector('label[for="sky-email-code"]')).toHaveTextContent("6 haneli kod");
    expect(container.textContent).not.toMatch(/8 haneli/);
    expect(container.querySelector('button[value="verify"]')).toHaveTextContent("Giriş yap");
    expect(container.querySelector('button[value="change"]')).toHaveTextContent("Başka bir adres yaz");
    expect(container.querySelector('button[value="change"]')).toHaveAttribute("formnovalidate");

    const resend = container.querySelector('button[value="resend"]');
    expect(resend).toBeDisabled();
    expect(resend).toHaveTextContent("Kodu 60 saniye sonra yeniden gönderebilirsin");
    for (let second = 0; second < 60; second++) {
      await act(async () => {
        await vi.advanceTimersByTimeAsync(1000);
      });
    }
    expect(resend).toBeEnabled();
    expect(resend).toHaveTextContent("Kodu yeniden gönder");
  });

  it("words a wrong code with the tries left, on the field", async () => {
    const { container } = await renderEmailCode(getEmailCodePreview("wrong"));

    const error = container.querySelector("#sky-email-code-error");
    expect(error).toHaveTextContent("Kod yanlış. 4 deneme hakkın kaldı.");
    expect(error).toHaveAttribute("data-sky-email-code-error", "wrong_code");
    expect(container.querySelector("input#sky-email-code")).toHaveAttribute("aria-describedby", "sky-email-code-error");
    expect(container.querySelector('button[value="resend"]')).toBeEnabled();
  });

  it("words every error code and shows none for a code it does not know", async () => {
    for (const error of emailCodeErrors) {
      const view = await renderEmailCode({ skyEmailCodeStage: "identifier", skyEmailCodeError: error, skyEmailCodeAttemptsLeft: "2" });
      const sentence = view.container.querySelector("#sky-email-code-error")?.textContent ?? "";
      expect(sentence.length, error).toBeGreaterThan(10);
      expect(sentence, error).not.toContain("emailCodeError");
      view.unmount();
    }
    expect(toEmailCodeError("<b>x</b>")).toBeUndefined();
    // The page never says that an address has no account (the SPI shows a dead code's sentence).
    expect(toEmailCodeError("no_account")).toBeUndefined();
    const { container } = await renderEmailCode({ skyEmailCodeStage: "identifier", skyEmailCodeError: "<b>x</b>" });
    expect(container.querySelector("#sky-email-code-error")).toBeNull();
  });

  it("sends a person with TOTP to the password or a passkey when the flow would skip the TOTP", async () => {
    const { container } = await renderEmailCode({ skyEmailCodeStage: "identifier", skyEmailCodeError: "unavailable" });

    expect(container.querySelector("#sky-email-code-error")).toHaveTextContent(
      "E-postayla giriş şu an kullanılamıyor. Parolanla ya da erişim anahtarınla gir."
    );
  });

  it("keeps what was typed after an error", async () => {
    const { container } = await renderEmailCode({
      skyEmailCodeStage: "identifier",
      skyEmailCodeIdentifier: "ada.lovelace@example.org",
      skyEmailCodeError: "rate_limited"
    });
    expect(container.querySelector("input#username")).toHaveValue("ada.lovelace@example.org");
    expect(container.querySelector("#sky-email-code-error")).toHaveTextContent("Çok fazla kod istendi.");
  });

  it("switches to the password form with Parolanla gir and remembers what was typed", async () => {
    const submitted: HTMLFormElement[] = [];
    vi.spyOn(HTMLFormElement.prototype, "submit").mockImplementation(function (this: HTMLFormElement) {
      submitted.push(this);
    });
    const { container, kcContext } = await renderEmailCode({
      ...getEmailCodePreview("identifier"),
      auth: { authenticationSelections: [passwordSelection] }
    });

    fireEvent.change(container.querySelector("input#username") as HTMLInputElement, { target: { value: " ada " } });
    fireEvent.click(container.querySelector("button#sky-email-code-password") as HTMLButtonElement);

    expect(submitted).toHaveLength(1);
    expect(submitted[0]).toHaveAttribute("method", "post");
    expect(submitted[0].action).toBe(new URL(kcContext.url.loginAction, window.location.href).href);
    expect(new FormData(submitted[0]).get("authenticationExecution")).toBe("exec-password");
    expect(takePasswordChoice()).toEqual({ identifier: "ada" });
    expect(takePasswordChoice(), "the choice is read once").toBeUndefined();
  });

  it("offers no password switch when Keycloak lists none", async () => {
    const { container } = await renderEmailCode(getEmailCodePreview("identifier"));
    expect(container.querySelector("button#sky-email-code-password")).toBeNull();
  });

  it("offers Keycloak's passkey on the first stage when the SPI put the challenge there", async () => {
    const { container } = await renderEmailCode({
      ...getEmailCodePreview("identifier"),
      enableWebAuthnConditionalUI: true,
      challenge: "challenge",
      rpId: "localhost",
      userVerification: "required",
      isUserIdentified: "false",
      createTimeout: "0"
    });

    expect(container.querySelector("input#username")).toHaveAttribute("autocomplete", "username webauthn");
    expect(container.querySelector("button#authenticateWebAuthnButton")).toHaveTextContent("Erişim anahtarı ile giriş yap");
    const webauth = container.querySelector("form#webauth");
    expect(webauth).not.toBeNull();
    expect(webauth?.querySelector('input[name="authenticatorData"]')).not.toBeNull();
  });

  it("speaks English from i18n.ts", async () => {
    const { container } = await renderEmailCode(getEmailCodePreview("wrong"), "en");
    expect(container.querySelector("h1")).toHaveTextContent("Continue with email");
    expect(container.querySelector("#sky-email-code-error")).toHaveTextContent("Wrong code. 4 tries left.");
    expect(container.querySelector('button[value="verify"]')).toHaveTextContent("Sign in");
  });
});
