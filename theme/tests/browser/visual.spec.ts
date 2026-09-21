import { fileURLToPath } from "node:url";
import { expect, test, type Page } from "@playwright/test";
import { themedPageIds } from "../../src/login/pageIds";

/**
 * Screenshot baselines for every Keycloak page in Turkish, desktop and mobile,
 * with reduced motion. Baselines live in visual.spec.ts-snapshots/ and are
 * rendered inside the Playwright Linux image so they match the CI runner:
 * `theme/scripts/update-visual-baselines.sh` regenerates them, `--check` compares.
 *
 * SL_VISUAL_BASELINE_ENV=1 marks that image (the script and the CI theme job set
 * it); SL_VISUAL_ANY_PLATFORM=1 forces the spec elsewhere, where fonts differ.
 */

const viewports = {
  desktop: { width: 1280, height: 800 },
  mobile: { width: 390, height: 844 }
} as const;

const runsInBaselineEnvironment =
  process.env.SL_VISUAL_BASELINE_ENV === "1" || process.env.SL_VISUAL_ANY_PLATFORM === "1";

const screenshotOptions = {
  animations: "disabled",
  caret: "hide",
  maxDiffPixelRatio: 0.01,
  stylePath: fileURLToPath(new URL("./visual.css", import.meta.url))
} as const;

async function stabilise(page: Page, pageId: string): Promise<void> {
  await expect(page.locator(".sl-legacy-shell")).toHaveAttribute("data-sl-translations", "ready");
  await expect(page.locator('[data-skylab-logo-animation="draw"] path').first()).toHaveCSS("fill-opacity", "1");
  if (pageId === "login-passkeys-conditional-authenticate.ftl") {
    // Conditional mediation is stubbed off, so Keycloak's script reveals the explicit button.
    await expect(page.locator("#kc-form-passkey-button")).toBeVisible();
  }
  await page.evaluate(() => document.fonts.ready);

  // Grow the viewport to the document so the fixed background covers tall pages,
  // exactly as a person sees them while scrolling.
  const viewport = page.viewportSize();
  const documentHeight = await page.evaluate(() => document.documentElement.scrollHeight);
  if (viewport !== null && documentHeight > viewport.height) {
    await page.setViewportSize({ width: viewport.width, height: documentHeight });
    await page.evaluate(() => document.fonts.ready);
  }
}

test.describe("visual baselines", () => {
  test.skip(
    !runsInBaselineEnvironment,
    "Baselines are rendered in the Playwright image; run theme/scripts/update-visual-baselines.sh --check"
  );

  test.beforeEach(async ({ page }) => {
    // WebAuthn availability differs per machine; pin the fallback branch of Keycloak's scripts.
    await page.addInitScript(() => {
      const credential = (window as Window & { PublicKeyCredential?: unknown }).PublicKeyCredential ?? class {};
      Object.assign(credential, {
        isConditionalMediationAvailable: async () => false,
        isUserVerifyingPlatformAuthenticatorAvailable: async () => false
      });
      (window as Window & { PublicKeyCredential?: unknown }).PublicKeyCredential = credential;
    });
  });

  for (const [viewportName, viewport] of Object.entries(viewports)) {
    test.describe(viewportName, () => {
      test.use({ viewport, reducedMotion: "reduce", locale: "tr-TR", colorScheme: "dark" });

      for (const pageId of themedPageIds) {
        const name = pageId.replace(/\.ftl$/, "");

        test(name, async ({ page }) => {
          await page.goto(`/?page=${pageId}`);
          await stabilise(page, pageId);
          await expect(page).toHaveScreenshot(`${name}-${viewportName}.png`, screenshotOptions);
        });
      }

      test("login-password-view", async ({ page }) => {
        await page.goto("/?page=login.ftl");
        await stabilise(page, "login.ftl");
        await page.getByRole("button", { name: "YTÜ Öğrencisi Değilim" }).click();
        await expect(page.locator("#kc-login")).toBeVisible();
        await expect(page).toHaveScreenshot(`login-password-view-${viewportName}.png`, screenshotOptions);
      });
    });
  }
});
