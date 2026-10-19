import { cleanup, fireEvent, render, waitFor, within } from "@testing-library/react";
import { afterEach, beforeAll, describe, expect, it } from "vitest";
import { getDevKcContextForPage } from "../devKcContext";
import type { KcContext } from "./KcContext";
import KcPage from "./KcPage";
import type { ThemedPageId } from "./pageIds";
import { KVKK_URL } from "../welcome/WelcomePage";

async function renderPage(pageId: ThemedPageId, state: string | null = null) {
  const kcContext = getDevKcContextForPage(pageId, "tr", state);
  const view = render(<KcPage kcContext={kcContext} />);

  await waitFor(() => {
    expect(view.container.querySelector(".sl-legacy-shell")).toHaveAttribute("data-sl-translations", "ready");
    expect(view.container.querySelectorAll("h1")).toHaveLength(1);
  });

  return { ...view, kcContext };
}

/** The page column's children in order: intro, page message, then the page body. */
function cardChildren(container: HTMLElement): Element[] {
  return Array.from(container.querySelector(".sl-legacy-card__body")?.children ?? []);
}

function loginContext(): Extract<KcContext, { pageId: "login.ftl" }> {
  const kcContext = getDevKcContextForPage("login.ftl");
  if (kcContext.pageId !== "login.ftl") {
    throw new Error("expected the login page");
  }
  return kcContext;
}

const resetUrl = loginContext().url.loginResetCredentialsUrl;

describe("login page: page-wide messages", () => {
  beforeAll(() => {
    window.history.replaceState(null, "", "/?viewMode=docs");
  });

  afterEach(() => {
    cleanup();
  });

  it("shows the reset e-mail confirmation at the top of the card on the first screen and focuses it", async () => {
    const { container } = await renderPage("login.ftl", "reset-email-sent");

    const message = container.querySelector("#sl-page-message");
    expect(message).toHaveClass("sl-legacy-alert", "sl-legacy-alert--success");
    expect(message).toHaveAttribute("role", "status");
    expect(message).toHaveTextContent("birincil e-posta adresine bir bağlantı gönderdik");

    // Directly under the heading, before the sign-in choices; nothing to expand first.
    const children = cardChildren(container);
    expect(children[0]).toHaveClass("sl-legacy-intro");
    expect(children[1]).toBe(message);
    expect(container.querySelector(".sl-legacy-choices")).not.toBeNull();
    expect(container.querySelector("#kc-form-login")).toBeNull();

    await waitFor(() => expect(message).toHaveFocus());
  });

  it("keeps the message on screen after switching to the password form", async () => {
    const view = await renderPage("login.ftl", "reset-email-sent");

    fireEvent.click(view.getByRole("button", { name: "E-postayla devam et" }));

    expect(view.container.querySelector("#kc-form-login")).not.toBeNull();
    expect(view.container.querySelectorAll(".sl-legacy-alert")).toHaveLength(1);
    expect(cardChildren(view.container)[1]).toHaveAttribute("id", "sl-page-message");
    expect(view.container.querySelector("#username")).toHaveFocus();
  });

  it("shows a page-wide error (failed YTÜ Microsoft sign-in) as an alert on the first screen", async () => {
    const { container } = await renderPage("login.ftl", "idp-error");

    const message = container.querySelector("#sl-page-message");
    expect(message).toHaveClass("sl-legacy-alert--error");
    expect(message).toHaveAttribute("role", "alert");
    expect(message).toHaveTextContent("beklenmeyen bir sorun");
    expect(cardChildren(container)[1]).toBe(message);
  });

  it("shows warnings too", async () => {
    const kcContext = getDevKcContextForPage("login.ftl");
    kcContext.message = { type: "warning", summary: "Oturumun sona ermek üzere." };
    const { container } = render(<KcPage kcContext={kcContext} />);

    await waitFor(() => expect(container.querySelector("#sl-page-message")).toHaveTextContent("Oturumun sona ermek üzere."));
    expect(container.querySelector("#sl-page-message")).toHaveAttribute("role", "status");
  });

  it("ties wrong credentials to the fields once, without a duplicate page-wide alert", async () => {
    const { container } = await renderPage("login.ftl", "invalid-credentials");

    expect(container.querySelector("#kc-form-login")).not.toBeNull();
    expect(container.querySelector(".sl-legacy-alert")).toBeNull();
    expect(container.querySelector("#input-error")).toHaveTextContent("Kullanıcı adı, e-posta veya parola hatalı.");
    expect(container.querySelector("#username")).toHaveAttribute("aria-describedby", "input-error");
    expect(container.querySelector("#password")).toHaveAttribute("aria-describedby", "input-error");
    expect(container.querySelector("#username")).toHaveFocus();
  });
});

