// The console sign-in of master after config/master-console.sh --apply (tests/master-console.sh runs
// it): Chromium with a CDP virtual authenticator (a passkey: resident key, user verification) drives
// the real Admin Console at /admin/master/console/ and Keycloak's own login pages. No physical
// authenticator is involved. Every case prints one "browser:" line; the last line is
// "browser: all cases passed".
//   1. A console account without a passkey: the password, then Keycloak's registration page
//      (webauthn-register), then the console (its token request succeeds).
//   2. The same browser, its SSO session open: the console asks for the password and the passkey
//      again (prompt=none is refused with login_required; the Cookie step is not in the flow).
//   3. Another browser whose authenticator holds no passkey of the account: the password is
//      accepted, the passkey step fails, the console is never reached.
//   4. The view-* reader (a group with e-skylab-realm's view roles only): registers and opens the
//      console.
import assert from "node:assert/strict";
import { mkdirSync } from "node:fs";
import { createRequire } from "node:module";

const require = createRequire(new URL("../theme/package.json", import.meta.url));
const { chromium } = require("@playwright/test");

const password = process.env.MASTER_CONSOLE_PASSWORD;
assert.match(process.env.MASTER_CONSOLE_BASE_URL ?? "", /^http:\/\/127\.0\.0\.1:[0-9]+$/);
// The browser opens Keycloak as localhost: a WebAuthn relying party id is a domain name, never an IP
// address ("SecurityError: This is an invalid domain"), and localhost is a secure context.
const base = process.env.MASTER_CONSOLE_BASE_URL.replace("127.0.0.1", "localhost");
assert.ok(password, "MASTER_CONSOLE_PASSWORD is required");
const consoleUrl = `${base}/admin/master/console/`;
const tokenPath = "/realms/master/protocol/openid-connect/token";

async function newPasskeyContext(browser) {
  const context = await browser.newContext();
  const page = await context.newPage();
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
  page.on("dialog", dialog => dialog.accept("Harness passkey"));
  return { context, page, cdp, authenticatorId };
}

// consoleToken PAGE: resolves with the status of the console's code-to-token request.
function consoleToken(page, timeout = 60_000) {
  return page
    .waitForResponse(
      response => new URL(response.url()).pathname === tokenPath && response.request().method() === "POST",
      { timeout }
    )
    .then(response => response.status());
}

async function password_step(page, username) {
  await page.locator("#username").waitFor({ timeout: 60_000 });
  assert.equal(await page.locator("#password").count(), 1, "the first page is not the password form");
  await page.locator("#username").fill(username);
  await page.locator("#password").fill(password);
  await page.locator("#kc-login").click();
}

async function credentialCount(cdp, authenticatorId) {
  const { credentials } = await cdp.send("WebAuthn.getCredentials", { authenticatorId });
  return credentials.length;
}

// register PAGE: Keycloak's webauthn-register page, then its Register button.
async function register(page) {
  const button = page.locator("#registerWebAuthn");
  await button.waitFor({ timeout: 30_000 });
  await button.click();
}

// authenticate PAGE: Keycloak's WebAuthn sign-in page, then its button.
async function authenticate(page) {
  const button = page.locator("#authenticateWebAuthnButton");
  await button.waitFor({ timeout: 30_000 });
  await button.click();
}

// diagnose PAGE LABEL: on a failure, the page's address, title and visible text (Keycloak's own pages;
// no secret is ever typed into a visible field) and a screenshot under theme/test-results.
async function diagnose(page, label) {
  try {
    const text = (await page.locator("body").innerText({ timeout: 5_000 })).replace(/\s+/g, " ").slice(0, 800);
    console.log(`browser: FAILED in ${label}: url=${page.url()} title=${await page.title()} text=${text}`);
    const results = new URL("../theme/test-results/", import.meta.url).pathname;
    mkdirSync(results, { recursive: true });
    await page.screenshot({ path: `${results}master-console-${label}.png` });
  } catch (error) {
    console.log(`browser: FAILED in ${label}; no page details (${error.message})`);
  }
}

