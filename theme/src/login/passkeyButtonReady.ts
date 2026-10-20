/**
 * A passkey button pressed before it works. Keycloak's passkey buttons (`#authenticateWebAuthnButton`,
 * `#registerWebAuthn`) are on the page from the first frame, but they do nothing until Keycloak's
 * WebAuthn script listens to them: keycloakify inserts that module script after the first render and
 * the translations, it imports webauthnAuthenticate.js/webauthnRegister.js, and only then adds a
 * one-time (`{ once: true }`) click listener. On a slow connection a press before that was lost.
 * - A press that comes too early is kept (one at most) and given to the button once the script
 *   listens, after the script has finished its own setup (conditional mediation included), the way a
 *   later press would. The button is never disabled; it reads as busy (`aria-busy`) meanwhile.
 * - Browsers start a passkey ceremony only shortly after a press (transient user activation), so a
 *   kept press is given only while the page still has it, or within REPLAY_WINDOW_MS where the
 *   browser cannot tell; otherwise it is dropped and the next press works as usual.
 * - A press after the script listens goes straight through; nothing is ever sent twice, because
 *   the script's listener runs once and a kept press is given once.
 */

export const PASSKEY_BUTTON_IDS = ["authenticateWebAuthnButton", "registerWebAuthn"];
export const REPLAY_WINDOW_MS = 5_000;

const selector = PASSKEY_BUTTON_IDS.map(id => `#${id}`).join(", ");
const watched = new WeakSet<Element>();
const listening = new WeakSet<Element>();
let kept: { button: HTMLElement; at: number; timer: number } | undefined;

function stillActive(at: number): boolean {
  const activation = (navigator as Navigator & { userActivation?: { isActive: boolean } }).userActivation;
  return activation !== undefined ? activation.isActive : Date.now() - at < REPLAY_WINDOW_MS;
}

function drop(): HTMLElement | undefined {
  if (kept === undefined) return undefined;
  const { button, timer } = kept;
  window.clearTimeout(timer);
  button.removeAttribute("aria-busy");
  kept = undefined;
  return button;
}

function onListening(button: HTMLElement): void {
  listening.add(button);
  if (kept?.button !== button) return;
  const at = kept.at;
  // After the script's own remaining setup, like a press that came now.
  window.setTimeout(() => {
    if (kept?.button !== button) return;
    drop();
    if (stillActive(at)) button.click();
  }, 0);
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

function onClick(event: MouseEvent): void {
  const button = event.target instanceof Element ? event.target.closest(selector) : null;
  if (!(button instanceof HTMLElement) || listening.has(button)) return;
  // Not listened to yet: keep this press (the latest one) for when it is.
  drop();
  button.setAttribute("aria-busy", "true");
  kept = { button, at: Date.now(), timer: window.setTimeout(drop, REPLAY_WINDOW_MS) };
}

/** Runs once in main.tsx, before the first render, so every passkey button is watched in time. */
export function installPasskeyButtonReady(): () => void {
  // React adds the buttons; the script that listens to them comes later (a later task).
  const observer = new MutationObserver(watchAll);
  observer.observe(document.documentElement, { childList: true, subtree: true });
  watchAll();
  document.addEventListener("click", onClick, true);
  return () => {
    observer.disconnect();
    document.removeEventListener("click", onClick, true);
    drop();
  };
}
