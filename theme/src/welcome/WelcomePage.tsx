import AnimatedSkyLabLogo from "../login/AnimatedSkyLabLogo";
import DeveloperCredit from "../login/DeveloperCredit";
import YtuMark from "../login/YtuMark";

/**
 * The page Keycloak serves at https://e.yildizskylab.com/ (the e-skylab-welcome theme, see
 * template.tsx): where the account is used, how to sign in and how to open an account. Rendered
 * once at build time to static HTML; it has no state, no script and no form, and it never links to
 * the Admin Console.
 *
 * Copy is functional only (Yusuf, 2026-10-19): headings, the login page's own button labels
 * (theme/src/login/i18n.ts: "YTÜ hesabınla devam et", "E-postayla devam et", "Parolanla gir",
 * "Erişim anahtarı ile giriş yap", "Hesabın yok mu? Hesap aç") and one short line each. When those
 * buttons change, this page changes with them.
 */

export const ACCOUNT_CENTER_URL = "https://my.yildizskylab.com/";
/** The published KVKK text itself, not the skyl.app short link (eskylab-login-ux ticket 05). */
export const KVKK_URL = "https://yildizskylab.com/kvkk-metni.pdf";

type App = { name: string; host: string; text: string };

const apps: App[] = [
  { name: "Hesap Merkezi", host: "my.yildizskylab.com", text: "Hesabını yönet." },
  { name: "SkyForms", host: "forms.yildizskylab.com", text: "Başvurular ve formlar." },
  { name: "Yönetim paneli", host: "admin.yildizskylab.com", text: "Yönetim ve ekip liderleri." },
  { name: "SkyMail", host: "mail.yildizskylab.com", text: "Kulübün e-posta paneli." },
  { name: "YıldızPlace", host: "place.yildizskylab.com", text: "Etkinlik yönetimi." },
  { name: "Kulüp siteleri", host: "yildizskylab.com", text: "Site editörleri." }
];

function SectionKicker(props: { path: string; label: string }) {
  return (
    <p className="sl-welcome-kicker">
      <span className="sl-welcome-kicker__path">{props.path}</span>
      <span className="sl-welcome-kicker__line" aria-hidden="true" />
      <span className="sl-welcome-kicker__label">{props.label}</span>
    </p>
  );
}

function ArrowIcon() {
  return (
    <svg className="sl-welcome-arrow" aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M7 17 17 7" />
      <path d="M8 7h9v9" />
    </svg>
  );
}

function LockIcon() {
  return (
    <svg aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <rect x="4" y="11" width="16" height="10" rx="2" />
      <path d="M8 11V7a4 4 0 0 1 8 0v4" />
    </svg>
  );
}

