/**
 * The loading state between two Keycloak steps: the card's own SKY LAB logo draws itself over and
 * over and the card's content dims (legacy-login.css, `html[data-sl-loading]`), the way an
 * identifier-first sign-in shows progress inside the same page. It never changes how a step is
 * sent: forms still post and links still navigate natively; this only watches them.
 * - Shown at once on every step (a form posted, a link followed, `chooseExecution`'s hidden form):
 *   Keycloak usually answers within a tenth of a second, and a delay before showing it meant it
 *   never showed at all (the old page is frozen once the answer arrives).
 * - Shown for MIN_VISIBLE_MS at least, so a fast step does not flicker: the next page of the same
 *   tab keeps it for the rest of that time (session storage, read once), its logo at the same point
 *   of the drawing (`--sl-loading-phase`). The logo and the frame stay in place across the page
 *   change (pageTransitions.ts), so it reads as one animation. That remainder is only a look
 *   (`data-sl-loading="carry-over"`): the new page takes clicks and its card is not marked busy,
 *   since nothing is on its way any more.
 * - A second submit while a step is on its way is cancelled (double submission). Buttons are not
 *   disabled: a disabled submit button would drop its own name/value from the POST.
 * - Cleared when the page comes back from the back/forward cache, and after FAILSAFE_MS in case
 *   the navigation was stopped.
 * - Passkey buttons open the browser's dialog without a navigation, so they show nothing. Keycloak's
 *   webauthn scripts then send the result (or the error) with `requestSubmit()` on `#webauth`
 *   (sign-in) or `#register` (registration), which fires a submit event. Those forms are never
 *   cancelled: the result must reach Keycloak even if an earlier step is still marked pending.
 */

export const MIN_VISIBLE_MS = 600;
export const FAILSAFE_MS = 20_000;
export const LOADING_ATTRIBUTE = "data-sl-loading";
export const PHASE_PROPERTY = "--sl-loading-phase";
/** LOADING_ATTRIBUTE's value for the next page's remainder, which only looks busy. */
export const CARRY_OVER = "carry-over";
const SINCE_KEY = "sl-loading-since";
const WEBAUTHN_FORM_IDS = ["webauth", "register"];

let failsafeTimer: number | undefined;
let carryOverTimer: number | undefined;
let pending = false;

function storage(): Storage | undefined {
  try {
    return window.sessionStorage;
  } catch {
    return undefined;
  }
}

function rememberSince(since: number): void {
  try {
    storage()?.setItem(SINCE_KEY, String(since));
  } catch {
    // The next page then shows no remainder; nothing else changes.
  }
}

function takeSince(): number | undefined {
  try {
    const store = storage();
    const stored = store?.getItem(SINCE_KEY);
    store?.removeItem(SINCE_KEY);
    const since = Number(stored);
    return stored === null || stored === undefined || !Number.isFinite(since) ? undefined : since;
  } catch {
    return undefined;
  }
}

function forgetSince(): void {
  try {
    storage()?.removeItem(SINCE_KEY);
  } catch {
    // Nothing to forget.
  }
}

function clearTimers(): void {
  window.clearTimeout(failsafeTimer);
  window.clearTimeout(carryOverTimer);
  failsafeTimer = undefined;
  carryOverTimer = undefined;
}

/**
 * The busy look. On the page the step started from (`navigating`) the card is busy too: it takes no
 * clicks, `aria-busy` is set and the live region is filled. The next page's remainder is a look only.
 */
function show(elapsedMs: number, navigating: boolean): void {
  const root = document.documentElement;
  root.style.setProperty(PHASE_PROPERTY, `${-Math.max(0, Math.round(elapsedMs))}ms`);
  root.setAttribute(LOADING_ATTRIBUTE, navigating ? "" : CARRY_OVER);
  if (!navigating) return;
  document.querySelectorAll<HTMLElement>(".sl-legacy-card").forEach(card => card.setAttribute("aria-busy", "true"));
  // The live region sits outside the busy card and is empty until now, so this text is announced.
  document.querySelectorAll<HTMLElement>(".sl-legacy-loading__status").forEach(status => {
    status.textContent = status.dataset.label ?? "";
  });
}

function hide(): void {
  const root = document.documentElement;
  root.removeAttribute(LOADING_ATTRIBUTE);
  root.style.removeProperty(PHASE_PROPERTY);
  document.querySelectorAll<HTMLElement>(".sl-legacy-card[aria-busy]").forEach(card => card.removeAttribute("aria-busy"));
  document.querySelectorAll<HTMLElement>(".sl-legacy-loading__status").forEach(status => {
    status.textContent = "";
  });
}

/** Back to the idle page: no busy look, nothing pending, nothing handed to the next page. */
export function resetNavigationLoading(): void {
  clearTimers();
  pending = false;
  forgetSince();
  hide();
}

/** A step is on its way (a form posted, a link followed, or `chooseExecution`'s hidden form). */
export function startNavigationLoading(now: number = Date.now()): void {
  clearTimers();
  pending = true;
  rememberSince(now);
  show(0, true);
  failsafeTimer = window.setTimeout(resetNavigationLoading, FAILSAFE_MS);
}

export function isNavigationPending(): boolean {
  return pending;
}

/**
 * Runs once in main.tsx right after the first render, before the first frame: when the step that
 * led here started less than MIN_VISIBLE_MS ago, this page keeps the loading state for the rest.
 * Only the look: the page's fields and buttons work meanwhile (autofocus, typing, clicks), the card
 * is not marked busy, and nothing is pending, so a submit goes through.
 */
export function continueNavigationLoading(now: number = Date.now()): void {
  const since = takeSince();
  if (since === undefined) return;
  const elapsed = now - since;
  if (elapsed < 0 || elapsed >= MIN_VISIBLE_MS) return;
  show(elapsed, false);
  carryOverTimer = window.setTimeout(() => {
    carryOverTimer = undefined;
    if (!pending) hide();
  }, MIN_VISIBLE_MS - elapsed);
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
