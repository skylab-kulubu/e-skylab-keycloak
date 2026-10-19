import { createHash, randomBytes } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
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
  const scope = await context.request.post(`${probe}/scope?native=${native}`);
  expect(scope.ok()).toBe(true);
  const readback = await scope.json();
  expect(readback.configuredClientFound === true).toBe(true);
  expect(readback.fullScopeAllowed === native).toBe(true);
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
  // The first screen's sign-up entry is "Hesabın yok mu? Hesap aç" on its quiet line under the choices.
  await page.getByRole("button", { name: registration ? "Hesap aç" : "E-postayla devam et", exact: true }).click();
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
  const atCallback = (url: URL) => url.origin + url.pathname === config.callbackUrl;
  // This fixture explicitly enables the existing optional session-lifetime question. It is
  // independent of B10 and may follow any completed native credential or ordinary-login path.
  const next = await Promise.race([
    page.waitForURL(atCallback).then(() => "callback" as const),
    page.locator("#kc-stay-signed-in-form").waitFor({ state: "visible" }).then(() => "stay" as const)
  ]);
  if (next === "stay") {
    await expect(page.locator("#kc-after-sign-up-credentials-form")).toHaveCount(0);
    await page.locator('[name="sky-stay-signed-in"][value="no"]').click();
  }
  await page.waitForURL(atCallback);
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

// Project only static controls when a browser assertion fails; never include the URL,
// input values, HTML body, cookies, or protocol/session values in CI diagnostics.
async function failureShape(page: Page) {
  const snapshot = page.evaluate(() => {
    const clean = (text: string) => text.replace(/https?:\/\/\S+/g, "[url]")
      .replace(/[\w.+-]+@[\w.-]+/g, "[address]").replace(/\b[0-9]{6}\b/g, "[redacted]").slice(0, 160);
    const identifier = (text: string) => /^[a-zA-Z0-9_.:-]{0,80}$/.test(text) ? text : "[dynamic]";
    return {
      heading: clean(document.querySelector("h1")?.textContent?.trim() ?? ""),
      forms: Array.from(document.forms).map(form => identifier(form.id)),
      controls: Array.from(document.querySelectorAll<HTMLElement>("button,input,select"))
        .filter(element => element.getClientRects().length > 0)
        .map(element => ({ tag: element.tagName, id: identifier(element.id),
          name: identifier(element.getAttribute("name") ?? ""), type: identifier(element.getAttribute("type") ?? "") }))
    };
  });
  const shape = await Promise.race([snapshot, new Promise<null>(resolve => setTimeout(() => resolve(null), 500))]);
  console.log("B10 synthetic failure controls:", JSON.stringify(shape));
}

async function withCleanup(page: Page, body: () => Promise<void>, cleanups: (() => Promise<unknown>)[]) {
  let bodyFailed = false, primary: unknown;
  try { await body(); } catch (error) {
    bodyFailed = true; primary = error;
    try { await failureShape(page); } catch { /* A closed browser must not replace the first failure. */ }
  }
  let cleanupFailed = false, cleanupError: unknown;
  for (const cleanup of cleanups) {
    try { await cleanup(); } catch (error) {
      if (!cleanupFailed) { cleanupFailed = true; cleanupError = error; }
    }
  }
  if (bodyFailed) throw primary;
  if (cleanupFailed) throw cleanupError;
}

