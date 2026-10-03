import type { ReactNode } from "react";
import skyLabWatermarkUrl from "../assets/skylab-watermark.svg";
import AnimatedSkyLabLogo from "./AnimatedSkyLabLogo";
import GridBackdrop from "./GridBackdrop";
import TeamMarquee from "./TeamMarquee";
import YtuMark from "./YtuMark";

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

/** The panel beside the card on wide screens: what one SKY LAB account gives. */
export type LegacyFrameBrand = {
  title: string;
  text: string;
  features: { sites: string; ytu: string; passkey: string };
};

type LegacyFrameProps = {
  brand?: LegacyFrameBrand;
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
    brand,
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
        <GridBackdrop />
        <span className="sl-legacy-background__iris" />
        <span className="sl-legacy-background__stars" />
        <span className="sl-legacy-background__grain" />
      </div>

      <main id={mainId} className="sl-legacy-main" tabIndex={-1}>
        <TeamMarquee direction="left" />
        <div className={brand === undefined ? "sl-legacy-stack" : "sl-legacy-stack sl-legacy-stack--wide"}>
          <section className={brand === undefined ? "sl-legacy-card" : "sl-legacy-card sl-legacy-card--brand"} aria-labelledby={titleId}>
            <div className="sl-legacy-card__body">
              <div className="sl-legacy-intro">
                <h1 id={titleId}>{title}</h1>
                {description !== undefined && description !== null && description !== "" && (
                  <p>{description}</p>
                )}
              </div>

              {headerExtras}

              {children}
            </div>

            <div className="sl-legacy-brand">
              {brand !== undefined && <img className="sl-legacy-brand__mark" src={skyLabWatermarkUrl} alt="" />}
              <header className="sl-legacy-logo">
                <AnimatedSkyLabLogo />
              </header>
              {brand !== undefined && (
                <div className="sl-legacy-brand__copy">
                  <p className="sl-legacy-brand__title">{brand.title}</p>
                  <p className="sl-legacy-brand__text">{brand.text}</p>
                  <ul className="sl-legacy-brand__features">
                    <li>
                      <span className="sl-legacy-brand__icon">
                        <svg aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                          <rect x="3" y="3" width="7" height="7" rx="1.5" />
                          <rect x="14" y="3" width="7" height="7" rx="1.5" />
                          <rect x="3" y="14" width="7" height="7" rx="1.5" />
                          <rect x="14" y="14" width="7" height="7" rx="1.5" />
                        </svg>
                      </span>
                      {brand.features.sites}
                    </li>
                    <li>
                      <span className="sl-legacy-brand__icon">
                        <YtuMark />
                      </span>
                      {brand.features.ytu}
                    </li>
                    <li>
                      <span className="sl-legacy-brand__icon">
                        <span className="sl-key-icon" aria-hidden="true" />
                      </span>
                      {brand.features.passkey}
                    </li>
                  </ul>
                </div>
              )}
            </div>
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
        <TeamMarquee direction="right" />
      </main>
    </div>
  );
}