describe("login page: forgot password link", () => {
  beforeAll(() => {
    window.history.replaceState(null, "", "/?viewMode=docs");
  });

  afterEach(() => {
    cleanup();
  });

  it("is not on the first screen: it waits in the password form, where a password is typed", async () => {
    const view = await renderPage("login.ftl");

    expect(view.queryByRole("link", { name: "Parolanı mı unuttun?" })).toBeNull();
    expect(view.container).not.toHaveTextContent("Parolanı mı unuttun?");
    fireEvent.click(view.getByRole("button", { name: "E-postayla devam et" }));
    expect(view.getByRole("link", { name: "Parolanı mı unuttun?" })).toHaveAttribute("href", resetUrl);
  });

  it("sits directly below the password field in the password form, before the submit button", async () => {
    const view = await renderPage("login.ftl");
    fireEvent.click(view.getByRole("button", { name: "E-postayla devam et" }));

    const form = view.container.querySelector("#kc-form-login") as HTMLElement;
    const links = within(form).getAllByRole("link", { name: "Parolanı mı unuttun?" });
    expect(links).toHaveLength(1);
    const [link] = links;
    expect(link).toHaveAttribute("href", resetUrl);

    // Not in the label row any more: the keyboard order is username, password, then the link.
    expect(view.container.querySelector(".sl-legacy-field__heading")).toBeNull();
    const options = link.closest(".sl-legacy-form-options");
    expect(options).not.toBeNull();
    expect(options?.previousElementSibling?.querySelector("#password")).not.toBeNull();
    expect(link.compareDocumentPosition(view.container.querySelector("#kc-login") as Node)).toBe(
      Node.DOCUMENT_POSITION_FOLLOWING
    );
    expect(view.container.querySelector("#password")?.compareDocumentPosition(link)).toBe(
      Node.DOCUMENT_POSITION_FOLLOWING
    );
    // Remember me shares the row, on the left.
    expect(options?.querySelector("#rememberMe")).not.toBeNull();
  });

  it("stays reachable in the error state", async () => {
    const view = await renderPage("login.ftl", "invalid-credentials");

    const form = view.container.querySelector("#kc-form-login") as HTMLElement;
    expect(within(form).getByRole("link", { name: "Parolanı mı unuttun?" })).toHaveAttribute("href", resetUrl);
  });

  it("stays reachable with conditional passkey sign-in on the username field", async () => {
    const view = await renderPage("login.ftl");
    fireEvent.click(view.getByRole("button", { name: "E-postayla devam et" }));

    expect(view.container.querySelector("#username")).toHaveAttribute("autocomplete", "username webauthn");
    expect(view.getByRole("link", { name: "Parolanı mı unuttun?" })).toHaveAttribute("href", resetUrl);
  });

  it("is absent everywhere when the realm does not allow resetting the password", async () => {
    const kcContext = loginContext();
    kcContext.realm.resetPasswordAllowed = false;
    const view = render(<KcPage kcContext={kcContext} />);
    await waitFor(() => expect(view.container.querySelector(".sl-legacy-choices")).not.toBeNull());

    expect(view.queryByRole("link", { name: "Parolanı mı unuttun?" })).toBeNull();
    fireEvent.click(view.getByRole("button", { name: "E-postayla devam et" }));
    expect(view.queryByRole("link", { name: "Parolanı mı unuttun?" })).toBeNull();
  });
});

