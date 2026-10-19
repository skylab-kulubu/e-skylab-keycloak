import { cleanup, render, waitFor } from "@testing-library/react";
import { afterEach, beforeAll, describe, expect, it } from "vitest";
import { getDevKcContextForPage, getEmailCodePreview } from "../devKcContext";
import type { KcContext } from "./KcContext";
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
});
