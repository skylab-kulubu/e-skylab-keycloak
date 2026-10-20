import { describe, expect, it } from "vitest";
import css from "./legacy-login.css?raw";
import tokensCss from "@skylab-kulubu/skylcn-ui/tokens.css?raw";
import kcPageSource from "./KcPage.tsx?raw";
import loginSource from "./Login.tsx?raw";
import templateSource from "./Template.tsx?raw";
import { classes } from "./KcPage";
import { TEAM_MARQUEE_SECONDS } from "./TeamMarquee";

type Rgb = [number, number, number];
type Rgba = [number, number, number, number];

const stylesheets = Object.keys(import.meta.glob("./*.css"));
const rules = [...css.replace(/\/\*[\s\S]*?\*\//g, "").matchAll(/([^{}]+)\{([^{}]*)\}/g)].map(match => ({
  selectors: match[1]
    .split(",")
    .map(selector => selector.trim())
    .filter(selector => selector !== ""),
  body: match[2]
}));

function rulesFor(selector: string) {
  const matches = rules.filter(rule => rule.selectors.includes(selector));
  expect(matches.length, `missing CSS rule ${selector}`).toBeGreaterThan(0);
  return matches;
}

function declaration(selector: string, property: string): string {
  let value: string | undefined;
  for (const rule of rulesFor(selector)) {
    const match = rule.body.match(new RegExp(`(?:^|;)\\s*${property}\\s*:\\s*([^;]+)`));
    if (match !== null) {
      value = match[1].trim();
    }
  }
  expect(value, `missing CSS declaration ${property} for ${selector}`).toBeDefined();
  return value!;
}