describe("every other page: the message sits at the top of the card", () => {
  beforeAll(() => {
    window.history.replaceState(null, "", "/?viewMode=docs");
  });

  afterEach(() => {
    cleanup();
  });

  // Pages that render Keycloak's message through Template's header slot.
  const templatePages: ThemedPageId[] = [
    "login-reset-password.ftl",
    "login-update-password.ftl",
    "login-password.ftl",
    "login-username.ftl",
    "login-otp.ftl",
    "login-config-totp.ftl",
    "webauthn-authenticate.ftl",
    "webauthn-register.ftl",
    "webauthn-error.ftl",
    "login-passkeys-conditional-authenticate.ftl",
    "select-authenticator.ftl",
    "login-verify-email.ftl"
  ];
  // The user-profile pages (login-update-profile, update-email, idp-review-user-profile) show only
  // Keycloak's "global" message there, attribute errors stay on their fields (Keycloak's own rule).

  it.each(templatePages)("%s puts a page-wide message directly under the heading", async pageId => {
    const kcContext = getDevKcContextForPage(pageId);
    kcContext.isAppInitiatedAction = false;
    kcContext.message = { type: "info", summary: "Sayfa genelindeki bilgi." };
    const { container } = render(<KcPage kcContext={kcContext} />);

    await waitFor(() => expect(container.querySelector("#sl-page-message")).not.toBeNull());
    const message = container.querySelector("#sl-page-message");
    expect(message).toHaveTextContent("Sayfa genelindeki bilgi.");
    expect(message).toHaveAttribute("role", "status");

    // Under the intro, or under the attempted-username line that belongs to the header.
    const before = cardChildren(container).slice(0, cardChildren(container).indexOf(message as Element));
    expect(before[0]).toHaveClass("sl-legacy-intro");
    for (const element of before.slice(1)) {
      expect(element).toHaveClass("sl-legacy-attempted-user");
    }
  });

  it("login-reset-password.ftl keeps a missing username on the field, once", async () => {
    const { container } = await renderPage("login-reset-password.ftl", "missing-username");

    await waitFor(() => expect(container.querySelector("#kc-reset-password-form")).not.toBeNull());
    expect(container.querySelector(".sl-legacy-alert")).toBeNull();
    expect(container.querySelector("#input-error-username")).toHaveTextContent("Kullanıcı adını veya e-postanı yaz.");
  });

  it("does not take focus away from a field the page focuses itself", async () => {
    const kcContext = getDevKcContextForPage("login-update-password.ftl");
    kcContext.isAppInitiatedAction = false;
    kcContext.message = { type: "info", summary: "Sayfa genelindeki bilgi." };
    const { container } = render(<KcPage kcContext={kcContext} />);

    await waitFor(() => expect(container.querySelector("#sl-page-message")).not.toBeNull());
    expect(container.querySelector("#password-new")).toHaveFocus();
  });

  it("info.ftl and error.ftl show the message as the page body", async () => {
    const info = await renderPage("info.ftl");
    expect(info.container.querySelector("#kc-info-message")).toHaveTextContent("Artık SKY LAB hesabınla");
    info.unmount();

    const error = await renderPage("error.ftl");
    expect(error.container.querySelector("#kc-error-message")).toHaveTextContent("Giriş isteği geçersiz");
  });
});

