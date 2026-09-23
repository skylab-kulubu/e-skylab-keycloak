import { expect, test } from "@playwright/test";

test("login uses semantic landmarks and preserves remember-me for passkeys", async ({ page }) => {
  await page.goto("/?page=login.ftl");

  await expect(page.getByRole("main")).toBeVisible();
  await expect(page.getByRole("heading", { name: "SKY LAB'e Hoş Geldin!" })).toBeVisible();
  await expect(page.getByRole("link", { name: "YTÜ Öğrencisiyim" })).toBeVisible();
  await expect(page.getByRole("button", { name: "YTÜ Öğrencisi Değilim" })).toBeVisible();
  await expect(page.getByRole("button", { name: "Erişim anahtarı ile giriş yap" })).toBeVisible();
  await expect(page.getByRole("contentinfo")).toContainText("e-skylab by WEBLAB");

  const logo = page.locator('[data-skylab-logo-animation="draw"]');
  await expect(logo).toBeVisible();
  await expect(logo.locator("path")).toHaveCount(19);
  await expect(logo.locator("path").first()).toHaveCSS(
    "animation-name",
    "sl-legacy-logo-draw, sl-legacy-logo-fill, sl-legacy-logo-stroke-fade"
  );

  await page.getByRole("button", { name: "YTÜ Öğrencisi Değilim" }).click();
  await expect(page.getByRole("button", { name: "Giriş yap", exact: true })).toBeVisible();

  const rememberMe = page.locator("#rememberMe");
  const passkeyRememberMe = page.locator("#sl-passkey-remember-me");
  await expect(rememberMe).toBeChecked();
  await expect(passkeyRememberMe).toBeEnabled();

  await rememberMe.uncheck();
  await expect(passkeyRememberMe).toBeDisabled();
  await rememberMe.check();
  await expect(passkeyRememberMe).toBeEnabled();
});

test("keyboard navigation exposes the skip link and localized legacy copy", async ({ page }) => {
  await page.goto("/?page=login.ftl");

  const skipLink = page.locator(".sl-legacy-skip-link");
  await skipLink.focus();
  await expect(skipLink).toBeFocused();
  await page.keyboard.press("Enter");
  await expect(page.locator("#sl-legacy-main")).toBeFocused();

  await page.goto("/?page=login.ftl&lang=en");
  await expect(page.locator("html")).toHaveAttribute("lang", "en");
  await expect(page.getByRole("heading", { name: "Welcome to SKY LAB!" })).toBeVisible();
  await expect(page.getByRole("link", { name: "I'm a YTÜ Student" })).toBeVisible();
  await expect(page.getByRole("contentinfo")).toContainText("e-skylab by WEBLAB");
});

test("known-username pages keep a labelled landmark and page heading", async ({ page }) => {
  await page.goto("/?page=login-password.ftl");

  await expect(page.locator(".sl-legacy-card")).toHaveAttribute("aria-labelledby", "kc-page-title");
  await expect(page.locator("#kc-page-title")).toBeVisible();
  await expect(page.getByRole("heading", { level: 1 })).toHaveCount(1);
  await expect(page.locator("#sl-main-content")).toHaveAttribute("tabindex", "-1");
  await expect(page.locator("#kc-attempted-username")).toHaveText("ayse.yilmaz@std.yildiz.edu.tr");
});

test("every Keycloak page shares the login chrome and the animated logo", async ({ page }) => {
  for (const pageId of ["login-update-password.ftl", "login-config-totp.ftl", "select-authenticator.ftl", "error.ftl"]) {
    await page.goto(`/?page=${pageId}`);
    await expect(page.locator(".sl-legacy-shell")).toHaveAttribute("data-sl-translations", "ready");
    await expect(page.locator('[data-skylab-logo-animation="draw"] path')).toHaveCount(19);
    await expect(page.locator(".sl-legacy-logo img")).toHaveCount(0);
    await expect(page.getByRole("contentinfo")).toContainText("KVKK Metni");
    await expect(page.getByRole("navigation", { name: "Dil seçimi" }).getByRole("link", { name: "English" })).toBeVisible();
  }

  await page.goto("/?page=login-update-password.ftl");
  await expect(page.locator("#kc-passwd-update-form .sl-legacy-submit")).toHaveCSS("background-color", "rgb(26, 115, 196)");
  await page.locator("#kc-passwd-update-form .sl-legacy-submit").hover();
  await expect(page.locator("#kc-passwd-update-form .sl-legacy-submit")).toHaveCSS("background-color", "rgb(217, 31, 109)");
  await expect(page).toHaveTitle("Parolanı yenile · SKY LAB");
});