// Failure-only observation: project each field; never serialize the response/context itself.
async function nativeCapabilityDiagnostic(page: Page) {
  const booleanFields = ["nativeLinkSupported", "supportedRelyingParty", "credentialsActionEnabled", "idpLinkActionEnabled",
    "configuredClientMatches", "clientEnabled", "clientStandardFlow", "clientOidc", "clientFullScopeAllowed", "userEnabled",
    "userIsServiceAccount", "accountClientFound", "manageAccountRoleFound", "userHasManageAccount", "clientHasManageAccountScope",
    "manageAccountLinksRoleFound", "userHasManageAccountLinks", "clientHasManageAccountLinksScope", "obsFound", "obsEnabled",
    "obsMicrosoft", "brokerRootFound", "promptCountAtLeast65"] as const;
  const enumFields = {
    status: ["ok", "auth_missing", "user_missing", "client_missing", "read_error"],
    brokerOverride: ["not_applicable", "none", "same_root", "other"],
    selectedProvider: ["missing", "guarded_microsoft", "other", "unavailable"]
  } as const;
  const server = async (): Promise<Record<string, boolean | number | string>> => {
    try {
      const tab = new URL(page.url()).searchParams.get("tab_id");
      if (!tab) return { probeStatus: "missing_tab" };
      const response = await page.context().request.get(`${probe}/native-capability?tab=${encodeURIComponent(tab)}`, { timeout: 1000 });
      if (!response.ok()) return { probeStatus: "http_error" };
      const raw: unknown = await response.json();
      if (raw === null || typeof raw !== "object" || Array.isArray(raw)) return { probeStatus: "invalid" };
      const source = raw as Record<string, unknown>, safe: Record<string, boolean | number | string> = { probeStatus: "ok" };
      for (const field of booleanFields) if (typeof source[field] === "boolean") safe[field] = source[field];
      for (const field of ["promptCount", "requiredLeafPromptCount"] as const) {
        const value = source[field];
        if (typeof value === "number" && Number.isInteger(value) && value >= 0 && value <= 65) safe[field] = value;
      }
      for (const field of ["status", "brokerOverride", "selectedProvider"] as const) {
        const value = source[field];
        if (typeof value === "string" && (enumFields[field] as readonly string[]).includes(value)) safe[field] = value;
      }
      return safe;
    } catch { return { probeStatus: "unavailable" }; }
  };
  const rendered = async () => {
    try {
      const value: unknown = await page.evaluate(() => {
        const context = (window as Window & { kcContext?: { skyYtuLinkAvailable?: unknown } }).kcContext;
        const value = context?.skyYtuLinkAvailable;
        return value === true ? "boolean_true" : value === false ? "boolean_false"
          : value === "true" ? "string_true" : value === "false" ? "string_false"
          : value === undefined ? "missing" : "other";
      });
      return typeof value === "string" && ["boolean_true", "boolean_false", "string_true", "string_false", "missing", "other"].includes(value)
        ? value : "other";
    } catch { return "unavailable" as const; }
  };
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    const diagnostic = await Promise.race([
      Promise.all([server(), rendered()]).then(([capability, renderedAvailability]) => ({ capability, renderedAvailability })),
      new Promise<{ diagnosticStatus: "timeout" }>(resolve => { timer = setTimeout(() => resolve({ diagnosticStatus: "timeout" }), 1500); })
    ]);
    console.log("B10 native capability diagnostic:", JSON.stringify(diagnostic));
    writeFileSync(test.info().outputPath("native-capability-safe-diagnostic.json"), JSON.stringify(diagnostic) + "\n", { mode: 0o600 });
  } finally { clearTimeout(timer); }
}

async function beginNativeLink(page: Page) {
  await test.step("Native school link is offered and selected", async () => {
    const link = page.locator('[name="sky-sign-up-school-choice"][value="link"]');
    try { await expect(link).toBeVisible(); } catch (error) {
      try { await nativeCapabilityDiagnostic(page); } catch { /* Keep the original visibility failure even if observation fails. */ }
      throw error;
    }
    await link.click();
  });
  await test.step("Native account-link confirmation", () => nativeConfirmation(page));
}

async function counterBlocked(context: BrowserContext, username: string, label: string) {
  const response = await context.request.get(`${config.baseUrl}/realms/${config.realm}/broker-link-probe/b10-${label}/counter?user=${encodeURIComponent(username)}`);
  expect(response.ok()).toBe(true);
  return (await response.json()).blocked as boolean;
}

function refusedCallback(landed: URL, auth: Auth) {
  expect(landed.origin + landed.pathname).toBe(config.callbackUrl);
  expect(landed.searchParams.getAll("state").length).toBe(1);
  expect(landed.searchParams.get("state") === auth.state).toBe(true);
  expect(landed.searchParams.getAll("error").length).toBe(1);
  expect(landed.searchParams.get("error")).toBe("access_denied");
  for (const parameter of ["code", "access_token", "id_token"]) expect(landed.searchParams.has(parameter)).toBe(false);
  expect(landed.hash === "").toBe(true);
}

test("generic RP defers school link, requires names, skips optional credentials and returns original PKCE callback", async ({ browser }) => {
  const { context, page } = await fixture(browser, false);
  await withCleanup(page, async () => {
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
  }, [() => context.close()]);
});

test("native password policy rejects weak input; success and later password/email logins preserve legacy 30-day offer", async ({ browser }) => {
  const { context, page } = await fixture(browser, false);
  await withCleanup(page, async () => {
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
  }, [() => context.close()]);
});

