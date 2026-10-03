import { teams, type Team } from "./teams";

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
      <div className="sl-legacy-teams__track">
        {[...row, ...row].map((team: Team, index) => (
          <span key={`${team.slug}-${index}`} className="sl-legacy-teams__item">
            {team.logo === undefined ? team.name : <img src={team.logo} alt="" decoding="async" />}
          </span>
        ))}
      </div>
    </div>
  );
}
