import type { ReactNode } from "react";
import skyLabWatermarkUrl from "../assets/skylab-watermark.svg";
import AnimatedSkyLabLogo from "./AnimatedSkyLabLogo";

export type LegacyFrameLanguage = {
  href: string;
  label: string;
  languageTag: string;
};

export type LegacyFrameLanguageMenu = {
  currentLanguageTag: string;
  label: string;
  languages: LegacyFrameLanguage[];
};

type LegacyFrameProps = {
  /** Rendered between the title and the card body; can be empty for pages whose body is the message. */
  children: ReactNode;
  description?: ReactNode;
  /** Optional slot rendered directly under the title, before `children` (alerts, attempted username). */
  headerExtras?: ReactNode;
  kvkkLinkText: ReactNode;
  kvkkPrefix: ReactNode;
  kvkkSuffix: ReactNode;
  languageMenu?: LegacyFrameLanguageMenu;
  mainId: string;
  skipToContent: string;
  title: ReactNode;
  titleId: string;
  /** False while Keycloakify is still fetching the current locale's base messages. */
  translationsReady?: boolean;
};

export default function LegacyFrame(props: LegacyFrameProps) {
  const {
    children,
    description,
    headerExtras,
    kvkkLinkText,
    kvkkPrefix,
    kvkkSuffix,
    languageMenu,
    mainId,
    skipToContent,
    title,
    titleId,
    translationsReady = true
  } = props;

  const showLanguageMenu = languageMenu !== undefined && languageMenu.languages.length > 1;

  return (
    <div className="sl-legacy-shell" data-sl-translations={translationsReady ? "ready" : "loading"}>
      <a
        className="sl-legacy-skip-link"
        href={`#${mainId}`}
        onClick={event => {
          event.preventDefault();
          document.getElementById(mainId)?.focus();
        }}
      >
        {skipToContent}
      </a>

      <div className="sl-legacy-background" aria-hidden="true">
        <span className="sl-legacy-background__layers" />
        <span className="sl-legacy-background__iris" />
        <span className="sl-legacy-background__stars" />
        <img className="sl-legacy-background__mark" src={skyLabWatermarkUrl} alt="" />
        <span className="sl-legacy-background__grain" />
      </div>

      <main id={mainId} className="sl-legacy-main" tabIndex={-1}>
        <div className="sl-legacy-stack">
          <header className="sl-legacy-logo">
            <AnimatedSkyLabLogo />
          </header>

          <section className="sl-legacy-card" aria-labelledby={titleId}>
            <div className="sl-legacy-intro">
              <h1 id={titleId}>{title}</h1>
              {description !== undefined && description !== null && description !== "" && (
                <p>{description}</p>
              )}
            </div>

            {headerExtras}

            {children}
          </section>

          <footer className="sl-legacy-footer" role="contentinfo">
            <p>
              {kvkkPrefix}
              <a href="https://skyl.app/kvkk-metni" target="_blank" rel="noreferrer">
                {kvkkLinkText}
              </a>
              {kvkkSuffix}
            </p>
            <strong>e-skylab by WEBLAB</strong>
            <span className="sl-legacy-credit">Developed by Yusuf Açmacı</span>

            {showLanguageMenu && (
              <nav className="sl-legacy-languages" aria-label={languageMenu.label}>
                <ul>
                  {languageMenu.languages.map(({ href, label, languageTag }) => (
                    <li key={languageTag}>
                      <a
                        href={href}
                        lang={languageTag}
                        hrefLang={languageTag}
                        aria-current={languageTag === languageMenu.currentLanguageTag ? "page" : undefined}
                      >
                        {label}
                      </a>
                    </li>
                  ))}
                </ul>
              </nav>
            )}
          </footer>
        </div>
      </main>
    </div>
  );
}
