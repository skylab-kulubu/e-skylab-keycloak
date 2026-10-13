export const DEVELOPER_CREDIT_URL = "https://www.linkedin.com/in/yusuf-acmaci/";

/**
 * Who built the e-skylab sign-in theme, at the foot of every LegacyFrame page
 * and the landing page. Like SkyMail's "Developed by Enes Genç" it opens the
 * developer's page in a new tab and keeps the quiet credit look. `linked={false}`
 * keeps it plain text, for pages that offer as little to click as possible
 * (the Web handoff failure page).
 */
export default function DeveloperCredit({ linked = true }: { linked?: boolean }) {
  if (!linked) {
    return <span className="sl-legacy-credit">Developed by Yusuf Açmacı</span>;
  }
  return (
    <a className="sl-legacy-credit" href={DEVELOPER_CREDIT_URL} target="_blank" rel="noopener noreferrer">
      Developed by Yusuf Açmacı
    </a>
  );
}
