import { createHash, createSign } from "node:crypto";
import { readFileSync } from "node:fs";
import { expect, test, type CDPSession, type Page, type Request } from "@playwright/test";

// End-to-end passkey (WebAuthn passwordless) ceremony against a real Keycloak: register a
// passkey through the sky-account SPI from an allowed my.-like origin, see it in GET identity,
// log in on Keycloak's own login page with it (proves RP-ID compatibility), sudo through a
// passkey assertion, then prove the refusals: a replayed challenge, a signature-counter
// regression, an assertion and a registration from an origin the policy does not allow, and
// (parent-domain run only) a page on another registrable domain that the browser itself stops.
//
// The harness runs this file twice. On localhost every party shares one host. The parent-domain
// run reproduces production, where my.yildizskylab.com and e.yildizskylab.com share the RP ID
// yildizskylab.com: the page is my.<parent>, Keycloak is e.<parent> (the realm frontend URL),
// and the RP ID is <parent>. The parent is a two-label name under the reserved .test TLD:
// browsers refuse a single-label RP ID such as "localtest" for my.localtest, because an RP ID
// must be a registrable domain. Chromium resolves the test names to 127.0.0.1 through
// --host-resolver-rules and treats them as secure contexts (production has TLS instead).

type IntegrationConfig = {
  /** Keycloak as the harness reaches it; every back-channel call (PAR, token, sky-account) uses it. */
  baseUrl: string;
  /** Keycloak as the browser reaches it (the realm frontend URL); defaults to baseUrl. */
  frontendUrl?: string;
  realm: string;
  callbackUrl: string;
  clientId: string;
  clientSecret: string;
  username: string;
  password: string;
  pageOrigin: string;
  disallowedOrigin: string;
  /** A page on another registrable domain than the RP ID (parent-domain run only). */
  foreignOrigin?: string;
  rpId: string;
  userId: string;
};

const configPath = process.env.WEBAUTHN_INTEGRATION_CONFIG;
if (configPath === undefined) {
  throw new Error("WEBAUTHN_INTEGRATION_CONFIG must point to the ephemeral integration config");
}
const config = JSON.parse(readFileSync(configPath, "utf8")) as IntegrationConfig;
const callback = new URL(config.callbackUrl);
const frontendUrl = config.frontendUrl ?? config.baseUrl;
const keycloakOrigin = new URL(frontendUrl).origin;
const tokenUrl = `${config.baseUrl}/realms/${config.realm}/protocol/openid-connect/token`;
const parUrl = `${config.baseUrl}/realms/${config.realm}/protocol/openid-connect/ext/par/request`;
const authUrl = `${frontendUrl}/realms/${config.realm}/protocol/openid-connect/auth`;
const api = `${config.baseUrl}/realms/${config.realm}/sky-account/v1`;
let requestSequence = 0;

// Every origin the browser opens that is not localhost: resolved to 127.0.0.1 (where Keycloak
// and the page server listen) and treated as a secure context, so the only rule left to refuse
// anything is WebAuthn's own RP ID check. The RP ID itself does not resolve: no related-origins
// list (/.well-known/webauthn) can vouch for the foreign page, so its refusal is deterministic.
// chrome-headless-shell ignores --unsafely-treat-insecure-origin-as-secure, so these runs use
// Chromium's new headless mode.
const testHosts = [
  ...new Set(
    [frontendUrl, config.pageOrigin, config.disallowedOrigin, config.foreignOrigin]
      .filter((origin): origin is string => origin !== undefined)
      .map(origin => new URL(origin))
      .filter(url => url.hostname !== "localhost")
      .map(url => url.hostname)
  )
];
if (testHosts.length > 0) {
  const secureOrigins = [frontendUrl, config.pageOrigin, config.disallowedOrigin, config.foreignOrigin]
    .filter((origin): origin is string => origin !== undefined)
    .map(origin => new URL(origin).origin);
  test.use({
    channel: "chromium",
    launchOptions: {
      args: [
        `--host-resolver-rules=${[...testHosts.map(host => `MAP ${host} 127.0.0.1`), `MAP ${config.rpId} ~NOTFOUND`].join(", ")}`,
        `--unsafely-treat-insecure-origin-as-secure=${[...new Set(secureOrigins)].join(",")}`
      ]
    }
  });
}

