import { cleanup, fireEvent, render, waitFor } from "@testing-library/react";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import { getDevKcContext, getDevKcContextForPage } from "../devKcContext";
import type { KcContext } from "./KcContext";
import KcPage from "./KcPage";
import { rememberPasswordChoice } from "./emailCodeChoice";
import { resetNavigationLoading } from "./navigationLoading";

type LoginContext = Extract<KcContext, { pageId: "login.ftl" }>;

/** The sign-up entry on either screen: "Hesap aç" on the first screen, "E-postayla hesap aç" in the password view. */
const signUpEntry = /^(E-postayla hesap aç|Hesap aç)$/;

async function renderLogin({
  flag,
  offersCode = true,
  passwordView = false,
  microsoft = true,
  brokerProof = false,
  language = "tr"
}: {
  flag?: unknown;
  offersCode?: boolean;
  passwordView?: boolean;
  microsoft?: boolean;
  brokerProof?: boolean;
  language?: "tr" | "en";
} = {}) {
  const kcContext = getDevKcContextForPage("login.ftl", language) as LoginContext;
  Object.assign(kcContext, { skyEmailCodeSignUp: flag, skyExistingAccountEscape: brokerProof });
  (kcContext.auth as Record<string, unknown>).authenticationSelections = [
    { authExecId: "offered-password", displayName: "sky-username-password-form-display-name" },
    ...(offersCode ? [{ authExecId: "offered-email-code", displayName: "sky-email-code-display-name" }] : [])
  ];
  kcContext.realm.registrationAllowed = true;
  kcContext.url.registrationUrl = "/realms/e-skylab/login-actions/registration";
  if (!microsoft) {
    kcContext.social = undefined;
  }
  if (passwordView) {
    rememberPasswordChoice("ayse.yilmaz");
  }
  const view = render(<KcPage kcContext={kcContext} />);
  await waitFor(() => {
    expect(view.container.querySelector(".sl-legacy-shell")).toHaveAttribute("data-sl-translations", "ready");
    expect(view.container.querySelector("h1")).not.toBeNull();
  });
  return { ...view, kcContext };
}

function submissions(): HTMLFormElement[] {
  const forms: HTMLFormElement[] = [];
  vi.spyOn(HTMLFormElement.prototype, "submit").mockImplementation(function (this: HTMLFormElement) {
    forms.push(this);
  });
  return forms;
}

