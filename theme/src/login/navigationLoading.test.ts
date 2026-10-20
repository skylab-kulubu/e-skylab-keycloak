import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  CARRY_OVER,
  continueNavigationLoading,
  FAILSAFE_MS,
  installNavigationLoading,
  isNavigationPending,
  LOADING_ATTRIBUTE,
  MIN_VISIBLE_MS,
  PHASE_PROPERTY,
  startNavigationLoading
} from "./navigationLoading";

const loading = () => document.documentElement.hasAttribute(LOADING_ATTRIBUTE);

function frame(): { card: HTMLElement; label: HTMLElement } {
  document.body.innerHTML = `
    <section class="sl-legacy-card">
      <div class="sl-legacy-loading"><span class="sl-legacy-loading__label" aria-hidden="true">Yükleniyor…</span></div>
    </section>
    <span class="sl-legacy-loading__status" role="status" data-label="Yükleniyor…"></span>`;
  return {
    card: document.querySelector(".sl-legacy-card") as HTMLElement,
    label: document.querySelector(".sl-legacy-loading__status") as HTMLElement
  };
}

function form(action: string, target = "", id = ""): HTMLFormElement {
  const element = document.createElement("form");
  element.method = "post";
  element.action = action;
  if (target !== "") element.target = target;
  if (id !== "") element.id = id;
  document.body.appendChild(element);
  return element;
}

function submit(element: HTMLFormElement): SubmitEvent {
  const event = new Event("submit", { bubbles: true, cancelable: true }) as SubmitEvent;
  element.dispatchEvent(event);
  return event;
}

function click(link: HTMLAnchorElement, init: MouseEventInit = {}): MouseEvent {
  const event = new MouseEvent("click", { bubbles: true, cancelable: true, button: 0, ...init });
  link.dispatchEvent(event);
  return event;
}

function link(href: string, attributes: Record<string, string> = {}): HTMLAnchorElement {
  const element = document.createElement("a");
  element.href = href;
  for (const [name, value] of Object.entries(attributes)) element.setAttribute(name, value);
  document.body.appendChild(element);
  return element;
}

