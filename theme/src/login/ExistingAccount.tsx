import { useEffect, useState } from "react";
import type { KcContext } from "./KcContext";
import type { I18n } from "./i18n";
import LegacyFrame from "./LegacyFrame";
import { getLegacyChromeProps, useLegacyChrome } from "./legacyChrome";

type Props = {
  kcContext: Extract<KcContext, { pageId: "sky-existing-account.ftl" }>;
  i18n: I18n;
};

export default function ExistingAccount({ kcContext, i18n }: Props) {
  const { msgStr } = i18n;
  const rawStage = kcContext.skyExistingAccountStage;
  const stage = rawStage === "question" || rawStage === "identifier" || rawStage === "code"
    ? rawStage : "unavailable";
  const title = msgStr(stage === "question" ? "existingAccountTitle" : "existingAccountLinkTitle");
  const parsedSeconds = Number(kcContext.skyExistingAccountResendAfter ?? 0);
  const [seconds, setSeconds] = useState(Number.isFinite(parsedSeconds) ? Math.max(0, Math.min(60, parsedSeconds)) : 60);
  useEffect(() => {
    if (seconds <= 0) return;
    const timeout = window.setTimeout(() => setSeconds(value => Math.max(0, value - 1)), 1000);
    return () => window.clearTimeout(timeout);
  }, [seconds]);
  useLegacyChrome(i18n, title);

  const error = kcContext.skyExistingAccountError;
  const errorText = error === "wrong_code" ? msgStr("existingAccountWrongCode")
    : error === "rate_limited" ? msgStr("existingAccountRateLimited")
    : error === "malformed_code" ? msgStr("emailCodeError.malformed_code")
    : error === "resend_too_soon" ? msgStr("emailCodeError.resend_too_soon")
    : error ? msgStr("existingAccountTryAgain") : undefined;

  return (
    <LegacyFrame {...getLegacyChromeProps(i18n)} teams mainId="sl-existing-account-main"
      titleId="sl-existing-account-title" title={title} description={msgStr("existingAccountDescription")}>
      <form action={kcContext.url.loginAction} method="post" className="sl-email-code"
        data-sky-existing-account-stage={stage}>
        {errorText && <p role="alert" className="sl-legacy-field-error">{errorText}</p>}
        {stage === "question" && <>
          {kcContext.skyExistingAccountSchoolCandidate === true && <p data-sky-existing-account-candidate="true">{msgStr("existingAccountSchoolCandidate")}</p>}
          <button type="submit" className="sl-legacy-choice sl-legacy-choice--primary"
            name="sky-existing-account-action" value="existing">{msgStr("existingAccountYes")}</button>
        </>}
        {stage === "identifier" && <>
          <div className="sl-legacy-field">
            <label htmlFor="sky-existing-identifier">{msgStr("existingAccountIdentifier")}</label>
            <input id="sky-existing-identifier" className="sl-legacy-input" name="username" type="text"
              autoComplete="username" maxLength={255} defaultValue={kcContext.skyExistingAccountIdentifier ?? ""} autoFocus />
          </div>
          <button type="submit" className="sl-legacy-choice sl-legacy-choice--primary"
            name="sky-existing-account-action" value="send">{msgStr("emailCodeSend")}</button>
          <button type="submit" className="sl-legacy-choice" name="sky-existing-account-action"
            value="password">{msgStr("existingAccountPassword")}</button>
        </>}
        {stage === "code" && <>
          <p>{msgStr("existingAccountCodeSent")}</p>
          {kcContext.skyExistingAccountIdentifier && <p>{msgStr("emailCodeFor", kcContext.skyExistingAccountIdentifier)}</p>}
          <div className="sl-legacy-field">
            <label htmlFor="sky-existing-code">{msgStr("emailCodeCodeLabel")}</label>
            <input id="sky-existing-code" className="sl-legacy-input" name="code" type="text"
              inputMode="numeric" autoComplete="one-time-code" maxLength={20} autoFocus />
          </div>
          <button type="submit" className="sl-legacy-choice sl-legacy-choice--primary"
            name="sky-existing-account-action" value="verify">{msgStr("existingAccountVerify")}</button>
          <button type="submit" className="sl-legacy-choice" name="sky-existing-account-action" value="resend"
            formNoValidate disabled={seconds > 0}>
            {seconds > 0 ? msgStr("emailCodeResendIn", String(seconds)) : msgStr("emailCodeResend")}
          </button>
          <button type="submit" className="sl-text-button" name="sky-existing-account-action"
            value="change" formNoValidate>{msgStr("emailCodeChange")}</button>
        </>}
        {stage === "unavailable" && <p>{msgStr("existingAccountTryAgain")}</p>}
        <button type="submit" className="sl-legacy-choice" name="sky-existing-account-action" value="new-account"
          formNoValidate>{msgStr(stage === "question" ? "existingAccountNo" : "existingAccountEscape")}</button>
      </form>
    </LegacyFrame>
  );
}
