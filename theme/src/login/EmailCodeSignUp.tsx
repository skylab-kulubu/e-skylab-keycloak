import type { KcContext } from "./KcContext";
import type { I18n } from "./i18n";
import LegacyFrame from "./LegacyFrame";
import YtuMark from "./YtuMark";
import {
  toEmailCodeSignUpError,
  toEmailCodeSignUpStage,
  type EmailCodeSignUpError,
  type EmailCodeSignUpStage
} from "./signUpStages";
import { getLegacyChromeProps, useLegacyChrome } from "./legacyChrome";

type EmailCodeSignUpProps = {
  kcContext: Extract<KcContext, { pageId: "sky-email-code-sign-up.ftl" }>;
  i18n: I18n;
};

const titleKey = {
  form: "signUpTitle",
  ytu: "signUpYtuTitle",
  existing: "signUpExistingTitle",
  unavailable: "signUpUnavailableTitle"
} as const satisfies Record<EmailCodeSignUpStage, string>;

const formId = {
  form: "kc-email-code-sign-up-form",
  ytu: "kc-email-code-sign-up-ytu-form",
  existing: "kc-email-code-sign-up-existing-form",
  unavailable: "kc-email-code-sign-up-unavailable-form"
} as const satisfies Record<EmailCodeSignUpStage, string>;

const errorKey = {
  first_name_missing: "signUpError.first_name_missing",
  first_name_invalid: "signUpError.first_name_invalid",
  last_name_missing: "signUpError.last_name_missing",
  last_name_invalid: "signUpError.last_name_invalid",
  try_again: "signUpError.try_again"
} as const satisfies Record<EmailCodeSignUpError, string>;

/**
 * Self-registration on "E-postayla devam et" (the SPI's sky-email-code step, eskylab-login-ux 09,
 * ADR-0063 decision 1), after the right code proved the address. The SPI decides the stage:
 * "Hesabını oluşturalım" (the address read-only, first and last name; no password, no consent box:
 * the KVKK footer only informs), a YTÜ school address (the YTÜ sign-in instead, spec S3), an address
 * that has an account ("Hesap aç": signed in, said once), or an address that cannot open one. Every
 * button posts sky-email-code-action to Keycloak's login action; the page only words the stage.
 */
export default function EmailCodeSignUp(props: EmailCodeSignUpProps) {
  const { kcContext, i18n } = props;
  const { msgStr } = i18n;
  const stage = toEmailCodeSignUpStage(kcContext.skySignUpStage);
  const title = msgStr(titleKey[stage]);
  const address = kcContext.skySignUpAddress ?? "";
  const error = stage === "form" ? toEmailCodeSignUpError(kcContext.skySignUpError) : undefined;
  const firstNameError = error === "first_name_missing" || error === "first_name_invalid";
  const lastNameError = error === "last_name_missing" || error === "last_name_invalid";
  const ytuAlias = kcContext.skySignUpYtuAlias ?? "OBS";
  const ytuProvider = kcContext.social?.providers?.find(provider => provider.alias === ytuAlias);
  const description =
    stage === "form"
      ? msgStr("signUpDescription")
      : stage === "ytu"
        ? msgStr("signUpYtuText", address)
        : stage === "existing"
          ? msgStr("signUpExistingText")
          : msgStr("signUpUnavailableText");

  useLegacyChrome(i18n, title);

  const change = (
    <button
      className="sl-legacy-choice sl-email-code-sign-up__secondary"
      type="submit"
      name="sky-email-code-action"
      value="change"
      formNoValidate
    >
      {msgStr("signUpChange")}
    </button>
  );

  return (
    <LegacyFrame
      {...getLegacyChromeProps(i18n)}
      teams
      mainId="sl-email-code-sign-up-main"
      titleId="sl-email-code-sign-up-title"
      title={title}
      description={description}
    >
      <form
        id={formId[stage]}
        className="sl-email-code-sign-up"
        data-sky-sign-up-stage={stage}
        action={kcContext.url.loginAction}
        method="post"
      >
        {stage === "form" && (
          <>
            <div className="sl-legacy-field">
              <label htmlFor="sky-sign-up-address">{msgStr("signUpAddressLabel")}</label>
              <input
                id="sky-sign-up-address"
                className="sl-legacy-input"
                type="email"
                value={address}
                readOnly
                aria-readonly="true"
              />
            </div>
            <div className={firstNameError ? "sl-legacy-field sl-legacy-field--error" : "sl-legacy-field"}>
              <label htmlFor="sky-sign-up-first-name">{msgStr("signUpFirstNameLabel")}</label>
              <input
                id="sky-sign-up-first-name"
                className="sl-legacy-input"
                name="firstName"
                type="text"
                autoComplete="given-name"
                maxLength={64}
                defaultValue={kcContext.skySignUpFirstName ?? ""}
                autoFocus={!lastNameError}
                aria-invalid={firstNameError}
                aria-describedby={firstNameError ? "sky-sign-up-error" : undefined}
              />
            </div>
            <div className={lastNameError ? "sl-legacy-field sl-legacy-field--error" : "sl-legacy-field"}>
              <label htmlFor="sky-sign-up-last-name">{msgStr("signUpLastNameLabel")}</label>
              <input
                id="sky-sign-up-last-name"
                className="sl-legacy-input"
                name="lastName"
                type="text"
                autoComplete="family-name"
                maxLength={64}
                defaultValue={kcContext.skySignUpLastName ?? ""}
                autoFocus={lastNameError}
                aria-invalid={lastNameError}
                aria-describedby={lastNameError ? "sky-sign-up-error" : undefined}
              />
            </div>
            {error !== undefined && (
              <p
                id="sky-sign-up-error"
                className="sl-legacy-field-error sl-legacy-field-error--after-field"
                role="alert"
                data-sky-sign-up-error={error}
              >
                {msgStr(errorKey[error])}
              </p>
            )}
            <p id="sky-sign-up-note" className="sl-email-code-sign-up__note">
              {msgStr("signUpNote")}
            </p>
            <div className="sl-email-code-sign-up__actions">
              <button className="sl-legacy-submit" type="submit" name="sky-email-code-action" value="sign-up">
                {msgStr("signUpSubmit")}
              </button>
              {change}
            </div>
          </>
        )}
        {stage === "ytu" && (
          <div className="sl-email-code-sign-up__actions">
            {ytuProvider !== undefined && (
              <a
                id="sky-sign-up-ytu"
                className="sl-legacy-choice sl-legacy-choice--row sl-legacy-choice--primary"
                href={ytuProvider.loginUrl}
              >
                <span className="sl-legacy-choice__icon">
                  <YtuMark />
                </span>
                <span className="sl-legacy-choice__label">{msgStr("signUpYtuButton")}</span>
              </a>
            )}
            {change}
          </div>
        )}
        {stage === "existing" && (
          <div className="sl-email-code-sign-up__actions">
            <button className="sl-legacy-submit" type="submit" name="sky-email-code-action" value="continue" autoFocus>
              {msgStr("signUpContinue")}
            </button>
          </div>
        )}
        {stage === "unavailable" && <div className="sl-email-code-sign-up__actions">{change}</div>}
      </form>
    </LegacyFrame>
  );
}
