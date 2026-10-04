import cmsTeams from "./teams.json";

/** One logo in the login page's team strips */
export type Team = { slug: string; name: string; logo?: string };

// The logo files live in the theme, named by team slug, as on the main site;
// the CMS only says which teams exist and in what order.
const logos = import.meta.glob<string>("../assets/teams/*.{svg,webp}", { eager: true, query: "?url", import: "default" });
const logoBySlug = new Map(
  Object.entries(logos).map(([path, url]) => [path.slice(path.lastIndexOf("/") + 1, path.lastIndexOf(".")), url])
);

const NAMES: Record<string, string> = {
  airlab: "AIR LAB",
  algolab: "ALGOLAB",
  chainlab: "CHAINLAB",
  gamelab: "GAME LAB",
  mobilab: "MOBILAB",
  skysec: "SKY-SEC",
  skysis: "SKYSIS",
  weblab: "WEBLAB",
  gdg: "GDG",
  skymedya: "SKY MEDYA",
  gecekodu: "GECE KODU",
  bizbize: "BİZ BİZE",
  skylab: "SKY LAB"
};

/** Teams and club events that are not in the CMS teams collection but belong in the strips */
const FIXED = ["gdg", "skymedya", "gecekodu", "bizbize", "skylab"];

/**
 * The CMS teams (scripts/fetch-teams.mjs writes them into teams.json at build
 * time), then the fixed ones. A team without a logo file shows its name.
 */
export const teams: Team[] = [...new Set([...cmsTeams.slugs, ...FIXED])].map(slug => ({
  slug,
  name: NAMES[slug] ?? slug.toUpperCase(),
  logo: logoBySlug.get(slug)
}));
