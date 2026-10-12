import { cleanup, render, waitFor } from "@testing-library/react";
import { afterEach, beforeAll, describe, expect, it } from "vitest";
import { getDevKcContextForPage } from "../devKcContext";
import type { KcContext } from "./KcContext";
import KcPage from "./KcPage";

type StayContext = Extract<KcContext, { pageId: "sky-stay-signed-in.ftl" }>;

async function renderStay(attributes: Record<string, string> = {}, languageTag: "tr" | "en" = "tr") {
  const kcContext = {
    ...getDevKcContextForPage("sky-stay-signed-in.ftl", languageTag),
    ...attributes
  } as StayContext;
  const view = render(<KcPage kcContext={kcContext} />);
  await waitFor(() => {
    expect(view.container.querySelector(".sl-legacy-shell")).toHaveAttribute("data-sl-translations", "ready");
    expect(view.container.querySelector("#kc-stay-signed-in-form")).not.toBeNull();
  });
  return view;
}

describe("stay signed in after a YTÜ login (sky-stay-signed-in.ftl)", () => {
  beforeAll(() => {
    window.history.replaceState(null, "", "/?viewMode=docs");
  });

  afterEach(() => {
    cleanup();
  });

  it("asks the decided question with the remember-me lifetimes and a shared-computer warning", async () => {
    const { container } = await renderStay();

    expect(container.querySelector("h1")).toHaveTextContent("Bu cihazda oturumum açık kalsın mı?");
    expect(container.querySelector(".sl-legacy-intro p")).toHaveTextContent(
      "Evet dersen bu tarayıcıda 30 güne kadar yeniden giriş yapman gerekmez; 7 gün hiç kullanmazsan oturumun kapanır."
    );
    expect(container.querySelector("#sky-stay-signed-in-shared-device")).toHaveTextContent(
      "Ortak ya da başkasının bilgisayarındaysan (laboratuvar, kütüphane) Hayır'ı seç ve işin bitince çıkış yap. Hayır dersen oturumun bu cihazda kalıcı olmaz, bir süre kullanmadığında kendiliğinden biter."
    );
    expect(document.title).toBe("Bu cihazda oturumum açık kalsın mı? · SKY LAB");
  });

  it("posts yes or no to Keycloak's login action, yes first, and nothing else", async () => {
    const { container } = await renderStay();

    const form = container.querySelector("form#kc-stay-signed-in-form");
    expect(form).toHaveAttribute("method", "post");
    expect(form?.getAttribute("action")).toBeTruthy();
    const buttons = Array.from(container.querySelectorAll('form#kc-stay-signed-in-form button[name="sky-stay-signed-in"]'));
    expect(buttons.map((button) => button.getAttribute("value"))).toEqual(["yes", "no"]);
    expect(buttons[0]).toHaveTextContent("Evet, açık kalsın");
    expect(buttons[0]).toHaveClass("sl-legacy-submit");
    expect(buttons[1]).toHaveTextContent("Hayır");
    expect(buttons[1]).toHaveClass("sl-legacy-choice");
    expect(container.querySelectorAll("form#kc-stay-signed-in-form input")).toHaveLength(0);
  });

  it("words the lifetimes the realm hands over", async () => {
    const { container } = await renderStay({ skyStaySignedInIdleDays: "3", skyStaySignedInMaxDays: "14" });

    expect(container.querySelector(".sl-legacy-intro p")).toHaveTextContent(
      "Evet dersen bu tarayıcıda 14 güne kadar yeniden giriş yapman gerekmez; 3 gün hiç kullanmazsan oturumun kapanır."
    );
  });

  it("speaks English from i18n.ts", async () => {
    const { container } = await renderStay({}, "en");

    expect(container.querySelector("h1")).toHaveTextContent("Stay signed in on this device?");
    expect(container.querySelector(".sl-legacy-intro p")).toHaveTextContent(
      "If you say yes, you will not have to sign in again in this browser for up to 30 days; your session ends if you do not use it for 7 days."
    );
    expect(container.querySelector("#sky-stay-signed-in-shared-device")).toHaveTextContent("choose No");
    expect(container.querySelector('button[value="yes"]')).toHaveTextContent("Yes, stay signed in");
    expect(container.querySelector('button[value="no"]')).toHaveTextContent("No");
  });
});
