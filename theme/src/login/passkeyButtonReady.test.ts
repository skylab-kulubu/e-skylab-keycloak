import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  installPasskeyButtonReady,
  READY_ATTRIBUTE,
  SETUP_LIMIT_MS,
  STATE_ATTRIBUTE,
  WAIT_LIMIT_MS
} from "./passkeyButtonReady";

type Request = { mediation: string; aborted: () => boolean };

// The browser side: availability checks the test resolves by hand, and the requests started.
let requests: Request[];
let checks: Array<{ name: string; resolve: (value: boolean) => void }>;

function check(name: string): () => Promise<boolean> {
  return () => new Promise<boolean>(resolve => checks.push({ name, resolve }));
}

async function answerCheck(name: string, value: boolean): Promise<void> {
  const index = checks.findIndex(pending => pending.name === name);
  expect(index, `${name} pending`).toBeGreaterThanOrEqual(0);
  checks.splice(index, 1)[0].resolve(value);
  await vi.advanceTimersByTimeAsync(0);
}

/**
 * Keycloak 26.7.4's login script as keycloakify inserts it: one shared signal() that aborts the
 * request before it, a one-time click listener for the modal request, then initAuthenticate.
 */
function keycloakScript(
  button: HTMLElement,
  { mediation = "conditional", platform = false, identified = false } = {}
): ReturnType<typeof vi.fn> {
  let controller: AbortController | undefined;
  const signal = () => {
    controller?.abort();
    controller = new AbortController();
    return controller.signal;
  };
  const ceremony = vi.fn(() => {
    void navigator.credentials.get({ signal: signal() });
  });
  button.addEventListener("click", ceremony, { once: true });
  void (async () => {
    if (identified || mediation === "none") return;
    if (platform && !(await PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable())) return;
    if (mediation === "conditional" && !(await PublicKeyCredential.isConditionalMediationAvailable())) return;
    void navigator.credentials.get({ mediation: mediation as CredentialMediationRequirement, signal: signal() });
  })();
  return ceremony;
}

async function passkeyButton(id = "authenticateWebAuthnButton"): Promise<HTMLElement> {
  const button = document.createElement("button");
  button.id = id;
  button.type = "button";
  button.dataset.slAgainLabel = "Hazır, tekrar bas";
  document.body.appendChild(button);
  // React added it; the observer sees it before any later script runs.
  await Promise.resolve();
  return button;
}

/** The module script's own task is over (keycloakify inserts it as a separate task). */
async function scriptTaskOver(): Promise<void> {
  await vi.advanceTimersByTimeAsync(0);
}

