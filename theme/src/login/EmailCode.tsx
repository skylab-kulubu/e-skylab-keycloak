import { useEffect, useRef, useState } from "react";
import { useScript } from "keycloakify/login/pages/Login.useScript";
import type { KcContext } from "./KcContext";
import type { I18n } from "./i18n";
import LegacyFrame from "./LegacyFrame";
import { getLegacyChromeProps, useLegacyChrome } from "./legacyChrome";
import {
  chooseExecution,
  passwordFormExecutionId,
  rememberPasswordChoice,
  toEmailCodeError,
  type EmailCodeError
} from "./emailCodeChoice";

type EmailCodeProps = {
  kcContext: Extract<KcContext, { pageId: "sky-email-code.ftl" }>;
  i18n: I18n;
};

const errorKey = {
  invalid_identifier: "emailCodeError.invalid_identifier",
  rate_limited: "emailCodeError.rate_limited",
  resend_too_soon: "emailCodeError.resend_too_soon",
  malformed_code: "emailCodeError.malformed_code",
  wrong_code: "emailCodeError.wrong_code",
  code_expired: "emailCodeError.code_expired",
  too_many_tries: "emailCodeError.too_many_tries",
  account_disabled: "emailCodeError.account_disabled",
  account_locked: "emailCodeError.account_locked",
  unavailable: "emailCodeError.unavailable"
} as const satisfies Record<EmailCodeError, string>;

/** What the SPI takes at most (LoginCodes.MAX_CODE_INPUT_LENGTH): six digits with spaces between. */
const CODE_INPUT_MAX_LENGTH = 20;

const webAuthnButtonId = "authenticateWebAuthnButton";

/**
 * "E-postayla devam et" (the SPI's sky-email-code step, eskylab-login-ux 08). Two stages share one
 * page: the address or username ("Kod gönder", "Parolanla gir", the passkey as on the login page)
 * and the code (six digits, "Giriş yap", "Kodu yeniden gönder" once its minute is up, "Başka bir
 * adres yaz"). The SPI decides the stage, the error and how long a resend waits; the page is the same
 * whether or not the address belongs to an account, and never says where the code went.
 */
