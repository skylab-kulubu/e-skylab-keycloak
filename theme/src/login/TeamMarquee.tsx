import { teams, type Team } from "./teams";

/** The strip's loop length; legacy-login.css `.sl-legacy-teams__track` runs this long (themeContract.test.ts). */
export const TEAM_MARQUEE_SECONDS = 70;

/**
 * Where the loop stands, read from the wall clock, so every step's page picks the strips up where
 * the previous page left them instead of starting over. Read once per page load.
 */
const phaseDelay = `${-((Date.now() / 1000) % TEAM_MARQUEE_SECONDS).toFixed(2)}s`;

/**
 * A slow, endless strip of SKY LAB team logos above or below the login card.
 * The track holds the list twice and slides by one copy, so the loop has no
 * seam. Decoration only: hidden from assistive technology, still with reduced
 * motion, gone in forced colors.
 */
export default function TeamMarquee(props: { direction: "left" | "right" }) {
  const row = props.direction === "left" ? teams : [...teams].reverse();

  return (
    <div className={`sl-legacy-teams sl-legacy-teams--${props.direction}`} aria-hidden="true">
      <div className="sl-legacy-teams__track" style={{ animationDelay: phaseDelay }}>
        {[...row, ...row].map((team: Team, index) => (
          <span key={`${team.slug}-${index}`} className="sl-legacy-teams__item">
            {team.logo === undefined ? team.name : <img src={team.logo} alt="" decoding="async" />}
          </span>
        ))}
      </div>
    </div>
  );
}