export default function WelcomePage() {
  return (
    <div className="sl-legacy-shell sl-welcome">
      <a className="sl-legacy-skip-link" href="#sl-welcome-main">
        İçeriğe geç
      </a>

      <div className="sl-legacy-background" aria-hidden="true">
        <span className="sl-legacy-background__layers" />
        {/* The login page's grid lines, still: the blinking cells need a script this page does not have. */}
        <span className="sl-legacy-grid" />
        <span className="sl-legacy-background__iris" />
        <span className="sl-legacy-background__stars" />
        <span className="sl-legacy-background__grain" />
      </div>

      <header className="sl-welcome-header">
        <div className="sl-welcome-container sl-welcome-header__inner">
          <span className="sl-welcome-brand">e-SKY LAB</span>
          <a className="sl-welcome-header__link" href={ACCOUNT_CENTER_URL}>
            Hesap Merkezi
            <ArrowIcon />
          </a>
        </div>
      </header>

      <main id="sl-welcome-main" className="sl-welcome-main" tabIndex={-1}>
        <section className="sl-welcome-container sl-welcome-hero" aria-labelledby="sl-welcome-title">
          <div className="sl-welcome-hero__copy">
            <SectionKicker path="./e-skylab" label="SKY LAB" />
            <h1 id="sl-welcome-title">
              Tek hesap, <span>bütün SKY LAB.</span>
            </h1>
            <p className="sl-welcome-lead">SKY LAB'in tüm platformlarına tek hesapla gir.</p>
            <div className="sl-welcome-actions">
              <a className="sl-legacy-choice sl-legacy-choice--primary" href={ACCOUNT_CENTER_URL}>
                Hesap Merkezi'ne git
                <ArrowIcon />
              </a>
              <a className="sl-legacy-choice" href="#giris">
                Nasıl giriş yapılır?
              </a>
            </div>
          </div>

          <div className="sl-legacy-card sl-welcome-window">
            <div className="sl-welcome-window__bar">
              <span className="sl-welcome-window__dots" aria-hidden="true">
                <span />
                <span />
                <span />
              </span>
              <span className="sl-welcome-window__address">
                <LockIcon />
                e.yildizskylab.com
              </span>
            </div>
            <div className="sl-welcome-window__body">
              <div className="sl-legacy-logo">
                <AnimatedSkyLabLogo />
              </div>
              <p className="sl-welcome-window__title">Tek hesap, tek giriş</p>
            </div>
          </div>
        </section>

        <section id="uygulamalar" className="sl-welcome-container sl-welcome-section" aria-labelledby="sl-welcome-apps-title">
          <SectionKicker path="./uygulamalar" label="nerede" />
          <h2 id="sl-welcome-apps-title">Nerede kullanılır?</h2>
          <ul className="sl-welcome-apps" aria-label="e-SKY LAB hesabıyla girilen uygulamalar">
            {apps.map(app => (
              <li key={app.host}>
                <a className="sl-welcome-app" href={`https://${app.host}/`}>
                  <span className="sl-welcome-app__name">
                    {app.name}
                    <ArrowIcon />
                  </span>
                  <span className="sl-welcome-app__host">{app.host}</span>
                  <span className="sl-welcome-app__text">{app.text}</span>
                </a>
              </li>
            ))}
          </ul>
        </section>

        <section id="giris" className="sl-welcome-container sl-welcome-section" aria-labelledby="sl-welcome-signin-title">
          <SectionKicker path="./giris" label="giriş yolları" />
          <h2 id="sl-welcome-signin-title">Nasıl giriş yapılır?</h2>
          <ol className="sl-welcome-steps" aria-label="Giriş yolları">
            <li className="sl-welcome-step">
              <span className="sl-welcome-step__meta">01 · YTÜ hesabı</span>
              <h3>
                <span className="sl-welcome-step__icon">
                  <YtuMark />
                </span>
                YTÜ hesabınla devam et
              </h3>
              <p>Okul hesabınla Microsoft üzerinden gir.</p>
            </li>
            <li className="sl-welcome-step">
              <span className="sl-welcome-step__meta">02 · E-posta kodu</span>
              <h3>
                <span className="sl-welcome-step__icon">
                  <span className="sl-authenticator-icon sl-authenticator-icon--email" aria-hidden="true" />
                </span>
                E-postayla devam et
              </h3>
              <p>
                E-postana gelen 6 haneli kodla gir. Parolan varsa <strong>Parolanla gir</strong>; unuttuysan{" "}
                <strong>Parolanı mı unuttun?</strong>
              </p>
            </li>
            <li className="sl-welcome-step">
              <span className="sl-welcome-step__meta">03 · Erişim anahtarı</span>
              <h3>
                <span className="sl-welcome-step__icon">
                  <span className="sl-key-icon" aria-hidden="true" />
                </span>
                Erişim anahtarı ile giriş yap
              </h3>
              <p>Touch ID, Face ID ya da Windows Hello ile gir.</p>
            </li>
          </ol>
        </section>

        <section id="hesap-ac" className="sl-welcome-container sl-welcome-section" aria-labelledby="sl-welcome-signup-title">
          <SectionKicker path="./hesap-ac" label="yeni hesap" />
          <h2 id="sl-welcome-signup-title">Hesap aç</h2>
          <p className="sl-welcome-note">
            Giriş ekranında <strong>Hesabın yok mu? Hesap aç</strong>: e-posta adresin, adın ve soyadın, e-postana gelen
            6 haneli kod. Parola ve erişim anahtarı isteğe bağlı.
          </p>
        </section>
      </main>

      <footer className="sl-legacy-footer sl-welcome-footer" role="contentinfo">
        <p>
          <a href={KVKK_URL}>KVKK Aydınlatma Metni</a>
          <span aria-hidden="true"> · </span>
          <a href="https://yildizskylab.com/">yildizskylab.com</a>
        </p>
        <strong>e-skylab by WEBLAB</strong>
        <DeveloperCredit />
      </footer>
    </div>
  );
}
