import { flushSync } from "react-dom";
import latinFontUrl from "@fontsource-variable/space-grotesk/files/space-grotesk-latin-wght-normal.woff2?url";
import latinExtFontUrl from "@fontsource-variable/space-grotesk/files/space-grotesk-latin-ext-wght-normal.woff2?url";

/**
 * Keycloak's steps are separate page loads. These pieces make them feel like one page, the way
 * identifier-first sign-ins do, without touching how the steps are submitted (every form still
 * posts to Keycloak and the server decides the next page):
 * - cross-document View Transitions (legacy-login.css: `@view-transition`, only without reduced
 *   motion): the frame stays put and only the card's content slides, backwards for "Geri dön";
 * - the entrance animations (logo trace, background bloom, watermark) play on the first page of
 *   a tab only (`data-sl-entered` on <html>);
 * - the font is requested before the first layout instead of after it.
 * Browsers without View Transitions load the next page as before.
 */

const ENTERED_KEY = "sl-entered";
const BACK_KEY = "sl-vt-back";
export const DIRECTION_ATTRIBUTE = "data-sl-vt-direction";

type Direction = "forward" | "back";

function storage(): Storage | undefined {
  try {
    return window.sessionStorage;
  } catch {
    return undefined;
  }
}

/** True once this tab has shown a page of the theme; the entrance animations then stay off. */
export function markEntered(root: HTMLElement = document.documentElement): void {
  const store = storage();
  try {
    if (store?.getItem(ENTERED_KEY) === "1") {
      root.setAttribute("data-sl-entered", "");
    } else {
      store?.setItem(ENTERED_KEY, "1");
    }
  } catch {
    // Without storage every page plays the entrance once; nothing else changes.
  }
}

/** Called just before a navigation that goes back a step ("Geri dön"), so the next page slides backwards. */
export function markBackNavigation(): void {
  try {
    storage()?.setItem(BACK_KEY, "1");
  } catch {
    // The next page then slides forwards.
  }
}

function takeBackNavigation(): boolean {
  try {
    const store = storage();
    const back = store?.getItem(BACK_KEY) === "1";
    store?.removeItem(BACK_KEY);
    return back;
  } catch {
    return false;
  }
}

type Activation = { navigationType?: string; from?: { index: number } | null; entry?: { index: number } };
type RevealEvent = Event & { viewTransition?: { finished: Promise<void> } | null };

/** The direction of the page this document was revealed by: the browser's back button or "Geri dön". */
export function revealDirection(activation: Activation | undefined, markedBack: boolean): Direction {
  if (markedBack) return "back";
  const from = activation?.from?.index;
  const to = activation?.entry?.index;
  return activation?.navigationType === "traverse" && from !== undefined && to !== undefined && to < from
    ? "back"
    : "forward";
}

function setDirection(direction: Direction, finished: Promise<void> | undefined): void {
  const root = document.documentElement;
  root.setAttribute(DIRECTION_ATTRIBUTE, direction);
  void finished?.finally(() => root.removeAttribute(DIRECTION_ATTRIBUTE));
}

function preloadFonts(): void {
  for (const href of [latinFontUrl, latinExtFontUrl]) {
    const link = document.createElement("link");
    link.rel = "preload";
    link.as = "font";
    link.type = "font/woff2";
    link.crossOrigin = "anonymous";
    link.href = href;
    document.head.appendChild(link);
  }
}

/**
 * Runs once in main.tsx before the first render. The entry script is render-blocking
 * (vite.config.ts), so the reveal listener is in place before the new page's first frame.
 */
export function installPageTransitions(): void {
  markEntered();
  preloadFonts();
  const markedBack = takeBackNavigation();
  window.addEventListener("pagereveal", event => {
    const transition = (event as RevealEvent).viewTransition;
    if (!transition) return;
    const activation = (window as Window & { navigation?: { activation?: Activation } }).navigation?.activation;
    setDirection(revealDirection(activation, markedBack), transition.finished);
  });
}

/**
 * A step inside one page (the login page's choice and password views) with the same slide as a
 * step between pages, where the browser supports it and motion is welcome.
 */
export function withViewTransition(update: () => void, direction: Direction = "forward"): void {
  const start = (document as Document & {
    startViewTransition?: (callback: () => void) => { finished: Promise<void> };
  }).startViewTransition;
  const reducedMotion = typeof window.matchMedia === "function"
    && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  if (typeof start !== "function" || reducedMotion) {
    update();
    return;
  }
  document.documentElement.setAttribute(DIRECTION_ATTRIBUTE, direction);
  const transition = start.call(document, () => flushSync(update));
  setDirection(direction, transition.finished);
}
