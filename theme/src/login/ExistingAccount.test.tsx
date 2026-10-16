import { cleanup, render, waitFor } from "@testing-library/react";
import { afterEach, beforeAll, describe, expect, it } from "vitest";
import { getDevKcContextForPage } from "../devKcContext";
import KcPage from "./KcPage";

async function page(attributes: Record<string, unknown>) {
  const context = { ...getDevKcContextForPage("sky-existing-account.ftl"), ...attributes };
  const view = render(<KcPage kcContext={context} />);
  await waitFor(() => expect(view.container.querySelector(".sl-legacy-shell"))
    .toHaveAttribute("data-sl-translations", "ready"));
  return view;
}

describe("first Microsoft login existing-account protection", () => {
  beforeAll(() => window.history.replaceState(null, "", "/?viewMode=docs"));
  afterEach(cleanup);

  it.each(["question", "identifier", "code", "unavailable"])("keeps the team backdrop on the %s stage without a wider brand panel", async stage => {
    const { container } = await page({ skyExistingAccountStage: stage });
    expect(container.querySelectorAll(".sl-legacy-teams")).toHaveLength(2);
    expect(container.querySelector(".sl-legacy-stack--wide")).toBeNull();
    expect(container.querySelector(".sl-legacy-brand__copy")).toBeNull();
  });

  it("offers an explicit existing-account decision and an explicit new-account decision", async () => {
    const { container } = await page({ skyExistingAccountStage: "question" });
    expect(container.querySelector("h1")).toHaveTextContent("Zaten bir SKY LAB hesabın var mı?");
    expect(container.querySelector('button[value="existing"]')).toHaveTextContent("Evet, giriş yap ve bağla");
    expect(container.querySelector('button[value="new-account"]')).toHaveTextContent("Hayır, yeni hesap aç");
  });

  it("shows only the person's own identifier with code and native credential options", async () => {
    const { container } = await page({ skyExistingAccountStage: "identifier", skyExistingAccountIdentifier: "typed@example.org" });
    expect(container.querySelector('input[name="username"]')).toHaveValue("typed@example.org");
    expect(container.querySelector('button[value="send"]')).toHaveTextContent("Kod gönder");
    expect(container.querySelector('button[value="password"]')).toHaveTextContent("Parola ya da erişim anahtarıyla gir");
    expect(container.querySelector('button[value="new-account"]')).toHaveAttribute("formnovalidate");
  });

  it("keeps the code page neutral and uses six digits and one-time-code autocomplete", async () => {
    const { container } = await page({ skyExistingAccountStage: "code", skyExistingAccountResendAfter: "60" });
    expect(container.textContent).toContain("Hesabın varsa kod, hesabının şu anki birincil e-posta adresine gider");
    expect(container.querySelector('input[name="code"]')).toHaveAttribute("autocomplete", "one-time-code");
    expect(container.querySelector('label[for="sky-existing-code"]')).toHaveTextContent("6 haneli kod");
    expect(container.querySelector('button[value="resend"]')).toBeDisabled();
    expect(container.querySelector('button[value="new-account"]')).not.toBeNull();
  });

  it("never renders an arbitrary server error as HTML and keeps the escape on a failed proof", async () => {
    const { container } = await page({ skyExistingAccountStage: "invalid", skyExistingAccountError: "<script>bad</script>" });
    expect(container.querySelector('[data-sky-existing-account-stage]')).toHaveAttribute("data-sky-existing-account-stage", "unavailable");
    expect(container.textContent).not.toContain("<script>");
    expect(container.querySelector('button[value="new-account"]')).not.toBeNull();
  });
});
