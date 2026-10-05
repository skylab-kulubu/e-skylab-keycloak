import AnimatedSkyLabLogo from "../login/AnimatedSkyLabLogo";
import YtuMark from "../login/YtuMark";

/**
 * The page Keycloak serves at https://e.yildizskylab.com/ (the e-skylab-welcome theme, see
 * template.tsx): what e-SKY LAB is, where the account is used, how to sign in today and what
 * happens to the school password. Rendered once at build time to static HTML; it has no state,
 * no script and no form, and it never links to the Admin Console.
 *
 * The copy follows today's login page (theme/src/login/i18n.ts: "YTÜ Öğrencisiyim",
 * "YTÜ Öğrencisi Değilim", "Erişim anahtarı ile giriş yap") and the trust copy of the login spec
 * (ADR-0063). When the login buttons change (e-postayla kodla giriş, kayıt), this page changes
 * with them.
 */

export const ACCOUNT_CENTER_URL = "https://my.yildizskylab.com/";
/** The published KVKK text itself, not the skyl.app short link (eskylab-login-ux ticket 05). */
export const KVKK_URL = "https://yildizskylab.com/kvkk-metni.pdf";

type App = { name: string; host: string; text: string };

const apps: App[] = [
  {
    name: "Hesap Merkezi",
    host: "my.yildizskylab.com",
    text: "Adın, e-posta adreslerin, parolan, erişim anahtarların ve oturumların. Hesabını buradan yönetir, istersen silersin."
  },
  { name: "SkyForms", host: "forms.yildizskylab.com", text: "Etkinlik başvuruları ve kulübün formları." },
  {
    name: "Yönetim paneli",
    host: "admin.yildizskylab.com",
    text: "Yönetim ve ekip liderleri için: üyeler, etkinlikler, biletler ve sertifikalar."
  },
  { name: "SkyMail", host: "mail.yildizskylab.com", text: "Kulübün e-posta gönderim paneli, yetkisi olanlar için." },
  { name: "YıldızPlace", host: "place.yildizskylab.com", text: "Etkinliğin yöneticileri bu hesapla girer." },
  {
    name: "Kulüp siteleri",
    host: "yildizskylab.com",
    text: "Sitelerin editörleri içeriği bu hesapla düzenler. Siteleri okumak için hesap gerekmez."
  }
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

function MailIcon() {
  return (
    <svg aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <rect x="3" y="5" width="18" height="14" rx="2" />
      <path d="m3 7 9 6 9-6" />
    </svg>
  );
}

function AddressIcon() {
  return (
    <svg aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <circle cx="12" cy="12" r="9" />
      <path d="M3 12h18" />
      <path d="M12 3a14 14 0 0 1 0 18a14 14 0 0 1 0-18" />
    </svg>
  );
}

function DocumentIcon() {
  return (
    <svg aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8Z" />
      <path d="M14 3v5h5" />
      <path d="M9 13h6" />
      <path d="M9 17h4" />
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
            <p className="sl-welcome-lead">
              e-SKY LAB, SKY LAB'in giriş hizmetidir. Kulübün uygulamalarına ve sitelerine aynı hesapla girersin. Bir
              uygulamada "Giriş yap"a bastığında bu adresteki giriş ekranı açılır; giriş bitince seni geldiğin yere geri
              gönderir.
            </p>
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
              <p className="sl-welcome-window__text">
                Okul şifren yalnız Microsoft'ta kalır. SKY LAB'in giriş adresi bu: e.yildizskylab.com.
              </p>
            </div>
          </div>
        </section>

        <section id="uygulamalar" className="sl-welcome-container sl-welcome-section" aria-labelledby="sl-welcome-apps-title">
          <SectionKicker path="./uygulamalar" label="nerede" />
          <h2 id="sl-welcome-apps-title">Nerede kullanılır?</h2>
          <p className="sl-welcome-section__intro">
            Kulübün hesap isteyen uygulamalarına ve sitelerine aynı e-SKY LAB hesabıyla girersin. Birine girdiğinde
            ötekilerde de çoğu zaman yeniden giriş yapman gerekmez.
          </p>
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
          <p className="sl-welcome-section__intro">
            Bir uygulamada "Giriş yap"a bas; giriş ekranında şu yollardan birini seç.
          </p>
          <ol className="sl-welcome-steps" aria-label="Giriş yolları">
            <li className="sl-welcome-step">
              <span className="sl-welcome-step__meta">01 · YTÜ hesabı</span>
              <h3>
                <span className="sl-welcome-step__icon">
                  <YtuMark />
                </span>
                YTÜ öğrencisiysen
              </h3>
              <p>
                <strong>YTÜ Öğrencisiyim</strong>'i seç. Microsoft'un sayfası açılır, okul hesabınla girersin. İlk girişinde
                SKY LAB hesabın açılır; adını onaylaman ve e-posta adresini doğrulaman istenebilir.
              </p>
              <p>
                İlk girişte Microsoft bir izin ekranı gösterebilir ve SKY LAB için "profilini okuma" izni ister. Profilinden
                yalnız adını, okul e-postanı ve bölümünü alırız.
              </p>
            </li>
            <li className="sl-welcome-step">
              <span className="sl-welcome-step__meta">02 · Parola</span>
              <h3>
                <span className="sl-welcome-step__icon">
                  <span className="sl-authenticator-icon sl-authenticator-icon--password" aria-hidden="true" />
                </span>
                Parolan varsa
              </h3>
              <p>
                <strong>YTÜ Öğrencisi Değilim</strong>'i seç; e-posta adresini (okul ya da kişisel) ya da kullanıcı adını
                ve parolanı yaz. Parolanı unuttuysan aynı ekrandaki <strong>Parolanı mı unuttun?</strong> bağlantısını
                kullan. Parolayı Hesap Merkezi'nden eklersin.
              </p>
            </li>
            <li className="sl-welcome-step">
              <span className="sl-welcome-step__meta">03 · Erişim anahtarı</span>
              <h3>
                <span className="sl-welcome-step__icon">
                  <span className="sl-key-icon" aria-hidden="true" />
                </span>
                Erişim anahtarın varsa
              </h3>
              <p>
                <strong>Erişim anahtarı ile giriş yap</strong>'ı seç; Touch ID, Face ID ya da Windows Hello ile parolasız
                girersin. Erişim anahtarını (passkey) Hesap Merkezi'nden eklersin.
              </p>
            </li>
          </ol>
          <p className="sl-welcome-note">
            YTÜ hesabın yoksa bugün kendin hesap açamazsın. E-postayla hesap açma ve e-postana gelen kodla giriş
            hazırlanıyor.
          </p>
        </section>

        <section id="guven" className="sl-welcome-container sl-welcome-section" aria-labelledby="sl-welcome-trust-title">
          <SectionKicker path="./guven" label="şifren ve verilerin" />
          <h2 id="sl-welcome-trust-title">Okul şifren yalnız Microsoft'ta.</h2>
          <ul className="sl-welcome-trust" aria-label="Şifren ve verilerin">
            <li>
              <span className="sl-legacy-brand__icon">
                <LockIcon />
              </span>
              <p>Okul şifreni yalnız Microsoft'un sayfasına yazarsın; SKY LAB onu hiçbir zaman görmez.</p>
            </li>
            <li>
              <span className="sl-legacy-brand__icon">
                <MailIcon />
              </span>
              <p>
                YTÜ hesabından yalnız adını, okul e-postanı ve bölümünü alırız; postalarına ve dosyalarına erişmeyiz.
                Hesabını tanımak için Microsoft hesabının değişmez kimlik numarasını da saklarız.
              </p>
            </li>
            <li>
              <span className="sl-legacy-brand__icon">
                <AddressIcon />
              </span>
              <p>
                Giriş adresi her zaman e.yildizskylab.com'dur. SKY LAB parolanı başka bir adreste isteyen sayfaya yazma.
              </p>
            </li>
            <li>
              <span className="sl-legacy-brand__icon">
                <DocumentIcon />
              </span>
              <p>
                Kişisel verilerinin nasıl işlendiğini <a href={KVKK_URL}>KVKK Aydınlatma Metni</a>'nde okuyabilirsin.
              </p>
            </li>
          </ul>
        </section>
      </main>

      <footer className="sl-legacy-footer sl-welcome-footer" role="contentinfo">
        <p>
          <a href={KVKK_URL}>KVKK Aydınlatma Metni</a>
          <span aria-hidden="true"> · </span>
          <a href="https://yildizskylab.com/">yildizskylab.com</a>
        </p>
        <strong>e-skylab by WEBLAB</strong>
        <span className="sl-legacy-credit">Developed by Yusuf Açmacı</span>
      </footer>
    </div>
  );
}