describe("the loading state between two steps", () => {
  let uninstall: () => void;
  // jsdom cannot navigate; stop the default after every listener on the page has seen the click.
  const stayHere = (event: Event) => event.preventDefault();

  // A new document in the same tab: this module's state is gone, the tab's session storage stays.
  const nextPage = () => {
    const handedOver = window.sessionStorage.getItem("sl-loading-since");
    uninstall();
    if (handedOver !== null) window.sessionStorage.setItem("sl-loading-since", handedOver);
    uninstall = installNavigationLoading();
  };

  beforeEach(() => {
    window.sessionStorage.clear();
    vi.useFakeTimers();
    uninstall = installNavigationLoading();
    window.addEventListener("click", stayHere);
  });

  afterEach(() => {
    window.removeEventListener("click", stayHere);
    uninstall();
    vi.useRealTimers();
    document.body.innerHTML = "";
  });

  it("shows at once on every step, the live region filled in so it is announced", () => {
    const { card, label } = frame();
    expect(loading()).toBe(false);
    submit(form("/realms/e-skylab/login-actions/authenticate"));

    expect(loading()).toBe(true);
    // The busy card: no clicks (legacy-login.css), aria-busy.
    expect(document.documentElement.getAttribute(LOADING_ATTRIBUTE)).toBe("");
    expect(card).toHaveAttribute("aria-busy", "true");
    expect(label.textContent).toBe("Yükleniyor…");
    expect(document.documentElement.style.getPropertyValue(PHASE_PROPERTY)).toBe("0ms");
  });

  it("keeps the look on the next page for the rest of its minimum, with the drawing where it was", () => {
    frame();
    startNavigationLoading(1_000);
    // The next page: a new document, nothing pending, the same tab's session storage.
    nextPage();
    const { card, label } = frame();

    continueNavigationLoading(1_000 + 200);
    expect(loading()).toBe(true);
    // Only the look: the card takes clicks (legacy-login.css) and is not busy.
    expect(document.documentElement.getAttribute(LOADING_ATTRIBUTE)).toBe(CARRY_OVER);
    expect(card).not.toHaveAttribute("aria-busy");
    // Not announced again: the page's content is already there.
    expect(label.textContent).toBe("");
    expect(document.documentElement.style.getPropertyValue(PHASE_PROPERTY)).toBe("-200ms");
    expect(isNavigationPending()).toBe(false);

    vi.advanceTimersByTime(MIN_VISIBLE_MS - 200 - 1);
    expect(loading()).toBe(true);
    vi.advanceTimersByTime(1);
    expect(loading()).toBe(false);
    expect(card).not.toHaveAttribute("aria-busy");
    expect(document.documentElement.style.getPropertyValue(PHASE_PROPERTY)).toBe("");
  });

  it("shows nothing on the next page once the minimum has passed, and reads the start only once", () => {
    frame();
    startNavigationLoading(1_000);
    nextPage();
    frame();
    continueNavigationLoading(1_000 + MIN_VISIBLE_MS);
    expect(loading()).toBe(false);

    startNavigationLoading(5_000);
    nextPage();
    frame();
    continueNavigationLoading(5_100);
    expect(loading()).toBe(true);
    vi.advanceTimersByTime(MIN_VISIBLE_MS);
    continueNavigationLoading(5_200);
    expect(loading()).toBe(false);
  });

  it("shows nothing on a page that no step led to", () => {
    frame();
    continueNavigationLoading();
    expect(loading()).toBe(false);
  });

  it("lets a submit on the next page through while it is still showing, and keeps showing for that step", () => {
    frame();
    startNavigationLoading(1_000);
    nextPage();
    const { card } = frame();
    continueNavigationLoading(1_100);

    expect(submit(form("/realms/e-skylab/login-actions/authenticate")).defaultPrevented).toBe(false);
    expect(isNavigationPending()).toBe(true);
    // Busy again: this page's own step is on its way.
    expect(document.documentElement.getAttribute(LOADING_ATTRIBUTE)).toBe("");
    expect(card).toHaveAttribute("aria-busy", "true");
    vi.advanceTimersByTime(MIN_VISIBLE_MS);
    expect(loading()).toBe(true);
  });

  it("cancels a second submission while the first is on its way, without disabling any button", () => {
    frame();
    const step = form("/realms/e-skylab/login-actions/authenticate");
    expect(submit(step).defaultPrevented).toBe(false);
    expect(isNavigationPending()).toBe(true);
    expect(submit(step).defaultPrevented).toBe(true);
    expect(document.querySelectorAll("button[disabled]")).toHaveLength(0);
  });

  it("never cancels the passkey result Keycloak's webauthn scripts send, even while a step is pending", () => {
    frame();
    const action = "/realms/e-skylab/login-actions/authenticate";
    startNavigationLoading();
    // webauthnAuthenticate.js and webauthnRegister.js send these with requestSubmit(), which fires submit.
    expect(submit(form(action, "", "webauth")).defaultPrevented).toBe(false);
    expect(submit(form("/realms/e-skylab/login-actions/required-action", "", "register")).defaultPrevented).toBe(false);
    expect(submit(form(action)).defaultPrevented).toBe(true);
  });

  it("clears itself when the page comes back from the back/forward cache", () => {
    const { card, label } = frame();
    submit(form("/realms/e-skylab/login-actions/authenticate"));
    expect(loading()).toBe(true);

    window.dispatchEvent(new PageTransitionEvent("pageshow", { persisted: true }));

    expect(loading()).toBe(false);
    expect(card).not.toHaveAttribute("aria-busy");
    expect(label.textContent).toBe("");
    expect(isNavigationPending()).toBe(false);
    // Nothing is handed to the page that comes next.
    continueNavigationLoading();
    expect(loading()).toBe(false);
  });

  it("ignores an ordinary first page show", () => {
    frame();
    startNavigationLoading();
    window.dispatchEvent(new PageTransitionEvent("pageshow", { persisted: false }));
    expect(loading()).toBe(true);
  });

  it("gives up after the failsafe in case the navigation was stopped", () => {
    frame();
    startNavigationLoading();
    vi.advanceTimersByTime(FAILSAFE_MS);
    expect(loading()).toBe(false);
    expect(isNavigationPending()).toBe(false);
  });

  it("leaves forms a handler cancelled, new-tab forms and other origins alone", () => {
    frame();
    const cancelled = form("/realms/e-skylab/login-actions/authenticate");
    cancelled.addEventListener("submit", event => event.preventDefault());
    submit(cancelled);
    submit(form("/realms/e-skylab/login-actions/authenticate", "_blank"));
    submit(form("https://login.microsoftonline.com/common/oauth2"));

    expect(loading()).toBe(false);
  });

  it("follows same-origin links, but not new tabs, other origins, modified clicks or in-page anchors", () => {
    frame();
    click(link("https://passwordreset.microsoftonline.com/"));
    click(link("/realms/e-skylab/login-actions/reset-credentials", { target: "_blank" }));
    click(link("/realms/e-skylab/login-actions/reset-credentials"), { metaKey: true });
    click(link("#sl-legacy-main"));
    const handled = link("/realms/e-skylab/login-actions/reset-credentials");
    handled.addEventListener("click", event => event.preventDefault());
    click(handled);
    expect(loading()).toBe(false);

    click(link("/realms/e-skylab/login-actions/reset-credentials"));
    expect(loading()).toBe(true);
  });
});
