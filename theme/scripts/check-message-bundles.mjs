// Checks that the built login theme JAR carries every custom translation of src/login/i18n.ts
// in its Turkish and English message bundles, the only copy Keycloak itself reads (page-wide
// notices, field errors, info pages, the password policy sentences of Account Center).
//
//   node scripts/check-message-bundles.mjs dist_keycloak/e-skylab-theme-2.0.1.jar
//
// Dependency-free (unzip and Node only), so it also runs where node_modules is absent.
import { execFileSync } from "node:child_process";
import { findI18nFile, LOGIN_SRC_DIR, readCustomTranslations } from "./custom-translations.mjs";

const THEME_NAME = "e-skylab-theme";

/** java.util.Properties values, then MessageFormat's quoting ('' is one apostrophe). */
function parseProperties(text) {
  const unescape = value =>
    value
      .replace(/\\u([0-9a-fA-F]{4})/g, (_, hex) => String.fromCharCode(parseInt(hex, 16)))
      .replace(/\\(.)/g, (_, char) => ({ n: "\n", r: "\r", t: "\t" })[char] ?? char);
  const messages = new Map();
  for (const line of text.replace(/\\\r?\n[ \t]*/g, "").split(/\r?\n/)) {
    if (/^\s*([#!]|$)/.test(line)) continue;
    const match = line.match(/^\s*((?:\\.|[^=:\s\\])+)\s*[=:]?\s*(.*)$/);
    if (match) messages.set(unescape(match[1]), unescape(match[2]).replace(/''/g, "'"));
  }
  return messages;
}

const jar = process.argv[2];
if (!jar) {
  console.error("usage: check-message-bundles.mjs <theme.jar>");
  process.exit(64);
}

const translations = readCustomTranslations(findI18nFile(LOGIN_SRC_DIR));
const failures = [];

for (const lang of ["tr", "en"]) {
  const entry = `theme/${THEME_NAME}/login/messages/messages_${lang}.properties`;
  let bundle;
  try {
    bundle = parseProperties(execFileSync("unzip", ["-p", jar, entry], { encoding: "utf8" }));
  } catch {
    failures.push(`${entry} is missing from ${jar}`);
    continue;
  }
  for (const [key, text] of Object.entries(translations[lang] ?? {})) {
    if (!bundle.has(key)) failures.push(`${lang}: ${key} is missing from ${entry}`);
    else if (bundle.get(key) !== text) failures.push(`${lang}: ${key} is "${bundle.get(key)}", expected "${text}"`);
  }
}

if (failures.length > 0) {
  console.error(`theme message bundles lost the custom translations:\n  ${failures.slice(0, 20).join("\n  ")}`);
  if (failures.length > 20) console.error(`  ... and ${failures.length - 20} more`);
  process.exit(1);
}
console.log(`message bundles carry all ${Object.keys(translations.tr).length} custom translations in tr and en`);
