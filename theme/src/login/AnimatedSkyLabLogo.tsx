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

export default function AnimatedSkyLabLogo() {
  return (
    <div
      className="sl-legacy-logo__animation"
      data-skylab-logo-animation="draw"
      role="img"
      aria-label="SKY LAB"
      dangerouslySetInnerHTML={{ __html: animatedSkyLabLogo }}
    />
  );
}
