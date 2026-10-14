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

  it("is on the first screen, under the sign-in choices", async () => {
    const view = await renderPage("login.ftl");

    const link = view.getByRole("link", { name: "Parolanı mı unuttun?" });
    expect(link).toHaveAttribute("href", resetUrl);
    // After the choices (and the passkey button), so the primary choices stay first in reading order.
    const choices = view.container.querySelector(".sl-legacy-choices");
    expect(choices?.compareDocumentPosition(link) ?? 0).toBe(Node.DOCUMENT_POSITION_FOLLOWING);
    expect(view.container.querySelector("#authenticateWebAuthnButton")?.compareDocumentPosition(link) ?? 0).toBe(
      Node.DOCUMENT_POSITION_FOLLOWING
    );
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

  it("does not assume an account in the description", async () => {
    const { container } = await renderPage("login.ftl");

    expect(container.querySelector(".sl-legacy-intro p")).toHaveTextContent(
      "YTÜ öğrencisiysen okul hesabınla gir. SKY LAB hesabın varsa e-posta adresin ve parolanla da girebilirsin."
    );
  });

  it("says under the choices that the school password stays with Microsoft and what is taken", async () => {
    const view = await renderPage("login.ftl");

    const trust = view.container.querySelector(".sl-legacy-trust") as HTMLElement;
    expect(trust).not.toBeNull();
    expect(view.container.querySelector(".sl-legacy-choices")?.compareDocumentPosition(trust)).toBe(
      Node.DOCUMENT_POSITION_FOLLOWING
    );
    expect(trust).toHaveTextContent(
      "Okul şifreni yalnız Microsoft'un sayfasına yazarsın; SKY LAB onu hiçbir zaman görmez. YTÜ hesabından yalnız adını, okul e-postanı ve bölümünü alırız; postalarına ve dosyalarına erişmeyiz."
    );

    const details = within(trust).getByText("Neleri alıyoruz?").closest("details") as HTMLDetailsElement;
    expect(details).not.toBeNull();
    expect(details.open).toBe(false);
    const taken = within(details).getAllByRole("listitem").map(item => item.textContent);
    expect(taken).toEqual([
      "Microsoft hesabının değişmez kimlik numarası (hesabını tanımak için)",
      "Adın ve soyadın",
      "Okul e-posta adresin",
      "Bölümün"
    ]);
    expect(details).toHaveTextContent(
      "Almadıklarımız: okul şifren (Microsoft'un sayfasına yazarsın, bize hiç gelmez), postaların, dosyaların (OneDrive), takvimin, kişilerin ve Teams."
    );
  });

  it("helps someone who does not know the school password, in a new tab", async () => {
    const view = await renderPage("login.ftl");

    const details = view.getByText("Okul şifreni bilmiyor musun?").closest("details") as HTMLElement;
    expect(details).not.toBeNull();
    const reset = within(details).getByRole("link", { name: "Okul şifreni Microsoft'ta sıfırla" });
    expect(reset).toHaveAttribute("href", "https://passwordreset.microsoftonline.com/");
    expect(details).toHaveTextContent("Olmazsa YTÜ BİDB'ye başvur: teknikdestek.yildiz.edu.tr");
    const support = within(details).getByRole("link", { name: "teknikdestek.yildiz.edu.tr" });
    expect(support).toHaveAttribute("href", "https://teknikdestek.yildiz.edu.tr/");
    for (const link of [reset, support]) {
      expect(link).toHaveAttribute("target", "_blank");
      expect(link).toHaveAttribute("rel", "noreferrer");
    }
    expect(details).toHaveTextContent("SKY LAB parolan varsa E-postayla devam et'i seç.");
  });

  it("names the sign-in address on both screens", async () => {
    const view = await renderPage("login.ftl");
    const notice = "Giriş adresi her zaman e.yildizskylab.com'dur.";

    expect(view.getByText(notice)).toBeInTheDocument();
    fireEvent.click(view.getByRole("button", { name: "E-postayla devam et" }));
    expect(view.getByText(notice)).toBeInTheDocument();
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

  it("tells honestly that accounts outside YTÜ are opened by the club and how to ask for one", async () => {
    const view = await renderPage("login.ftl");
    expect(view.container.querySelector(".sl-legacy-no-account")).toBeNull();

    fireEvent.click(view.getByRole("button", { name: "E-postayla devam et" }));

    const help = view.container.querySelector(".sl-legacy-no-account") as HTMLElement;
    expect(help).not.toBeNull();
    // After the form: the sign-in fields and the submit button come first.
    expect(view.container.querySelector("#kc-login")?.compareDocumentPosition(help)).toBe(Node.DOCUMENT_POSITION_FOLLOWING);
    expect(within(help).getByText("Hesabın yok mu?")).toBeInTheDocument();
    expect(help).toHaveTextContent(
      "YTÜ öğrencisiysen geri dön ve YTÜ hesabınla devam et; SKY LAB hesabın ilk girişinde açılır."
    );
    expect(help).toHaveTextContent(
      "YTÜ dışından bugün kendin hesap açamazsın; hesabı kulüp yöneticileri açar. Hesap istemek için bize yaz: info@yildizskylab.com"
    );
    expect(within(help).getByRole("link", { name: "info@yildizskylab.com" })).toHaveAttribute(
      "href",
      "mailto:info@yildizskylab.com"
    );
  });

  it("never links Keycloak's built-in registration, even if the realm offered it (ADR-0063)", async () => {
    const kcContext = loginContext();
    kcContext.realm.registrationAllowed = true;
    kcContext.url.registrationUrl = "/realms/e-skylab/login-actions/registration";
    const view = render(<KcPage kcContext={kcContext} />);
    await waitFor(() => expect(view.container.querySelector(".sl-legacy-choices")).not.toBeNull());

    fireEvent.click(view.getByRole("button", { name: "E-postayla devam et" }));
    const hrefs = Array.from(view.container.querySelectorAll("a")).map(link => link.getAttribute("href") ?? "");
    expect(hrefs.filter(href => href.includes("registration"))).toEqual([]);
    expect(view.queryByText("Kayıt ol")).toBeNull();
  });
});
