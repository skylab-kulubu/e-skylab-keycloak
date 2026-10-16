import { createHash, randomBytes } from "node:crypto";
import { readFileSync } from "node:fs";
import { expect, test, type Browser, type BrowserContext, type Page } from "@playwright/test";

const path = process.env.B10_BROWSER_CONFIG;
if (!path) throw new Error("B10_BROWSER_CONFIG must name the disposable fixture config");
const config = JSON.parse(readFileSync(path, "utf8")) as {
  baseUrl: string; mailUrl: string; realm: string; clientId: string; callbackUrl: string;
  linkedMock: string; conflictMock: string; mockPassword: string;
};
const probe = `${config.baseUrl}/realms/${config.realm}/after-sign-up-probe`;
const strongPassword = "Fixture-Native-Password-2026";
const name = { firstName: "Deniz", lastName: "Kaya" };

function authorization() {
  const verifier = randomBytes(32).toString("base64url");
  const state = randomBytes(16).toString("hex"), nonce = randomBytes(16).toString("hex");
  const query = new URLSearchParams({ client_id: config.clientId, response_type: "code", scope: "openid profile email",
    redirect_uri: config.callbackUrl, state, nonce, ui_locales: "tr", code_challenge_method: "S256",
    code_challenge: createHash("sha256").update(verifier).digest("base64url"), prompt: "login" });
  return { verifier, state, nonce, url: `${config.baseUrl}/realms/${config.realm}/protocol/openid-connect/auth?${query}` };
}
type Auth = ReturnType<typeof authorization>;

async function fixture(browser: Browser, native: boolean) {
  const context = await browser.newContext();
  await context.route(`${config.callbackUrl}*`, route => route.fulfill({ status: 200, body: "original fixture RP callback" }));
  await context.addInitScript(() => {
    if (window.PublicKeyCredential) Object.defineProperty(window.PublicKeyCredential, "isConditionalMediationAvailable", { value: async () => false });
  });
  expect((await context.request.post(`${probe}/scope?native=${native}`)).ok()).toBe(true);
  const page = await context.newPage();
  return { context, page };
}
async function person(context: BrowserContext, email: string) {
  const response = await context.request.get(`${probe}/person?email=${encodeURIComponent(email)}`);
  expect(response.ok()).toBe(true);
  return response.json() as Promise<{ found: boolean; username: string; email: string; emailVerified: boolean;
    firstName: string; lastName: string; schoolEmail: string | null; links: number; obsLinked: boolean; credentials: string[]; requiredActions: string[] }>;
}
async function code(context: BrowserContext, email: string, previousId: string) {
  let id = "";
  await expect.poll(async () => {
    const list = await (await context.request.get(`${config.mailUrl}/api/v1/messages?limit=200`)).json();
    id = list.messages?.find((m: { ID: string; To?: { Address: string }[] }) => m.ID !== previousId && m.To?.some(to => to.Address === email))?.ID ?? "";
    return Boolean(id);
  }).toBe(true);
  const message = await (await context.request.get(`${config.mailUrl}/api/v1/message/${id}`)).json();
  const value = (message.Text as string).match(/^\s*([0-9]{6})\s*$/m)?.[1];
  if (!value) throw new Error("the fixture mail has no six-digit code");
  return value;
}
async function emailCode(page: Page, context: BrowserContext, email: string, auth: Auth, registration: boolean) {
  await page.goto(auth.url);
  await page.getByRole("button", { name: registration ? "E-postayla hesap aç" : "E-postayla devam et", exact: true }).click();
  await page.locator("#username").fill(email);
  const before = await (await context.request.get(`${config.mailUrl}/api/v1/messages?limit=200`)).json();
  const previousId = before.messages?.find((m: { To?: { Address: string }[] }) => m.To?.some(to => to.Address === email))?.ID ?? "";
  await page.locator('[name="sky-email-code-action"][value="send"]').click();
  await page.locator("#sky-email-code").fill(await code(context, email, previousId));
  await page.locator('[name="sky-email-code-action"][value="verify"]').click();
}
async function signup(page: Page, context: BrowserContext, label: string) {
  const email = `b10.${label}@example.invalid`, auth = authorization();
  await emailCode(page, context, email, auth, true);
  await expect(page.locator("#kc-email-code-sign-up-form")).toBeVisible();
  // A name is required by the server, even with a forged empty form POST.
  if (label === "deferred") {
    await page.locator('[name="sky-email-code-action"][value="sign-up"]').click();
    await expect(page.locator("#sky-sign-up-error")).toBeVisible();
    expect((await person(context, email)).found).toBe(false);
  }
  await page.locator("#sky-sign-up-first-name").fill(name.firstName);
  await page.locator("#sky-sign-up-last-name").fill(name.lastName);
  await page.locator('[name="sky-email-code-action"][value="sign-up"]').click();
  await expect(page.locator("#kc-after-sign-up-school-form")).toBeVisible();
  return { email, auth };
}
async function credentials(page: Page) {
  await page.locator('[name="sky-sign-up-school-choice"][value="skip"]').click();
  await expect(page.locator("#kc-after-sign-up-credentials-form")).toBeVisible();
}
async function callback(page: Page, context: BrowserContext, auth: Auth) {
  await page.waitForURL(url => url.origin + url.pathname === config.callbackUrl);
  const landed = new URL(page.url());
  expect(landed.searchParams.get("state")).toBe(auth.state);
  const value = landed.searchParams.get("code");
  expect(Boolean(value)).toBe(true);
  const response = await context.request.post(`${config.baseUrl}/realms/${config.realm}/protocol/openid-connect/token`, {
    form: { grant_type: "authorization_code", client_id: config.clientId, redirect_uri: config.callbackUrl,
      code: value!, code_verifier: auth.verifier }
  });
  expect(response.status()).toBe(200);
  const tokens = await response.json();
  expect(typeof tokens.access_token).toBe("string");
  const claims = JSON.parse(Buffer.from(tokens.id_token.split(".")[1], "base64url").toString("utf8"));
  expect(claims.nonce).toBe(auth.nonce);
  expect(claims.aud).toBe(config.clientId);
  // Never attach/log the tokens or authorization code.
}
async function nativeConfirmation(page: Page) {
  await expect(page.locator("#kc-continue")).toBeVisible();
  await expect(page.locator("#kc-cancel")).toBeVisible();
  await expect(page.locator("#kc-after-sign-up-credentials-form")).toHaveCount(0);
  await expect(page.locator("#kc-stay-signed-in-form")).toHaveCount(0);
}

