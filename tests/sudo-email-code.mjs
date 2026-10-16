// Local-only real Keycloak acceptance of Sudo e-mail codes. The wrapper owns every container.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { execFileSync, spawnSync } from "node:child_process";

const base = process.env.SUDO_EMAIL_BASE_URL;
assert.match(base ?? "", /^http:\/\/127\.0\.0\.1:[0-9]+$/);
const realm = `sudo-email-test-${process.pid}`;
const password = "sudo-harness-password";
const secret = "sudo-harness-client-secret";
const mailerSecret = "sudo-harness-mailer-secret";
const container = process.env.SUDO_EMAIL_SKYMAIL_CONTAINER;
const mailUrl = process.env.SUDO_EMAIL_MAIL_URL;
const api = `${base}/realms/${realm}/sky-account/v1`;
const cases = [];
let adminToken;
const issuedCodes = [];
const fixtureAddresses = [];
const sleep = (ms) => new Promise(resolve => setTimeout(resolve, ms));
async function jsonRequest(url, { method = "GET", token, body, form, expected = 200 } = {}) {
  const response = await fetch(url, { method, headers: {
    ...(token ? { authorization: `Bearer ${token}` } : {}),
    ...(body !== undefined ? { "content-type": "application/json" } : {}),
  }, ...(body !== undefined ? { body: JSON.stringify(body) } : {}), ...(form ? { body: new URLSearchParams(form) } : {}) });
  const text = await response.text();
  let value; try { value = text ? JSON.parse(text) : null; } catch { value = null; }
  assert.equal(response.status, expected, `${method} ${new URL(url).pathname}: expected ${expected}, got ${response.status} (${value?.code ?? value?.error ?? "no problem code"})`);
  return value;
}
const admin = (path, options = {}) => jsonRequest(`${base}/admin/realms/${realm}/${path}`, { token: adminToken, ...options });
const sky = (person, path, { method = "POST", body, expected = 200 } = {}) => jsonRequest(`${api}/${path}`, { method, token: person.token, body, expected });
async function skySudo(person, path, body, sudo, expected = 200) {
  const response = await fetch(`${api}/${path}`, { method: "POST", headers: { authorization: `Bearer ${person.token}`, "x-sky-sudo": sudo, "content-type": "application/json" }, body: JSON.stringify(body) });
  const value = await response.json();
  assert.equal(response.status, expected, `${path}: ${response.status} (${value?.code ?? "no problem code"})`);
  return value;
}
async function tokenFor(username) {
  return jsonRequest(`${base}/realms/${realm}/protocol/openid-connect/token`, { method: "POST", form: { grant_type: "password", client_id: "account-center", client_secret: secret, username, password } });
}
async function person(label, { second = false, keepPassword = false, fallback = false } = {}) {
  const username = `sudo-${label}`;
  const email = `${fallback ? "skymail-fallback" : username}@example.invalid`;
  await admin("users", { method: "POST", expected: 201, body: { username, email, emailVerified: true, enabled: true, firstName: "Sudo", lastName: "Fixture", credentials: [{ type: "password", value: password, temporary: false }] } });
  const [user] = await admin(`users?username=${username}&exact=true`);
  fixtureAddresses.push(email);
  const tokens = await tokenFor(username);
  const other = second ? await tokenFor(username) : null;
  if (!keepPassword) {
    for (const credential of await admin(`users/${user.id}/credentials`)) {
      await admin(`users/${user.id}/credentials/${credential.id}`, { method: "DELETE", expected: 204 });
    }
  }
  return { id: user.id, username, email, token: tokens.access_token, other: other?.access_token };
}
function tasks() {
  return execFileSync("docker", ["logs", container], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).split("\n").filter(line => line.startsWith("SKYMAIL_FIXTURE ")).map(line => JSON.parse(line.slice(16))).filter(value => value.event === "mail_task");
}
async function send(person) {
  const before = tasks().length;
  await sky(person, "sudo/email-code/send", { body: {}, expected: 202 });
  let task;
  for (let i = 0; i < 30; i++) {
    task = tasks().slice(before).find(value => value.recipient_email === person.email);
    if (task) break;
    await sleep(100);
  }
  assert.ok(task, "Sudo mail task did not reach the isolated SkyMail fixture");
  assert.equal(task.template_key, "keycloak.login-code");
  assert.equal(task.body_variables.purpose, "sudo");
  assert.equal(task.body_variables.subjectKey, "skySudoCodeSubject");
  assert.equal(task.body_variables.codeExpirationMinutes, "10");
  assert.equal(task.body_variables.link, "");
  assert.match(task.body_variables.code, /^[0-9]{6}$/);
  issuedCodes.push(task.body_variables.code);
  return task.body_variables.code;
}
const verify = (person, code, expected = 200) => sky(person, "sudo/email-code/verify", { body: { code }, expected });
const claims = token => JSON.parse(Buffer.from(token.split(".")[1], "base64url").toString());
const check = name => { cases.push(name); console.log(`PASS ${name}`); };

