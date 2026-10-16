import { expect, test } from "@playwright/test";

for (const viewport of [{ width: 1280, height: 800 }, { width: 390, height: 844 }]) {
  test.describe(`email code (${viewport.width}px)`, () => {
    test.use({ viewport });

    test("the logo finishes once through countdown, input and validity changes", async ({ page }) => {
      await page.goto("/?page=sky-email-code.ftl&code=sent");
      await expect(page.locator(".sl-legacy-shell")).toHaveAttribute("data-sl-translations", "ready");
      const logo = page.locator('[data-skylab-logo-animation="draw"]');
      await expect(logo.locator("path")).toHaveCount(19);
      await logo.evaluate(element => {
        const path = element.querySelector("path")!;
        const animations = path.getAnimations();
        if (animations.length !== 3) throw new Error("The logo should draw, fill and fade its stroke once.");
        (window as Window & { logoProbe?: unknown }).logoProbe = { path, animations };
      });

      const input = page.locator("#sky-email-code");
      await input.fill("012345");
      await input.evaluate(element => {
        (element as HTMLInputElement).setCustomValidity("fixture");
        element.dispatchEvent(new Event("input", { bubbles: true }));
      });
      await input.evaluate(element => (element as HTMLInputElement).setCustomValidity(""));
      // At least five real React renders from the resend countdown, past the last logo path's fill.
      await expect(page.locator("#sky-email-code-resend")).toContainText(/5[0-4] saniye/, { timeout: 12000 });
      expect(await logo.evaluate(element => {
        const probe = (window as Window & { logoProbe?: { path: Element; animations: Animation[] } }).logoProbe!;
        const path = element.querySelector("path")!;
        return {
          samePath: path === probe.path && probe.path.isConnected,
          sameAnimations: path.getAnimations().every((animation, index) => animation === probe.animations[index]),
          finished: probe.animations.every(animation => animation.playState === "finished")
        };
      })).toEqual({ samePath: true, sameAnimations: true, finished: true });
      await expect(logo.locator("path").last()).toHaveCSS("fill-opacity", "1");
      await expect(input).toHaveValue("012345");
    });

    test("both stages reuse loaded team logos around the readable form", async ({ page }) => {
      await page.emulateMedia({ reducedMotion: "reduce" });
      for (const suffix of ["", "&code=wrong"]) {
        await page.goto(`/?page=sky-email-code.ftl${suffix}`);
        const rows = page.locator(".sl-legacy-teams");
        await expect(rows).toHaveCount(2);
        await expect(rows.first()).toBeVisible();
        await expect(rows.first()).toHaveAttribute("aria-hidden", "true");
        const images = rows.first().locator("img");
        expect(await images.count()).toBeGreaterThan(10);
        await expect.poll(() => images.evaluateAll(elements => elements.every(element => {
          const image = element as HTMLImageElement;
          return image.complete && image.naturalWidth > 0;
        }))).toBe(true);
        await expect(rows.first().locator(".sl-legacy-teams__track")).toHaveCSS("animation-name", "none");
        const card = await page.locator(".sl-legacy-card").boundingBox();
        const strip = await rows.first().boundingBox();
        expect(strip!.y + strip!.height).toBeLessThanOrEqual(card!.y);
        expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
        await expect(page.locator('[data-skylab-logo-animation="draw"] path').first()).toHaveCSS("animation-name", "none");
        await expect(page.getByRole("heading", { name: "E-postayla devam et" })).toBeVisible();
        if (viewport.width < 640) await expect(rows.last()).toBeHidden();
      }
      await page.emulateMedia({ forcedColors: "active" });
      await expect(page.locator(".sl-legacy-teams").first()).toBeHidden();
      await expect(page.locator("#sky-email-code")).toBeVisible();
    });
  });
}
