import skyLabLogoSource from "../assets/skylab-watermark.svg?raw";

let pathIndex = 0;

const animatedSkyLabLogo = skyLabLogoSource
  .replace(/^<\?xml[^>]*>\s*/, "")
  .replace(/<!DOCTYPE[^>]*>\s*/, "")
  .replace(/<desc>.*?<\/desc>/s, "")
  .replace(/\sstyle="[^"]*"/g, "")
  .replace(
    "<svg ",
    '<svg class="sl-legacy-logo__svg" aria-hidden="true" focusable="false" '
  )
  .replace(/<path /g, () => {
    const currentPathIndex = pathIndex;
    pathIndex += 1;

    return `<path pathLength="1" style="--sl-logo-path-index: ${currentPathIndex}" `;
  });

// React replaces innerHTML when this prop object changes, even when the SVG text is identical.
// Keep the same object so countdowns and form updates preserve the paths and their animation clock.
const logoMarkup = { __html: animatedSkyLabLogo };

/**
 * The page's logo (`draw`: whole from the first frame, a light trace on top), or the loading
 * state's copy of it (`loading`: drawn over and over while a step is on its way; decorative, the
 * loading state's own text speaks for it).
 */
export default function AnimatedSkyLabLogo(props: { variant?: "draw" | "loading" }) {
  if (props.variant === "loading") {
    return (
      <div
        className="sl-legacy-logo__animation"
        data-skylab-logo-animation="loading"
        aria-hidden="true"
        dangerouslySetInnerHTML={logoMarkup}
      />
    );
  }
  return (
    <div
      className="sl-legacy-logo__animation"
      data-skylab-logo-animation="draw"
      role="img"
      aria-label="SKY LAB"
      dangerouslySetInnerHTML={logoMarkup}
    />
  );
}
