import { cleanup, fireEvent, render, waitFor, within } from "@testing-library/react";
import { afterEach, beforeAll, describe, expect, it } from "vitest";
import { getDevKcContextForPage } from "../devKcContext";
import type { KcContext } from "./KcContext";
import KcPage from "./KcPage";
import type { ThemedPageId } from "./pageIds";

async function renderPage(pageId: ThemedPageId, state: string | null = null) {
  const kcContext = getDevKcContextForPage(pageId, "tr", state);
  const view = render(<KcPage kcContext={kcContext} />);

  await waitFor(() => {
    expect(view.container.querySelector(".sl-legacy-shell")).toHaveAttribute("data-sl-translations", "ready");
    expect(view.container.querySelectorAll("h1")).toHaveLength(1);
  });

  return { ...view, kcContext };
}

/** The card's own children in order: intro, page message, then the page body. */
function cardChildren(container: HTMLElement): Element[] {
  return Array.from(container.querySelector(".sl-legacy-card")?.children ?? []);
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
    expect(message).toHaveTextContent("kısa sürede bir e-posta almalısınız");

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

    fireEvent.click(view.getByRole("button", { name: "YTÜ Öğrencisi Değilim" }));

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
    expect(message).toHaveTextContent("beklenmeyen bir hata");
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
    expect(container.querySelector("#input-error")).toHaveTextContent("Geçersiz kullanıcı adı veya şifre.");
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
    fireEvent.click(view.getByRole("button", { name: "YTÜ Öğrencisi Değilim" }));

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
    fireEvent.click(view.getByRole("button", { name: "YTÜ Öğrencisi Değilim" }));

    expect(view.container.querySelector("#username")).toHaveAttribute("autocomplete", "username webauthn");
    expect(view.getByRole("link", { name: "Parolanı mı unuttun?" })).toHaveAttribute("href", resetUrl);
  });

  it("is absent everywhere when the realm does not allow resetting the password", async () => {
    const kcContext = loginContext();
    kcContext.realm.resetPasswordAllowed = false;
    const view = render(<KcPage kcContext={kcContext} />);
    await waitFor(() => expect(view.container.querySelector(".sl-legacy-choices")).not.toBeNull());

    expect(view.queryByRole("link", { name: "Parolanı mı unuttun?" })).toBeNull();
    fireEvent.click(view.getByRole("button", { name: "YTÜ Öğrencisi Değilim" }));
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
    expect(container.querySelector("#input-error-username")).toHaveTextContent("Lütfen kullanıcı adını belirtin.");
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