test("native YTU success keeps personal primary and entered names, then credentials precede StaySignedIn", async ({ browser }) => {
  const { context, page } = await fixture(browser, true);
  await withCleanup(page, async () => {
    const { email, auth } = await signup(page, context, "native");
    await beginNativeLink(page); await page.locator("#kc-continue").click();
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
  }, [() => context.close()]);
});

test("native link can be cancelled before Microsoft; deferred credentials still finish the original RP", async ({ browser }) => {
  const { context, page } = await fixture(browser, true);
  await withCleanup(page, async () => {
    const { email, auth } = await signup(page, context, "cancel");
    await beginNativeLink(page); await page.locator("#kc-cancel").click();
    await expect(page.locator("#kc-after-sign-up-credentials-form")).toBeVisible();
    expect((await person(context, email)).links).toBe(0);
    await page.locator('[name="sky-sign-up-credential-choice"][value="skip"]').click();
    await callback(page, context, auth);
  }, [() => context.close()]);
});

test("a Microsoft identity linked to another account cannot create a false linked result", async ({ browser }) => {
  const { context, page } = await fixture(browser, true);
  await withCleanup(page, async () => {
    const { email } = await signup(page, context, "conflict");
    await beginNativeLink(page); await page.locator("#kc-continue").click();
    await page.locator("#username").fill(config.conflictMock); await page.locator("#password").fill(config.mockPassword);
    await page.locator("#kc-login").click();
    await expect(page.locator('#kc-error-message, [role="alert"]')).not.toHaveCount(0);
    expect(new URL(page.url()).pathname).not.toBe(new URL(config.callbackUrl).pathname);
    expect((await person(context, email)).links).toBe(0);
    expect((await person(context, "b10.holder@example.invalid")).links).toBe(1);
  }, [() => context.close()]);
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
  await withCleanup(page, async () => {
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
  }, [() => cdp.send("WebAuthn.removeVirtualAuthenticator", { authenticatorId }), () => context.close()]);
});

for (const mode of ["expire", "wrong-tab"] as const) {
  test(`server capsule ${mode} cannot schedule a native credential action`, async ({ browser }) => {
    const { context, page } = await fixture(browser, false);
    await withCleanup(page, async () => {
      const { email, auth } = await signup(page, context, mode);
      await credentials(page);
      const before = await person(context, email);
      expect(before.found).toBe(true); expect(before.credentials).toEqual([]);
      expect(before.links).toBe(0); expect(before.obsLinked).toBe(false);
      const blockedBefore = await counterBlocked(context, before.username, mode);
      const tab = new URL(page.url()).searchParams.get("tab_id"); expect(Boolean(tab)).toBe(true);
      expect((await context.request.post(`${probe}/continuation?tab=${tab}&mode=${mode}`)).status()).toBe(204);
      await page.locator('[name="sky-sign-up-credential-choice"][value="password"]').click();
      // Capture durable effects before the terminal assertions, so an unexpected redirect
      // cannot hide a new credential/link. Native tab cleanup and LOGIN counter reset are
      // observed separately; their values are not assumed to be unchanged.
      const after = await person(context, email);
      const continuation = await (await context.request.get(`${probe}/continuation?tab=${tab}`)).json();
      const blockedAfter = await counterBlocked(context, after.username, mode);
      console.log("B10 invalid capsule effects:", JSON.stringify({ mode,
        credentialsBefore: before.credentials.length, credentialsAfter: after.credentials.length,
        linksBefore: before.links, linksAfter: after.links, obsBefore: before.obsLinked, obsAfter: after.obsLinked,
        userActionsBefore: before.requiredActions.length, userActionsAfter: after.requiredActions.length,
        authSessionFound: continuation.found, blockedBefore, blockedAfter }));
      expect(after.credentials).toEqual([]);
      expect(after.credentials).toEqual(before.credentials);
      expect(after.links).toBe(before.links); expect(after.obsLinked).toBe(before.obsLinked);
      await expect(page.locator("#kc-passwd-update-form")).toHaveCount(0);
      await page.waitForURL(url => url.origin + url.pathname === config.callbackUrl);
      refusedCallback(new URL(page.url()), auth);
      // Keycloak OIDCLoginProtocol.sendError removes this authentication-session tab.
      expect(continuation.found).toBe(false);
    }, [() => context.close()]);
  });
}

test("parallel different credential choices produce at most one native challenge and cannot reopen DONE", async ({ browser }) => {
  const { context, page } = await fixture(browser, false);
  await withCleanup(page, async () => {
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
  }, [() => context.close()]);
});