describe("a passkey button pressed before Keycloak's script is set up", () => {
  let uninstall: () => void;

  beforeEach(() => {
    vi.useFakeTimers();
    requests = [];
    checks = [];
    vi.stubGlobal("PublicKeyCredential", {
      isConditionalMediationAvailable: check("isConditionalMediationAvailable"),
      isUserVerifyingPlatformAuthenticatorAvailable: check("isUserVerifyingPlatformAuthenticatorAvailable")
    });
    Object.defineProperty(navigator, "credentials", {
      configurable: true,
      value: {
        get(options: CredentialRequestOptions) {
          const signal = options.signal!;
          requests.push({ mediation: options.mediation ?? "modal", aborted: () => signal.aborted });
          return new Promise(() => {});
        }
      }
    });
    uninstall = installPasskeyButtonReady();
  });

  afterEach(() => {
    uninstall();
    vi.useRealTimers();
    vi.unstubAllGlobals();
    Reflect.deleteProperty(navigator, "credentials");
    document.body.innerHTML = "";
  });

  it("stops a press before the listener, and asks for it again once the conditional request runs", async () => {
    const button = await passkeyButton();
    button.click();
    expect(button).toHaveAttribute(STATE_ATTRIBUTE, "waiting");
    expect(button).toHaveAttribute("aria-disabled", "true");
    expect(button).not.toBeDisabled();

    const ceremony = keycloakScript(button);
    await scriptTaskOver();
    expect(button).not.toHaveAttribute(READY_ATTRIBUTE);
    await answerCheck("isConditionalMediationAvailable", true);

    // Nothing was replayed: the conditional request is the only one, and it was not aborted.
    expect(ceremony).not.toHaveBeenCalled();
    expect(requests.map(request => request.mediation)).toEqual(["conditional"]);
    expect(requests[0].aborted()).toBe(false);
    expect(button).toHaveAttribute(READY_ATTRIBUTE, "");
    expect(button).toHaveAttribute(STATE_ATTRIBUTE, "again");
    expect(button).not.toHaveAttribute("aria-disabled");

    // The press again is Keycloak's normal path: the modal request takes over from the conditional one.
    button.click();
    expect(ceremony).toHaveBeenCalledTimes(1);
    expect(requests.map(request => request.mediation)).toEqual(["conditional", "modal"]);
    expect(requests[0].aborted()).toBe(true);
    expect(requests[1].aborted()).toBe(false);
    expect(button).not.toHaveAttribute(STATE_ATTRIBUTE);
  });

  it("stops a press between the listener and the conditional request (no modal request to abort)", async () => {
    const button = await passkeyButton();
    const ceremony = keycloakScript(button);
    await scriptTaskOver();
    button.click();
    expect(ceremony).not.toHaveBeenCalled();
    expect(button).toHaveAttribute(STATE_ATTRIBUTE, "waiting");

    await answerCheck("isConditionalMediationAvailable", true);
    expect(requests.map(request => request.mediation)).toEqual(["conditional"]);
    expect(button).toHaveAttribute(STATE_ATTRIBUTE, "again");
  });

  it("waits for both checks of a platform-only policy", async () => {
    const button = await passkeyButton();
    keycloakScript(button, { platform: true });
    await scriptTaskOver();
    await answerCheck("isUserVerifyingPlatformAuthenticatorAvailable", true);
    expect(button).not.toHaveAttribute(READY_ATTRIBUTE);
    await answerCheck("isConditionalMediationAvailable", true);
    expect(requests.map(request => request.mediation)).toEqual(["conditional"]);
    expect(button).toHaveAttribute(READY_ATTRIBUTE, "");
  });

  it("is ready once the browser says there is no conditional request", async () => {
    const button = await passkeyButton();
    const ceremony = keycloakScript(button);
    await scriptTaskOver();
    await answerCheck("isConditionalMediationAvailable", false);
    expect(button).toHaveAttribute(READY_ATTRIBUTE, "");
    button.click();
    expect(ceremony).toHaveBeenCalledTimes(1);
    expect(requests.map(request => request.mediation)).toEqual(["modal"]);
    expect(button).not.toHaveAttribute(STATE_ATTRIBUTE);
  });

  it("is ready right after the script's task when it starts nothing on its own", async () => {
    const button = await passkeyButton("registerWebAuthn");
    const ceremony = keycloakScript(button, { identified: true });
    expect(button).not.toHaveAttribute(READY_ATTRIBUTE);
    await scriptTaskOver();
    expect(button).toHaveAttribute(READY_ATTRIBUTE, "");
    button.click();
    expect(ceremony).toHaveBeenCalledTimes(1);
  });

  it("lets a press through untouched once the button is ready", async () => {
    const button = await passkeyButton();
    const ceremony = keycloakScript(button);
    await scriptTaskOver();
    await answerCheck("isConditionalMediationAvailable", true);
    button.click();
    expect(ceremony).toHaveBeenCalledTimes(1);
    expect(button).not.toHaveAttribute(STATE_ATTRIBUTE);
    expect(button).not.toHaveAttribute("aria-disabled");
  });

  it("does not wait for ever on a check that never answers", async () => {
    const button = await passkeyButton();
    keycloakScript(button);
    await vi.advanceTimersByTimeAsync(SETUP_LIMIT_MS - 1);
    expect(button).not.toHaveAttribute(READY_ATTRIBUTE);
    await vi.advanceTimersByTimeAsync(1);
    expect(button).toHaveAttribute(READY_ATTRIBUTE, "");
  });

  it("stops waiting after WAIT_LIMIT_MS when the script never comes", async () => {
    const button = await passkeyButton();
    button.click();
    await vi.advanceTimersByTimeAsync(WAIT_LIMIT_MS);
    expect(button).not.toHaveAttribute(STATE_ATTRIBUTE);
    expect(button).not.toHaveAttribute("aria-disabled");
  });

  it("leaves other buttons alone", async () => {
    const other = document.createElement("button");
    other.id = "kc-login";
    const listener = vi.fn();
    other.addEventListener("click", listener);
    document.body.appendChild(other);
    await Promise.resolve();
    other.click();
    expect(listener).toHaveBeenCalledTimes(1);
    expect(other).not.toHaveAttribute(STATE_ATTRIBUTE);
  });
});
