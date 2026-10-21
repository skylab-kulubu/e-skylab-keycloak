import type { BrowserContext, Page } from "@playwright/test";

// Keycloak's passkey buttons (#authenticateWebAuthnButton; #registerWebAuthn on older pages) do
// nothing until the page's WebAuthn module script runs: keycloakify inserts it after the first
// render and the translations, it imports webauthnAuthenticate.js/webauthnRegister.js, and only
// then adds a one-time click listener to the button. A click before that is lost, and the page
// stays where it was. This marks the button when that listener is added, so a test clicks it then.
// The theme (passkeyButtonReady.ts) also holds a click until the script's own setup is over (the
// conditional request started, or no availability check pending) and marks the button then.
const READY = "data-sky-test-passkey-ready";
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
  await page.locator(BUTTON_IDS.map(id => `#${id}[${READY}][${THEME_READY}]`).join(", ")).first().click();
}
