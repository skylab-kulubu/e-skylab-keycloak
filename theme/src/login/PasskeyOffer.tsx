import type { KcContext } from "./KcContext";
import type { I18n } from "./i18n";
import LegacyFrame from "./LegacyFrame";
import { getLegacyChromeProps, useLegacyChrome } from "./legacyChrome";

type PasskeyOfferProps = {
  kcContext: Extract<KcContext, { pageId: "passkey-offer.ftl" }>;
  i18n: I18n;
};

export default function PasskeyOffer(props: PasskeyOfferProps) {
  const { kcContext, i18n } = props;
  const { msgStr } = i18n;
  const title = msgStr("passkeyOfferTitle");

  useLegacyChrome(i18n, title);

  return (
    <LegacyFrame
      {...getLegacyChromeProps(i18n)}
      mainId="sl-passkey-offer-main"
      titleId="sl-passkey-offer-title"
      title={title}
      description={msgStr("passkeyOfferDescription")}
    >
      <form
        id="kc-passkey-offer-form"
        className="sl-passkey-offer"
        action={kcContext.url.loginAction}
        method="post"
      >
        <p className="sl-passkey-offer__privacy">{msgStr("passkeyOfferPrivacy")}</p>
        <div className="sl-passkey-offer__actions">
          <button
            className="sl-legacy-submit"
            type="submit"
            name="passkey-choice"
            value="yes"
          >
            {msgStr("passkeyOfferNow")}
          </button>
          <button
            className="sl-legacy-choice sl-passkey-offer__later"
            type="submit"
            name="passkey-choice"
            value="no"
          >
            {msgStr("passkeyOfferLater")}
          </button>
        </div>
      </form>
    </LegacyFrame>
  );
}
