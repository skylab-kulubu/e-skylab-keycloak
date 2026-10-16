// Extra local acceptance module. The optimized-image CI suite never registers this probe.
import assert from "node:assert/strict";

export async function verifySudoEmailExpiry({ base, realm, person, send, verify, jsonRequest }) {
  const expires = await person("expires");
  const code = await send(expires);
  try {
    await jsonRequest(`${base}/realms/${realm}/sudo-email-clock/601`, { method: "POST" });
    assert.equal((await verify(expires, code, 404)).code, "no_pending_sudo_email_code");
  } finally {
    await jsonRequest(`${base}/realms/${realm}/sudo-email-clock/0`, { method: "POST" });
  }
}
