import type { KcContext } from "./KcContext";
import type { I18n } from "./i18n";
import LegacyFrame from "./LegacyFrame";
import { getLegacyChromeProps, useLegacyChrome } from "./legacyChrome";
import { toPersonalEmailOfferError, type PersonalEmailOfferError } from "./offerErrors";

type PersonalEmailOfferProps = {
  kcContext: Extract<KcContext, { pageId: "sky-personal-email-offer.ftl" }>;
  i18n: I18n;
};

const errorKey = {
  invalid_address: "personalEmailOfferError.invalid_address",
  own_address: "personalEmailOfferError.own_address",
  email_taken: "personalEmailOfferError.email_taken",
  rate_limited: "personalEmailOfferError.rate_limited",
  email_not_sent: "personalEmailOfferError.email_not_sent",
  malformed_code: "personalEmailOfferError.malformed_code",
  wrong_code: "personalEmailOfferError.wrong_code",
  code_expired: "personalEmailOfferError.code_expired",
  too_many_tries: "personalEmailOfferError.too_many_tries"
} as const satisfies Record<PersonalEmailOfferError, string>;

/**
 * Once, at the end of a first YTÜ login that opened the account with the school address as its
 * primary (the SPI's sky-personal-email-offer required action, eskylab-login-ux 21): add a personal
 * e-mail with a code mailed to it, on this page, or skip. Two stages share one form: the address
 * ("Kod gönder") and the code ("Doğrula ve devam et", or another address). "Şimdilik geç" is on both
 * and never needs the fields. The SPI decides the stage and the error; the page only words them.
 */
export default function PersonalEmailOffer(props: PersonalEmailOfferProps) {
  const { kcContext, i18n } = props;
  const { msgStr } = i18n;
  const title = msgStr("personalEmailOfferTitle");
  const stage = kcContext.skyOfferStage === "code" ? "code" : "address";
  const error = toPersonalEmailOfferError(kcContext.skyOfferError);
  const address = kcContext.skyOfferAddress ?? "";
  const minutes = kcContext.skyOfferCodeMinutes ?? "10";
  const fieldId = stage === "code" ? "sky-offer-code" : "sky-offer-address";

  useLegacyChrome(i18n, title);

  return (
    <LegacyFrame
      {...getLegacyChromeProps(i18n)}
      mainId="sl-personal-email-offer-main"
      titleId="sl-personal-email-offer-title"
      title={title}
      description={msgStr("personalEmailOfferDescription")}
    >
      <form
        id="kc-personal-email-offer-form"
        className="sl-personal-email-offer"
        action={kcContext.url.loginAction}
        method="post"
      >
        {stage === "code" && (
          <p id="sky-offer-code-sent" className="sl-personal-email-offer__sent">
            {msgStr("personalEmailOfferCodeSent", address, minutes)}
          </p>
        )}
        <div className={error === undefined ? "sl-legacy-field" : "sl-legacy-field sl-legacy-field--error"}>
          <label htmlFor={fieldId}>
            {msgStr(stage === "code" ? "personalEmailOfferCodeLabel" : "personalEmailOfferAddressLabel")}
          </label>
          {stage === "code" ? (
            <input
              key="code"
              id="sky-offer-code"
              className="sl-legacy-input"
              name="code"
              type="text"
              inputMode="numeric"
              autoComplete="one-time-code"
              maxLength={12}
              autoFocus
              aria-invalid={error !== undefined}
              aria-describedby={error === undefined ? undefined : "sky-offer-error"}
            />
          ) : (
            <input
              key="address"
              id="sky-offer-address"
              className="sl-legacy-input"
              name="address"
              type="email"
              autoComplete="email"
              maxLength={255}
              defaultValue={address}
              autoFocus
              aria-invalid={error !== undefined}
              aria-describedby={error === undefined ? undefined : "sky-offer-error"}
            />
          )}
        </div>
        {error !== undefined && (
          <p
            id="sky-offer-error"
            className="sl-legacy-field-error sl-legacy-field-error--after-field"
            role="alert"
            data-sky-offer-error={error}
          >
            {msgStr(errorKey[error], kcContext.skyOfferAttemptsLeft ?? "")}
          </p>
        )}
        <div className="sl-personal-email-offer__actions">
          {stage === "code" ? (
            <>
              <button className="sl-legacy-submit" type="submit" name="sky-offer-action" value="verify">
                {msgStr("personalEmailOfferVerify")}
              </button>
              <button
                className="sl-legacy-choice sl-personal-email-offer__secondary"
                type="submit"
                name="sky-offer-action"
                value="change"
                formNoValidate
              >
                {msgStr("personalEmailOfferChange")}
              </button>
            </>
          ) : (
            <button className="sl-legacy-submit" type="submit" name="sky-offer-action" value="send">
              {msgStr("personalEmailOfferSend")}
            </button>
          )}
          <p className="sl-personal-email-offer__note">{msgStr("personalEmailOfferPrimaryNote")}</p>
          <button
            className="sl-legacy-choice sl-personal-email-offer__secondary"
            type="submit"
            name="sky-offer-action"
            value="skip"
            formNoValidate
          >
            {msgStr("personalEmailOfferSkip")}
          </button>
        </div>
      </form>
    </LegacyFrame>
  );
}
