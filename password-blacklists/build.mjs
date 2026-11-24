// Builds skylab-yaygin-parolalar.txt, the password denylist of the realm's passwordBlacklist policy
// (config/account-center-realm-security.json). The image ships the built file; this script only
// documents and reproduces it. Network: GitHub raw only, at a pinned commit, checked by SHA-256.
//
//   node password-blacklists/build.mjs           # writes the list
//   node password-blacklists/build.mjs --check   # fails if the committed list differs
//
// Sources (README.md has the licences):
//   - SecLists 100k-most-used-passwords-NCSC.txt (NCSC's top 100,000 from Have I Been Pwned)
//   - SecLists Turkish_Pwdb_common-password-list-top-150.txt (Pwdb-Public)
//   - turkce-ve-baglam.txt (ours): each root word with SUFFIXES
//
// Rules: lower case (Keycloak lower-cases both the list and the password), at least 8 characters
// (length(8) already refuses shorter ones), no empty line, no duplicate, sorted, LF line ends.
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const OUTPUT = join(HERE, "skylab-yaygin-parolalar.txt");
const SECLISTS_COMMIT = "fcde9140df969b1e4d7bb056122646dace4ed4cc";
const SECLISTS = `https://raw.githubusercontent.com/danielmiessler/SecLists/${SECLISTS_COMMIT}/Passwords/Common-Credentials`;
const SOURCES = [
  {
    url: `${SECLISTS}/100k-most-used-passwords-NCSC.txt`,
    sha256: "c2e5696882c603b76bb67a47ee970897e5a76fc4c3f5547abe3d0ca340c576e0",
  },
  {
    url: `${SECLISTS}/Language-Specific/Turkish_Pwdb_common-password-list-top-150.txt`,
    sha256: "9ea7f064c0448fe8c321edf8da56ea937862ffc3d97878cecbd2952635e10ccd",
  },
];
const MIN_LENGTH = 8;
const YEARS = Array.from({ length: 2027 - 1990 + 1 }, (_, i) => String(1990 + i));
const SUFFIXES = [
  "", "1", "12", "123", "1234", "12345", "123456", "123456789", "!", "123!", ".", "*", "_",
  "1453", "1903", "1905", "1907", "1911", "1919", "1923", "1967", "34", "06", "35",
  ...YEARS,
];

async function download({ url, sha256 }) {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`${url}: HTTP ${response.status}`);
  const bytes = Buffer.from(await response.arrayBuffer());
  const actual = createHash("sha256").update(bytes).digest("hex");
  if (actual !== sha256) throw new Error(`${url}: SHA-256 ${actual}, expected ${sha256}`);
  return bytes.toString("utf8");
}

function lines(text) {
  return text.split("\n").map(line => line.replace(/\r$/, ""));
}

const candidates = [];
for (const source of SOURCES) candidates.push(...lines(await download(source)));
for (const root of lines(readFileSync(join(HERE, "turkce-ve-baglam.txt"), "utf8"))) {
  if (root === "" || root.startsWith("#")) continue;
  for (const suffix of SUFFIXES) candidates.push(root + suffix);
}

const entries = [...new Set(
  candidates
    .filter(line => line.trim() !== "")
    .map(line => line.toLowerCase())
    .filter(line => [...line].length >= MIN_LENGTH),
)].sort();
const built = entries.join("\n") + "\n";

if (process.argv.includes("--check")) {
  if (readFileSync(OUTPUT, "utf8") !== built) {
    console.error(`${OUTPUT} differs from what build.mjs builds; run node password-blacklists/build.mjs`);
    process.exit(1);
  }
  console.log(`${OUTPUT}: ${entries.length} entries, up to date`);
} else {
  writeFileSync(OUTPUT, built);
  console.log(`${OUTPUT}: ${entries.length} entries, ${Buffer.byteLength(built)} bytes`);
}
