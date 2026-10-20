import { describe, expect, it } from "vitest";
import type { I18n } from "./i18n";
import { getLegacyLanguageMenu } from "./legacyChrome";

function i18nWith(languageTags: string[], current = "en"): I18n {
  return {
    currentLanguage: { languageTag: current, label: current },
    enabledLanguages: languageTags.map(languageTag => ({ languageTag, label: languageTag, href: `?kc_locale=${languageTag}` })),
    msgStr: (key: string) => key
  } as unknown as I18n;
}

describe("the language menu", () => {
  it("puts Türkçe first, whatever order Keycloak lists the languages in", () => {
    const menu = getLegacyLanguageMenu(i18nWith(["en", "tr"]));
    expect(menu.languages.map(language => language.languageTag)).toEqual(["tr", "en"]);
    expect(menu.languages[0]).toEqual({ languageTag: "tr", label: "tr", href: "?kc_locale=tr" });
    expect(menu.currentLanguageTag).toBe("en");
  });

  it("keeps Keycloak's order for the other languages", () => {
    expect(getLegacyLanguageMenu(i18nWith(["de", "en", "tr-TR", "fr"])).languages.map(language => language.languageTag)).toEqual([
      "tr-TR",
      "de",
      "en",
      "fr"
    ]);
  });
});