const pageServer = createServer((request, response) => response.end("<!doctype html><html lang='en'><title>Local Sudo passkey fixture</title><body>Passkey test</body></html>"));
await new Promise(resolve => pageServer.listen(0, "127.0.0.1", resolve));
const pageOrigin = `http://localhost:${pageServer.address().port}`;
let browser;
try {
  adminToken = (await jsonRequest(`${base}/realms/master/protocol/openid-connect/token`, { method: "POST", form: { grant_type: "password", client_id: "admin-cli", username: "admin", password: process.env.SUDO_EMAIL_ADMIN_PASSWORD ?? "sudo-harness-admin" } })).access_token;
  const security = JSON.parse(await readFile(new URL("../config/account-center-realm-security.json", import.meta.url), "utf8"));
  await jsonRequest(`${base}/admin/realms`, { method: "POST", token: adminToken, expected: 201, body: {
    realm, enabled: true, sslRequired: "none", registrationAllowed: false, loginWithEmailAllowed: true,
    eventsEnabled: true, adminEventsEnabled: true, defaultLocale: "tr", supportedLocales: ["tr", "en"], internationalizationEnabled: true,
    accessTokenLifespan: 3600, ssoSessionIdleTimeout: 7200, ssoSessionMaxLifespan: 7200,
    ...security, quickLoginCheckMilliSeconds: 0, minimumQuickLoginWaitSeconds: 0,
    smtpServer: { host: process.env.SUDO_EMAIL_MAIL_CONTAINER, port: "1025", from: "fixture@example.invalid" },
    webAuthnPolicyPasswordlessRpEntityName: "SKY LAB", webAuthnPolicyPasswordlessRpId: "localhost",
    webAuthnPolicyPasswordlessExtraOrigins: [pageOrigin], webAuthnPolicyPasswordlessSignatureAlgorithms: ["ES256", "RS256"],
    webAuthnPolicyPasswordlessResidentKey: "required", webAuthnPolicyPasswordlessUserVerificationRequirement: "required",
  } });
  // Only this isolated fixture enables Direct Grants, avoiding unrelated login/signup UI tours.
  await admin("clients", { method: "POST", expected: 201, body: { clientId: "account-center", enabled: true, publicClient: false, secret, directAccessGrantsEnabled: true, standardFlowEnabled: false, fullScopeAllowed: true, protocolMappers: [
    { name: "account-audience", protocol: "openid-connect", protocolMapper: "oidc-audience-mapper", config: { "included.client.audience": "account", "access.token.claim": "true", "id.token.claim": "false" } },
  ] } });
  await admin("clients", { method: "POST", expected: 201, body: { clientId: "skymail", enabled: true, publicClient: false, bearerOnly: true } });
  const [mailClient] = await admin("clients?clientId=skymail");
  const roles = [];
  for (const name of ["skymail:access", "skymail:mails:send"]) {
    await admin(`clients/${mailClient.id}/roles`, { method: "POST", expected: 201, body: { name } });
    roles.push(await admin(`clients/${mailClient.id}/roles/${encodeURIComponent(name)}`));
  }
  await admin("clients", { method: "POST", expected: 201, body: { clientId: "keycloak-mailer", enabled: true, publicClient: false, secret: mailerSecret, serviceAccountsEnabled: true, standardFlowEnabled: false } });
  const [mailerClient] = await admin("clients?clientId=keycloak-mailer");
  const serviceAccount = await admin(`clients/${mailerClient.id}/service-account-user`);
  await admin(`users/${serviceAccount.id}/role-mappings/clients/${mailClient.id}`, { method: "POST", expected: 204, body: roles });
  await admin("identity-provider/instances", { method: "POST", expected: 201, body: { alias: "OBS", providerId: "oidc", enabled: true, config: { clientId: "unused", clientSecret: "unused", authorizationUrl: "http://127.0.0.1:9/auth", tokenUrl: "http://127.0.0.1:9/token", disableUserInfo: "true", validateSignature: "false" } } });

  const eligible = await person("eligible", { second: true });
  assert.equal((await sky(eligible, "identity", { method: "GET" })).sudoEmailCodeAvailable, true);
  const code = await send(eligible);
  assert.equal((await verify({ ...eligible, token: eligible.other }, code, 404)).code, "no_pending_sudo_email_code");
  const foreign = await person("foreign");
  assert.equal((await verify(foreign, code, 404)).code, "no_pending_sudo_email_code");
  const grant = await verify(eligible, code);
  const proof = claims(grant.sudoToken), bearer = claims(eligible.token);
  assert.equal(proof.sub, eligible.id); assert.equal(proof.sid, bearer.sid); assert.equal(proof.exp - proof.iat, 300); assert.deepEqual(proof.amr, ["otp"]);
  assert.equal((await verify(eligible, code, 404)).code, "no_pending_sudo_email_code");
  check("six digits, current primary, foreign user/sid rejection, single use and 5-minute HMAC grant");

  // A real virtual passkey is added using the e-mail Sudo grant.
  const { chromium } = await import(process.env.SUDO_EMAIL_PLAYWRIGHT_MODULE ?? "@playwright/test");
  browser = await chromium.launch({ headless: true });
  const context = await browser.newContext();
  const page = await context.newPage();
  const cdp = await context.newCDPSession(page);
  await cdp.send("WebAuthn.enable");
  await cdp.send("WebAuthn.addVirtualAuthenticator", { options: { protocol: "ctap2", transport: "internal", hasResidentKey: true, hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true } });
  await page.goto(pageOrigin);
  const options = await skySudo(eligible, "credentials/webauthn/options", {}, grant.sudoToken);
  const attestation = await page.evaluate(async options => {
    const decode = value => Uint8Array.from(atob(value.replace(/-/g, "+").replace(/_/g, "/")), c => c.charCodeAt(0)).buffer;
    const encode = buffer => btoa(String.fromCharCode(...new Uint8Array(buffer))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
    const credential = await navigator.credentials.create({ publicKey: { ...options, challenge: decode(options.challenge), user: { ...options.user, id: decode(options.user.id) }, excludeCredentials: (options.excludeCredentials ?? []).map(value => ({ ...value, id: decode(value.id) })) } });
    return { id: credential.id, rawId: encode(credential.rawId), type: credential.type, authenticatorAttachment: credential.authenticatorAttachment, response: { clientDataJSON: encode(credential.response.clientDataJSON), attestationObject: encode(credential.response.attestationObject), transports: credential.response.getTransports() } };
  }, options);
  const registered = await skySudo(eligible, "credentials/webauthn/register", { ...attestation, label: "Sudo fixture passkey" }, grant.sudoToken, 201);
  assert.ok(registered.id);
  assert.equal((await sky(eligible, "identity", { method: "GET" })).sudoEmailCodeAvailable, false);
  assert.equal((await sky(eligible, "sudo/email-code/send", { body: {}, expected: 403 })).code, "sudo_email_not_allowed");
  await context.close(); await browser.close(); browser = null;
  check("e-mail Sudo adds a real virtual passkey; capability and mail route disappear");

  const disabled = await person("disabled"); const disabledCode = await send(disabled);
  await admin(`users/${disabled.id}`, { method: "PUT", expected: 204, body: { enabled: false } });
  assert.equal((await sky(disabled, "sudo/email-code/send", { body: {}, expected: 401 })).code, "unauthorized");
  assert.equal((await verify(disabled, disabledCode, 401)).code, "unauthorized");
  const loggedOut = await person("logged-out"); const logoutCode = await send(loggedOut);
  await admin(`users/${loggedOut.id}/logout`, { method: "POST", expected: 204 });
  assert.equal((await sky(loggedOut, "sudo/email-code/send", { body: {}, expected: 401 })).code, "unauthorized");
  assert.equal((await verify(loggedOut, logoutCode, 401)).code, "unauthorized");
  check("disabled user and revoked session refuse both sending and verification");

  const primary = await person("primary");
  const old = await send(primary);
  await admin(`users/${primary.id}`, { method: "PUT", expected: 204, body: { email: "changed-primary@example.invalid", emailVerified: true } });
  assert.equal((await verify(primary, old, 404)).code, "no_pending_sudo_email_code");
  await admin(`users/${primary.id}`, { method: "PUT", expected: 204, body: { email: primary.email, emailVerified: false } });
  assert.equal((await sky(primary, "sudo/email-code/send", { body: {}, expected: 409 })).code, "sudo_email_unavailable");
  assert.equal((await sky(primary, "identity", { method: "GET" })).sudoEmailCodeAvailable, false);
  check("primary replacement invalidates old code and an unverified primary fails closed");

  const pendingChange = await person("pending-change");
  const pendingProof = await verify(pendingChange, await send(pendingChange));
  const beforeChange = tasks().length;
  await skySudo(pendingChange, "email/change-request", { address: "pending-new-personal@example.invalid" }, pendingProof.sudoToken, 202);
  const changeTask = tasks().slice(beforeChange).find(value => value.template_key === "keycloak.personal-email-confirm");
  assert.equal(changeTask.recipient_email, "pending-new-personal@example.invalid");
  assert.equal((await sky(pendingChange, "identity", { method: "GET" })).email, pendingChange.email);
  await send(pendingChange);
  check("pending personal-email change does not replace the old current-primary Sudo destination");

  const factor = await person("factor");
  const stale = await send(factor);
  await admin(`users/${factor.id}/reset-password`, { method: "PUT", expected: 204, body: { type: "password", value: password, temporary: false } });
  assert.equal((await verify(factor, stale, 403)).code, "sudo_email_not_allowed");
  assert.equal((await sky(factor, "sudo/email-code/send", { body: {}, expected: 403 })).code, "sudo_email_not_allowed");
  check("factor added after delivery refuses send and verification");

  const linked = await person("linked");
  await admin(`users/${linked.id}/federated-identity/OBS`, { method: "POST", expected: 204, body: { identityProvider: "OBS", userId: "linked-fixture", userName: "linked-fixture" } });
  const linkedIdentity = await sky(linked, "identity", { method: "GET" });
  assert.equal(linkedIdentity.verifiedYtu, true); assert.equal(linkedIdentity.sudoEmailCodeAvailable, true);
  check("legacy OBS federated link keeps both Microsoft capability and e-mail capability");

  const attempts = await person("attempts");
  const first = await send(attempts); const wrong = first === "000000" ? "000001" : "000000";
  for (let left = 4; left >= 0; left--) assert.equal((await verify(attempts, wrong, 400)).attemptsLeft, left);
  assert.equal((await verify(attempts, first, 404)).code, "no_pending_sudo_email_code");
  let detection;
  for (let i = 0; i < 30; i++) { detection = await admin(`attack-detection/brute-force/users/${attempts.id}`); if (detection.numFailures >= 5) break; await sleep(100); }
  assert.ok(detection.numFailures >= 5);
  check("five wrong codes kill issuance and reach Keycloak brute-force counter");
  for (let i = 0; i < 4; i++) await verify(attempts, wrong, 404);
  assert.equal((await verify(attempts, wrong, 429)).code, "rate_limited");
  const budget = await person("budget");
  for (let i = 0; i < 3; i++) await send(budget);
  assert.equal((await sky(budget, "sudo/email-code/send", { body: {}, expected: 429 })).code, "rate_limited");
  check("3/hour delivery and shared 10/15-minute Sudo verification budgets");

  await jsonRequest(`${base}/admin/realms/${realm}`, { method: "PUT", token: adminToken, body: { failureFactor: 2 }, expected: 204 });
  const locked = await person("locked"); const lockCode = await send(locked);
  const lockWrong = lockCode === "000000" ? "000001" : "000000";
  await verify(locked, lockWrong, 400); await verify(locked, lockWrong, 400);
  let lockState;
  for (let i = 0; i < 30; i++) { lockState = await admin(`attack-detection/brute-force/users/${locked.id}`); if (lockState.disabled) break; await sleep(100); }
  assert.equal(lockState.disabled, true);
  assert.equal((await sky(locked, "sudo/email-code/send", { body: {}, expected: 401 })).code, "user_temporarily_locked");
  assert.equal((await verify(locked, lockCode, 401)).code, "user_temporarily_locked");
  await jsonRequest(`${base}/admin/realms/${realm}`, { method: "PUT", token: adminToken, body: { failureFactor: 10 }, expected: 204 });
  check("existing brute-force lock blocks both sending and the correct outstanding code");

  // The standalone wrapper explicitly registers an extra local clock module. CI/release
  // run the standard API suite and never register a clock test without its separate fixture.
  if (process.env.SUDO_EMAIL_CLOCK_PROBE_MODULE) {
    const { verifySudoEmailExpiry } = await import(process.env.SUDO_EMAIL_CLOCK_PROBE_MODULE);
    await verifySudoEmailExpiry({ base, realm, person, send, verify, jsonRequest });
    check("local clock-probe suite: real server beyond 10 minutes refuses stale code");
  }

  const smtp = await person("smtp", { fallback: true }); await send(smtp);
  const messages = await jsonRequest(`${mailUrl}/api/v1/messages?limit=50`);
  const found = messages.messages.find(message => message.To.some(to => to.Address === smtp.email));
  assert.ok(found);
  const message = await jsonRequest(`${mailUrl}/api/v1/message/${found.ID}`);
  assert.ok(message.Text.includes("bir işlemi onaylamak için kodun"));
  assert.ok(message.HTML.includes("bir işlemi onaylamak için kodun"));
  assert.equal(message.Subject, "SKY LAB hesap işlemi doğrulama kodun");
  assert.ok(!/[0-9]{6}/.test(message.Subject));
  check("SMTP fallback keeps dedicated Sudo subject/body without a code in the subject");
  if (process.env.SUDO_EMAIL_KEYCLOAK_CONTAINER) {
    const output = spawnSync("docker", ["logs", process.env.SUDO_EMAIL_KEYCLOAK_CONTAINER], { encoding: "utf8" });
    assert.equal(output.status, 0, "could not read owned Keycloak container logs");
    const logs = output.stdout + output.stderr;
    for (const address of fixtureAddresses) assert.ok(!logs.includes(address), "fixture address leaked into Keycloak logs");
    for (const code of issuedCodes) assert.ok(!logs.includes(`code=${code}`) && !logs.includes(`"code":"${code}"`), "verification code leaked into Keycloak logs");
    check("Keycloak logs contain no fixture mailbox address or structured verification code");
  }
  console.log(`PASS ${cases.length} real Keycloak Sudo acceptance groups`);
} finally {
  if (browser) await browser.close();
  if (adminToken) await fetch(`${base}/admin/realms/${realm}`, { method: "DELETE", headers: { authorization: `Bearer ${adminToken}` } }).catch(() => {});
  await new Promise(resolve => pageServer.close(resolve));
}