describe("login page: sign-in choices and trust copy (eskylab-login-ux 05)", () => {
  beforeAll(() => {
    window.history.replaceState(null, "", "/?viewMode=docs");
  });

  afterEach(() => {
    cleanup();
  });

  it("names the two ways in by what the person has, not by who they are", async () => {
    const view = await renderPage("login.ftl");

    const microsoft = view.getByRole("link", { name: "YTÜ hesabınla devam et Microsoft ile" });
    expect(microsoft).toHaveAttribute("href", loginContext().social?.providers?.[0]?.loginUrl);
    expect(view.getByRole("button", { name: "E-postayla devam et" })).toBeInTheDocument();
    expect(view.container).not.toHaveTextContent("Öğrencisi");
  });

  it.each([
    { language: "tr" as const, text: "YTÜ hesabınla ya da e-posta adresinle devam et." },
    { language: "en" as const, text: "Continue with your YTÜ account or email address." }
  ])("describes both entry methods without a password prerequisite ($language)", async ({ language, text }) => {
    const kcContext = getDevKcContextForPage("login.ftl", language);
    const { container } = render(<KcPage kcContext={kcContext} />);
    await waitFor(() => expect(container.querySelector(".sl-legacy-shell")).toHaveAttribute("data-sl-translations", "ready"));
    expect(container.querySelector(".sl-legacy-intro p")?.textContent).toBe(text);
  });

  it("keeps the first screen to the choices, one quiet line and a plain reset link: no explanatory copy", async () => {
    const view = await renderPage("login.ftl");

    // Reading order: the two choices, the quiet line, the school password reset link.
    const choices = view.container.querySelector(".sl-legacy-choices") as Element;
    const alternatives = view.container.querySelector(".sl-legacy-alternatives") as Element;
    const reset = view.getByRole("link", { name: "Okul şifreni sıfırla" });
    expect(choices.compareDocumentPosition(alternatives)).toBe(Node.DOCUMENT_POSITION_FOLLOWING);
    expect(alternatives.compareDocumentPosition(reset)).toBe(Node.DOCUMENT_POSITION_FOLLOWING);
    expect(reset).toHaveAttribute("href", "https://passwordreset.microsoftonline.com/");
    expect(reset).toHaveAttribute("target", "_blank");
    expect(reset).toHaveAttribute("rel", "noopener noreferrer");
    expect(reset.closest("p")?.textContent).toBe("Okul şifreni sıfırla");

    // Nothing to unfold and none of the removed sentences (Yusuf, 2026-10-19).
    expect(view.container.querySelector("details")).toBeNull();
    for (const removed of [
      "Okul şifreni yalnız Microsoft'a yazarsın",
      "Neleri alıyoruz?",
      "Postalarına ve dosyalarına erişmeyiz",
      "Okul şifreni bilmiyor musun?",
      "BİDB",
      "Giriş adresi her zaman",
      "Tek hesap, tek giriş"
    ]) {
      expect(view.container, removed).not.toHaveTextContent(removed);
    }
  });

  it("says the same in English", async () => {
    const kcContext = getDevKcContextForPage("login.ftl", "en");
    const view = render(<KcPage kcContext={kcContext} />);
    await waitFor(() => expect(view.container.querySelector(".sl-legacy-shell")).toHaveAttribute("data-sl-translations", "ready"));

    expect(view.getByRole("link", { name: "Reset your school password" })).toHaveAttribute(
      "href",
      "https://passwordreset.microsoftonline.com/"
    );
    for (const removed of ["SKY LAB never sees it", "What do we take?", "contact YTÜ IT", "The sign-in address is always", "One account, one sign-in"]) {
      expect(view.container, removed).not.toHaveTextContent(removed);
    }
  });

  it("puts the passkey on one quiet line under the two choices", async () => {
    const view = await renderPage("login.ftl");

    const alternatives = view.container.querySelector(".sl-legacy-alternatives") as HTMLElement;
    const passkey = within(alternatives).getByRole("button", { name: "Erişim anahtarı ile giriş yap" });
    expect(passkey).toHaveAttribute("id", "authenticateWebAuthnButton");
    // Only the two main choices are big buttons.
    expect(view.container.querySelectorAll(".sl-legacy-choice")).toHaveLength(2);
  });

  it("drops the school password link without a YTÜ provider", async () => {
    const kcContext = loginContext();
    kcContext.social = undefined;
    const view = render(<KcPage kcContext={kcContext} />);
    await waitFor(() => expect(view.container.querySelector(".sl-legacy-choices")).not.toBeNull());

    expect(view.queryByRole("link", { name: "Okul şifreni sıfırla" })).toBeNull();
  });

  it("keeps the wide panel to the logo alone", async () => {
    const view = await renderPage("login.ftl");

    const panel = view.container.querySelector(".sl-legacy-card--brand .sl-legacy-brand") as HTMLElement;
    expect(panel.querySelector('[data-skylab-logo-animation="draw"]')).not.toBeNull();
    expect(panel.textContent?.trim()).toBe("");
  });

  it("points to the KVKK notice itself and says it can be read, not that it was accepted", async () => {
    const { container } = await renderPage("login.ftl");

    const footer = container.querySelector("footer.sl-legacy-footer p") as HTMLElement;
    expect(footer).toHaveTextContent("Kişisel verilerinin nasıl işlendiğini KVKK Aydınlatma Metni'nde okuyabilirsin.");
    expect(within(footer).getByRole("link", { name: "KVKK Aydınlatma Metni" })).toHaveAttribute("href", KVKK_URL);
  });
});