test("generic RP defers school link, requires names, skips optional credentials and returns original PKCE callback", async ({ browser }) => {
  const { context, page } = await fixture(browser, false);
  try {
    const { email, auth } = await signup(page, context, "deferred");
    await expect(page.getByText("Okul hesabını daha sonra Hesap Merkezi’nden bağlayabilirsin.")).toBeVisible();
    await expect(page.locator('[value="link"][name="sky-sign-up-school-choice"]')).toHaveCount(0);
    // A forged unsupported yes must not turn into a false successful link or consume skip.
    await page.locator("#kc-after-sign-up-school-form").evaluate((form: HTMLFormElement) => {
      const input = document.createElement("input"); input.name = "sky-sign-up-school-choice"; input.value = "link";
      form.append(input); form.requestSubmit();
    });
    await expect(page.locator("#kc-after-sign-up-school-form")).toBeVisible();
    await credentials(page);
    await page.locator('[name="sky-sign-up-credential-choice"][value="skip"]').click();
    await callback(page, context, auth);
    const stored = await person(context, email);
    expect(stored.firstName).toBe(name.firstName); expect(stored.lastName).toBe(name.lastName);
    expect(stored.emailVerified).toBe(true); expect(stored.links).toBe(0);
    expect(stored.credentials).toEqual([]); expect(stored.requiredActions).toEqual([]);
  } finally { await context.close(); }
});

