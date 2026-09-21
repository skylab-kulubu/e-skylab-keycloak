import { render } from "@testing-library/react";
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

  it("keeps the KVKK footer landmark and marks translation readiness", () => {
    const { container, rerender } = render(
      <LegacyFrame {...chrome} title="Giriş yap" translationsReady={false}>
        <p>İçerik</p>
      </LegacyFrame>
    );

    const footer = container.querySelector("footer.sl-legacy-footer");
    expect(footer).toHaveAttribute("role", "contentinfo");
    expect(footer?.querySelector('a[href="https://skyl.app/kvkk-metni"]')).toHaveTextContent("KVKK metnini");
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