test("reduced motion and secondary-button contrast survive hover", async ({ browser }) => {
  const context = await browser.newContext({ reducedMotion: "reduce", locale: "tr-TR" });
  const page = await context.newPage();
  await page.goto("/?page=login.ftl");

  const logoPath = page.locator('[data-skylab-logo-animation="draw"] path').first();
  await expect(logoPath).toHaveCSS("animation-name", "none");
  await expect(logoPath).toHaveCSS("fill-opacity", "1");

  await page.goto("/?page=login-update-password.ftl");

  const mark = page.locator(".sl-legacy-background__mark");
  await expect(mark).toHaveCSS("animation-name", "none");
  await expect(page.locator('[data-skylab-logo-animation="draw"] path').first()).toHaveCSS("animation-name", "none");

  const secondary = page.locator('button[name="cancel-aia"].sl-legacy-choice');
  await expect(secondary).toHaveCSS("background-color", "rgba(255, 255, 255, 0.05)");
  await expect(secondary).toHaveCSS("color", "rgb(244, 244, 245)");
  await secondary.hover();
  await expect(secondary).toHaveCSS("background-color", "rgba(255, 255, 255, 0.1)");

  await context.close();
});

test("WebAuthn registration carries the Keycloak 26.7 resident-key contract", async ({ page }) => {
  await page.goto("/?page=webauthn-register.ftl");

  await expect(page.locator("#authenticatorAttachment")).toHaveAttribute("name", "authenticatorAttachment");
  const moduleSource = await page.locator('script[type="module"]:not([src])').allTextContents();
  const source = moduleSource.join("\n");
  expect(source).toContain("authenticatorAttachment");
  expect(source).toContain("requireResidentKey");
  expect(source).toContain("residentKey");
  expect(source).toContain('"required"');
});

test("optional passkey offer is explicit, branded and always has a safe exit", async ({ page }) => {
  await page.goto("/?page=passkey-offer.ftl");

  await expect(page.locator(".sl-legacy-shell")).toBeVisible();
  await expect(page.getByRole("heading", { name: "Erişim anahtarı ekle" })).toBeVisible();
  await expect(page.getByRole("button", { name: "Şimdi ekle" })).toHaveCSS(
    "background-color",
    "rgb(26, 115, 196)"
  );
  await expect(page.getByRole("button", { name: "30 gün boyunca tekrar sorma" })).toBeVisible();
});

test("WebAuthn retry submits the actual execution and AIA screens expose cancel", async ({ page }) => {
  await page.goto("/?page=webauthn-error.ftl");
  await page.locator("#kc-error-credential-form").evaluate(form => {
    form.addEventListener("submit", event => event.preventDefault(), { once: true });
  });
  await page.locator("#kc-try-again").click();
  await expect(page.locator("#executionValue")).toHaveValue("webauthn-execution-fixture");
  await expect(page.locator("#isSetRetry")).toHaveValue("retry");
  await expect(page.locator("#cancelWebAuthnAIA")).toBeVisible();

  await page.goto("/?page=login-config-totp.ftl");
  await expect(page.locator("#saveTOTPBtn")).toBeVisible();
  await expect(page.locator("#cancelTOTPBtn")).toBeVisible();

  await page.goto("/?page=login-update-password.ftl");
  await expect(page.locator('button[name="cancel-aia"]')).toBeVisible();
});

test("Web handoff failure page shows one sentence per reason in light and dark, and nothing to act on", async ({ page }) => {
  const sentences = {
    expired: "Bağlantının süresi doldu.",
    used: "Bu bağlantı zaten kullanıldı.",
    invalid: "Bağlantı geçersiz.",
    target_disabled: "Bu siteye uygulamadan geçiş şu an kapalı.",
    account_unavailable: "Hesabın şu an kullanılamıyor.",
    unavailable: "Geçici bir sorun oluştu.",
    "not-a-reason": "Geçici bir sorun oluştu."
  };

  for (const colorScheme of ["light", "dark"] as const) {
    await page.emulateMedia({ colorScheme });
    for (const [reason, sentence] of Object.entries(sentences)) {
      await page.goto(`/?page=sky-handoff-failed.ftl&reason=${reason}`);
      await expect(page.locator(".sl-legacy-shell")).toHaveAttribute("data-sl-translations", "ready");
      await expect(page.getByRole("heading", { level: 1 })).toHaveText(sentence);
      await expect(page.locator(".sl-legacy-intro p")).toHaveText("Uygulamaya dönüp tekrar dene.");
      await expect(page.locator("form, input, button, select, textarea")).toHaveCount(0);
      await expect(page.getByRole("navigation", { name: "Dil seçimi" })).toHaveCount(0);
      await expect(page.locator("a")).toHaveCount(2);
      await expect(page.getByRole("contentinfo").getByRole("link", { name: "KVKK Metni" })).toBeVisible();
      await expect(page).toHaveTitle(`${sentence.replace(/\.$/, "")} · SKY LAB`);
    }

    // The LegacyFrame design is dark only: a phone in light mode gets the same page and contrast.
    expect(await page.evaluate(() => getComputedStyle(document.documentElement).colorScheme)).toBe("dark");
    await expect(page.locator(".sl-legacy-intro h1")).toHaveCSS("color", "rgb(255, 255, 255)");
    await expect(page.locator(".sl-legacy-intro p")).toHaveCSS("color", "rgb(161, 161, 170)");
    await expect(page.locator(".sl-body")).toHaveCSS("background-color", "rgb(8, 7, 11)");
  }
});
