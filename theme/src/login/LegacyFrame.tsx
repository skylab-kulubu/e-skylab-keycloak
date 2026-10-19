import type { ReactNode } from "react";
import skyLabWatermarkUrl from "../assets/skylab-watermark.svg";
import AnimatedSkyLabLogo from "./AnimatedSkyLabLogo";
import DeveloperCredit from "./DeveloperCredit";
import GridBackdrop from "./GridBackdrop";
import TeamMarquee from "./TeamMarquee";

/**
 * The published KVKK notice itself, not the skyl.app short link (eskylab-login-ux 05). The same
 * file as the landing page's KVKK_URL (welcome/WelcomePage.tsx); Login.test.tsx holds them equal.
 */
const KVKK_URL = "https://yildizskylab.com/kvkk-metni.pdf";

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
  /**
   * The login page's wide layout: a quiet panel beside the card with only the logo (and its faint
   * watermark). No slogan or copy: the form beside it says what there is to do.
   */
  brand?: boolean;
  /** The developer credit links to LinkedIn; false keeps it plain text (Web handoff failure page). */
  creditLinked?: boolean;
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
  /** The team logo strips above and below the card; the login page and the e-mail code page. */
  teams?: boolean;
  title: ReactNode;
  titleId: string;
  /** False while Keycloakify is still fetching the current locale's base messages. */
  translationsReady?: boolean;
};

export default function LegacyFrame(props: LegacyFrameProps) {
  const {
    brand = false,
    children,
    creditLinked = true,
    description,
    headerExtras,
    kvkkLinkText,
    kvkkPrefix,
    kvkkSuffix,
    languageMenu,
    mainId,
    skipToContent,
    teams = false,
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
        {teams && <TeamMarquee direction="left" />}
        <div className={brand ? "sl-legacy-stack sl-legacy-stack--wide" : "sl-legacy-stack"}>
          <section className={brand ? "sl-legacy-card sl-legacy-card--brand" : "sl-legacy-card"} aria-labelledby={titleId}>
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
              {brand && <img className="sl-legacy-brand__mark" src={skyLabWatermarkUrl} alt="" />}
              <header className="sl-legacy-logo">
                <AnimatedSkyLabLogo />
              </header>
            </div>
          </section>

          <footer className="sl-legacy-footer" role="contentinfo">
            <p>
              {kvkkPrefix}
              <a href={KVKK_URL} target="_blank" rel="noreferrer">
                {kvkkLinkText}
              </a>
              {kvkkSuffix}
            </p>
            <strong>e-skylab by WEBLAB</strong>
            <DeveloperCredit linked={creditLinked} />

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
        {teams && <TeamMarquee direction="right" />}
      </main>
    </div>
  );
}
