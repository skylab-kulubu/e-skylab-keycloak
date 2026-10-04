import { describe, expect, it } from "vitest";
import packageJson from "../../package.json";
import cmsTeams from "./teams.json";
import { teams } from "./teams";

describe("login page team strips", () => {
  it("lists the CMS teams in CMS order, then the teams and events the CMS does not hold", () => {
    expect(teams.map(team => team.slug)).toEqual([...cmsTeams.slugs, "gdg", "skymedya", "gecekodu", "bizbize", "skylab"]);
  });

  it("has a logo file for every team it knows", () => {
    for (const team of teams) {
      expect(team.logo, team.slug).toBeTruthy();
      expect(team.name, team.slug).not.toBe("");
    }
  });

  it("never calls the CMS while building: CI and the release image ship the committed list", () => {
    const scripts: Record<string, string> = packageJson.scripts;
    for (const name of ["prebuild", "build", "postbuild", "build-keycloak-theme", "prebuild-keycloak-theme"]) {
      expect(scripts[name] ?? "", name).not.toMatch(/fetch-teams|npm run teams/);
    }
  });
});
