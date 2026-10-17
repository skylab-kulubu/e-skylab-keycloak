import { expect, test, type Page } from "@playwright/test";

async function ready(page: Page, url: string) {
  await page.goto(url);
  await expect(page.locator(".sl-legacy-shell")).toHaveAttribute("data-sl-translations", "ready");
}

/** Capture the browser's native form POST without calling an identity service from the preview. */
async function postFrom(page: Page, button: string) {
  const currentAction = page.url().split("#")[0];
  await page.route("**/*", async route => {
    if (route.request().method() === "POST") {
      await route.fulfill({ contentType: "text/html", body: "<h1>POST fixture</h1>" });
    } else {
      await route.continue();
    }
  });
  const [request] = await Promise.all([
    page.waitForRequest(request => request.method() === "POST"),
    page.getByRole("button", { name: button, exact: true }).click()
  ]);
  expect(request.url()).toBe(currentAction);
  return new URLSearchParams(request.postData() ?? "");
}

for (const viewport of [{ width: 1280, height: 800 }, { width: 390, height: 844 }]) {
  test.describe(`registration entry (${viewport.width}px)`, () => {
    test.use({ viewport, reducedMotion: "reduce" });

    test("hides the entry while off and posts only the offered execution with explicit registration intent while on", async ({ page }) => {
      await ready(page, "/?page=login.ftl");
      await expect(page.getByRole("button", { name: "E-postayla hesap aç" })).toHaveCount(0);
      await expect(page.locator('a[href*="/registration"]')).toHaveCount(0);

      await ready(page, "/?page=login.ftl&registration=on");
      const fields = await postFrom(page, "E-postayla hesap aç");
      expect([...fields.entries()]).toEqual([
        ["authenticationExecution", "preview-email-code"],
        ["sky-email-code-intent", "sign-up"]
      ]);
    });

    test("does not add registration intent to the ordinary e-mail choice", async ({ page }) => {
      await ready(page, "/?page=login.ftl&registration=on");
      const fields = await postFrom(page, "E-postayla devam et");
      expect([...fields.entries()]).toEqual([["authenticationExecution", "preview-email-code"]]);
    });

    test("leaves broker proof on its explicit new-account POST", async ({ page }) => {
      await ready(page, "/?page=login.ftl&registration=on&broker=proof");
      await expect(page.getByRole("button", { name: "E-postayla hesap aç" })).toHaveCount(0);
      await expect(page.locator(".sl-legacy-no-account")).toHaveCount(0);
      const fields = await postFrom(page, "Bağlanamadım, yeni hesap aç");
      expect([...fields.entries()]).toEqual([["sky-existing-account-action", "new-account"]]);
    });

    test("uses a neutral registration intent through the shared address and code stages", async ({ page }) => {
      for (const suffix of ["", "&code=wrong"]) {
        await ready(page, `/?page=sky-email-code.ftl&registration=sign-up${suffix}`);
        await expect(page.getByRole("heading", { name: "Hesap aç", exact: true })).toBeVisible();
        await expect(page.locator(".sl-legacy-teams")).toHaveCount(2);
        if (suffix === "") {
          await expect(page.locator("#username")).toBeVisible();
          await expect(page.locator(".sl-legacy-intro")).toContainText("Hesabın varsa giriş yaparsın; yoksa");
        } else {
          await expect(page.locator("#sky-email-code-sent")).toContainText("Bu adresle bir hesabın varsa");
          await expect(page.locator("#sky-email-code-error")).toContainText("Kod yanlış. 4 deneme hakkın kaldı.");
          await expect(page.locator("#sky-email-code")).toHaveAttribute("autocomplete", "one-time-code");
          await expect(page.locator("#kc-email-code-sign-up-form")).toHaveCount(0);
        }
      }
    });

    test("loads the team backdrop on every registration and existing-account stage without widening the card", async ({ page }) => {
      test.setTimeout(90000);
      const pages = [
        ...["form", "ytu", "existing", "unavailable"].map(stage => `/?page=sky-email-code-sign-up.ftl&signup=${stage}`),
        ...["question", "candidate", "identifier", "code"].map(stage => `/?page=sky-existing-account.ftl&broker=${stage}`)
      ];
      for (const url of pages) {
        await ready(page, url);
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
        await expect(page.locator(".sl-legacy-stack--wide")).toHaveCount(0);
        expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
        if (viewport.width < 640) await expect(rows.last()).toBeHidden();
      }
      await page.emulateMedia({ reducedMotion: "no-preference" });
      await expect(page.locator(".sl-legacy-teams__track").first()).not.toHaveCSS("animation-name", "none");
      await page.emulateMedia({ forcedColors: "active" });
      await expect(page.locator(".sl-legacy-teams").first()).toBeHidden();
      await expect(page.locator("#sky-existing-code")).toBeVisible();
    });
  });
}
