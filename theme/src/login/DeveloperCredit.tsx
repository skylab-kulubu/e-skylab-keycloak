export const DEVELOPER_CREDIT_URL = "https://www.linkedin.com/in/yusuf-acmaci/";

/**
 * Who built the e-skylab sign-in theme, at the foot of every LegacyFrame page
 * and the landing page. Like SkyMail's "Developed by Enes Genç" it opens the
 * developer's page in a new tab and keeps the quiet credit look.
 */
export default function DeveloperCredit() {
  return (
    <a className="sl-legacy-credit" href={DEVELOPER_CREDIT_URL} target="_blank" rel="noopener noreferrer">
      Developed by Yusuf Açmacı
    </a>
  );
}
