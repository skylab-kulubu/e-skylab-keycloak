import { cleanup, render, screen, within } from "@testing-library/react";
import { afterEach, describe, expect, it } from "vitest";
import WelcomePage, { ACCOUNT_CENTER_URL, KVKK_URL } from "./WelcomePage";
import { renderWelcomeTemplate, WELCOME_TITLE } from "./template";

// Every address the landing page may link to. The page sends no one to the Admin Console, to a
// login form of its own or to a short link: it explains, and the apps start the sign-in.
const allowedLinks = new Set([
  ACCOUNT_CENTER_URL,
  "https://forms.yildizskylab.com/",
  "https://admin.yildizskylab.com/",
  "https://mail.yildizskylab.com/",
  "https://place.yildizskylab.com/",
  "https://yildizskylab.com/",
  KVKK_URL,
  "#sl-welcome-main",
  "#uygulamalar",
  "#giris",
  "#guven"
]);

afterEach(() => {
  cleanup();
});

describe("the e-SKY LAB landing page", () => {
  it("has one page heading, the landmarks and a skip link to the main content", () => {
    const { container } = render(<WelcomePage />);

    expect(screen.getAllByRole("heading", { level: 1 })).toHaveLength(1);
    expect(screen.getByRole("heading", { level: 1 })).toHaveTextContent("Tek hesap, bütün SKY LAB.");
    expect(screen.getByRole("banner")).toBeInTheDocument();
    expect(screen.getByRole("main")).toHaveAttribute("id", "sl-welcome-main");
    expect(screen.getByRole("main")).toHaveAttribute("tabindex", "-1");
    expect(screen.getByRole("contentinfo")).toHaveTextContent("e-skylab by WEBLAB");
    expect(screen.getByRole("link", { name: "İçeriğe geç" })).toHaveAttribute("href", "#sl-welcome-main");

    // The same chrome as the login page: background layers, the animated logo.
    expect(container.querySelector(".sl-legacy-shell .sl-legacy-background[aria-hidden='true']")).not.toBeNull();
    const logo = container.querySelector('[data-skylab-logo-animation="draw"]');
    expect(logo).toHaveAttribute("role", "img");
    expect(logo?.querySelectorAll("path")).toHaveLength(19);

    for (const name of ["Nerede kullanılır?", "Nasıl giriş yapılır?", "Okul şifren yalnız Microsoft'ta."]) {
      expect(screen.getByRole("heading", { level: 2, name })).toBeInTheDocument();
    }
  });

  it("says what e-SKY LAB is and links to Account Center", () => {
    render(<WelcomePage />);

    expect(screen.getByText(/e-SKY LAB, SKY LAB'in giriş hizmetidir\./)).toBeInTheDocument();
    const accountCenter = screen.getAllByRole("link", { name: /Hesap Merkezi/ });
    expect(accountCenter.length).toBeGreaterThan(0);
    for (const link of accountCenter) {
      expect(link).toHaveAttribute("href", ACCOUNT_CENTER_URL);
    }
  });

  it("lists the apps that use the account, with their addresses", () => {
    render(<WelcomePage />);

    const apps = within(screen.getByRole("list", { name: "e-SKY LAB hesabıyla girilen uygulamalar" }));
    const expected: Array<[string, string]> = [
      ["Hesap Merkezi", "my.yildizskylab.com"],
      ["SkyForms", "forms.yildizskylab.com"],
      ["Yönetim paneli", "admin.yildizskylab.com"],
      ["SkyMail", "mail.yildizskylab.com"],
      ["YıldızPlace", "place.yildizskylab.com"],
      ["Kulüp siteleri", "yildizskylab.com"]
    ];
    const items = apps.getAllByRole("listitem");
    expect(items).toHaveLength(expected.length);
    expected.forEach(([name, host], index) => {
      expect(items[index]).toHaveTextContent(name);
      expect(items[index]).toHaveTextContent(host);
      expect(within(items[index]).getByRole("link")).toHaveAttribute("href", `https://${host}/`);
    });
  });

  it("explains today's sign-in ways with the buttons' own labels", () => {
    render(<WelcomePage />);

    const steps = within(screen.getByRole("list", { name: "Giriş yolları" })).getAllByRole("listitem");
    expect(steps).toHaveLength(3);
    // The labels are the login page's (theme/src/login/i18n.ts: microsoft, notYtuStudent, passkeyChoice).
    expect(steps[0]).toHaveTextContent("YTÜ Öğrencisiyim");
    expect(steps[0]).toHaveTextContent("Microsoft");
    expect(steps[1]).toHaveTextContent("YTÜ Öğrencisi Değilim");
    expect(steps[1]).toHaveTextContent("Parolanı mı unuttun?");
    expect(steps[2]).toHaveTextContent("Erişim anahtarı ile giriş yap");
    // Self-registration (ADR-0063) is not live yet; the page does not promise it.
    expect(screen.getByText(/YTÜ hesabın yoksa bugün kendin hesap açamazsın/)).toBeInTheDocument();
  });

  it("carries the trust copy of the login spec word for word", () => {
    render(<WelcomePage />);

    const trust = within(screen.getByRole("list", { name: "Şifren ve verilerin" }));
    expect(
      trust.getByText("Okul şifreni yalnız Microsoft'un sayfasına yazarsın; SKY LAB onu hiçbir zaman görmez.")
    ).toBeInTheDocument();
    expect(
      trust.getByText(
        "YTÜ hesabından yalnız adını, okul e-postanı ve bölümünü alırız; postalarına ve dosyalarına erişmeyiz.",
        { exact: false }
      )
    ).toBeInTheDocument();
    expect(trust.getByText(/değişmez kimlik numarasını/)).toBeInTheDocument();
    expect(trust.getByText(/Giriş adresi her zaman e\.yildizskylab\.com'dur\./)).toBeInTheDocument();

    const kvkk = screen.getAllByRole("link", { name: "KVKK Aydınlatma Metni" });
    expect(kvkk.length).toBeGreaterThan(0);
    for (const link of kvkk) {
      expect(link).toHaveAttribute("href", KVKK_URL);
    }
  });

  it("links only to the allowed addresses and never to the Admin Console", () => {
    const { container } = render(<WelcomePage />);

    for (const link of container.querySelectorAll("a")) {
      expect(allowedLinks, link.outerHTML).toContain(link.getAttribute("href"));
      expect(link.getAttribute("target")).toBeNull();
    }
    expect(container.innerHTML).not.toMatch(/\/admin\/|realms\/master|skyl\.app/);
  });

  it("gives every in-page link a target on the page", () => {
    const { container } = render(<WelcomePage />);

    for (const link of container.querySelectorAll('a[href^="#"]')) {
      const id = link.getAttribute("href")?.slice(1) ?? "";
      expect(container.querySelector(`#${id}`), id).not.toBeNull();
    }
  });
});

describe("the welcome theme template (index.ftl)", () => {
  const template = renderWelcomeTemplate();

  it("is a static Turkish document: no script, form, frame or inline handler", () => {
    expect(template).toMatch(/^<#-- [^\n]+ -->\n<!doctype html>\n<html lang="tr" class="sl-html">/);
    expect(template).toContain(`<title>${WELCOME_TITLE}</title>`);
    expect(template).toContain('<meta name="viewport" content="width=device-width, initial-scale=1">');
    expect(template).toContain('<body class="sl-body">');
    expect(template).not.toMatch(/<script|<form|<iframe|<object|<embed|<input|<button|\son[a-z]+=/i);
  });

  it("uses no Keycloak value but the theme's resource path", () => {
    // Keycloak hands the welcome theme adminUrl, localAdminUrl, stateChecker and bootstrap; the page
    // uses none of them, so it can never show the Admin Console link or the admin creation form.
    const interpolations = template.match(/\$\{[^}]*\}/g) ?? [];
    expect(new Set(interpolations)).toEqual(new Set(["${resourcesPath}"]));
    expect(template).not.toMatch(/adminUrl|localAdminUrl|stateChecker|bootstrap|<#if|<#list/);
    expect(template).toContain('<link rel="stylesheet" href="${resourcesPath}/welcome.css">');
    expect(template).toContain('<link rel="icon" type="image/png" href="${resourcesPath}/skylab-logo.png">');
  });

  it("keeps the page body out of FreeMarker's reach", () => {
    const body = template.slice(template.indexOf('<body class="sl-body">'));
    expect(body.indexOf("<#noparse>")).toBeGreaterThan(0);
    expect(body.indexOf("</#noparse>")).toBeGreaterThan(body.indexOf("<#noparse>"));
    expect(body.slice(body.indexOf("<#noparse>") + 10, body.indexOf("</#noparse>"))).not.toContain("#noparse");
    expect(template.trimEnd().endsWith("</html>")).toBe(true);
  });
});