function base64UrlEncode(bytes: Buffer | Uint8Array): string {
  return Buffer.from(bytes).toString("base64url");
}

function withTimeout<T>(promise: Promise<T>, message: string, timeoutMs = 45_000): Promise<T> {
  let timeout: ReturnType<typeof setTimeout> | undefined;
  return Promise.race([
    promise,
    new Promise<never>((_resolve, reject) => {
      timeout = setTimeout(() => reject(new Error(message)), timeoutMs);
    })
  ]).finally(() => {
    if (timeout !== undefined) {
      clearTimeout(timeout);
    }
  });
}

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

/** The first login form post that carries a WebAuthn assertion, with its decoded clientDataJSON. */
function waitForAssertionPost(page: Page): Promise<{ url: string; clientData: Record<string, unknown> }> {
  return new Promise(resolve => {
    const onRequest = (request: Request) => {
      if (request.method() !== "POST") {
        return;
      }
      const clientDataJSON = new URLSearchParams(request.postData() ?? "").get("clientDataJSON");
      if (!clientDataJSON) {
        return;
      }
      page.off("request", onRequest);
      resolve({
        url: request.url(),
        clientData: JSON.parse(Buffer.from(clientDataJSON, "base64").toString("utf8")) as Record<string, unknown>
      });
    };
    page.on("request", onRequest);
  });
}

async function parAuthorizationUrl(): Promise<{ state: string; url: string; verifier: string }> {
  const state = `passkey-${++requestSequence}`;
  const verifier = `sky-account-passkey-${state}-verifier-0123456789abcdefghijklmnop`;
  const challenge = createHash("sha256").update(verifier).digest("base64url");
  const body = new URLSearchParams({
    client_id: config.clientId,
    response_type: "code",
    scope: "openid",
    redirect_uri: config.callbackUrl,
    code_challenge: challenge,
    code_challenge_method: "S256",
    state,
    nonce: `${state}-nonce`,
    ui_locales: "tr"
  });
  const response = await fetch(parUrl, {
    method: "POST",
    headers: {
      authorization: `Basic ${Buffer.from(`${config.clientId}:${config.clientSecret}`).toString("base64")}`,
      "content-type": "application/x-www-form-urlencoded"
    },
    body
  });
  const payload = JSON.parse(await response.text()) as { request_uri: string };
  return {
    state,
    verifier,
    url: `${authUrl}?client_id=${encodeURIComponent(config.clientId)}&request_uri=${encodeURIComponent(payload.request_uri)}`
  };
}

/** A full password login through Keycloak's own form, returning the Account Center tokens. */
async function passwordLogin(page: Page): Promise<{ accessToken: string; sessionId: string }> {
  const callbackReached = waitForCallbackRequest(page);
  const authorization = await parAuthorizationUrl();
  await page.goto(authorization.url);
  await expect(page.locator(".sl-legacy-shell")).toBeVisible();
  // The theme opens on a choice screen; the password form is behind "YTÜ Öğrencisi Değilim".
  // Wait for whichever renders first instead of probing visibility before hydration.
  const passwordChoice = page.getByRole("button", { name: "YTÜ Öğrencisi Değilim" });
  const username = page.locator("#username");
  await expect(passwordChoice.or(username).first()).toBeVisible();
  if (await passwordChoice.isVisible()) {
    await passwordChoice.click();
  }
  await username.fill(config.username);
  await page.locator("#password").fill(config.password);
  await page.locator("#kc-login").click();
  const callbackUrl = await withTimeout(callbackReached, "Keycloak did not complete the password login");
  // The callback host is the public Account Center; stop the outbound load before reusing the page.
  await page.goto("about:blank", { waitUntil: "commit" });
  const code = new URL(callbackUrl).searchParams.get("code");
  expect(code, "the login callback carries an authorization code").not.toBeNull();
  const tokens = await exchangeCode(code as string, authorization.verifier);
  return { accessToken: tokens.access_token, sessionId: decodeJwt(tokens.id_token).sid as string };
}

