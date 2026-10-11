import { cleanup, render, waitFor } from "@testing-library/react";
import { afterEach, beforeAll, describe, expect, it } from "vitest";
import { getDevKcContextForPage, getPersonalEmailOfferPreview } from "../devKcContext";
import type { KcContext } from "./KcContext";
import KcPage from "./KcPage";
import { personalEmailOfferErrors, toPersonalEmailOfferError } from "./offerErrors";

type OfferContext = Extract<KcContext, { pageId: "sky-personal-email-offer.ftl" }>;

async function renderOffer(attributes: Record<string, string>, languageTag: "tr" | "en" = "tr") {
  const kcContext = {
    ...getDevKcContextForPage("sky-personal-email-offer.ftl", languageTag),
    ...attributes
  } as OfferContext;
  const view = render(<KcPage kcContext={kcContext} />);
  await waitFor(() => {
    expect(view.container.querySelector(".sl-legacy-shell")).toHaveAttribute("data-sl-translations", "ready");
    expect(view.container.querySelector("#kc-personal-email-offer-form")).not.toBeNull();
  });
  return view;
}

describe("the first-login personal e-mail offer (sky-personal-email-offer.ftl)", () => {
  beforeAll(() => {
    window.history.replaceState(null, "", "/?viewMode=docs");
  });

  afterEach(() => {
    cleanup();
  });

  it("asks for an address with the ticket's copy, a send button and a skip that needs no field", async () => {
    const { container } = await renderOffer({ skyOfferStage: "address" });

    expect(container.querySelector("h1")).toHaveTextContent("Kişisel e-posta ekle");
    expect(container.querySelector(".sl-legacy-intro p")).toHaveTextContent(
      "Mezun olunca okul adresin kapanabilir. Kişisel e-postanı ekle."
    );
    const form = container.querySelector("form#kc-personal-email-offer-form");
    expect(form).toHaveAttribute("method", "post");
    const address = container.querySelector("input#sky-offer-address");
    expect(address).toHaveAttribute("name", "address");
    expect(address).toHaveAttribute("type", "email");
    expect(container.querySelector('label[for="sky-offer-address"]')).toHaveTextContent("Kişisel e-posta adresin");
    expect(container.querySelector('button[value="send"]')).toHaveTextContent("Kod gönder");
    const skip = container.querySelector('button[value="skip"]');
    expect(skip).toHaveTextContent("Şimdilik geç");
    expect(skip).toHaveAttribute("formnovalidate");
    expect(container.querySelector("input#sky-offer-code")).toBeNull();
    expect(container.querySelector("#sky-offer-error")).toBeNull();
    expect(container).toHaveTextContent("Birincil adresin okul adresin olarak kalır");
    expect(document.title).toBe("Kişisel e-posta ekle · SKY LAB");
  });

  it("shows the code stage with the address, the minutes and the tries left after a wrong code", async () => {
    const { container } = await renderOffer(getPersonalEmailOfferPreview("code"));

    expect(container.querySelector("#sky-offer-code-sent")).toHaveTextContent(
      "ada.lovelace@example.org adresine 6 haneli bir kod gönderdik. Kod 10 dakika geçerli."
    );
    const code = container.querySelector("input#sky-offer-code");
    expect(code).toHaveAttribute("name", "code");
    expect(code).toHaveAttribute("autocomplete", "one-time-code");
    expect(code).toHaveAttribute("inputmode", "numeric");
    expect(code).toHaveAttribute("aria-invalid", "true");
    expect(code).toHaveAttribute("aria-describedby", "sky-offer-error");
    expect(container.querySelector("#sky-offer-error")).toHaveTextContent("Kod yanlış. 4 deneme hakkın kaldı.");
    expect(container.querySelector('button[value="verify"]')).toHaveTextContent("Doğrula ve devam et");
    expect(container.querySelector('button[value="change"]')).toHaveTextContent("Başka bir adres yaz");
    expect(container.querySelector('button[value="skip"]')).not.toBeNull();
    expect(container.querySelector("input#sky-offer-address")).toBeNull();
  });

  it("keeps the typed address after an error and words every error code", async () => {
    const taken = await renderOffer(getPersonalEmailOfferPreview("taken"));
    expect(taken.container.querySelector("input#sky-offer-address")).toHaveValue("ada.lovelace@example.org");
    expect(taken.container.querySelector("#sky-offer-error")).toHaveTextContent("başka bir hesapta kayıtlı");
    taken.unmount();

    for (const error of personalEmailOfferErrors) {
      const view = await renderOffer({ skyOfferStage: "address", skyOfferError: error, skyOfferAttemptsLeft: "2" });
      const sentence = view.container.querySelector("#sky-offer-error")?.textContent ?? "";
      expect(sentence.length, error).toBeGreaterThan(10);
      expect(sentence, error).not.toContain("personalEmailOfferError");
      view.unmount();
    }
  });

  it("shows no error for a code it does not know", async () => {
    expect(toPersonalEmailOfferError("something_else")).toBeUndefined();
    expect(toPersonalEmailOfferError(undefined)).toBeUndefined();
    const { container } = await renderOffer({ skyOfferStage: "address", skyOfferError: "<b>x</b>" });
    expect(container.querySelector("#sky-offer-error")).toBeNull();
  });

  it("speaks English from i18n.ts", async () => {
    const { container } = await renderOffer(getPersonalEmailOfferPreview("code"), "en");
    expect(container.querySelector("h1")).toHaveTextContent("Add a personal e-mail");
    expect(container.querySelector(".sl-legacy-intro p")).toHaveTextContent(
      "Your school address may close after you graduate. Add your personal e-mail."
    );
    expect(container.querySelector("#sky-offer-error")).toHaveTextContent("Wrong code. 4 tries left.");
    expect(container.querySelector('button[value="skip"]')).toHaveTextContent("Skip for now");
  });
});
