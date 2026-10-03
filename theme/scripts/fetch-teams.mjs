// Writes src/login/teams.json from the main site's CMS "teams" collection before
// every build: which R&D teams the login page's logo strips show, in CMS order.
// The file is committed, so a build that cannot reach the CMS keeps the last
// list and only warns; it never fails the theme build.
import { readFile, writeFile } from "node:fs/promises";

const url = process.env.SKYLAB_TEAMS_URL ?? "https://api.yildizskylab.com/api/cms/collections/teams?limit=50";
const clientId = process.env.SKYLAB_TEAMS_CLIENT_ID ?? "frontend-main";
const target = new URL("../src/login/teams.json", import.meta.url);
const SLUG = /^[a-z0-9]+(-[a-z0-9]+)*$/;

async function fetchSlugs() {
  const response = await fetch(url, {
    headers: { Accept: "application/json", "X-CMS-Client-Id": clientId },
    signal: AbortSignal.timeout(10_000)
  });
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  const body = await response.json();
  if (!Array.isArray(body?.items)) throw new Error("no items array");
  const slugs = body.items.map(item => item?.slug).filter(slug => typeof slug === "string" && SLUG.test(slug));
  if (slugs.length === 0) throw new Error("no teams");
  return [...new Set(slugs)];
}

try {
  const slugs = await fetchSlugs();
  const next = `${JSON.stringify({ slugs }, null, 2)}\n`;
  const current = await readFile(target, "utf8").catch(() => "");
  if (next !== current) await writeFile(target, next);
  console.log(`[teams] ${slugs.length} teams from the CMS`);
} catch (error) {
  console.warn(`[teams] CMS unreachable (${error.message}); keeping the committed src/login/teams.json`);
}