async function exchangeCode(code: string, verifier: string): Promise<{ access_token: string; id_token: string }> {
  const response = await fetch(tokenUrl, {
    method: "POST",
    headers: {
      authorization: `Basic ${Buffer.from(`${config.clientId}:${config.clientSecret}`).toString("base64")}`,
      "content-type": "application/x-www-form-urlencoded"
    },
    body: new URLSearchParams({
      grant_type: "authorization_code",
      client_id: config.clientId,
      code,
      redirect_uri: config.callbackUrl,
      code_verifier: verifier
    })
  });
  const body = await response.text();
  expect(response.ok, body).toBe(true);
  return JSON.parse(body) as { access_token: string; id_token: string };
}

function decodeJwt(token: string): Record<string, unknown> {
  return JSON.parse(Buffer.from(token.split(".")[1], "base64url").toString("utf8")) as Record<string, unknown>;
}

type SkyResponse = { status: number; body: Record<string, unknown> };

async function sky(
  method: string,
  path: string,
  options: { bearer?: string; sudo?: string; json?: unknown } = {}
): Promise<SkyResponse> {
  const headers: Record<string, string> = {};
  if (options.bearer) {
    headers.authorization = `Bearer ${options.bearer}`;
  }
  if (options.sudo) {
    headers["x-sky-sudo"] = options.sudo;
  }
  if (options.json !== undefined) {
    headers["content-type"] = "application/json";
  }
  const response = await fetch(`${api}/${path}`, {
    method,
    headers,
    body: options.json === undefined ? undefined : JSON.stringify(options.json)
  });
  const text = await response.text();
  return { status: response.status, body: text ? (JSON.parse(text) as Record<string, unknown>) : {} };
}

async function passwordSudo(accessToken: string): Promise<string> {
  const result = await sky("POST", "sudo/password", { bearer: accessToken, json: { password: config.password } });
  expect(result.status, JSON.stringify(result.body)).toBe(200);
  return result.body.sudoToken as string;
}

