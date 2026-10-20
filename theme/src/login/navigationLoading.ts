/**
 * The loading state between two Keycloak steps: when a step takes longer than a moment, the card's
 * content fades and the SKY LAB logo draws in its middle (LegacyFrame's `.sl-legacy-loading`), the
 * way an identifier-first sign-in shows progress inside the same page. It never changes how a step
 * is sent: forms still post and links still navigate natively; this only watches them.
 * - Shown after LOADING_DELAY_MS only, so a fast step does not flicker.
 * - A second submit while a step is on its way is cancelled (double submission). Buttons are not
 *   disabled: a disabled submit button would drop its own name/value from the POST.
 * - Cleared when the page comes back from the back/forward cache, and after FAILSAFE_MS in case
 *   the navigation was stopped.
 * - Passkey buttons open the browser's dialog without a navigation, so they show nothing. Keycloak's
 *   webauthn scripts then send the result (or the error) with `requestSubmit()` on `#webauth`
 *   (sign-in) or `#register` (registration), which fires a submit event. Those forms are never
 *   cancelled: the result must reach Keycloak even if an earlier step is still marked pending.
 */

export const LOADING_DELAY_MS = 150;
export const FAILSAFE_MS = 20_000;
export const LOADING_ATTRIBUTE = "data-sl-loading";
const WEBAUTHN_FORM_IDS = ["webauth", "register"];

let delayTimer: number | undefined;
let failsafeTimer: number | undefined;
let pending = false;

function clearTimers(): void {
  window.clearTimeout(delayTimer);
  window.clearTimeout(failsafeTimer);
  delayTimer = undefined;
  failsafeTimer = undefined;
}

function show(): void {
  const root = document.documentElement;
  root.setAttribute(LOADING_ATTRIBUTE, "");
  document.querySelectorAll<HTMLElement>(".sl-legacy-card").forEach(card => card.setAttribute("aria-busy", "true"));
  // The live region sits outside the busy card and is empty until now, so this text is announced.
  document.querySelectorAll<HTMLElement>(".sl-legacy-loading__status").forEach(status => {
    status.textContent = status.dataset.label ?? "";
  });
}

/** Back to the idle page: no overlay, no busy card, nothing pending. */
export function resetNavigationLoading(): void {
  clearTimers();
  pending = false;
  document.documentElement.removeAttribute(LOADING_ATTRIBUTE);
  document.querySelectorAll<HTMLElement>(".sl-legacy-card[aria-busy]").forEach(card => card.removeAttribute("aria-busy"));
  document.querySelectorAll<HTMLElement>(".sl-legacy-loading__status").forEach(status => {
    status.textContent = "";
  });
}

/** A step is on its way (a form posted, a link followed, or `chooseExecution`'s hidden form). */
export function startNavigationLoading(): void {
  clearTimers();
  pending = true;
  delayTimer = window.setTimeout(show, LOADING_DELAY_MS);
  failsafeTimer = window.setTimeout(resetNavigationLoading, FAILSAFE_MS);
}

export function isNavigationPending(): boolean {
  return pending;
}

function sameOrigin(url: string): boolean {
  try {
    return new URL(url, window.location.href).origin === window.location.origin;
  } catch {
    return false;
  }
}

function onSubmit(event: SubmitEvent): void {
  if (event.defaultPrevented) return;
  const form = event.target;
  if (!(form instanceof HTMLFormElement)) return;
  if (pending && !WEBAUTHN_FORM_IDS.includes(form.getAttribute("id") ?? "")) {
    // The first submission is already on its way.
    event.preventDefault();
    return;
  }
  const target = event.submitter?.getAttribute("formtarget") ?? form.target;
  if (target !== "" && target !== "_self") return;
  if (!sameOrigin(event.submitter?.getAttribute("formaction") ?? form.action)) return;
  startNavigationLoading();
}

function onClick(event: MouseEvent): void {
  if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) {
    return;
  }
  const link = event.target instanceof Element ? event.target.closest("a[href]") : null;
  if (!(link instanceof HTMLAnchorElement)) return;
  if ((link.target !== "" && link.target !== "_self") || link.hasAttribute("download")) return;
  if (!sameOrigin(link.href)) return;
  const destination = new URL(link.href, window.location.href);
  const here = new URL(window.location.href);
  // A link to a place on this page is not a step.
  if (destination.hash !== "" && destination.pathname === here.pathname && destination.search === here.search) return;
  startNavigationLoading();
}

function onPageShow(event: PageTransitionEvent): void {
  if (event.persisted) resetNavigationLoading();
}

/** Runs once in main.tsx. Bubble-phase listeners, so a handler that cancels the event wins. */
export function installNavigationLoading(): () => void {
  document.addEventListener("submit", onSubmit);
  document.addEventListener("click", onClick);
  window.addEventListener("pageshow", onPageShow);
  return () => {
    document.removeEventListener("submit", onSubmit);
    document.removeEventListener("click", onClick);
    window.removeEventListener("pageshow", onPageShow);
    resetNavigationLoading();
  };
}
