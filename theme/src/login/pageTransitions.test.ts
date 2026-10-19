import { afterEach, describe, expect, it, vi } from "vitest";
import { DIRECTION_ATTRIBUTE, markBackNavigation, markEntered, revealDirection, withViewTransition } from "./pageTransitions";

afterEach(() => {
  window.sessionStorage.clear();
  document.documentElement.removeAttribute("data-sl-entered");
  document.documentElement.removeAttribute(DIRECTION_ATTRIBUTE);
  vi.unstubAllGlobals();
  Reflect.deleteProperty(document, "startViewTransition");
});

describe("one page across Keycloak's steps", () => {
  it("plays the entrance on a tab's first page only", () => {
    const first = document.createElement("html");
    markEntered(first);
    expect(first.hasAttribute("data-sl-entered")).toBe(false);

    const next = document.createElement("html");
    markEntered(next);
    expect(next.hasAttribute("data-sl-entered")).toBe(true);
  });

  it("slides backwards for Geri dön and for the browser's back button, forwards otherwise", () => {
    expect(revealDirection(undefined, true)).toBe("back");
    expect(revealDirection({ navigationType: "traverse", from: { index: 3 }, entry: { index: 2 } }, false)).toBe("back");
    expect(revealDirection({ navigationType: "traverse", from: { index: 2 }, entry: { index: 3 } }, false)).toBe("forward");
    expect(revealDirection({ navigationType: "push", from: { index: 3 }, entry: { index: 4 } }, false)).toBe("forward");
    expect(revealDirection(undefined, false)).toBe("forward");
  });

  it("remembers a Geri dön for the next page only", () => {
    markBackNavigation();
    expect(window.sessionStorage.getItem("sl-vt-back")).toBe("1");
  });

  it("switches views at once where View Transitions are missing", () => {
    const update = vi.fn();
    withViewTransition(update);
    expect(update).toHaveBeenCalledTimes(1);
    expect(document.documentElement.hasAttribute(DIRECTION_ATTRIBUTE)).toBe(false);
  });

  it("switches views at once with reduced motion, even where View Transitions exist", () => {
    const start = vi.fn();
    Object.defineProperty(document, "startViewTransition", { configurable: true, value: start });
    vi.stubGlobal("matchMedia", (query: string) => ({ matches: query === "(prefers-reduced-motion: reduce)" }));
    const update = vi.fn();

    withViewTransition(update, "back");

    expect(start).not.toHaveBeenCalled();
    expect(update).toHaveBeenCalledTimes(1);
  });

  it("runs the view switch inside a View Transition and marks its direction until it ends", async () => {
    let finish: () => void = () => undefined;
    const finished = new Promise<void>(resolve => {
      finish = resolve;
    });
    const start = vi.fn((callback: () => void) => {
      callback();
      return { finished };
    });
    Object.defineProperty(document, "startViewTransition", { configurable: true, value: start });
    vi.stubGlobal("matchMedia", () => ({ matches: false }));
    const update = vi.fn();

    withViewTransition(update, "back");

    expect(start).toHaveBeenCalledTimes(1);
    expect(update).toHaveBeenCalledTimes(1);
    expect(document.documentElement.getAttribute(DIRECTION_ATTRIBUTE)).toBe("back");
    finish();
    await finished;
    await Promise.resolve();
    expect(document.documentElement.hasAttribute(DIRECTION_ATTRIBUTE)).toBe(false);
  });
});