test(`passkey registration, Keycloak login, sudo and the required refusals (rpId ${config.rpId})`, async ({ browser }) => {
  test.setTimeout(300_000);
  // The page and Keycloak both sit at or under the RP ID. The parent-domain run must keep them
  // two distinct subdomains of it, or it would silently fall back to the one-host case.
  const pageHost = new URL(config.pageOrigin).hostname;
  const keycloakHost = new URL(keycloakOrigin).hostname;
  for (const host of [pageHost, keycloakHost]) {
    expect(host === config.rpId || host.endsWith(`.${config.rpId}`), `${host} is not under ${config.rpId}`).toBe(true);
  }
  if (config.foreignOrigin !== undefined) {
    expect(pageHost).not.toBe(keycloakHost);
    expect([pageHost, keycloakHost]).not.toContain(config.rpId);
  }
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

  const { accessToken, sessionId } = await passwordLogin(page);
  expect(sessionId).toBeTruthy();
  let acceptedSignCount = 0;
  let registeredCredentialId = "";

  await test.step("register a passkey through the SPI from an allowed origin", async () => {
    const sudo = await passwordSudo(accessToken);
    const options = await sky("POST", "credentials/webauthn/options", { bearer: accessToken, sudo });
    expect(options.status, JSON.stringify(options.body)).toBe(200);
    expect((options.body.rp as Record<string, unknown>).id).toBe(config.rpId);

    await page.goto(`${config.pageOrigin}/`);
    const credential = await page.evaluate(
      opts => (window as unknown as { skyRegister: (o: unknown) => Promise<unknown> }).skyRegister(opts),
      options.body
    );
    registeredCredentialId = (credential as { rawId: string }).rawId;
    const registered = await sky("POST", "credentials/webauthn/register", {
      bearer: accessToken,
      sudo,
      json: { ...(credential as Record<string, unknown>), label: "CI virtual passkey" }
    });
    expect(registered.status, JSON.stringify(registered.body)).toBe(201);
    expect(registered.body.type).toBe("webauthn-passwordless");
    expect(registered.body.label).toBe("CI virtual passkey");
    expect(Array.isArray(registered.body.transports)).toBe(true);
    // The authenticator scoped the new passkey to the RP ID, not to the page's own host: on the
    // parent-domain run that is the parent, which is what lets e.<parent> use it below.
    const { credentials } = await cdp.send("WebAuthn.getCredentials", { authenticatorId });
    expect(credentials.map(stored => stored.rpId)).toEqual([config.rpId]);
  });

  await test.step("the new passkey appears in GET identity", async () => {
    const identity = await sky("GET", "identity", { bearer: accessToken });
    expect(identity.status).toBe(200);
    const passkeys = (identity.body.credentials as { passkeys: Array<Record<string, unknown>> }).passkeys;
    expect(passkeys).toHaveLength(1);
    expect(passkeys[0].label).toBe("CI virtual passkey");
    expect(typeof passkeys[0].id).toBe("string");
    expect(typeof passkeys[0].createdAt).toBe("string");
  });

  await test.step("log in on Keycloak's own login page with that passkey", async () => {
    await context.clearCookies();
    const callbackReached = waitForCallbackRequest(page);
    const credentialAsserted = new Promise<{ authenticatorId: string }>(resolve =>
      cdp.once("WebAuthn.credentialAsserted", payload => resolve(payload as { authenticatorId: string }))
    );
    const assertionPosted = waitForAssertionPost(page);
    const authorization = await parAuthorizationUrl();
    await page.goto(authorization.url);
    // Keycloak's conditional (autofill) ceremony discovers the resident passkey by itself on a
    // supporting browser and may complete, and navigate, before any probe of the page runs; so
    // do not touch the page: wait for the assertion event, and only fall back to the explicit
    // button when the conditional ceremony did not complete promptly.
    let asserted: { authenticatorId: string } | null = await Promise.race([
      credentialAsserted,
      new Promise<null>(resolve => setTimeout(() => resolve(null), 20_000))
    ]);
    if (asserted === null) {
      const passkeyButton = page.locator("#authenticateWebAuthnButton");
      await expect(passkeyButton).toBeVisible();
      await passkeyButton.click();
      asserted = await withTimeout(credentialAsserted, "Keycloak did not assert the SPI-registered passkey");
    }
    const callbackUrl = await withTimeout(callbackReached, "Keycloak's passkey login did not reach the callback");
    expect(asserted.authenticatorId).toBe(authenticatorId);
    expect(new URL(callbackUrl).searchParams.get("code")).toBeTruthy();
    // The assertion Keycloak accepted was made on Keycloak's own origin (e.<parent> on the
    // parent-domain run) for a passkey registered on the page origin (my.<parent>).
    const posted = await withTimeout(assertionPosted, "Keycloak's login page did not post a passkey assertion");
    expect(new URL(posted.url).origin).toBe(keycloakOrigin);
    expect(posted.clientData.type).toBe("webauthn.get");
    expect(posted.clientData.origin).toBe(keycloakOrigin);
    expect(posted.clientData.origin).not.toBe(new URL(config.pageOrigin).origin);
    await page.goto("about:blank", { waitUntil: "commit" });
  });

  await test.step("sudo through a passkey assertion, and refuse a replayed challenge", async () => {
    const options = await sky("POST", "sudo/webauthn/options", { bearer: accessToken });
    expect(options.status, JSON.stringify(options.body)).toBe(200);
    expect(options.body.rpId).toBe(config.rpId);

    await page.goto(`${config.pageOrigin}/`);
    const assertion = await page.evaluate(
      opts => (window as unknown as { skyAuthenticate: (o: unknown) => Promise<unknown> }).skyAuthenticate(opts),
      options.body
    );
    const verified = await sky("POST", "sudo/webauthn/verify", { bearer: accessToken, json: assertion });
    expect(verified.status, JSON.stringify(verified.body)).toBe(200);
    expect(typeof verified.body.sudoToken).toBe("string");
    expect(new Date(verified.body.expiresAt as string).getTime()).toBeGreaterThan(Date.now());
    // Remember the counter Keycloak just accepted and persisted; replaying it must be refused.
    acceptedSignCount = readSignCount((assertion as { response: { authenticatorData: string } }).response.authenticatorData);

    const replayed = await sky("POST", "sudo/webauthn/verify", { bearer: accessToken, json: assertion });
    expect(replayed.status).toBe(400);
    expect(replayed.body.code).toBe("webauthn_challenge_expired");
  });

  await test.step("refuse a signature-counter regression", async () => {
    const exported = await exportCredential(cdp, authenticatorId, registeredCredentialId);
    const options = await sky("POST", "sudo/webauthn/options", { bearer: accessToken });
    expect(options.status).toBe(200);
    // Re-present the exact counter Keycloak stored: a non-advancing counter must be refused.
    const forged = forgeAssertion(exported, options.body.challenge as string, config.pageOrigin, acceptedSignCount);
    const refused = await sky("POST", "sudo/webauthn/verify", { bearer: accessToken, json: forged });
    expect(refused.status, JSON.stringify(refused.body)).toBe(401);
    expect(refused.body.code).toBe("webauthn_invalid");
  });

  await test.step("refuse an assertion made on an origin the policy does not allow", async () => {
    const options = await sky("POST", "sudo/webauthn/options", { bearer: accessToken });
    expect(options.status).toBe(200);
    // Same RP ID, so the browser signs (on the parent-domain run this is a sibling subdomain
    // such as other.<parent>); only the server's origin list can refuse it.
    await page.goto(`${config.disallowedOrigin}/`);
    const assertion = await page.evaluate(
      opts => (window as unknown as { skyAuthenticate: (o: unknown) => Promise<unknown> }).skyAuthenticate(opts),
      options.body
    );
    const refused = await sky("POST", "sudo/webauthn/verify", { bearer: accessToken, json: assertion });
    expect(refused.status, JSON.stringify(refused.body)).toBe(401);
    expect(refused.body.code).toBe("webauthn_origin_not_allowed");
  });

  if (config.foreignOrigin !== undefined) {
    const foreignOrigin = config.foreignOrigin;
    await test.step("a page on another registrable domain cannot use or create the passkey", async () => {
      const before = await cdp.send("WebAuthn.getCredentials", { authenticatorId });
      await page.goto(`${foreignOrigin}/`);
      // A secure context like the allowed pages, so what refuses below is the RP ID rule alone.
      expect(await page.evaluate(() => window.isSecureContext)).toBe(true);

      const assertionOptions = await sky("POST", "sudo/webauthn/options", { bearer: accessToken });
      expect(assertionOptions.status).toBe(200);
      const asserted = await page.evaluate(async opts => {
        try {
          await (window as unknown as { skyAuthenticate: (o: unknown) => Promise<unknown> }).skyAuthenticate(opts);
          return "asserted";
        } catch (error) {
          return `${(error as Error).name}: ${(error as Error).message}`;
        }
      }, assertionOptions.body);
      expect(asserted).toMatch(/^SecurityError: /);

      const sudo = await passwordSudo(accessToken);
      const creationOptions = await sky("POST", "credentials/webauthn/options", { bearer: accessToken, sudo });
      expect(creationOptions.status).toBe(200);
      const created = await page.evaluate(async opts => {
        try {
          await (window as unknown as { skyRegister: (o: unknown) => Promise<unknown> }).skyRegister(opts);
          return "created";
        } catch (error) {
          return `${(error as Error).name}: ${(error as Error).message}`;
        }
      }, { ...creationOptions.body, excludeCredentials: [] });
      expect(created).toMatch(/^SecurityError: /);

      // Nothing was signed or stored: same credentials, same signature counters.
      const after = await cdp.send("WebAuthn.getCredentials", { authenticatorId });
      const summary = (list: typeof before) =>
        list.credentials.map(stored => `${stored.credentialId}:${stored.rpId}:${stored.signCount}`).sort();
      expect(summary(after)).toEqual(summary(before));
    });
  }

  await test.step("refuse a registration attested on an origin the policy does not allow", async () => {
    const sudo = await passwordSudo(accessToken);
    const options = await sky("POST", "credentials/webauthn/options", { bearer: accessToken, sudo });
    expect(options.status).toBe(200);
    await page.goto(`${config.disallowedOrigin}/`);
    // The authenticator already holds the registered passkey, which the SPI lists in
    // excludeCredentials; drop that client-side hint so the browser runs the ceremony and
    // the refusal below can only come from the server-side origin check. This runs last:
    // the new resident credential may replace the earlier one inside the authenticator.
    const credential = await page.evaluate(
      opts => (window as unknown as { skyRegister: (o: unknown) => Promise<unknown> }).skyRegister(opts),
      { ...options.body, excludeCredentials: [] }
    );
    const refused = await sky("POST", "credentials/webauthn/register", {
      bearer: accessToken,
      sudo,
      json: { ...(credential as Record<string, unknown>), label: "Rogue origin" }
    });
    expect(refused.status).toBe(400);
    expect(refused.body.code).toBe("webauthn_origin_not_allowed");
  });

  await cdp.send("WebAuthn.removeVirtualAuthenticator", { authenticatorId });
  await cdp.send("WebAuthn.disable");
  await context.close();
});