export default function EmailCode(props: EmailCodeProps) {
  const { kcContext, i18n } = props;
  const { msgStr } = i18n;
  const signUpIntent = (kcContext.skyEmailCodeSignUp === "true" || kcContext.skyEmailCodeSignUp === true)
    && kcContext.skyEmailCodeIntent === "sign-up";
  const title = msgStr(signUpIntent ? "emailCodeSignUpTitle" : "emailCodeTitle");
  const stage = kcContext.skyEmailCodeStage === "code" ? "code" : "identifier";
  const error = toEmailCodeError(kcContext.skyEmailCodeError);
  const identifier = kcContext.skyEmailCodeIdentifier ?? "";
  const minutes = kcContext.skyEmailCodeMinutes ?? "10";
  const passkeys = stage === "identifier" && kcContext.enableWebAuthnConditionalUI === true;
  const passwordExecution = passwordFormExecutionId(kcContext);
  const identifierInput = useRef<HTMLInputElement>(null);
  const [resendAfter, setResendAfter] = useState(() => secondsOf(kcContext.skyEmailCodeResendAfter));

  useLegacyChrome(i18n, title);
  // Keycloak's passkey scripts, exactly as the login page runs them; they do nothing unless the SPI
  // put the passkey challenge on this page (Keycloak's conditional UI).
  useScript({ webAuthnButtonId, kcContext: kcContext as never, i18n });

  useEffect(() => {
    if (resendAfter <= 0) {
      return;
    }
    const timer = window.setTimeout(() => setResendAfter(seconds => seconds - 1), 1000);
    return () => window.clearTimeout(timer);
  }, [resendAfter]);

  const fieldId = stage === "code" ? "sky-email-code" : "username";

  return (
    <LegacyFrame
      {...getLegacyChromeProps(i18n)}
      teams
      mainId="sl-email-code-main"
      titleId="sl-email-code-title"
      title={title}
      description={msgStr(stage === "code" ? "emailCodeCodeDescription"
        : signUpIntent ? "emailCodeSignUpDescription" : "emailCodeDescription")}
    >
      <form
        id={stage === "code" ? "kc-email-code-form" : "kc-email-code-identifier-form"}
        className="sl-email-code"
        action={kcContext.url.loginAction}
        method="post"
      >
        {stage === "code" && (
          <>
            <p id="sky-email-code-sent" className="sl-email-code__sent">
              {msgStr("emailCodeSent", minutes)}
            </p>
            {identifier !== "" && (
              <p id="sky-email-code-identifier" className="sl-email-code__identifier">
                {msgStr("emailCodeFor", identifier)}
              </p>
            )}
          </>
        )}
        <div className={error === undefined ? "sl-legacy-field" : "sl-legacy-field sl-legacy-field--error"}>
          <label htmlFor={fieldId}>{msgStr(stage === "code" ? "emailCodeCodeLabel" : "emailCodeIdentifierLabel")}</label>
          {stage === "code" ? (
            <input
              key="code"
              id="sky-email-code"
              className="sl-legacy-input sl-email-code__code"
              name="code"
              type="text"
              inputMode="numeric"
              autoComplete="one-time-code"
              pattern="[0-9 ]*"
              maxLength={CODE_INPUT_MAX_LENGTH}
              autoFocus
              aria-invalid={error !== undefined}
              aria-describedby={error === undefined ? undefined : "sky-email-code-error"}
            />
          ) : (
            <input
              key="identifier"
              ref={identifierInput}
              id="username"
              className="sl-legacy-input"
              name="username"
              type="text"
              autoComplete={passkeys ? "username webauthn" : "username"}
              maxLength={255}
              defaultValue={identifier}
              autoFocus
              aria-invalid={error !== undefined}
              aria-describedby={error === undefined ? undefined : "sky-email-code-error"}
            />
          )}
        </div>
        {error !== undefined && (
          <p
            id="sky-email-code-error"
            className="sl-legacy-field-error sl-legacy-field-error--after-field"
            role="alert"
            data-sky-email-code-error={error}
          >
            {msgStr(errorKey[error], kcContext.skyEmailCodeAttemptsLeft ?? "")}
          </p>
        )}
        <div className="sl-email-code__actions">
          {stage === "code" ? (
            <>
              <button className="sl-legacy-submit" type="submit" name="sky-email-code-action" value="verify">
                {msgStr("emailCodeVerify")}
              </button>
              <button
                id="sky-email-code-resend"
                className="sl-legacy-choice sl-email-code__secondary"
                type="submit"
                name="sky-email-code-action"
                value="resend"
                formNoValidate
                disabled={resendAfter > 0}
              >
                {resendAfter > 0 ? msgStr("emailCodeResendIn", String(resendAfter)) : msgStr("emailCodeResend")}
              </button>
              <button
                className="sl-legacy-choice sl-email-code__secondary"
                type="submit"
                name="sky-email-code-action"
                value="change"
                formNoValidate
              >
                {msgStr("emailCodeChange")}
              </button>
            </>
          ) : (
            <>
              <button className="sl-legacy-submit" type="submit" name="sky-email-code-action" value="send">
                {msgStr("emailCodeSend")}
              </button>
              {passwordExecution !== undefined && (
                <button
                  id="sky-email-code-password"
                  className="sl-legacy-choice sl-email-code__secondary"
                  type="button"
                  onClick={() => {
                    rememberPasswordChoice(identifierInput.current?.value.trim() ?? "");
                    chooseExecution(kcContext.url.loginAction, passwordExecution);
                  }}
                >
                  {msgStr("emailCodePassword")}
                </button>
              )}
            </>
          )}
        </div>
      </form>

      {passkeys && (
        <>
          <div className="sl-legacy-passkey-wrap">
            <button id={webAuthnButtonId} className="sl-legacy-passkey" type="button">
              <span className="sl-key-icon" aria-hidden="true" />
              {msgStr("passkeyChoice")}
            </button>
          </div>
          <form id="webauth" action={kcContext.url.loginAction} method="post" hidden>
            <input type="hidden" id="clientDataJSON" name="clientDataJSON" />
            <input type="hidden" id="authenticatorData" name="authenticatorData" />
            <input type="hidden" id="signature" name="signature" />
            <input type="hidden" id="credentialId" name="credentialId" />
            <input type="hidden" id="userHandle" name="userHandle" />
            <input type="hidden" id="error" name="error" />
          </form>
        </>
      )}
    </LegacyFrame>
  );
}

function secondsOf(value: string | undefined): number {
  const seconds = Number.parseInt(value ?? "0", 10);
  return Number.isFinite(seconds) && seconds > 0 ? Math.min(seconds, 600) : 0;
}