// step LABEL PAGE FN: runs FN, prints the page's state when it throws.
async function step(label, page, fn) {
  try {
    return await fn();
  } catch (error) {
    await diagnose(page, label);
    throw error;
  }
}

const browser = await chromium.launch();
try {
  // 1. registration right after the password, then the console.
  const writer = await newPasskeyContext(browser);
  let token;
  await step("1-register", writer.page, async () => {
    await writer.page.goto(consoleUrl);
    await password_step(writer.page, "yazici-bir");
    token = consoleToken(writer.page);
    await register(writer.page);
    assert.equal(await token, 200, "the console's token request after the registration failed");
  });
  assert.equal(await credentialCount(writer.cdp, writer.authenticatorId), 1, "no passkey was registered");
  console.log("browser: 1 an account without a passkey is sent to register one right after the password and reaches the console");

  // 2. the open SSO session does not stand in for the two factors.
  const cookies = await writer.context.cookies(base);
  assert.ok(cookies.some(cookie => cookie.name === "KEYCLOAK_IDENTITY"), "no SSO session cookie after the first sign-in");
  const passive = await writer.page.request.get(
    `${base}/realms/master/protocol/openid-connect/auth?client_id=security-admin-console&response_type=code&scope=openid` +
      `&redirect_uri=${encodeURIComponent(consoleUrl)}&prompt=none&state=harness`,
    { maxRedirects: 0 }
  );
  const passiveLocation = passive.headers()["location"] ?? "";
  assert.match(passiveLocation, /error=login_required/, `prompt=none was not refused: ${passive.status()} ${passiveLocation}`);
  const second = await writer.context.newPage();
  await step("2-sso", second, async () => {
    await second.goto(consoleUrl);
    await password_step(second, "yazici-bir");
    token = consoleToken(second);
    await authenticate(second);
    assert.equal(await token, 200, "the console's token request after the passkey failed");
  });
  console.log("browser: 2 with the SSO session open the console asks for the password and the passkey again (prompt=none: login_required)");
  await writer.context.close();

  // 3. without the registered passkey: refused.
  const stranger = await newPasskeyContext(browser);
  let reached = false;
  stranger.page.on("response", response => {
    if (new URL(response.url()).pathname === tokenPath && response.request().method() === "POST") {
      reached = true;
    }
  });
  await step("3-stranger", stranger.page, async () => {
    await stranger.page.goto(consoleUrl);
    await password_step(stranger.page, "yazici-bir");
    await authenticate(stranger.page);
  });
  await stranger.page.locator("#kc-error-message, .pf-v5-c-alert, .alert-error, #input-error").first()
    .waitFor({ timeout: 30_000 })
    .catch(() => undefined);
  await stranger.page.waitForTimeout(3_000);
  assert.equal(reached, false, "the console got a token without the registered passkey");
  assert.ok(!stranger.page.url().startsWith(consoleUrl), `the browser reached the console: ${stranger.page.url()}`);
  assert.equal(await credentialCount(stranger.cdp, stranger.authenticatorId), 0, "the other browser registered a passkey");
  console.log("browser: 3 the password without the registered passkey is refused (no console token)");
  await stranger.context.close();

  // 4. the view-* reader opens the console.
  const reader = await newPasskeyContext(browser);
  await step("4-reader", reader.page, async () => {
    await reader.page.goto(consoleUrl);
    await password_step(reader.page, "okuyucu");
    token = consoleToken(reader.page);
    await register(reader.page);
    assert.equal(await token, 200, "the reader's console token request failed");
  });
  console.log("browser: 4 the view-* reader registers a passkey and opens the console");
  await reader.context.close();
} finally {
  await browser.close();
}
console.log("browser: all cases passed");
