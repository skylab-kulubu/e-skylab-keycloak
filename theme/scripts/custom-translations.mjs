// Reads the theme's custom translations the way `keycloakify build` does when it writes the
// login theme's messages_*.properties: it finds the i18n file (the shortest path under
// src/login whose source mentions the builder), takes the source text of the argument of
// `withCustomTranslations(...)` and evaluates it on its own, with nothing in scope. An
// argument that refers to anything else (a variable, an import, a spread) cannot be
// evaluated, and Keycloakify then only warns and leaves every custom text out of the
// server-side message bundles. Dependency-free, so CI can run it without node_modules.
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

/** The directory `keycloakify build` searches for the login theme's i18n file. */
export const LOGIN_SRC_DIR = fileURLToPath(new URL("../src/login/", import.meta.url));

const BUILDER_MARKER = "i18n" + "Builder";
const CALL = ".withCustomTranslations(";

function sourceFiles(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap(entry => {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) return sourceFiles(path);
    return /\.(js|ts|tsx)$/.test(entry.name) ? [path] : [];
  });
}

/** The file Keycloakify reads the translations from: the shortest path that mentions the builder. */
export function findI18nFile(loginSrcDir) {
  const candidates = sourceFiles(loginSrcDir)
    .sort((a, b) => a.length - b.length)
    .filter(file => readFileSync(file, "utf8").includes(BUILDER_MARKER));
  if (candidates.length === 0) throw new Error(`no i18n file under ${loginSrcDir}`);
  return candidates[0];
}

/** Source text of the first argument of the call that opens at `start` (just after its "("). */
function firstArgument(source, start) {
  let depth = 0;
  for (let i = start; i < source.length; i++) {
    const char = source[i];
    if (char === '"' || char === "'" || char === "`") {
      for (i++; i < source.length && source[i] !== char; i++) if (source[i] === "\\") i++;
    } else if (char === "/" && source[i + 1] === "/") {
      i = source.indexOf("\n", i);
      if (i === -1) break;
    } else if (char === "/" && source[i + 1] === "*") {
      i = source.indexOf("*/", i) + 1;
      if (i === 0) break;
    } else if (char === "(" || char === "{" || char === "[") {
      depth++;
    } else if (char === ")" || char === "}" || char === "]") {
      if (depth === 0) return source.slice(start, i);
      depth--;
    } else if (char === "," && depth === 0) {
      return source.slice(start, i);
    }
  }
  throw new Error(`unterminated ${CALL}...) call`);
}

/** The custom translations as Keycloakify sees them at build time; throws if it cannot see them. */
export function readCustomTranslations(i18nFile) {
  const source = readFileSync(i18nFile, "utf8");
  const at = source.indexOf(CALL);
  if (at === -1) throw new Error(`${i18nFile} has no ${CALL}...) call`);
  const argument = firstArgument(source, at + CALL.length).trim();
  try {
    return new Function(`"use strict"; return (${argument});`)();
  } catch (error) {
    throw new Error(
      `the argument of withCustomTranslations in ${i18nFile} cannot be statically evaluated ` +
        `(${error.message}); Keycloakify would leave every custom text out of messages_*.properties. ` +
        "Write the translations as one object literal inside the call."
    );
  }
}
