import { readFileSync } from "node:fs";
import { expect, test, type CDPSession, type Page } from "@playwright/test";

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

// Failure-only observations: never include URLs, input values, or credential contents.
async function registrationFailureDiagnostic(page: Page, cdp: CDPSession, authenticatorId: string) {
  const diagnostic = {
    route: "unavailable", actionStatus: "unavailable", formsStatus: "unavailable",
    forms: [] as string[], credentialsStatus: "unavailable", credentialCount: null as number | null,
    observation: "complete"
  };
  try {
    const current = new URL(page.url()), callback = new URL(config.callbackUrl), base = new URL(config.baseUrl);
    const realm = `/realms/${config.realm}`;
    diagnostic.route = current.origin === callback.origin && current.pathname === callback.pathname ? "callback"
      : current.origin !== base.origin ? "other_origin"
      : current.pathname === `${realm}/login-actions/required-action` ? "required_action"
      : current.pathname === `${realm}/login-actions/authenticate` ? "authenticate"
      : current.pathname === `${realm}/protocol/openid-connect/auth` ? "authorization"
      : current.pathname.startsWith(`${realm}/broker/`) ? "broker" : "other";
    const statuses = current.searchParams.getAll("kc_action_status");
    diagnostic.actionStatus = statuses.length === 0 ? "missing"
      : statuses.length === 1 && ["success", "cancelled", "error"].includes(statuses[0]) ? statuses[0] : "other";
  } catch { /* Keep the projection unavailable when navigation state cannot be read. */ }
  const allowedForms = ["kc-form-login", "register", "kc-webauthn-settings-form",
    "kc-stay-signed-in-form", "kc-after-sign-up-credentials-form", "kc-otp-login-form"];
  const forms = async () => {
    try {
      const ids = await page.evaluate(allowed => allowed.filter(id =>
        Array.from(document.forms).some(form => form.id === id)), allowedForms);
      diagnostic.forms = allowedForms.filter(id => Array.isArray(ids) && ids.includes(id));
      diagnostic.formsStatus = "ok";
    } catch { /* A closed page must not replace the original assertion. */ }
  };
  const credentials = async () => {
    try {
      const result = await cdp.send("WebAuthn.getCredentials", { authenticatorId });
      if (Array.isArray(result.credentials)) {
        diagnostic.credentialCount = result.credentials.length;
        diagnostic.credentialsStatus = "ok";
      }
    } catch { /* Only a count is observable; credential data stays in memory. */ }
  };
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    await Promise.race([
      Promise.all([forms(), credentials()]),
      new Promise<void>(resolve => { timer = setTimeout(() => { diagnostic.observation = "timeout"; resolve(); }, 1000); })
    ]);
    console.log("B12 passkey registration diagnostic:", JSON.stringify(diagnostic));
  } finally { clearTimeout(timer); }
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
  await page.locator("#registerWebAuthn, #authenticateWebAuthnButton").first().click();
  try {
    await page.waitForURL(url => url.origin + url.pathname === config.callbackUrl);
  } catch (error) {
    try { await registrationFailureDiagnostic(page, cdp, authenticatorId); } catch { /* Preserve the first failure. */ }
    throw error;
  }
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
    await page.locator("#authenticateWebAuthnButton, #kc-form-passkey-button").first().click();
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
