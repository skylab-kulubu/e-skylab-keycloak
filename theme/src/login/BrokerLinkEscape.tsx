import type { KcContext } from "./KcContext";
import type { I18n } from "./i18n";

/** Posted to the current broker proof step; it never selects a browser login alternative. */
export default function BrokerLinkEscape({ kcContext, i18n }: { kcContext: KcContext; i18n: I18n }) {
  if (kcContext.skyExistingAccountEscape !== true) return null;
  return (
    <form action={kcContext.url.loginAction} method="post" className="sl-legacy-try-another-way">
      <button className="sl-text-button" type="submit" name="sky-existing-account-action" value="new-account">
        {i18n.msgStr("existingAccountEscape")}
      </button>
    </form>
  );
}
