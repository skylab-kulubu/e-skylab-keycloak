/**
 * A passkey button pressed before it works. Keycloak's passkey buttons (`#authenticateWebAuthnButton`,
 * `#registerWebAuthn`) are on the page from the first frame, but a press only works once Keycloak's
 * WebAuthn script is set up: keycloakify inserts that module script after the first render and the
 * translations, it imports webauthnAuthenticate.js, adds a one-time (`{ once: true }`) click
 * listener, and then `initAuthenticate` (passkeysConditionalAuth.js) awaits
 * `isConditionalMediationAvailable()` (and `isUserVerifyingPlatformAuthenticatorAvailable()` for
 * platform-only policies) before it starts the conditional (autofill) request. Every request takes
 * the script's one shared `signal()`, which aborts the one before it with an AbortError. A press
 * before the listener was lost; a press between the listener and the conditional request started a
 * modal request that the conditional one then aborted, and the script sent that AbortError to
 * Keycloak as the result.
 * - So the button is ready only once the script listens and its own setup is over: the page-load
 *   request started (`navigator.credentials.get`), or no availability check is pending any more,
 *   or SETUP_LIMIT_MS passed. It is then marked `data-sl-passkey-ready`. A press after that goes
 *   straight to Keycloak, the way Keycloak's own pages work: it aborts the conditional request.
 * - A press before that is not replayed: a replayed `click()` is no user gesture, and Safari before
 *   17.4 (iOS/macOS) lets a page make one WebAuthn call without one, which the conditional request
 *   has already used. The press is stopped before Keycloak's listener, the button reads as waiting
 *   (`data-sl-passkey="waiting"`, `aria-disabled`), and once it is ready it asks for the press again
 *   (`data-sl-passkey="again"`, the page's `data-sl-again-label` text). Without the script the
 *   waiting look ends after WAIT_LIMIT_MS.
 */

export const PASSKEY_BUTTON_IDS = ["authenticateWebAuthnButton", "registerWebAuthn"];
export const READY_ATTRIBUTE = "data-sl-passkey-ready";
/** On <html> while this runs, so a test tells the theme's pages from Keycloak's own (no ready mark). */
export const WATCH_ATTRIBUTE = "data-sl-passkey-watch";
export const STATE_ATTRIBUTE = "data-sl-passkey";
export const SETUP_LIMIT_MS = 3_000;
export const WAIT_LIMIT_MS = 10_000;

const selector = PASSKEY_BUTTON_IDS.map(id => `#${id}`).join(", ");
type Setup = { limit: number; check?: number };
const watched = new WeakSet<Element>();
const ready = new WeakSet<Element>();
const settingUp = new Map<HTMLElement, Setup>();
const waiting = new Map<HTMLElement, number>();
let pendingChecks = 0;
const restore: Array<() => void> = [];

function becomeReady(button: HTMLElement): void {
  const setup = settingUp.get(button);
  if (setup !== undefined) {
    window.clearTimeout(setup.limit);
    window.clearTimeout(setup.check);
    settingUp.delete(button);
  }
  ready.add(button);
  button.setAttribute(READY_ATTRIBUTE, "");
  const timer = waiting.get(button);
  if (timer === undefined) return;
  window.clearTimeout(timer);
  waiting.delete(button);
  button.removeAttribute("aria-disabled");
  button.setAttribute(STATE_ATTRIBUTE, "again");
}

/** After the script's current task and the microtasks it queued: ready unless a check is pending. */
function checkSoon(button: HTMLElement): void {
  const setup = settingUp.get(button);
  if (setup === undefined) return;
  window.clearTimeout(setup.check);
  setup.check = window.setTimeout(() => {
    setup.check = undefined;
    if (pendingChecks === 0) becomeReady(button);
  }, 0);
}

function onListening(button: HTMLElement): void {
  if (ready.has(button) || settingUp.has(button)) return;
  settingUp.set(button, { limit: window.setTimeout(() => becomeReady(button), SETUP_LIMIT_MS) });
  checkSoon(button);
}