// The dark (default) skylcn-ui tokens, the layer under the login's own :root roles.
const sharedTokens = new Map(
  [...(tokensCss.replace(/\/\*[\s\S]*?\*\//g, "").match(/:root,\s*\[data-theme='dark'\]\s*\{([^}]*)\}/)?.[1] ?? "").matchAll(/(--[a-z0-9-]+)\s*:\s*([^;]+);/gi)].map(
    match => [match[1], match[2].trim()]
  )
);

function resolveVariable(value: string): string {
  const variable = value.match(/^var\((--[a-z0-9-]+)\)$/i)?.[1];
  if (variable === undefined) return value;
  const own = rules.filter(rule => rule.selectors.includes(":root")).some(rule => new RegExp(`(?:^|;)\\s*${variable}\\s*:`).test(rule.body));
  const next = own ? declaration(":root", variable) : sharedTokens.get(variable);
  expect(next, `unresolved token ${variable}`).toBeDefined();
  return resolveVariable(next!);
}

function parseColor(value: string): Rgba {
  const resolved = resolveVariable(value);
  const hex = resolved.match(/^#([0-9a-f]{3}|[0-9a-f]{6})$/i)?.[1];
  if (hex !== undefined) {
    const digits = hex.length === 3 ? [...hex].map(channel => channel.repeat(2)) : hex.match(/.{2}/g)!;
    const [r, g, b] = digits.map(channel => Number.parseInt(channel, 16));
    return [r, g, b, 1];
  }
  const modern = resolved.match(/^rgb\(\s*([\d.]+)\s+([\d.]+)\s+([\d.]+)\s*(?:\/\s*([\d.]+)(%?)\s*)?\)$/i);
  if (modern !== null) {
    const alpha = modern[4] === undefined ? 1 : Number(modern[4]) / (modern[5] === "%" ? 100 : 1);
    return [Number(modern[1]), Number(modern[2]), Number(modern[3]), alpha];
  }
  const rgba = resolved.match(/^rgba?\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)\s*(?:,\s*([\d.]+)\s*)?\)$/i);
  expect(rgba, `unsupported CSS color ${resolved}`).not.toBeNull();
  return [Number(rgba![1]), Number(rgba![2]), Number(rgba![3]), rgba![4] === undefined ? 1 : Number(rgba![4])];
}

function composite(top: Rgba, bottom: Rgb): Rgb {
  const alpha = top[3];
  return [0, 1, 2].map(index => top[index] * alpha + bottom[index] * (1 - alpha)) as Rgb;
}

function relativeLuminance([r, g, b]: Rgb): number {
  const [lr, lg, lb] = [r, g, b]
    .map(channel => channel / 255)
    .map(channel => (channel <= 0.04045 ? channel / 12.92 : ((channel + 0.055) / 1.055) ** 2.4));
  return 0.2126 * lr + 0.7152 * lg + 0.0722 * lb;
}

function contrastRatio(foreground: Rgb, background: Rgb): number {
  const lighter = Math.max(relativeLuminance(foreground), relativeLuminance(background));
  const darker = Math.min(relativeLuminance(foreground), relativeLuminance(background));
  return (lighter + 0.05) / (darker + 0.05);
}

// The stack every control sits on: page background, then the glass card.
const pageBackground = composite(parseColor(declaration(".sl-body", "background")), [0, 0, 0]);
const cardSurface = composite(parseColor(declaration(".sl-legacy-card", "background")), pageBackground);

function surfaceContrast(selector: string): number {
  const background = composite(parseColor(declaration(selector, "background")), cardSurface);
  const foreground = composite(parseColor(declaration(selector, "color")), background);
  return contrastRatio(foreground, background);
}

describe("SKY LAB theme: one design system", () => {
  it("ships a single stylesheet with a single token set", () => {
    expect(stylesheets).toEqual(["./legacy-login.css"]);
    expect(rulesFor(":root")).toHaveLength(1);
    for (const token of ["--sl-legacy-accent", "--sl-legacy-primary", "--sl-legacy-bg", "--sl-legacy-font"]) {
      expect(declaration(":root", token)).not.toBe("");
    }
    // The palette, radius and type come from skylcn-ui, not from values of the login's own.
    expect(declaration(":root", "--sl-legacy-accent")).toBe("var(--skylab-500)");
    expect(resolveVariable("var(--sl-legacy-accent)")).toBe("#e0c8e5");
    expect(declaration(":root", "--sl-legacy-primary")).toBe("var(--primary)");
    expect(declaration(":root", "--sl-legacy-radius")).toBe("var(--radius)");
    expect(declaration(":root", "--sl-legacy-font")).toBe("var(--font-family-sans)");
    expect(declaration(":root", "--skylcn-font-sans")).toBe('"Space Grotesk Variable"');
    expect(css).not.toMatch(/\bInter\b/);

    // The retired theme.css tokens and chrome must not come back under another name.
    for (const retired of ["--sl-ink", "--sl-surface:", "--sl-pink-hover", "--sl-blue:", "--sl-focus:", ".sl-shell", ".sl-site-header", ".sl-atmosphere", ".sl-brand", ".sl-glow", ".sl-orbit", ".sl-card__eyebrow"]) {
      expect(css, `retired token or selector ${retired}`).not.toContain(retired);
    }

    // Colours outside the token block are tokens or alpha tints, never hex literals.
    const [, body] = css.split(/:root\s*\{[^}]*\}/);
    expect(body.replace(/\/\*[\s\S]*?\*\//g, "")).not.toMatch(/#[0-9a-f]{3,6}\b/i);
  });

  it("is imported exactly once, by the page router", () => {
    expect(kcPageSource).toContain('import "./legacy-login.css"');
    // Shared tokens and the self-hosted brand face load first, so the login roles can build on them.
    const order = ["@fontsource-variable/space-grotesk/wght.css", "@skylab-kulubu/skylcn-ui/tokens.css", "./legacy-login.css"].map(path => kcPageSource.indexOf(`import "${path}"`));
    expect(order.every(index => index >= 0)).toBe(true);
    expect(order).toEqual([...order].sort((a, b) => a - b));
    expect(loginSource).not.toMatch(/import\s+"[^"]*\.css"/);
    expect(templateSource).not.toMatch(/import\s+"[^"]*\.css"/);
    expect(templateSource).not.toContain("skylab-logo.png");
    expect(templateSource).not.toContain("ytu-logo.png");
  });

  it("points the DefaultPage class contract at the login page's own classes", () => {
    expect(classes).toMatchObject({
      kcButtonPrimaryClass: "sl-legacy-submit",
      kcButtonDefaultClass: "sl-legacy-choice",
      kcButtonSecondaryClass: "sl-legacy-choice",
      kcFormGroupClass: "sl-legacy-field",
      kcLabelClass: "sl-legacy-label",
      kcInputClass: "sl-legacy-input",
      kcInputGroup: "sl-legacy-password-input",
      kcFormPasswordVisibilityButtonClass: "sl-legacy-password-toggle",
      kcInputErrorMessageClass: "sl-legacy-field-error",
      kcAlertClass: "sl-legacy-alert"
    });
    for (const selector of [".sl-legacy-submit", ".sl-legacy-choice", ".sl-legacy-field", ".sl-legacy-label", ".sl-legacy-input", ".sl-legacy-password-toggle", ".sl-legacy-field-error", ".sl-legacy-alert"]) {
      expect(rulesFor(selector).length, selector).toBeGreaterThan(0);
    }
    // No second spelling of a login control survives.
    expect(css).not.toMatch(/\.sl-(button|field|input|alert|label|password-toggle|input-group)(?![\w-])/);
    expect(declaration(".sl-legacy-submit", "background")).toBe("var(--sl-legacy-primary)");
    expect(declaration(".sl-legacy-submit:hover", "background")).toBe("var(--sl-legacy-primary-hover)");
    expect(loginSource).toContain('className="sl-legacy-input"');
    expect(loginSource).toContain('className="sl-legacy-password-toggle"');
  });

  it("keeps text, links and secondary buttons at WCAG AA contrast on the glass card", () => {
    for (const selector of [".sl-legacy-choice", ".sl-legacy-choice:hover", ".sl-legacy-choice--primary", ".sl-legacy-choice--primary:hover", ".sl-auth-item", ".sl-otp-list__input:checked + .sl-otp-list"]) {
      const contrast = selector.includes("otp-list")
        ? contrastRatio(composite(parseColor("var(--sl-legacy-text)"), cardSurface), composite(parseColor(declaration(selector, "background")), cardSurface))
        : surfaceContrast(selector);
      expect(contrast, selector).toBeGreaterThanOrEqual(4.5);
    }
    for (const token of ["--sl-legacy-ink", "--sl-legacy-text", "--sl-legacy-label", "--sl-legacy-muted", "--sl-legacy-link", "--sl-legacy-danger"]) {
      const foreground = composite(parseColor(`var(${token})`), cardSurface);
      expect(contrastRatio(foreground, cardSurface), token).toBeGreaterThanOrEqual(4.5);
    }
  });

  it("keeps every page heading and its one-line description (the whole Web handoff failure page) at WCAG AA contrast", () => {
    for (const selector of [".sl-legacy-intro h1", ".sl-legacy-intro p"]) {
      const foreground = composite(parseColor(declaration(selector, "color")), cardSurface);
      expect(contrastRatio(foreground, cardSurface), selector).toBeGreaterThanOrEqual(4.5);
    }
  });

  it("keeps the primary submit text at WCAG AA contrast in every state", () => {
    for (const selector of [".sl-legacy-submit", ".sl-legacy-submit:hover", ".sl-legacy-submit:active"]) {
      const background = composite(parseColor(declaration(selector, "background")), cardSurface);
      const foreground = composite(parseColor(declaration(selector, "color")), background);
      expect(contrastRatio(foreground, background), selector).toBeGreaterThanOrEqual(4.5);
    }
  });

  it("takes the field focus ring from skylcn-ui, at 3:1 or more against the card (WCAG 1.4.11)", () => {
    // skylcn-ui 0.1.7+ ships the dark ring at 60%, so the login keeps no override of its own.
    expect(declaration(":root", "--sl-legacy-ring")).toBe("var(--ring)");
    expect(declaration(".sl-legacy-input:focus", "box-shadow")).toBe("0 0 0 2px var(--sl-legacy-ring)");
    const ring = composite(parseColor("var(--sl-legacy-ring)"), cardSurface);
    expect(contrastRatio(ring, cardSurface)).toBeGreaterThanOrEqual(3);
  });

  it("has explicit keyboard focus, reduced-motion and forced-colors behavior", () => {
    expect(css).toContain(":focus-visible");
    expect(css).toContain("@media (prefers-reduced-motion: reduce)");
    expect(css).toContain("animation: none");
    expect(css).toContain("@media (forced-colors: active)");
    expect(css).toContain("@media (max-width: 39.999rem)");
  });

  /** The body of one `@media` block, comments removed. */
  function mediaBlock(query: string): string {
    const source = css.replace(/\/\*[\s\S]*?\*\//g, "");
    const start = source.indexOf(`@media ${query} {`);
    expect(start, `missing @media ${query}`).toBeGreaterThanOrEqual(0);
    let depth = 0;
    for (let index = source.indexOf("{", start); index < source.length; index += 1) {
      if (source[index] === "{") depth += 1;
      if (source[index] === "}") depth -= 1;
      if (depth === 0) return source.slice(start, index + 1);
    }
    throw new Error(`unterminated @media ${query}`);
  }

  it("shows the whole logo from the first frame; the animation only traces a line over it", () => {
    const path = rules.find(rule => rule.selectors.includes(".sl-legacy-logo__svg path"))!.body;
    expect(path).toMatch(/(?:^|;)\s*fill-opacity:\s*1\s*;/);
    expect(path).not.toMatch(/fill-opacity:\s*0\s*;/);
    expect(declaration(".sl-legacy-logo__svg path", "animation-name")).toBe("sl-legacy-logo-draw, sl-legacy-logo-stroke-fade");
    // Nothing fades the fill in any more.
    expect(css).not.toContain("sl-legacy-logo-fill");
    expect(mediaBlock("(prefers-reduced-motion: reduce)")).toMatch(
      /\.sl-legacy-logo__svg path\s*\{[^}]*animation:\s*none;[^}]*fill-opacity:\s*1;[^}]*stroke-opacity:\s*0;/
    );
  });

  it("keeps help copy, field labels and the KVKK line at 14px or more", () => {
    // The developer credit, the language links and the attempted-account label may stay at 12-13px.
    for (const selector of [
      ".sl-legacy-label",
      ".sl-legacy-field > label",
      ".sl-legacy-footer p",
      ".sl-legacy-school-reset",
      ".sl-legacy-alternatives",
      ".sl-legacy-no-account",
      ".sl-legacy-choice__hint",
      ".sl-legacy-field-error",
      ".sl-helper-text",
      ".sl-legacy-required-note",
      ".sl-passkey-offer__privacy",
      ".sl-personal-email-offer__note",
      ".sl-stay-signed-in__warning",
      ".sl-email-code-sign-up__note",
      ".sl-auth-item__description"
    ]) {
      const size = declaration(selector, "font-size");
      expect(size, selector).toMatch(/rem$/);
      expect(Number.parseFloat(size) * 16, selector).toBeGreaterThanOrEqual(14);
    }
  });

  it("keeps the team strips quiet, inside the window and, on a phone, below the form", () => {
    expect(Number(declaration(".sl-legacy-teams__item", "opacity"))).toBeLessThanOrEqual(0.2);
    const base = rules.find(rule => rule.selectors.includes(".sl-legacy-teams"))!.body;
    expect(base).toMatch(/width:\s*min\(100% - 2rem,/);
    const phone = mediaBlock("(max-width: 39.999rem)");
    expect(phone).toMatch(/\.sl-legacy-teams--left\s*\{\s*display:\s*none;/);
    expect(phone).not.toMatch(/\.sl-legacy-teams--right\s*\{\s*display:\s*none;/);
  });

  it("opts into cross-document View Transitions only without reduced motion", () => {
    const motion = mediaBlock("(prefers-reduced-motion: no-preference)");
    expect(motion).toMatch(/@view-transition\s*\{\s*navigation:\s*auto;/);
    // The rule never stands outside that block.
    expect(css.replace(/\/\*[\s\S]*?\*\//g, "").replace(motion, "")).not.toContain("@view-transition");
    expect(mediaBlock("(prefers-reduced-motion: reduce)")).not.toContain("view-transition");
    // Only the card's content slides, both ways; the frame is swapped at once.
    expect(motion).toMatch(/::view-transition-old\(sl-card-body\)\s*\{\s*animation:\s*sl-legacy-step-out\b/);
    expect(motion).toMatch(/::view-transition-new\(sl-card-body\)\s*\{\s*animation:\s*sl-legacy-step-in\b/);
    expect(motion).toMatch(/data-sl-vt-direction="back"\]::view-transition-old\(sl-card-body\)/);
    for (const name of ["sl-backdrop", "sl-teams-top", "sl-teams-bottom", "sl-footer"]) {
      expect(motion, name).toContain(`::view-transition-new(${name})`);
    }
  });

  it("names the frame's parts once each, so they stay put across steps", () => {
    const names = new Map([
      [".sl-legacy-background", "sl-backdrop"],
      [".sl-legacy-teams--left", "sl-teams-top"],
      [".sl-legacy-teams--right", "sl-teams-bottom"],
      [".sl-legacy-card", "sl-card"],
      [".sl-legacy-card__body", "sl-card-body"],
      [".sl-legacy-logo", "sl-logo"],
      [".sl-legacy-footer", "sl-footer"]
    ]);
    for (const [selector, name] of names) {
      expect(declaration(selector, "view-transition-name"), selector).toBe(name);
    }
    expect(new Set(names.values()).size).toBe(names.size);
  });

  it("plays the entrance animations on a tab's first page only", () => {
    for (const selector of [
      "html[data-sl-entered] .sl-legacy-background__layers",
      "html[data-sl-entered] .sl-legacy-background__iris",
      "html[data-sl-entered] .sl-legacy-background__grain",
      "html[data-sl-entered] .sl-legacy-brand__mark",
      "html[data-sl-entered] .sl-legacy-logo .sl-legacy-logo__svg path"
    ]) {
      expect(declaration(selector, "animation"), selector).toBe("none");
    }
  });

  it("draws the card's logo while a step loads, and holds it still with reduced motion", () => {
    const logo = rules.find(rule => rule.selectors.includes("html[data-sl-loading] .sl-legacy-logo .sl-legacy-logo__svg path"))!.body;
    expect(logo).toMatch(/animation:\s*sl-legacy-loading-draw [^;]*infinite/);
    // The next page picks the drawing up where the last one was (navigationLoading.ts).
    expect(logo).toMatch(/animation-delay:\s*calc\(var\(--sl-loading-phase, 0ms\)/);
    // After the entrance rule, which stops the logo's animation on every page but a tab's first.
    const order = rules.map(rule => rule.selectors);
    expect(order.findIndex(selectors => selectors.includes("html[data-sl-loading] .sl-legacy-logo .sl-legacy-logo__svg path")))
      .toBeGreaterThan(order.findIndex(selectors => selectors.includes("html[data-sl-entered] .sl-legacy-logo .sl-legacy-logo__svg path")));
    expect(declaration("html[data-sl-loading] .sl-legacy-card__body", "pointer-events")).toBe("none");
    expect(declaration(".sl-legacy-loading", "display")).toBe("none");
    const reduced = mediaBlock("(prefers-reduced-motion: reduce)");
    expect(reduced).toMatch(/html\[data-sl-loading\] \.sl-legacy-logo \.sl-legacy-logo__svg path\s*\{\s*animation:\s*none;/);
    // A plain text indicator instead of the drawing.
    expect(reduced).toMatch(/html\[data-sl-loading\] \.sl-legacy-loading\s*\{\s*display:\s*flex;/);
  });

  it("runs the team strips as long as TeamMarquee.tsx assumes for its clock-based phase", () => {
    const track = rules.find(rule => rule.selectors.includes(".sl-legacy-teams__track"))!.body;
    expect(track).toMatch(new RegExp(`animation:\\s*sl-legacy-teams ${TEAM_MARQUEE_SECONDS}s linear infinite`));
  });
});
