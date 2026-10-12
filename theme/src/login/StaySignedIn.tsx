import type { KcContext } from "./KcContext";
import type { I18n } from "./i18n";
import LegacyFrame from "./LegacyFrame";
import { getLegacyChromeProps, useLegacyChrome } from "./legacyChrome";

type StaySignedInProps = {
  kcContext: Extract<KcContext, { pageId: "sky-stay-signed-in.ftl" }>;
  i18n: I18n;
};

/**
 * "Bu cihazda oturumum açık kalsın mı?" at the end of every YTÜ login (the SPI's
 * sky-stay-signed-in required action; Microsoft's "Stay signed in?"). "Evet, açık kalsın"
 * makes the session a remember-me session, "Hayır" keeps it an ordinary one that ends with
 * the browser. The SPI hands over the remember-me idle time and lifespan in days; the page
 * words them and warns against "Evet" on a shared computer.
 */
export default function StaySignedIn(props: StaySignedInProps) {
  const { kcContext, i18n } = props;
  const { msgStr } = i18n;
  const title = msgStr("staySignedInTitle");
  const maxDays = kcContext.skyStaySignedInMaxDays ?? "30";
  const idleDays = kcContext.skyStaySignedInIdleDays ?? "7";

  useLegacyChrome(i18n, title);

  return (
    <LegacyFrame
      {...getLegacyChromeProps(i18n)}
      mainId="sl-stay-signed-in-main"
      titleId="sl-stay-signed-in-title"
      title={title}
      description={msgStr("staySignedInDescription", maxDays, idleDays)}
    >
      <form
        id="kc-stay-signed-in-form"
        className="sl-stay-signed-in"
        action={kcContext.url.loginAction}
        method="post"
      >
        <p id="sky-stay-signed-in-shared-device" className="sl-stay-signed-in__warning">
          {msgStr("staySignedInSharedDevice")}
        </p>
        <div className="sl-stay-signed-in__actions">
          <button className="sl-legacy-submit" type="submit" name="sky-stay-signed-in" value="yes">
            {msgStr("staySignedInYes")}
          </button>
          <button
            className="sl-legacy-choice sl-stay-signed-in__no"
            type="submit"
            name="sky-stay-signed-in"
            value="no"
          >
            {msgStr("staySignedInNo")}
          </button>
        </div>
      </form>
    </LegacyFrame>
  );
}
