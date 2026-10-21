import { readFileSync } from "node:fs";
import { expect, test } from "@playwright/test";
import { clickPasskeyButton, markPasskeyButtonsReady } from "./passkeyButton";

// Separate disposable fixture config; no production account or credential is used.
const configPath = process.env.B12_PASSKEY_CONFIG;
if (!configPath) throw new Error("B12_PASSKEY_CONFIG must name the disposable fixture config");
const config = JSON.parse(readFileSync(configPath, "utf8")) as {
  baseUrl: string; realm: string; clientId: string; callbackUrl: string;
  username: string; otherUsername: string; password: string;
  mockUsername: string; secondMockUsername: string; mockPassword: string;
  counterSeedUrl?: string;
};

function authorization(parameters: Record<string, string>): string {
  const query = new URLSearchParams({ client_id: config.clientId, response_type: "code", scope: "openid",
    redirect_uri: config.callbackUrl, state: "b12-passkey-fixture", ...parameters });
  return `${config.baseUrl}/realms/${config.realm}/protocol/openid-connect/auth?${query}`;
}

test("native passkey proof links only the explicitly selected existing account", async ({ browser }) => {
  test.setTimeout(120_000);
  const context = await browser.newContext();
  await context.route(`${config.callbackUrl}*`, route => route.fulfill({ status: 200, body: "fixture callback" }));
  // Pin explicit mediation. Real platform/conditional UI is covered by the shared WebAuthn harness.
  await context.addInitScript(() => {
    if (window.PublicKeyCredential) {
      Object.defineProperty(window.PublicKeyCredential, "isConditionalMediationAvailable", { value: async () => false });
    }
  });
  await markPasskeyButtonsReady(context);
  const page = await context.newPage();
  const cdp = await context.newCDPSession(page);
  await cdp.send("WebAuthn.enable");
  const { authenticatorId } = await cdp.send("WebAuthn.addVirtualAuthenticator", { options: {
    protocol: "ctap2", transport: "internal", hasResidentKey: true, hasUserVerification: true,
    isUserVerified: true, automaticPresenceSimulation: true
  } });
  page.on("dialog", dialog => dialog.accept("B12 virtual passkey"));

  await page.goto(authorization({ kc_action: "webauthn-register-passwordless" }));
  await page.locator("#username").fill(config.username);
  await page.locator("#password").fill(config.password);
  await page.locator("#kc-login").click();
  await clickPasskeyButton(page);
  await page.waitForURL(url => url.origin + url.pathname === config.callbackUrl);
  expect(new URL(page.url()).searchParams.get("kc_action_status")).toBe("success");
  if (config.counterSeedUrl) {
    expect((await context.request.post(config.counterSeedUrl)).ok()).toBe(true);
    expect(await (await context.request.get(config.counterSeedUrl)).json()).toEqual({ blocked: true });
  }

  async function chooseTarget(mock: string, target: string) {
    await context.clearCookies();
    await page.goto(authorization({ kc_idp_hint: "OBS" }));
    await page.locator("#username").fill(mock);
    await page.locator("#password").fill(config.mockPassword);
    await page.locator("#kc-login").click();
    await page.locator('[name="sky-existing-account-action"][value="existing"]').click();
    await page.locator('[name="username"]').fill(target);
    await page.locator('[name="sky-existing-account-action"][value="password"]').click();
    await expect(page.locator("#username")).toHaveValue(target);
    await clickPasskeyButton(page);
  }

  // The resident passkey belongs to username, not otherUsername. Native validation can
  // discover it, but the broker wrapper must reject switching the selected local target.
  await chooseTarget(config.mockUsername, config.otherUsername);
  await expect(page.locator('[data-sky-existing-account-stage="identifier"]')).toBeVisible();
  expect(new URL(page.url()).pathname).not.toBe(new URL(config.callbackUrl).pathname);
  if (config.counterSeedUrl) {
    expect(await (await context.request.get(config.counterSeedUrl)).json()).toEqual({ blocked: true });
  }

  await chooseTarget(config.secondMockUsername, config.username);
  await page.waitForURL(url => url.origin + url.pathname === config.callbackUrl);
  expect(new URL(page.url()).searchParams.has("code")).toBe(true);
  await cdp.send("WebAuthn.removeVirtualAuthenticator", { authenticatorId });
  await context.close();
});
