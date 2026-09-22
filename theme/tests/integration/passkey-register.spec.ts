import { readFileSync } from "node:fs";
import { expect, test, type Page, type Request } from "@playwright/test";

// Registers exactly one passwordless passkey for a person through Keycloak's own login page and
// the webauthn-register-passwordless application-initiated action, with a Chromium virtual
// authenticator. The integration harness runs it after a relying party id switch to prove that
// the legacy passkey cleanup keeps passkeys registered after the switch.

type IntegrationConfig = {
  baseUrl: string;
  realm: string;
  callbackUrl: string;
  clientId: string;
  clientSecret: string;
  username: string;
  password: string;
};

const configPath = process.env.PASSKEY_REGISTER_CONFIG;
if (configPath === undefined) {
  throw new Error("PASSKEY_REGISTER_CONFIG must point to the ephemeral integration config");
}
const config = JSON.parse(readFileSync(configPath, "utf8")) as IntegrationConfig;
const callback = new URL(config.callbackUrl);

function waitForCallbackRequest(page: Page): Promise<string> {
  return new Promise(resolve => {
    const onRequest = (request: Request) => {
      const requestUrl = new URL(request.url());
      if (requestUrl.origin !== callback.origin || requestUrl.pathname !== callback.pathname) {
        return;
      }
      page.off("request", onRequest);
      resolve(request.url());
    };
    page.on("request", onRequest);
  });
}

async function authorizationUrl(): Promise<{ state: string; url: string }> {
  const state = `passkey-register-${Date.now()}`;
  const body = new URLSearchParams({
    client_id: config.clientId,
    response_type: "code",
    scope: "openid",
    redirect_uri: config.callbackUrl,
    code_challenge: "QWxhZGRpbjpPcGVuU2VzYW1lMTIzNDU2Nzg5MDEyMzQ1Njc",
    code_challenge_method: "S256",
    state,
    nonce: `${state}-nonce`,
    ui_locales: "tr",
    kc_action: "webauthn-register-passwordless"
  });
  const response = await fetch(
    `${config.baseUrl}/realms/${config.realm}/protocol/openid-connect/ext/par/request`,
    {
      method: "POST",
      headers: {
        authorization: `Basic ${Buffer.from(`${config.clientId}:${config.clientSecret}`).toString("base64")}`,
        "content-type": "application/x-www-form-urlencoded"
      },
      body
    }
  );
  const responseBody = await response.text();
  expect(response.ok, responseBody).toBe(true);
  const payload = JSON.parse(responseBody) as { request_uri: string };
  return {
    state,
    url: `${config.baseUrl}/realms/${config.realm}/protocol/openid-connect/auth?client_id=${encodeURIComponent(config.clientId)}&request_uri=${encodeURIComponent(payload.request_uri)}`
  };
}

test("registers one passkey after the relying party id switch", async ({ browser }) => {
  test.setTimeout(120_000);
  const context = await browser.newContext();
  const page = await context.newPage();
  const callbackReached = waitForCallbackRequest(page);
  const cdp = await context.newCDPSession(page);
  await cdp.send("WebAuthn.enable");
  const { authenticatorId } = await cdp.send("WebAuthn.addVirtualAuthenticator", {
    options: {
      protocol: "ctap2",
      transport: "internal",
      hasResidentKey: true,
      hasUserVerification: true,
      isUserVerified: true,
      automaticPresenceSimulation: true
    }
  });
  page.on("dialog", dialog => dialog.accept("Post-switch virtual passkey"));

  const authorization = await authorizationUrl();
  await page.goto(authorization.url);
  await expect(page.locator(".sl-legacy-shell")).toBeVisible();
  const passwordChoice = page.getByRole("button", { name: "YTÜ Öğrencisi Değilim" });
  const username = page.locator("#username");
  await expect(passwordChoice.or(username).first()).toBeVisible();
  if (await passwordChoice.isVisible()) {
    await passwordChoice.click();
  }
  await username.fill(config.username);
  await page.locator("#password").fill(config.password);
  await page.locator("#kc-login").click();
  await page.locator("#authenticateWebAuthnButton").click();

  const callbackUrl = await callbackReached;
  const result = new URL(callbackUrl);
  expect(result.searchParams.get("state")).toBe(authorization.state);
  expect(result.searchParams.get("kc_action_status")).toBe("success");
  await page.goto("about:blank", { waitUntil: "commit" });

  await cdp.send("WebAuthn.removeVirtualAuthenticator", { authenticatorId });
  await cdp.send("WebAuthn.disable");
  await context.close();
});
