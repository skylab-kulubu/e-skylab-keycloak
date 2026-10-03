import { describe, expect, it } from "vitest";
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
});