test("native password policy rejects weak input; success and later password/email logins preserve legacy 30-day offer", async ({ browser }) => {
  const { context, page } = await fixture(browser, false);
  try {
    const { email, auth } = await signup(page, context, "password");
    await credentials(page);
    await page.locator('[name="sky-sign-up-credential-choice"][value="password"]').click();
    await page.locator("#password-new").fill("weak"); await page.locator("#password-confirm").fill("weak");
    await page.locator('#kc-passwd-update-form input[type="submit"], #kc-passwd-update-form button[type="submit"]').first().click();
    await expect(page.locator("#kc-passwd-update-form")).toBeVisible();
    expect((await person(context, email)).credentials).toEqual([]);
    await page.locator("#password-new").fill(strongPassword); await page.locator("#password-confirm").fill(strongPassword);
    await page.locator('#kc-passwd-update-form input[type="submit"], #kc-passwd-update-form button[type="submit"]').first().click();
    await callback(page, context, auth);
    expect((await person(context, email)).credentials).toEqual(["password"]);
    await context.clearCookies();
    let login = authorization();
    await page.goto(login.url);
    await page.getByRole("button", { name: "E-postayla devam et", exact: true }).click();
    await page.locator("#sky-email-code-password").click();
    await page.locator("#username").fill(email); await page.locator("#password").fill(strongPassword);
    await page.locator("#kc-login").click();
    await expect(page.locator("#kc-passkey-offer-form")).toBeVisible();
    await expect(page.locator("#kc-after-sign-up-school-form")).toHaveCount(0);
    await page.locator('[name="passkey-choice"][value="no"]').click();
    await callback(page, context, login);
    await context.clearCookies(); login = authorization();
    await emailCode(page, context, email, login, false);
    await callback(page, context, login); // The delegated offer obeys the same 30-day suppression.
  } finally { await context.close(); }
});

test("native YTU success keeps personal primary and entered names, then credentials precede StaySignedIn", async ({ browser }) => {
  const { context, page } = await fixture(browser, true);
  try {
    const { email, auth } = await signup(page, context, "native");
    await page.locator('[name="sky-sign-up-school-choice"][value="link"]').click();
    await nativeConfirmation(page); await page.locator("#kc-continue").click();
    await page.locator("#username").fill(config.linkedMock); await page.locator("#password").fill(config.mockPassword);
    await page.locator("#kc-login").click();
    await expect(page.locator("#kc-after-sign-up-credentials-form")).toBeVisible();
    await expect(page.locator("#kc-stay-signed-in-form")).toHaveCount(0);
    const stored = await person(context, email);
    expect(stored.email).toBe(email); expect(stored.emailVerified).toBe(true); expect(stored.links).toBe(1);
    expect(stored.obsLinked).toBe(true);
    expect(stored.schoolEmail).toBe(config.linkedMock);
    expect(stored.firstName).toBe(name.firstName); expect(stored.lastName).toBe(name.lastName);
    await page.locator('[name="sky-sign-up-credential-choice"][value="skip"]').click();
    await expect(page.locator("#kc-stay-signed-in-form")).toBeVisible();
    await page.locator('[name="sky-stay-signed-in"][value="no"]').click();
    await callback(page, context, auth);
    expect((await person(context, email)).requiredActions).toEqual([]);
  } finally { await context.close(); }
});

test("native link can be cancelled before Microsoft; deferred credentials still finish the original RP", async ({ browser }) => {
  const { context, page } = await fixture(browser, true);
  try {
    const { email, auth } = await signup(page, context, "cancel");
    await page.locator('[name="sky-sign-up-school-choice"][value="link"]').click();
    await nativeConfirmation(page); await page.locator("#kc-cancel").click();
    await expect(page.locator("#kc-after-sign-up-credentials-form")).toBeVisible();
    expect((await person(context, email)).links).toBe(0);
    await page.locator('[name="sky-sign-up-credential-choice"][value="skip"]').click();
    await callback(page, context, auth);
  } finally { await context.close(); }
});

