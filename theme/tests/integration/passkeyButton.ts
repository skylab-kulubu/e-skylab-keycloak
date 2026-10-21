import type { BrowserContext, Page } from "@playwright/test";

// Keycloak's passkey buttons (#authenticateWebAuthnButton; #registerWebAuthn on older pages) do
// nothing until the page's WebAuthn module script runs: keycloakify inserts it after the first
// render and the translations, it imports webauthnAuthenticate.js/webauthnRegister.js, and only
// then adds a one-time click listener to the button. A click before that is lost, and the page
// stays where it was. This marks the button when that listener is added, so a test clicks it then.
// On the theme's pages (passkeyButtonReady.ts marks <html>) a click is also held until the
// script's own setup is over (the conditional request started, or no availability check pending),
// and the theme marks the button then. Keycloak's own pages (harnesses without the theme JAR) have
// neither mark.
const READY = "data-sky-test-passkey-ready";
const THEME_PAGE = "data-sl-passkey-watch";
const THEME_READY = "data-sl-passkey-ready";
const BUTTON_IDS = ["authenticateWebAuthnButton", "registerWebAuthn"];

/** Before any page of the context loads: mark a passkey button once its click listener is added. */
export async function markPasskeyButtonsReady(context: BrowserContext): Promise<void> {
  await context.addInitScript(({ ready, ids }) => {
    const add = EventTarget.prototype.addEventListener;
    EventTarget.prototype.addEventListener = function (this: EventTarget, ...args: Parameters<EventTarget["addEventListener"]>) {
      const result = Reflect.apply(add, this, args);
      if (args[0] === "click" && this instanceof Element && ids.includes(this.id)) this.setAttribute(ready, "");
      return result;
    };
  }, { ready: READY, ids: BUTTON_IDS });
}

/** Clicks the page's passkey button once the WebAuthn script listens to it and is set up. */
export async function clickPasskeyButton(page: Page): Promise<void> {
  const ready = BUTTON_IDS.flatMap(id => [
    `html[${THEME_PAGE}] #${id}[${READY}][${THEME_READY}]`,
    `html:not([${THEME_PAGE}]) #${id}[${READY}]`
  ]);
  await page.locator(ready.join(", ")).first().click();
}
