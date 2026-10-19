import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  FAILSAFE_MS,
  installNavigationLoading,
  isNavigationPending,
  LOADING_ATTRIBUTE,
  LOADING_DELAY_MS,
  startNavigationLoading
} from "./navigationLoading";

const loading = () => document.documentElement.hasAttribute(LOADING_ATTRIBUTE);

function frame(): { card: HTMLElement; label: HTMLElement } {
  document.body.innerHTML = `
    <section class="sl-legacy-card">
      <div class="sl-legacy-loading"><span class="sl-legacy-loading__label" role="status" data-label="Yükleniyor…"></span></div>
    </section>`;
  return {
    card: document.querySelector(".sl-legacy-card") as HTMLElement,
    label: document.querySelector(".sl-legacy-loading__label") as HTMLElement
  };
}

function form(action: string, target = ""): HTMLFormElement {
  const element = document.createElement("form");
  element.method = "post";
  element.action = action;
  if (target !== "") element.target = target;
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

  beforeEach(() => {
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

  it("shows only after the delay, so a fast step does not flicker", () => {
    const { card, label } = frame();
    submit(form("/realms/e-skylab/login-actions/authenticate"));

    vi.advanceTimersByTime(LOADING_DELAY_MS - 1);
    expect(loading()).toBe(false);
    expect(card).not.toHaveAttribute("aria-busy");
    expect(label.textContent).toBe("");

    vi.advanceTimersByTime(1);
    expect(loading()).toBe(true);
    expect(card).toHaveAttribute("aria-busy", "true");
    // Filled in now, so the live region announces it.
    expect(label.textContent).toBe("Yükleniyor…");
  });

  it("cancels a second submission while the first is on its way, without disabling any button", () => {
    frame();
    const step = form("/realms/e-skylab/login-actions/authenticate");
    expect(submit(step).defaultPrevented).toBe(false);
    expect(isNavigationPending()).toBe(true);
    expect(submit(step).defaultPrevented).toBe(true);
    expect(document.querySelectorAll("button[disabled]")).toHaveLength(0);
  });

  it("clears itself when the page comes back from the back/forward cache", () => {
    const { card, label } = frame();
    submit(form("/realms/e-skylab/login-actions/authenticate"));
    vi.advanceTimersByTime(LOADING_DELAY_MS);
    expect(loading()).toBe(true);

    window.dispatchEvent(new PageTransitionEvent("pageshow", { persisted: true }));

    expect(loading()).toBe(false);
    expect(card).not.toHaveAttribute("aria-busy");
    expect(label.textContent).toBe("");
    expect(isNavigationPending()).toBe(false);
  });

  it("ignores an ordinary first page show", () => {
    frame();
    startNavigationLoading();
    window.dispatchEvent(new PageTransitionEvent("pageshow", { persisted: false }));
    vi.advanceTimersByTime(LOADING_DELAY_MS);
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

    vi.advanceTimersByTime(LOADING_DELAY_MS);
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
    vi.advanceTimersByTime(LOADING_DELAY_MS);
    expect(loading()).toBe(false);

    click(link("/realms/e-skylab/login-actions/reset-credentials"));
    vi.advanceTimersByTime(LOADING_DELAY_MS);
    expect(loading()).toBe(true);
  });
});
