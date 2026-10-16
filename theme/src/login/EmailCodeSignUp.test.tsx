import { cleanup, render, waitFor } from "@testing-library/react";
import { afterEach, beforeAll, describe, expect, it } from "vitest";
import { getDevKcContextForPage, getEmailCodeSignUpPreview } from "../devKcContext";
import type { KcContext } from "./KcContext";
import KcPage from "./KcPage";
import { emailCodeSignUpErrors } from "./signUpStages";

type SignUpContext = Extract<KcContext, { pageId: "sky-email-code-sign-up.ftl" }>;

async function renderSignUp(attributes: Record<string, string | undefined> = {}, languageTag: "tr" | "en" = "tr") {
  const kcContext = {
    ...getDevKcContextForPage("sky-email-code-sign-up.ftl", languageTag),
    ...attributes
  } as SignUpContext;
  const view = render(<KcPage kcContext={kcContext} />);
  await waitFor(() => {
    expect(view.container.querySelector(".sl-legacy-shell")).toHaveAttribute("data-sl-translations", "ready");
    expect(view.container.querySelector("form[data-sky-sign-up-stage]")).not.toBeNull();
  });
  return view;
}

function actionsOf(container: HTMLElement, formId: string): (string | null)[] {
  return Array.from(container.querySelectorAll(`form#${formId} button[name="sky-email-code-action"]`)).map(button =>
    button.getAttribute("value")
  );
}

