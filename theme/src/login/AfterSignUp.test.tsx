import { cleanup, render, waitFor } from "@testing-library/react";
import { afterEach, describe, expect, it } from "vitest";
import { getDevKcContextForPage } from "../devKcContext";
import KcPage from "./KcPage";

afterEach(cleanup);

async function page(pageId: "sky-after-sign-up-school.ftl" | "sky-after-sign-up-credentials.ftl", available?: unknown, lang: "tr" | "en" = "tr") {
  window.history.replaceState(null, "", "/?viewMode=docs");
  const context = getDevKcContextForPage(pageId, lang);
  if (pageId === "sky-after-sign-up-school.ftl") Object.assign(context, { skyYtuLinkAvailable: available });
  const view = render(<KcPage kcContext={context} />);
  await waitFor(() => expect(view.container.querySelector(".sl-legacy-shell")).toHaveAttribute("data-sl-translations", "ready"));
  return { ...view, context };
}

describe("registration-only native choices", () => {
  it.each([true, "true"])("offers native school link only for explicit server availability %s", async available => {
    const view = await page("sky-after-sign-up-school.ftl", available);
    const form = view.container.querySelector("form")!;
    expect(form).toHaveAttribute("method", "post");
    expect(form).toHaveAttribute("action", view.context.url.loginAction);
    expect(view.getByRole("button", { name: "YTÜ hesabımı bağla" })).toHaveAttribute("name", "sky-sign-up-school-choice");
    expect(view.getByRole("button", { name: "YTÜ hesabımı bağla" })).toHaveAttribute("value", "link");
    expect(view.getByRole("button", { name: "Şimdi değil" })).toHaveAttribute("value", "skip");
    expect(view.container.querySelectorAll(".sl-legacy-teams")).toHaveLength(2);
    expect(view.container.textContent).not.toMatch(/adın doğrulanır|verified name/i);
  });
  it.each([false, "false", undefined, "TRUE", "unexpected"])("defers unsupported school link and leaves continuation at %s", async available => {
    const view = await page("sky-after-sign-up-school.ftl", available);
    expect(view.queryByRole("button", { name: "YTÜ hesabımı bağla" })).toBeNull();
    expect(view.getByText("Okul hesabını daha sonra Hesap Merkezi’nden bağlayabilirsin.")).toBeVisible();
    expect(view.getByRole("button", { name: "Devam et" })).toHaveAttribute("value", "skip");
    expect(view.container.querySelector('a[href*="kc_action"], a[href*="my.yildizskylab.com"]')).toBeNull();
  });
  it("uses only session-native choices, with password and skip optional", async () => {
    const view = await page("sky-after-sign-up-credentials.ftl");
    expect(view.getByRole("heading", { name: "Girişini kolaylaştır" })).toBeVisible();
    for (const [label, value] of [["Erişim anahtarı ekle (önerilen)", "passkey"], ["Parola belirle", "password"], ["Şimdilik geç", "skip"]]) {
      const button = view.getByRole("button", { name: label });
      expect(button).toHaveAttribute("name", "sky-sign-up-credential-choice");
      expect(button).toHaveAttribute("value", value);
    }
    expect(view.container.querySelector('input[type="password"], input[name="redirect_uri"], input[name="state"]')).toBeNull();
    expect(view.getByText(/Kodla girmeye devam edebilirsin/)).toBeVisible();
  });
  it("translates both page copy and credential choices into English", async () => {
    const view = await page("sky-after-sign-up-credentials.ftl", undefined, "en");
    expect(view.getByRole("heading", { name: "Make signing in easier" })).toBeVisible();
    expect(view.getByRole("button", { name: "Set a password" })).toHaveAttribute("value", "password");
    expect(view.getByRole("button", { name: "Skip for now" })).toHaveAttribute("value", "skip");
  });
});
