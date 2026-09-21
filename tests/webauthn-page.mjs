// A tiny static page for the passkey integration ceremony. It serves the same document on
// two localhost origins: the one the fixture passwordless policy allows (18081) and one it
// does not (18082), so the harness can drive navigator.credentials.create/get from an allowed
// and a disallowed origin. The page only exposes base64url<->ArrayBuffer helpers and thin
// wrappers over the WebAuthn API; every option comes from the sky-account SPI and every result
// is handed straight back to the harness. localhost is a secure context, so no TLS is needed.
import { createServer } from "node:http";

const allowedPort = parsePort(process.env.WEBAUTHN_PAGE_PORT ?? "18081");
const disallowedPort = parsePort(process.env.WEBAUTHN_PAGE_DISALLOWED_PORT ?? "18082");

const PAGE = `<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>SKY LAB passkey ceremony harness</title></head>
<body>
<h1>SKY LAB passkey ceremony harness</h1>
<script>
  function fromBase64Url(value) {
    const padded = value.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((value.length + 3) % 4);
    const binary = atob(padded);
    const bytes = new Uint8Array(binary.length);
    for (let index = 0; index < binary.length; index += 1) {
      bytes[index] = binary.charCodeAt(index);
    }
    return bytes.buffer;
  }

  function toBase64Url(buffer) {
    const bytes = new Uint8Array(buffer);
    let binary = "";
    for (const byte of bytes) {
      binary += String.fromCharCode(byte);
    }
    return btoa(binary).replace(/\\+/g, "-").replace(/\\//g, "_").replace(/=+$/, "");
  }

  function mapDescriptors(list) {
    return (list ?? []).map(descriptor => ({
      type: descriptor.type,
      id: fromBase64Url(descriptor.id),
      ...(descriptor.transports ? { transports: descriptor.transports } : {})
    }));
  }

  // Runs navigator.credentials.create() with the SPI creation options and returns the
  // PublicKeyCredential as the JSON the BFF forwards to credentials/webauthn/register.
  window.skyRegister = async options => {
    const publicKey = {
      ...options,
      challenge: fromBase64Url(options.challenge),
      user: { ...options.user, id: fromBase64Url(options.user.id) },
      excludeCredentials: mapDescriptors(options.excludeCredentials)
    };
    const credential = await navigator.credentials.create({ publicKey });
    const response = credential.response;
    const transports = typeof response.getTransports === "function" ? response.getTransports() : [];
    return {
      id: credential.id,
      rawId: toBase64Url(credential.rawId),
      type: credential.type,
      authenticatorAttachment: credential.authenticatorAttachment ?? undefined,
      response: {
        clientDataJSON: toBase64Url(response.clientDataJSON),
        attestationObject: toBase64Url(response.attestationObject),
        ...(transports && transports.length > 0 ? { transports } : {})
      }
    };
  };

  // Runs navigator.credentials.get() with the SPI assertion options and returns the
  // PublicKeyCredential as the JSON the BFF forwards to sudo/webauthn/verify.
  window.skyAuthenticate = async options => {
    const publicKey = {
      challenge: fromBase64Url(options.challenge),
      rpId: options.rpId,
      allowCredentials: mapDescriptors(options.allowCredentials),
      ...(options.userVerification ? { userVerification: options.userVerification } : {})
    };
    const credential = await navigator.credentials.get({ publicKey });
    const response = credential.response;
    return {
      id: credential.id,
      rawId: toBase64Url(credential.rawId),
      type: credential.type,
      response: {
        clientDataJSON: toBase64Url(response.clientDataJSON),
        authenticatorData: toBase64Url(response.authenticatorData),
        signature: toBase64Url(response.signature),
        ...(response.userHandle ? { userHandle: toBase64Url(response.userHandle) } : {})
      }
    };
  };
</script>
</body>
</html>`;

function parsePort(value) {
  if (!/^[1-9][0-9]{1,4}$/.test(value)) {
    throw new Error("Expected a TCP port.");
  }
  return Number.parseInt(value, 10);
}

function handle(request, response) {
  response.setHeader("Cache-Control", "no-store");
  response.setHeader("Content-Type", "text/html; charset=utf-8");
  response.end(PAGE);
}

const servers = [allowedPort, disallowedPort].map(port => {
  const server = createServer(handle);
  server.listen(port, "127.0.0.1", () => {
    process.stdout.write(`WebAuthn ceremony page ready on http://localhost:${port}\n`);
  });
  return server;
});

function shutdown() {
  for (const server of servers) {
    server.close();
  }
}

process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);