/** Notice when Keycloak's script adds its click listener to this button. */
function watch(button: Element): void {
  if (watched.has(button) || !(button instanceof HTMLElement)) return;
  watched.add(button);
  button.addEventListener = function (this: HTMLElement, ...args: Parameters<EventTarget["addEventListener"]>) {
    const result = Reflect.apply(EventTarget.prototype.addEventListener, this, args);
    if (args[0] === "click" && args[1] !== null) onListening(this);
    return result;
  } as typeof button.addEventListener;
}

function watchAll(): void {
  document.querySelectorAll(selector).forEach(watch);
}

/** Wraps a WebAuthn availability check so a pending one keeps the buttons from being ready. */
function trackCheck(name: "isConditionalMediationAvailable" | "isUserVerifyingPlatformAuthenticatorAvailable"): void {
  const credential = (window as unknown as { PublicKeyCredential?: Record<string, unknown> }).PublicKeyCredential;
  const original = credential?.[name];
  if (typeof original !== "function") return;
  try {
    restore.push(() => { credential![name] = original; });
    credential![name] = function (this: unknown, ...args: unknown[]) {
      const result = Reflect.apply(original, this, args) as Promise<boolean>;
      pendingChecks += 1;
      // The script's own `await` resumes after this, so a check scheduled here sees what it did next.
      return Promise.resolve(result).finally(() => {
        pendingChecks -= 1;
        settingUp.forEach((_setup, button) => checkSoon(button));
      });
    };
  } catch {
    // Not writable: the buttons are then ready right after the listener (or at SETUP_LIMIT_MS).
  }
}

/** The script's page-load request (conditional or modal) started: a press now goes after it. */
function trackRequests(): void {
  const container = navigator.credentials as CredentialsContainer | undefined;
  const original = container?.get;
  if (container === undefined || typeof original !== "function") return;
  try {
    restore.push(() => { delete (container as { get?: unknown }).get; });
    Object.defineProperty(container, "get", {
      configurable: true,
      writable: true,
      value: function (this: CredentialsContainer, ...args: Parameters<CredentialsContainer["get"]>) {
        const result = Reflect.apply(original, this, args) as ReturnType<CredentialsContainer["get"]>;
        [...settingUp.keys()].forEach(becomeReady);
        return result;
      }
    });
  } catch {
    // Then the availability checks and SETUP_LIMIT_MS decide.
  }
}

function onClick(event: MouseEvent): void {
  const button = event.target instanceof Element ? event.target.closest(selector) : null;
  if (!(button instanceof HTMLElement)) return;
  if (ready.has(button)) {
    button.removeAttribute(STATE_ATTRIBUTE);
    return;
  }
  // Too early for Keycloak's script: stop the press and ask for it again once the button works.
  event.preventDefault();
  event.stopImmediatePropagation();
  window.clearTimeout(waiting.get(button));
  button.setAttribute(STATE_ATTRIBUTE, "waiting");
  button.setAttribute("aria-disabled", "true");
  waiting.set(button, window.setTimeout(() => {
    waiting.delete(button);
    button.removeAttribute(STATE_ATTRIBUTE);
    button.removeAttribute("aria-disabled");
  }, WAIT_LIMIT_MS));
}

/** Runs once in main.tsx, before the first render and Keycloak's script, so every button is watched. */
export function installPasskeyButtonReady(): () => void {
  trackCheck("isConditionalMediationAvailable");
  trackCheck("isUserVerifyingPlatformAuthenticatorAvailable");
  trackRequests();
  // React adds the buttons; the script that listens to them comes later (a later task).
  const observer = new MutationObserver(watchAll);
  observer.observe(document.documentElement, { childList: true, subtree: true });
  watchAll();
  document.addEventListener("click", onClick, true);
  document.documentElement.setAttribute(WATCH_ATTRIBUTE, "");
  return () => {
    document.documentElement.removeAttribute(WATCH_ATTRIBUTE);
    observer.disconnect();
    document.removeEventListener("click", onClick, true);
    restore.splice(0).reverse().forEach(undo => undo());
    settingUp.forEach(setup => { window.clearTimeout(setup.limit); window.clearTimeout(setup.check); });
    settingUp.clear();
    waiting.forEach(timer => window.clearTimeout(timer));
    waiting.clear();
    pendingChecks = 0;
  };
}