test("a Microsoft identity linked to another account cannot create a false linked result", async ({ browser }) => {
  const { context, page } = await fixture(browser, true);
  try {
    const { email } = await signup(page, context, "conflict");
    await page.locator('[name="sky-sign-up-school-choice"][value="link"]').click();
    await nativeConfirmation(page); await page.locator("#kc-continue").click();
    await page.locator("#username").fill(config.conflictMock); await page.locator("#password").fill(config.mockPassword);
    await page.locator("#kc-login").click();
    await expect(page.locator('#kc-error-message, [role="alert"]')).not.toHaveCount(0);
    expect(new URL(page.url()).pathname).not.toBe(new URL(config.callbackUrl).pathname);
    expect((await person(context, email)).links).toBe(0);
    expect((await person(context, "b10.holder@example.invalid")).links).toBe(1);
  } finally { await context.close(); }
});

test("optional native passkey registration and later resident sign-in work without onboarding again", async ({ browser }) => {
  const { context, page } = await fixture(browser, false);
  const cdp = await context.newCDPSession(page);
  await cdp.send("WebAuthn.enable");
  const { authenticatorId } = await cdp.send("WebAuthn.addVirtualAuthenticator", { options: {
    protocol: "ctap2", transport: "internal", hasResidentKey: true, hasUserVerification: true,
    isUserVerified: true, automaticPresenceSimulation: true
  } });
  page.on("dialog", dialog => dialog.accept("B10 virtual passkey"));
  try {
    const { email, auth } = await signup(page, context, "passkey");
    await credentials(page);
    await page.locator('[name="sky-sign-up-credential-choice"][value="passkey"]').click();
    await page.locator("#authenticateWebAuthnButton, #registerWebAuthn").first().click();
    await callback(page, context, auth);
    expect((await person(context, email)).credentials).toEqual(["webauthn-passwordless"]);
    await context.clearCookies();
    const login = authorization(); await page.goto(login.url);
    await page.locator("#authenticateWebAuthnButton").click();
    await callback(page, context, login);
  } finally {
    await cdp.send("WebAuthn.removeVirtualAuthenticator", { authenticatorId }); await context.close();
  }
});

for (const mode of ["expire", "wrong-tab"] as const) {
  test(`server capsule ${mode} cannot schedule a native credential action`, async ({ browser }) => {
    const { context, page } = await fixture(browser, false);
    try {
      const { email } = await signup(page, context, mode);
      await credentials(page);
      const tab = new URL(page.url()).searchParams.get("tab_id"); expect(Boolean(tab)).toBe(true);
      expect((await context.request.post(`${probe}/continuation?tab=${tab}&mode=${mode}`)).status()).toBe(204);
      await page.locator('[name="sky-sign-up-credential-choice"][value="password"]').click();
      await expect(page.locator("#kc-passwd-update-form")).toHaveCount(0);
      expect(new URL(page.url()).pathname).not.toBe(new URL(config.callbackUrl).pathname);
      expect((await person(context, email)).credentials).toEqual([]);
    } finally { await context.close(); }
  });
}

test("parallel different credential choices produce at most one native challenge and cannot reopen DONE", async ({ browser }) => {
  const { context, page } = await fixture(browser, false);
  try {
    const { email } = await signup(page, context, "race");
    await credentials(page);
    const action = await page.locator("#kc-after-sign-up-credentials-form").getAttribute("action");
    const tab = new URL(page.url()).searchParams.get("tab_id");
    const responses = await Promise.all(["password", "passkey"].map(choice => context.request.post(action!, {
      form: { "sky-sign-up-credential-choice": choice }, maxRedirects: 0
    })));
    const bodies = await Promise.all(responses.map(r => r.text()));
    const nativeChallenges = bodies.filter(body => body.includes('"login-update-password.ftl"') || body.includes('"webauthn-register.ftl"'));
    expect(nativeChallenges.length).toBe(1);
    const state = await (await context.request.get(`${probe}/continuation?tab=${tab}`)).json();
    expect(state.stage).toBe("DONE");
    expect(state.requiredActions.filter((a: string) => a === "UPDATE_PASSWORD" || a === "webauthn-register-passwordless").length).toBeLessThanOrEqual(1);
    const replay = await context.request.post(action!, { form: { "sky-sign-up-credential-choice": "password" }, maxRedirects: 0 });
    expect((await replay.text()).includes('"sky-after-sign-up-credentials.ftl"')).toBe(false);
    expect((await person(context, email)).credentials).toEqual([]);
  } finally { await context.close(); }
});
