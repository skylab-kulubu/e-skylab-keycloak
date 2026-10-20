import { afterEach, describe, expect, it, vi } from "vitest";
import { chooseExecution } from "./emailCodeChoice";
import { resetNavigationLoading } from "./navigationLoading";

const action = "/realms/e-skylab/login-actions/authenticate?session_code=session&execution=password&tab_id=tab";

function captureSubmissions(): HTMLFormElement[] {
  const submitted: HTMLFormElement[] = [];
  vi.spyOn(HTMLFormElement.prototype, "submit").mockImplementation(function (this: HTMLFormElement) {
    submitted.push(this);
  });
  return submitted;
}

afterEach(() => {
  resetNavigationLoading();
  vi.restoreAllMocks();
  document.body.replaceChildren();
  window.sessionStorage.clear();
});

describe("switching to the shared e-mail code step", () => {
  it("posts the sign-up intent to the current login action, keeping its authentication session", () => {
    const submitted = captureSubmissions();

    chooseExecution(action, "offered-email-code", "sign-up");

    expect(submitted).toHaveLength(1);
    const form = submitted[0];
    expect(form.method).toBe("post");
    expect(form.action).toBe(new URL(action, window.location.href).href);
    expect(form.hidden).toBe(true);
    expect(form.isConnected).toBe(true);
    expect([...new FormData(form).entries()]).toEqual([
      ["authenticationExecution", "offered-email-code"],
      ["sky-email-code-intent", "sign-up"]
    ]);
    // Only the loading state's start time (navigationLoading.ts) is kept in the tab.
    const stored = Object.keys(window.sessionStorage).filter(key => key !== "sl-loading-since");
    expect(stored, "the server's authentication session owns the intent").toEqual([]);
  });

  it("keeps an ordinary e-mail or password switch free of sign-up intent", () => {
    const submitted = captureSubmissions();

    chooseExecution(action, "offered-email-code");
    resetNavigationLoading();
    chooseExecution(action, "offered-password");

    expect(submitted).toHaveLength(2);
    expect([...new FormData(submitted[0]).entries()]).toEqual([["authenticationExecution", "offered-email-code"]]);
    expect([...new FormData(submitted[1]).entries()]).toEqual([["authenticationExecution", "offered-password"]]);
  });

  it("does not carry an earlier sign-up intent into a later ordinary switch", () => {
    const submitted = captureSubmissions();

    chooseExecution(action, "offered-email-code", "sign-up");
    resetNavigationLoading();
    chooseExecution(action, "offered-email-code");

    expect(new FormData(submitted[0]).get("sky-email-code-intent")).toBe("sign-up");
    expect(new FormData(submitted[1]).get("sky-email-code-intent")).toBeNull();
  });

  it("posts once when the choice is clicked twice", () => {
    const submitted = captureSubmissions();

    chooseExecution(action, "offered-email-code");
    chooseExecution(action, "offered-email-code");

    expect(submitted).toHaveLength(1);
  });
});
