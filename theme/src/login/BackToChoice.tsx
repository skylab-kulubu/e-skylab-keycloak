import type { KcContext } from "./KcContext";
import { chooseExecution, passwordFormExecutionId } from "./emailCodeChoice";

/** The "Geri dön" arrow, shared with the password view's own back button (Login.tsx). */
export function BackArrow() {
  return (
    <svg aria-hidden="true" viewBox="0 0 24 24" fill="none">
      <path d="m15 19-7-7 7-7" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" />
    </svg>
  );
}

/**
 * "Geri dön" on the steps of "E-postayla devam et": back to the login page's first screen, the
 * choice between YTÜ and e-mail. It switches steps the way "Parolanla gir" does, with Keycloak's
 * own execution selection (`authenticationExecution`, the "try another way" list): the login
 * page belongs to the password form's execution and opens on its choice screen. The login session
 * stays as it is, so a code already sent (and its budgets) is still waiting if the person comes
 * back to the e-mail step. Only when Keycloak offers no password form here does it restart the
 * flow (`url.loginRestartFlowUrl`), which leads to the same first screen.
 */
export default function BackToChoice(props: { kcContext: KcContext; label: string }) {
  const { kcContext, label } = props;
  const passwordExecution = passwordFormExecutionId(kcContext);
  const restartUrl = kcContext.url.loginRestartFlowUrl;

  if (passwordExecution !== undefined) {
    return (
      <button
        id="sl-back-to-choice"
        className="sl-legacy-back"
        type="button"
        onClick={() => chooseExecution(kcContext.url.loginAction, passwordExecution)}
      >
        <BackArrow />
        {label}
      </button>
    );
  }
  if (restartUrl) {
    return (
      <a id="sl-back-to-choice" className="sl-legacy-back" href={restartUrl}>
        <BackArrow />
        {label}
      </a>
    );
  }
  return null;
}