type ExportedCredential = { credentialId: string; privateKeyPem: string };

/** The 32-bit big-endian signature counter at bytes 33..37 of authenticatorData. */
function readSignCount(authenticatorDataBase64Url: string): number {
  return Buffer.from(authenticatorDataBase64Url, "base64url").readUInt32BE(33);
}

/** The registered passkey inside the virtual authenticator; its private key lets us forge a regressed assertion. */
async function exportCredential(
  cdp: CDPSession,
  authenticatorId: string,
  credentialIdBase64Url: string
): Promise<ExportedCredential> {
  const { credentials } = await cdp.send("WebAuthn.getCredentials", { authenticatorId });
  const credential = credentials.find(
    candidate => Buffer.from(candidate.credentialId, "base64").toString("base64url") === credentialIdBase64Url
  );
  expect(credential, "the registered passkey is still inside the virtual authenticator").toBeDefined();
  if (credential === undefined) {
    throw new Error("unreachable");
  }
  const privateKeyPem = `-----BEGIN PRIVATE KEY-----\n${(credential.privateKey.match(/.{1,64}/g) ?? []).join("\n")}\n-----END PRIVATE KEY-----\n`;
  return {
    credentialId: Buffer.from(credential.credentialId, "base64").toString("base64url"),
    privateKeyPem
  };
}

/** A cryptographically valid assertion whose only defect is a non-advancing signature counter. */
function forgeAssertion(
  credential: ExportedCredential,
  challenge: string,
  origin: string,
  signCount: number
): Record<string, unknown> {
  const clientData = Buffer.from(
    JSON.stringify({ type: "webauthn.get", challenge, origin, crossOrigin: false }),
    "utf8"
  );
  const rpIdHash = createHash("sha256").update(config.rpId).digest();
  const flags = Buffer.from([0x05]); // user present + user verified
  const counter = Buffer.alloc(4);
  counter.writeUInt32BE(signCount >>> 0);
  const authenticatorData = Buffer.concat([rpIdHash, flags, counter]);
  const signed = Buffer.concat([authenticatorData, createHash("sha256").update(clientData).digest()]);
  const signature = createSign("SHA256").update(signed).end().sign(credential.privateKeyPem);
  return {
    id: credential.credentialId,
    rawId: credential.credentialId,
    type: "public-key",
    response: {
      clientDataJSON: base64UrlEncode(clientData),
      authenticatorData: base64UrlEncode(authenticatorData),
      signature: base64UrlEncode(signature),
      userHandle: base64UrlEncode(Buffer.from(config.userId, "utf8"))
    }
  };
}
