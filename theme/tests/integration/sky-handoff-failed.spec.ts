import { expect, test } from "@playwright/test";

// The Web handoff failure page served by a live Keycloak (sky-handoff v1/failed) in the SKY LAB
// login theme: every reason in Chromium with the phone in light and in dark mode, under the
// page's own strict Content Security Policy. Run by tests/sky-handoff-contract.sh.

const pageUrl = process.env.SKY_HANDOFF_FAILED_URL;
if (pageUrl === undefined) {
  throw new Error("SKY_HANDOFF_FAILED_URL must point to /realms/{realm}/sky-handoff/v1/failed");
}

const sentences: Record<string, string> = {
  expired: "Bağlantının süresi doldu.",
  used: "Bu bağlantı zaten kullanıldı.",
  invalid: "Bağlantı geçersiz.",
  target_disabled: "Bu siteye uygulamadan geçiş şu an kapalı.",
  account_unavailable: "Hesabın şu an kullanılamıyor.",
  unavailable: "Geçici bir sorun oluştu."
};

for (const colorScheme of ["light", "dark"] as const) {
  test.describe(`Web handoff failure page, ${colorScheme} mode`, () => {
    test.use({ colorScheme, locale: "tr-TR", viewport: { width: 390, height: 844 } });

    test("every reason renders in the LegacyFrame design with nothing to act on", async ({ page }) => {
      const violations: string[] = [];
      page.on("console", message => {
        if (message.type() === "error" && /content security policy|refused to/i.test(message.text())) {
          violations.push(message.text());
        }
      });
      page.on("pageerror", error => violations.push(error.message));
      await page.addInitScript(() => {
        document.addEventListener("securitypolicyviolation", event => {
          console.error(`Content Security Policy violation: ${event.violatedDirective} ${event.blockedURI}`);
        });
      });

      for (const [reason, sentence] of [...Object.entries(sentences), ["no-such-reason", sentences.unavailable]]) {
        const response = await page.goto(`${pageUrl}?reason=${encodeURIComponent(reason)}`);
        expect(response?.status(), reason).toBe(200);
        const headers = response!.headers();
        expect(headers["cache-control"]).toBe("no-store");
        expect(headers["x-frame-options"]).toBe("DENY");
        expect(headers["referrer-policy"]).toBe("no-referrer");
        expect(headers["content-security-policy"]).toContain("frame-ancestors 'none'");

        await expect(page.locator(".sl-legacy-shell")).toHaveAttribute("data-sl-translations", "ready");
        await expect(page.getByRole("heading", { level: 1 })).toHaveText(sentence);
        await expect(page.locator(".sl-legacy-intro p")).toHaveText("Uygulamaya dönüp tekrar dene.");
        await expect(page.locator('[data-skylab-logo-animation="draw"] path')).toHaveCount(19);
        await expect(page.locator("form, input, button, select, textarea")).toHaveCount(0);
        const links = await page.locator("a").evaluateAll(anchors => anchors.map(anchor => anchor.getAttribute("href")));
        expect(links, reason).toEqual(["#sl-handoff-failed-main", "https://skyl.app/kvkk-metni"]);
        await expect(page).toHaveTitle(`${sentence.replace(/\.$/, "")} · SKY LAB`);
        expect(await page.evaluate(() => getComputedStyle(document.documentElement).colorScheme)).toBe("dark");
        await expect(page.locator(".sl-body")).toHaveCSS("background-color", "rgb(8, 7, 11)");
      }

      // A refused open (an unknown code, no proof) redirects the WebView to the same page.
      const refused = await page.goto(`${pageUrl.replace(/\/failed$/, "/open")}?code=${"A".repeat(43)}`);
      expect(refused?.status()).toBe(200);
      expect(new URL(page.url()).pathname).toBe(new URL(pageUrl).pathname);
      expect(new URL(page.url()).searchParams.get("reason")).toBe("invalid");
      await expect(page.getByRole("heading", { level: 1 })).toHaveText(sentences.invalid);
      await expect(page.locator("form, input, button, select, textarea")).toHaveCount(0);

      // The page's policy allows its own inline context script by hash only; nothing was blocked.
      expect(violations).toEqual([]);
    });
  });
}
