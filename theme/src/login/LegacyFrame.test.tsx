import { render, within } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import LegacyFrame from "./LegacyFrame";

const chrome = {
  kvkkLinkText: "KVKK metnini",
  kvkkPrefix: "Devam ederek ",
  kvkkSuffix: " kabul edersiniz.",
  mainId: "main",
  skipToContent: "İçeriğe geç",
  titleId: "title"
};

describe("LegacyFrame SKY LAB identity", () => {
  it("links the developer credit to Yusuf Açmacı's LinkedIn in a new tab", () => {
    const { container } = render(
      <LegacyFrame {...chrome} title="Giriş yap">
        <p>İçerik</p>
      </LegacyFrame>
    );

    const credit = container.querySelector("footer .sl-legacy-credit");
    expect(credit?.tagName).toBe("A");
    expect(within(container).getByRole("link", { name: "Developed by Yusuf Açmacı" })).toBe(credit);
    expect(credit).toHaveAttribute("href", "https://www.linkedin.com/in/yusuf-acmaci/");
    expect(credit).toHaveAttribute("target", "_blank");
    expect(credit).toHaveAttribute("rel", "noopener noreferrer");
  });

  it("keeps the developer credit as plain text when the page asks for no link", () => {
    const { container } = render(
      <LegacyFrame {...chrome} creditLinked={false} title="Bağlantı geçersiz.">
        {null}
      </LegacyFrame>
    );

    const credit = container.querySelector("footer .sl-legacy-credit");
    expect(credit?.tagName).toBe("SPAN");
    expect(credit).toHaveTextContent("Developed by Yusuf Açmacı");
    expect(container.querySelector("footer a.sl-legacy-credit")).toBeNull();
  });

  it("renders the Forms-style vector drawing instead of a static logo image", () => {
    const { container } = render(
      <LegacyFrame {...chrome} description="Açıklama" title="Giriş yap">
        <p>İçerik</p>
      </LegacyFrame>
    );

    const animation = container.querySelector('[data-skylab-logo-animation="draw"]');

    expect(animation).not.toBeNull();
    expect(animation).toHaveAttribute("role", "img");
    expect(animation).toHaveAttribute("aria-label", "SKY LAB");
    expect(animation?.querySelectorAll("path")).toHaveLength(19);
    expect(animation?.querySelector("path")).toHaveAttribute("pathLength", "1");
    expect(container.querySelector(".sl-legacy-logo img")).toBeNull();
  });

  it("keeps the wide brand panel to the logo alone: no slogan, no list", () => {
    const { container } = render(
      <LegacyFrame {...chrome} title="Giriş yap" brand>
        <p>İçerik</p>
      </LegacyFrame>
    );

    const panel = container.querySelector(".sl-legacy-card--brand .sl-legacy-brand") as HTMLElement;
    expect(panel.querySelector('[data-skylab-logo-animation="draw"]')).not.toBeNull();
    expect(panel.querySelector("p, ul, li")).toBeNull();
    expect(panel.textContent?.trim()).toBe("");
  });

  it("keeps the KVKK footer landmark and marks translation readiness", () => {
    const { container, rerender } = render(
      <LegacyFrame {...chrome} title="Giriş yap" translationsReady={false}>
        <p>İçerik</p>
      </LegacyFrame>
    );

    const footer = container.querySelector("footer.sl-legacy-footer");
    expect(footer).toHaveAttribute("role", "contentinfo");
    expect(footer?.querySelector('a[href="https://yildizskylab.com/kvkk-metni.pdf"]')).toHaveTextContent("KVKK metnini");
    expect(footer).toHaveTextContent("e-skylab by WEBLAB");
    expect(container.querySelector(".sl-legacy-shell")).toHaveAttribute("data-sl-translations", "loading");
    expect(container.querySelector(".sl-legacy-intro p")).toBeNull();

    rerender(
      <LegacyFrame {...chrome} title="Giriş yap" description="Açıklama" translationsReady>
        <p>İçerik</p>
      </LegacyFrame>
    );

    expect(container.querySelector(".sl-legacy-shell")).toHaveAttribute("data-sl-translations", "ready");
    expect(container.querySelector(".sl-legacy-intro p")).toHaveTextContent("Açıklama");
  });

  it("renders the language menu as plain links with the current locale marked", () => {
    const { container } = render(
      <LegacyFrame
        {...chrome}
        title="Giriş yap"
        languageMenu={{
          currentLanguageTag: "tr",
          label: "Dil seçimi",
          languages: [
            { languageTag: "tr", label: "Türkçe", href: "?lang=tr" },
            { languageTag: "en", label: "English", href: "?lang=en" }
          ]
        }}
      >
        <p>İçerik</p>
      </LegacyFrame>
    );

    const menu = container.querySelector("nav.sl-legacy-languages");
    expect(menu).toHaveAttribute("aria-label", "Dil seçimi");
    const links = menu?.querySelectorAll("a") ?? [];
    expect(links).toHaveLength(2);
    expect(links[0]).toHaveAttribute("aria-current", "page");
    expect(links[0]).toHaveAttribute("lang", "tr");
    expect(links[1]).not.toHaveAttribute("aria-current");
    expect(links[1]).toHaveAttribute("href", "?lang=en");
  });

  it("hides the language menu when only one locale is enabled", () => {
    const { container } = render(
      <LegacyFrame
        {...chrome}
        title="Giriş yap"
        languageMenu={{
          currentLanguageTag: "tr",
          label: "Dil seçimi",
          languages: [{ languageTag: "tr", label: "Türkçe", href: "?lang=tr" }]
        }}
      >
        <p>İçerik</p>
      </LegacyFrame>
    );

    expect(container.querySelector("nav.sl-legacy-languages")).toBeNull();
  });
});
