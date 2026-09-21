import { isValidElement, useEffect, type ReactNode } from "react";
import { useSetClassName } from "keycloakify/tools/useSetClassName";
import type { I18n } from "./i18n";
import type { LegacyFrameLanguageMenu } from "./LegacyFrame";

type LegacyChromeOptions = {
  /** "login" keeps the login page's KVKK sentence; "action" is the context-neutral variant of every other page. */
  kvkk?: "login" | "action";
};

/** Props shared by every page rendered inside `LegacyFrame` (skip link, KVKK footer, language menu). */
export function getLegacyChromeProps(i18n: I18n, options: LegacyChromeOptions = {}) {
  const { kvkk = "login" } = options;
  const { msgStr } = i18n;

  return {
    kvkkLinkText: msgStr("kvkkLinkText"),
    kvkkPrefix: msgStr(kvkk === "login" ? "kvkkPrefix" : "kvkkActionPrefix"),
    kvkkSuffix: msgStr(kvkk === "login" ? "kvkkSuffix" : "kvkkActionSuffix"),
    languageMenu: getLegacyLanguageMenu(i18n),
    skipToContent: msgStr("skipToContent"),
    translationsReady: !i18n.isFetchingTranslations
  };
}

export function getLegacyLanguageMenu(i18n: I18n): LegacyFrameLanguageMenu {
  const { currentLanguage, enabledLanguages, msgStr } = i18n;

  return {
    currentLanguageTag: currentLanguage.languageTag,
    label: msgStr("languages"),
    languages: enabledLanguages.map(({ href, label, languageTag }) => ({ href, label, languageTag }))
  };
}

/** The one-sentence explanation under a page title; undefined when no copy exists for the page. */
export function getLegacyPageDescription(i18n: I18n, pageId: string): string | undefined {
  const key = `skylabPageDesc.${pageId.replace(/\.ftl$/, "")}`;
  const resolved = i18n.advancedMsgStr(key);

  return resolved === key ? undefined : resolved;
}

type LegacyTitleOptions = {
  /** The title already names the brand (the login page); otherwise " · SKY LAB" is appended. */
  brandedTitle?: boolean;
};

/** Document title, html/body class names and the html lang attribute, in one place for every page. */
export function useLegacyChrome(i18n: I18n, title: string, options: LegacyTitleOptions = {}): void {
  const { brandedTitle = false } = options;
  const { languageTag } = i18n.currentLanguage;

  useSetClassName({ qualifiedName: "html", className: "sl-html" });
  useSetClassName({ qualifiedName: "body", className: "sl-body" });

  useEffect(() => {
    document.title = brandedTitle ? title : `${title} · SKY LAB`;
    document.documentElement.lang = languageTag;
  }, [brandedTitle, languageTag, title]);
}

/**
 * Plain text of a page heading. Keycloakify hands headings over as React
 * nodes whose `msg()` parts carry sanitized HTML, so the markup is stripped.
 */
export function reactNodeToText(node: ReactNode): string {
  if (node === null || node === undefined || typeof node === "boolean") {
    return "";
  }
  if (typeof node === "string" || typeof node === "number") {
    return String(node);
  }
  if (Array.isArray(node)) {
    return node.map(reactNodeToText).join("");
  }
  if (isValidElement<{ children?: ReactNode; dangerouslySetInnerHTML?: { __html: string } }>(node)) {
    const { children, dangerouslySetInnerHTML } = node.props;
    return dangerouslySetInnerHTML === undefined ? reactNodeToText(children) : htmlToText(dangerouslySetInnerHTML.__html);
  }
  return "";
}

function htmlToText(html: string): string {
  return html
    .replace(/<[^>]+>/g, " ")
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/\s+/g, " ")
    .trim();
}