describe("the e-mail registration entry", () => {
  beforeAll(() => window.history.replaceState(null, "", "/?viewMode=docs"));
  afterEach(() => {
    cleanup();
    vi.restoreAllMocks();
    document.body.querySelectorAll("form[hidden]").forEach(form => form.remove());
    window.sessionStorage.clear();
    window.history.replaceState(null, "", "/?viewMode=docs");
  });

  it.each(["true", true])("offers a working entry on the first screen and password view for explicit flag %s", async flag => {
    for (const passwordView of [false, true]) {
      const forms = submissions();
      const view = await renderLogin({ flag, passwordView });
      // The first screen says it on the one quiet line under the choices; the password view keeps its block.
      const entry = passwordView
        ? view.getByRole("button", { name: "E-postayla hesap aç" })
        : view.getByRole("button", { name: "Hesap aç" });
      expect(entry.closest(passwordView ? ".sl-legacy-no-account" : ".sl-legacy-alternatives__sign-up"))
        .toHaveTextContent("Hesabın yok mu?");
      expect(view.getAllByRole("button", { name: signUpEntry })).toHaveLength(1);

      fireEvent.click(entry);

      expect(forms).toHaveLength(1);
      expect(forms[0].method).toBe("post");
      expect(forms[0].action).toBe(new URL(view.kcContext.url.loginAction, window.location.href).href);
      expect(new FormData(forms[0]).get("authenticationExecution")).toBe("offered-email-code");
      expect(new FormData(forms[0]).get("sky-email-code-intent")).toBe("sign-up");
      expect(view.container.querySelector('a[href*="/registration"]')).toBeNull();
      view.unmount();
      vi.restoreAllMocks();
      // The next view is a new page, with nothing on its way.
      resetNavigationLoading();
    }
  });

  it.each([undefined, false, "false", "on", "1", "TRUE", "true "])("hides the entry for absent, false or malformed flag %s", async flag => {
    for (const passwordView of [false, true]) {
      const view = await renderLogin({ flag, passwordView });
      expect(view.queryByRole("button", { name: signUpEntry })).toBeNull();
      expect(view.container.querySelector('a[href*="/registration"]')).toBeNull();
      view.unmount();
    }
  });

  it("hides the entry when Keycloak offers no e-mail code execution, even if registration is flagged on", async () => {
    const view = await renderLogin({ flag: "true", offersCode: false });
    expect(view.queryByRole("button", { name: signUpEntry })).toBeNull();
  });

  it("does not need a Microsoft provider for e-mail registration", async () => {
    const view = await renderLogin({ flag: "true", microsoft: false });
    expect(view.getByRole("button", { name: "Hesap aç" })).toBeInTheDocument();
    expect(view.queryByRole("link", { name: "YTÜ hesabınla devam et" })).toBeNull();
  });

  it("keeps the ordinary e-mail choice free of registration intent while registration is enabled", async () => {
    const forms = submissions();
    const view = await renderLogin({ flag: "true" });

    fireEvent.click(view.getByRole("button", { name: "E-postayla devam et" }));

    expect(forms).toHaveLength(1);
    expect(new FormData(forms[0]).get("authenticationExecution")).toBe("offered-email-code");
    expect(new FormData(forms[0]).get("sky-email-code-intent")).toBeNull();
  });

  it("offers the same registration action in English", async () => {
    const view = await renderLogin({ flag: "true", language: "en" });
    expect(view.getByRole("button", { name: "Create one" }).closest(".sl-legacy-alternatives__sign-up"))
      .toHaveTextContent("No account yet? Create one");
    expect(view.container).not.toHaveTextContent("emailCodeSignUpShort");
    view.unmount();

    const passwordView = await renderLogin({ flag: "true", language: "en", passwordView: true });
    expect(passwordView.getByRole("button", { name: "Create an account with email" })).toBeInTheDocument();
    expect(passwordView.container).not.toHaveTextContent("emailCodeSignUpLink");
  });

  it("keeps broker proof on its explicit escape POST even when sign-up and an ordinary code execution are offered", async () => {
    const forms = submissions();
    const view = await renderLogin({ flag: "true", brokerProof: true });

    expect(view.queryByRole("button", { name: signUpEntry })).toBeNull();
    expect(view.container.querySelector(".sl-legacy-no-account")).toBeNull();
    const escape = view.container.querySelector('button[name="sky-existing-account-action"][value="new-account"]');
    expect(escape).toHaveTextContent("Bağlanamadım, yeni hesap aç");
    const escapeForm = escape?.closest("form");
    expect(escapeForm).toHaveAttribute("method", "post");
    expect(escapeForm).toHaveAttribute("action", view.kcContext.url.loginAction);
    expect(escapeForm?.querySelector('[name="authenticationExecution"]')).toBeNull();
    expect(forms).toHaveLength(0);
  });

  it("keeps the ordinary preview off and enables the offered execution only in an explicit registration preview", () => {
    window.history.replaceState(null, "", "/?page=login.ftl");
    expect(getDevKcContext().skyEmailCodeSignUp).toBeUndefined();

    window.history.replaceState(null, "", "/?page=login.ftl&registration=on");
    const context = getDevKcContext();
    expect(context.skyEmailCodeSignUp).toBe("true");
    expect(((context as LoginContext).auth as Record<string, unknown>).authenticationSelections).toEqual([
      { authExecId: "preview-password", displayName: "sky-username-password-form-display-name" },
      { authExecId: "preview-email-code", displayName: "sky-email-code-display-name" }
    ]);
  });

  it("previews the shared code page's sign-up intent separately from an enabled ordinary sign-in", () => {
    for (const registration of ["on", "sign-up"]) {
      window.history.replaceState(null, "", `/?page=sky-email-code.ftl&registration=${registration}`);
      const context = getDevKcContext();
      expect(context.pageId).toBe("sky-email-code.ftl");
      if (context.pageId === "sky-email-code.ftl") {
        expect(context.skyEmailCodeSignUp).toBe("true");
        expect(context.skyEmailCodeIntent).toBe(registration === "sign-up" ? "sign-up" : undefined);
      }
    }
  });
});
