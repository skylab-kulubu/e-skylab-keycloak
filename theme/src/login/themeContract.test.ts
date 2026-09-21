import { describe, expect, it } from "vitest";
import css from "./legacy-login.css?raw";
import kcPageSource from "./KcPage.tsx?raw";
import loginSource from "./Login.tsx?raw";
import templateSource from "./Template.tsx?raw";
import { classes } from "./KcPage";

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

function parseColor(value: string): Rgba {
  const variable = value.match(/^var\((--[a-z0-9-]+)\)$/i)?.[1];
  const resolved = variable === undefined ? value : declaration(":root", variable);
  const hex = resolved.match(/^#([0-9a-f]{3}|[0-9a-f]{6})$/i)?.[1];
  if (hex !== undefined) {
    const digits = hex.length === 3 ? [...hex].map(channel => channel.repeat(2)) : hex.match(/.{2}/g)!;
    const [r, g, b] = digits.map(channel => Number.parseInt(channel, 16));
    return [r, g, b, 1];
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
    for (const token of ["--sl-legacy-accent", "--sl-legacy-blue", "--sl-legacy-pink", "--sl-legacy-bg", "--sl-legacy-font"]) {
      expect(declaration(":root", token)).not.toBe("");
    }
    expect(declaration(":root", "--sl-legacy-accent")).toBe("#e0c8e5");
    expect(declaration(":root", "--sl-legacy-bg")).toBe("#08070b");
    expect(declaration(":root", "--sl-legacy-font")).toMatch(/^Inter,/);
    expect(css.match(/^\s*Inter,/gm)).toHaveLength(1);

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
    expect(declaration(".sl-legacy-submit", "background")).toBe("var(--sl-legacy-blue)");
    expect(declaration(".sl-legacy-submit:hover", "background")).toBe("var(--sl-legacy-pink)");
    expect(loginSource).toContain('className="sl-legacy-input"');
    expect(loginSource).toContain('className="sl-legacy-password-toggle"');
  });

  it("keeps text, links and secondary buttons at WCAG AA contrast on the glass card", () => {
    for (const selector of [".sl-legacy-choice", ".sl-legacy-choice:hover", ".sl-auth-item", ".sl-otp-list__input:checked + .sl-otp-list"]) {
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

  it("keeps the primary submit text at WCAG AA contrast in both states", () => {
    for (const selector of [".sl-legacy-submit", ".sl-legacy-submit:hover", ".sl-legacy-submit:active"]) {
      const background = composite(parseColor(declaration(selector, "background")), cardSurface);
      const foreground = composite(parseColor(declaration(selector, "color")), background);
      expect(contrastRatio(foreground, background), selector).toBeGreaterThanOrEqual(4.5);
    }
    expect(declaration(":root", "--sl-legacy-blue")).toBe("#1a73c4");
    expect(declaration(":root", "--sl-legacy-pink")).toBe("#d91f6d");
  });

  it("has explicit keyboard focus, reduced-motion and forced-colors behavior", () => {
    expect(css).toContain(":focus-visible");
    expect(css).toContain("@media (prefers-reduced-motion: reduce)");
    expect(css).toContain("animation: none");
    expect(css).toContain("@media (forced-colors: active)");
    expect(css).toContain("@media (max-width: 39.999rem)");
  });
});