describe("login page: no account yet (password form)", () => {
  beforeAll(() => {
    window.history.replaceState(null, "", "/?viewMode=docs");
  });

  afterEach(() => {
    cleanup();
  });

  it("sends a YTÜ student without an account straight to the YTÜ sign-in, and promises nothing else", async () => {
    const view = await renderPage("login.ftl");
    expect(view.container.querySelector(".sl-legacy-no-account")).toBeNull();

    fireEvent.click(view.getByRole("button", { name: "E-postayla devam et" }));

    const help = view.container.querySelector(".sl-legacy-no-account") as HTMLElement;
    expect(help).not.toBeNull();
    // After the form: the sign-in fields and the submit button come first.
    expect(view.container.querySelector("#kc-login")?.compareDocumentPosition(help)).toBe(Node.DOCUMENT_POSITION_FOLLOWING);
    expect(within(help).getByText("Hesabın yok mu?")).toBeInTheDocument();
    expect(help.querySelectorAll("p")[1]?.textContent).toBe("YTÜ hesabın varsa YTÜ hesabınla devam et.");
    expect(within(help).getByRole("link", { name: "YTÜ hesabınla devam et" })).toHaveAttribute(
      "href",
      loginContext().social?.providers?.[0]?.loginUrl
    );
    // No contact address or "ask the club" promise until self-registration (ticket 09) replaces this block.
    expect(help).not.toHaveTextContent("@");
    expect(help.querySelectorAll("a")).toHaveLength(1);
  });

  it("never links Keycloak's built-in registration, even if the realm offered it (ADR-0063)", async () => {
    const kcContext = loginContext();
    kcContext.realm.registrationAllowed = true;
    kcContext.url.registrationUrl = "/realms/e-skylab/login-actions/registration";
    const view = render(<KcPage kcContext={kcContext} />);
    await waitFor(() => expect(view.container.querySelector(".sl-legacy-choices")).not.toBeNull());
    const registrationLinks = () =>
      Array.from(view.container.querySelectorAll("a"))
        .map(link => link.getAttribute("href") ?? "")
        .filter(href => href.includes("registration"));

    // Neither the choice screen nor the password form.
    expect(registrationLinks()).toEqual([]);
    expect(view.queryByText("Kayıt ol")).toBeNull();
    fireEvent.click(view.getByRole("button", { name: "E-postayla devam et" }));
    expect(registrationLinks()).toEqual([]);
    expect(view.queryByText("Kayıt ol")).toBeNull();
  });
});
