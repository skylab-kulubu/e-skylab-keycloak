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

test("after a reset request the confirmation is the first thing on the login card and takes focus", async ({ page }) => {
  await page.goto("/?page=login.ftl&state=reset-email-sent");

  const message = page.locator("#sl-page-message");
  await expect(message).toHaveAttribute("role", "status");
  await expect(message).toContainText("birincil e-posta adresine bir bağlantı gönderdik");
  await expect(message).toBeVisible();
  await expect(message).toBeFocused();

  // Above the sign-in choices, without opening the password form first.
  const microsoft = page.getByRole("link", { name: "YTÜ Öğrencisiyim" });
  const messageBox = await message.boundingBox();
  const microsoftBox = await microsoft.boundingBox();
  expect(messageBox).not.toBeNull();
  expect(microsoftBox).not.toBeNull();
  expect((messageBox?.y ?? 0) + (messageBox?.height ?? 0)).toBeLessThanOrEqual(microsoftBox?.y ?? 0);

  // Keyboard users continue from the message into the choices.
  await page.keyboard.press("Tab");
  await expect(microsoft).toBeFocused();

  // The message stays on the card in the password form.
  await page.getByRole("button", { name: "YTÜ Öğrencisi Değilim" }).click();
  await expect(message).toBeVisible();
  await expect(page.locator("#username")).toBeFocused();
});

test("a page-wide login error is an alert on the first screen; wrong credentials stay on the fields", async ({ page }) => {
  await page.goto("/?page=login.ftl&state=idp-error");
  await expect(page.getByRole("alert")).toContainText("beklenmeyen bir sorun");
  await expect(page.getByRole("link", { name: "YTÜ Öğrencisiyim" })).toBeVisible();

  await page.goto("/?page=login.ftl&state=invalid-credentials");
  await expect(page.locator(".sl-legacy-alert")).toHaveCount(0);
  await expect(page.locator("#input-error")).toHaveText("Kullanıcı adı, e-posta veya parola hatalı.");
  await expect(page.locator("#password")).toHaveAttribute("aria-describedby", "input-error");
  await expect(page.getByRole("link", { name: "Parolanı mı unuttun?" })).toBeVisible();
});

for (const viewport of [
  { width: 1280, height: 800 },
  { width: 390, height: 844 }
]) {
  test(`forgot password is on the first screen and right below the password field (${viewport.width}px)`, async ({ browser }) => {
    const context = await browser.newContext({ viewport, locale: "tr-TR" });
    const page = await context.newPage();
    await page.goto("/?page=login.ftl");

    const firstScreenLink = page.getByRole("link", { name: "Parolanı mı unuttun?" });
    await expect(firstScreenLink).toBeVisible();
    await expect(firstScreenLink).toBeInViewport();

    await page.getByRole("button", { name: "YTÜ Öğrencisi Değilim" }).click();
    const link = page.locator("#kc-form-login").getByRole("link", { name: "Parolanı mı unuttun?" });
    await expect(link).toBeVisible();

    const password = await page.locator("#password").boundingBox();
    const linkBox = await link.boundingBox();
    const submit = await page.locator("#kc-login").boundingBox();
    expect(password).not.toBeNull();
    expect(linkBox).not.toBeNull();
    expect(submit).not.toBeNull();
    if (password === null || linkBox === null || submit === null) {
      return;
    }
    // Below the password field, above the submit button, right-aligned with the field.
    expect(linkBox.y).toBeGreaterThanOrEqual(password.y + password.height);
    expect(linkBox.y - (password.y + password.height)).toBeLessThan(48);
    expect(linkBox.y + linkBox.height).toBeLessThanOrEqual(submit.y);
    expect(Math.abs(linkBox.x + linkBox.width - (password.x + password.width))).toBeLessThanOrEqual(1);

    // Keyboard order: password, show password, remember me, then the link.
    await page.locator("#rememberMe").focus();
    await page.keyboard.press("Tab");
    await expect(link).toBeFocused();

    await context.close();
  });
}
