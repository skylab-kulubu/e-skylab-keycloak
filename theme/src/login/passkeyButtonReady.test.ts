import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { installPasskeyButtonReady, REPLAY_WINDOW_MS } from "./passkeyButtonReady";

// Keycloak's WebAuthn module script, as keycloakify inserts it: a one-time click listener.
function keycloakScriptListens(button: HTMLElement): ReturnType<typeof vi.fn> {
  const ceremony = vi.fn();
  button.addEventListener("click", ceremony, { once: true });
  return ceremony;
}

async function passkeyButton(id = "authenticateWebAuthnButton", tag: "button" | "input" = "button"): Promise<HTMLElement> {
  const button = document.createElement(tag);
  button.id = id;
  if (button instanceof HTMLButtonElement) button.type = "button";
  else (button as HTMLInputElement).type = "submit";
  document.body.appendChild(button);
  // React added it; the observer sees it before any later script runs.
  await Promise.resolve();
  return button;
}

describe("a passkey button pressed before Keycloak's script listens", () => {
  let uninstall: () => void;

  beforeEach(() => {
    vi.useFakeTimers();
    uninstall = installPasskeyButtonReady();
  });

  afterEach(() => {
    uninstall();
    vi.useRealTimers();
    vi.unstubAllGlobals();
    document.body.innerHTML = "";
  });

  it("keeps the press and gives it once the script listens, after the script's own setup", async () => {
    const button = await passkeyButton();
    button.click();
    expect(button).toHaveAttribute("aria-busy", "true");
    expect(button).not.toBeDisabled();

    const ceremony = keycloakScriptListens(button);
    expect(ceremony).not.toHaveBeenCalled();
    vi.advanceTimersByTime(0);
    expect(ceremony).toHaveBeenCalledTimes(1);
    expect(button).not.toHaveAttribute("aria-busy");
  });

  it("starts the ceremony once for several early presses", async () => {
    const button = await passkeyButton();
    button.click();
    button.click();
    const ceremony = keycloakScriptListens(button);
    vi.advanceTimersByTime(0);
    button.click();
    expect(ceremony).toHaveBeenCalledTimes(1);
  });

  it("lets a press through untouched once the script listens", async () => {
    const button = await passkeyButton();
    const ceremony = keycloakScriptListens(button);
    button.click();
    expect(ceremony).toHaveBeenCalledTimes(1);
    expect(button).not.toHaveAttribute("aria-busy");
    vi.advanceTimersByTime(REPLAY_WINDOW_MS);
    expect(ceremony).toHaveBeenCalledTimes(1);
  });

  it("covers the registration button, an <input type=submit> outside any form", async () => {
    const button = await passkeyButton("authenticateWebAuthnButton", "input");
    const legacy = await passkeyButton("registerWebAuthn");
    button.click();
    legacy.click();
    const ceremony = keycloakScriptListens(button);
    const legacyCeremony = keycloakScriptListens(legacy);
    vi.advanceTimersByTime(0);
    // One kept press: the latest.
    expect(ceremony).not.toHaveBeenCalled();
    expect(legacyCeremony).toHaveBeenCalledTimes(1);
  });

  it("drops a press the script never answers in time, and the next press works", async () => {
    const button = await passkeyButton();
    button.click();
    vi.advanceTimersByTime(REPLAY_WINDOW_MS);
    expect(button).not.toHaveAttribute("aria-busy");
    const ceremony = keycloakScriptListens(button);
    vi.advanceTimersByTime(0);
    expect(ceremony).not.toHaveBeenCalled();
    button.click();
    expect(ceremony).toHaveBeenCalledTimes(1);
  });

  it("does not give a press the browser no longer counts as one", async () => {
    const activation = { isActive: true };
    vi.stubGlobal("navigator", Object.assign(Object.create(navigator), { userActivation: activation }));
    const button = await passkeyButton();
    button.click();
    activation.isActive = false;
    const ceremony = keycloakScriptListens(button);
    vi.advanceTimersByTime(0);
    expect(ceremony).not.toHaveBeenCalled();
    expect(button).not.toHaveAttribute("aria-busy");
  });

  it("leaves other buttons alone", async () => {
    const other = document.createElement("button");
    other.id = "kc-login";
    document.body.appendChild(other);
    await Promise.resolve();
    other.click();
    expect(other).not.toHaveAttribute("aria-busy");
  });
});
