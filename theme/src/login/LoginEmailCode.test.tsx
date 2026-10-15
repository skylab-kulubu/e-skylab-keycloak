import { cleanup, fireEvent, render, waitFor } from "@testing-library/react";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import { getDevKcContextForPage } from "../devKcContext";
import type { KcContext } from "./KcContext";
import KcPage from "./KcPage";
import { rememberPasswordChoice } from "./emailCodeChoice";

type LoginContext = Extract<KcContext, { pageId: "login.ftl" }>;

/**
 * The login page's e-mail button (eskylab-login-ux 08): with the SPI's sky-email-code step in the
 * realm's browser flow, Keycloak lists it in auth.authenticationSelections and the button switches to
 * it; without it the button keeps opening the password view. "Parolanla gir" on the code page comes
 * back here straight to the password view.
 */
async function renderLogin(selections?: { authExecId: string; displayName: string }[]) {
  const kcContext = getDevKcContextForPage("login.ftl") as LoginContext;
  if (selections !== undefined) {
    (kcContext.auth as Record<string, unknown>).authenticationSelections = selections;
  }
  const view = render(<KcPage kcContext={kcContext} />);
  await waitFor(() => {
    expect(view.container.querySelector(".sl-legacy-shell")).toHaveAttribute("data-sl-translations", "ready");
    expect(view.container.querySelector("h1")).not.toBeNull();
  });
  return { ...view, kcContext };
}

/** The first screen's second choice: the e-mail button, whatever its words are. */
function emailButton(container: HTMLElement): HTMLButtonElement {
  const button = container.querySelector(".sl-legacy-choices button");
  if (!(button instanceof HTMLButtonElement)) {
    throw new Error("the first screen has no e-mail button");
  }
  return button;
}

describe("login page: the e-mail button and the e-mail code step", () => {
  beforeAll(() => {
    window.history.replaceState(null, "", "/?viewMode=docs");
  });

  afterEach(() => {
    cleanup();
    vi.restoreAllMocks();
    window.sessionStorage.clear();
  });

  it("switches to the e-mail code step when Keycloak offers it", async () => {
    const submitted: HTMLFormElement[] = [];
    vi.spyOn(HTMLFormElement.prototype, "submit").mockImplementation(function (this: HTMLFormElement) {
      submitted.push(this);
    });
    const { container, kcContext } = await renderLogin([
      { authExecId: "exec-password", displayName: "sky-username-password-form-display-name" },
      { authExecId: "exec-email-code", displayName: "sky-email-code-display-name" }
    ]);

    fireEvent.click(emailButton(container));

    expect(submitted).toHaveLength(1);
    expect(submitted[0]).toHaveAttribute("method", "post");
    expect(submitted[0].action).toBe(new URL(kcContext.url.loginAction, window.location.href).href);
    expect(new FormData(submitted[0]).get("authenticationExecution")).toBe("exec-email-code");
    expect(container.querySelector("#kc-form-login"), "the password view stays closed").toBeNull();
  });

  it("keeps opening the password view while the realm has no e-mail code step", async () => {
    const submit = vi.spyOn(HTMLFormElement.prototype, "submit").mockImplementation(() => undefined);
    const { container } = await renderLogin([{ authExecId: "exec-password", displayName: "sky-username-password-form-display-name" }]);

    fireEvent.click(emailButton(container));

    expect(submit).not.toHaveBeenCalled();
    expect(container.querySelector("#kc-form-login")).not.toBeNull();
  });

  it("opens straight on the password view, the field filled, after Parolanla gir", async () => {
    rememberPasswordChoice("ada.lovelace@example.org");
    const { container } = await renderLogin([{ authExecId: "exec-email-code", displayName: "sky-email-code-display-name" }]);

    expect(container.querySelector("#kc-form-login")).not.toBeNull();
    expect(container.querySelector("input#username")).toHaveValue("ada.lovelace@example.org");
    expect(window.sessionStorage.length, "the choice is read once").toBe(0);
  });

  it("ignores a choice older than a few minutes", async () => {
    window.sessionStorage.setItem(
      "sl-email-code-password-choice",
      JSON.stringify({ identifier: "old@example.org", at: Date.now() - 10 * 60 * 1000 })
    );
    const { container } = await renderLogin();

    expect(container.querySelector("#kc-form-login")).toBeNull();
    expect(container.querySelector(".sl-legacy-choices")).not.toBeNull();
  });
});
