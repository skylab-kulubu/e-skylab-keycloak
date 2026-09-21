// Prints the RFC 6238 code an authenticator app would show for a Base32 secret.
// usage: node totp-code.mjs <base32-secret> [step=0] [digits=6] [period=30] [algorithm=SHA1]
// `step` is an offset from the current time step, or an absolute counter when prefixed with `@`.
import { createHmac } from "node:crypto";

const BASE32_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

function base32Decode(encoded) {
  const clean = encoded.toUpperCase().replace(/=+$/u, "").replace(/\s+/gu, "");
  const bytes = [];
  let bits = 0;
  let value = 0;
  for (const char of clean) {
    const index = BASE32_ALPHABET.indexOf(char);
    if (index < 0) {
      throw new Error("invalid base32 input");
    }
    value = (value << 5) | index;
    bits += 5;
    if (bits >= 8) {
      bytes.push((value >>> (bits - 8)) & 0xff);
      bits -= 8;
    }
  }
  return Buffer.from(bytes);
}

const [secret, step = "0", digits = "6", period = "30", algorithm = "SHA1"] = process.argv.slice(2);
if (!secret) {
  console.error("usage: totp-code.mjs <base32-secret> [step] [digits] [period] [algorithm]");
  process.exit(2);
}

const counter = step.startsWith("@")
  ? Number(step.slice(1))
  : Math.floor(Date.now() / 1000 / Number(period)) + Number(step);
const message = Buffer.alloc(8);
message.writeBigUInt64BE(BigInt(counter));
const digest = createHmac(algorithm.toLowerCase(), base32Decode(secret)).update(message).digest();
const offset = digest[digest.length - 1] & 0x0f;
const binary =
  ((digest[offset] & 0x7f) << 24) |
  ((digest[offset + 1] & 0xff) << 16) |
  ((digest[offset + 2] & 0xff) << 8) |
  (digest[offset + 3] & 0xff);
const code = binary % 10 ** Number(digits);
process.stdout.write(String(code).padStart(Number(digits), "0") + "\n");