describe("Self-registration after the right sign-up code (sky-email-code-sign-up.ftl)", () => {
  beforeAll(() => {
    window.history.replaceState(null, "", "/?viewMode=docs");
  });

  afterEach(() => {
    cleanup();
  });

  it("asks for the first and last name with the proven address read-only and no password", async () => {
    const { container } = await renderSignUp();

    expect(container.querySelector("h1")).toHaveTextContent("Hesabını oluşturalım");
    expect(document.title).toBe("Hesabını oluşturalım · SKY LAB");
    const form = container.querySelector("form#kc-email-code-sign-up-form");
    expect(form).toHaveAttribute("method", "post");
    expect(form).toHaveAttribute("data-sky-sign-up-stage", "form");
    expect(form?.getAttribute("action")).toBeTruthy();
    const address = container.querySelector<HTMLInputElement>("#sky-sign-up-address");
    expect(address).toHaveValue("ayse.yilmaz@example.org");
    expect(address).toHaveAttribute("readonly");
    expect(address).not.toHaveAttribute("name");
    expect(container.querySelector("#sky-sign-up-first-name")).toHaveAttribute("name", "firstName");
    expect(container.querySelector("#sky-sign-up-first-name")).toHaveAttribute("autocomplete", "given-name");
    expect(container.querySelector("#sky-sign-up-last-name")).toHaveAttribute("name", "lastName");
    expect(container.querySelector("#sky-sign-up-last-name")).toHaveAttribute("autocomplete", "family-name");
    expect(container.querySelector('input[type="password"]')).toBeNull();
    expect(container.querySelector('input[type="checkbox"]')).toBeNull();
    expect(container.querySelector("#sky-sign-up-note")).toHaveTextContent("Parola gerekmez");
    expect(actionsOf(container, "kc-email-code-sign-up-form")).toEqual(["sign-up", "change"]);
    expect(container.querySelector('button[value="sign-up"]')).toHaveTextContent("Hesabı aç");
    expect(container.querySelector('button[value="sign-up"]')).toHaveClass("sl-legacy-submit");
    expect(container.querySelector('button[value="change"]')).toHaveAttribute("formnovalidate");
  });

  it("informs about KVKK in the footer without asking to accept anything", async () => {
    const { container } = await renderSignUp();

    const footer = container.querySelector(".sl-legacy-footer");
    expect(footer).toHaveTextContent("Kişisel verilerinin nasıl işlendiğini KVKK Aydınlatma Metni'nde okuyabilirsin.");
    expect(footer).not.toHaveTextContent("kabul");
  });

  it("words every error of the form next to the field it is about and keeps what was typed", async () => {
    for (const error of emailCodeSignUpErrors) {
      const { container } = await renderSignUp({ skySignUpError: error, skySignUpFirstName: "<Ayşe>", skySignUpLastName: "Yılmaz" });
      const alert = container.querySelector("#sky-sign-up-error");
      expect(alert, error).toHaveAttribute("role", "alert");
      expect(alert).toHaveAttribute("data-sky-sign-up-error", error);
      expect(alert?.textContent?.trim()).not.toBe("");
      expect(container.querySelector("#sky-sign-up-first-name")).toHaveValue("<Ayşe>");
      expect(container.querySelector("#sky-sign-up-first-name")).toHaveAttribute(
        "aria-invalid",
        String(error.startsWith("first_name"))
      );
      expect(container.querySelector("#sky-sign-up-last-name")).toHaveAttribute(
        "aria-invalid",
        String(error.startsWith("last_name"))
      );
      cleanup();
    }
    const { container } = await renderSignUp({ skySignUpError: "something_else" });
    expect(container.querySelector("#sky-sign-up-error")).toBeNull();
  });

  it("sends a school address to the YTÜ sign-in and opens no form", async () => {
    const { container } = await renderSignUp(getEmailCodeSignUpPreview("ytu"));

    expect(container.querySelector("h1")).toHaveTextContent("Okul adresinle YTÜ hesabınla devam et");
    expect(container.querySelector(".sl-legacy-intro p")).toHaveTextContent(
      "ayse.yilmaz@std.yildiz.edu.tr bir YTÜ adresi."
    );
    expect(container.querySelector("#sky-sign-up-ytu")).toHaveAttribute("href", "#microsoft");
    expect(container.querySelector("#sky-sign-up-ytu")).toHaveTextContent("YTÜ hesabınla devam et");
    expect(container.querySelector('input[name="firstName"]')).toBeNull();
    expect(actionsOf(container, "kc-email-code-sign-up-ytu-form")).toEqual(["change"]);
  });

  it("has no YTÜ link when the realm names another provider", async () => {
    const { container } = await renderSignUp({ ...getEmailCodeSignUpPreview("ytu"), skySignUpYtuAlias: "OTHER" });

    expect(container.querySelector("#sky-sign-up-ytu")).toBeNull();
    expect(actionsOf(container, "kc-email-code-sign-up-ytu-form")).toEqual(["change"]);
  });

  it("tells a person who used 'Hesap aç' with an account that they are signed in", async () => {
    const { container } = await renderSignUp(getEmailCodeSignUpPreview("existing"));

    expect(container.querySelector("h1")).toHaveTextContent("Zaten hesabın var");
    expect(container.querySelector(".sl-legacy-intro p")).toHaveTextContent("Bu adresle zaten hesabın vardı, giriş yaptın.");
    expect(actionsOf(container, "kc-email-code-sign-up-existing-form")).toEqual(["continue"]);
    expect(container.querySelector('button[value="continue"]')).toHaveTextContent("Devam et");
  });

  it("says when the address cannot open an account and offers another address", async () => {
    const { container } = await renderSignUp(getEmailCodeSignUpPreview("unavailable"));

    expect(container.querySelector("h1")).toHaveTextContent("Bu adresle hesap açılamıyor");
    expect(actionsOf(container, "kc-email-code-sign-up-unavailable-form")).toEqual(["change"]);
  });

  it("treats a stage it does not know as the form", async () => {
    const { container } = await renderSignUp({ skySignUpStage: "something-else" });

    expect(container.querySelector("form#kc-email-code-sign-up-form")).not.toBeNull();
  });

  it("speaks English from i18n.ts", async () => {
    const { container } = await renderSignUp({}, "en");

    expect(container.querySelector("h1")).toHaveTextContent("Let's create your account");
    expect(container.querySelector('label[for="sky-sign-up-first-name"]')).toHaveTextContent("First name");
    expect(container.querySelector('button[value="sign-up"]')).toHaveTextContent("Create account");
    cleanup();
    const existing = await renderSignUp(getEmailCodeSignUpPreview("existing"), "en");
    expect(existing.container.querySelector(".sl-legacy-intro p")).toHaveTextContent(
      "You already had an account with this address, so you are signed in."
    );
  });
});
