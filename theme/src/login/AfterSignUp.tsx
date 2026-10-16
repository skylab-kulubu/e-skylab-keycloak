import type { KcContext } from "./KcContext";
import type { I18n } from "./i18n";
import LegacyFrame from "./LegacyFrame";
import PageMessage from "./PageMessage";
import { getLegacyChromeProps, useLegacyChrome } from "./legacyChrome";

type Context = Extract<KcContext, { pageId: "sky-after-sign-up-school.ftl" | "sky-after-sign-up-credentials.ftl" }>;

/** Server-owned registration continuation; every choice posts to the current native login action. */
export default function AfterSignUp({ kcContext, i18n }: { kcContext: Context; i18n: I18n }) {
  const { msgStr } = i18n;
  const school = kcContext.pageId === "sky-after-sign-up-school.ftl";
  const available = school && (kcContext.skyYtuLinkAvailable === true || kcContext.skyYtuLinkAvailable === "true");
  const title = msgStr(school ? "afterSignUpSchoolTitle" : "afterSignUpCredentialsTitle");
  useLegacyChrome(i18n, title);

  return (
    <LegacyFrame
      {...getLegacyChromeProps(i18n)}
      teams
      mainId={school ? "sl-after-sign-up-school-main" : "sl-after-sign-up-credentials-main"}
      titleId="sl-after-sign-up-title"
      title={title}
      description={msgStr(school ? "afterSignUpSchoolDescription" : "afterSignUpCredentialsDescription")}
    >
      {kcContext.message !== undefined && <PageMessage message={kcContext.message} />}
      <form
        id={school ? "kc-after-sign-up-school-form" : "kc-after-sign-up-credentials-form"}
        className="sl-passkey-offer"
        action={kcContext.url.loginAction}
        method="post"
      >
        <p className="sl-passkey-offer__privacy">
          {msgStr(school
            ? available ? "afterSignUpSchoolOptional" : "afterSignUpSchoolDeferred"
            : "afterSignUpCredentialsNote")}
        </p>
        <div className="sl-passkey-offer__actions">
          {school ? (
            <>
              {available && (
                <button className="sl-legacy-submit" type="submit" name="sky-sign-up-school-choice" value="link">
                  {msgStr("afterSignUpSchoolLink")}
                </button>
              )}
              <button
                className={available ? "sl-legacy-choice" : "sl-legacy-submit"}
                type="submit" name="sky-sign-up-school-choice" value="skip"
              >
                {msgStr(available ? "afterSignUpSchoolSkip" : "afterSignUpContinue")}
              </button>
            </>
          ) : (
            <>
              <button className="sl-legacy-submit" type="submit" name="sky-sign-up-credential-choice" value="passkey">
                {msgStr("afterSignUpPasskey")}
              </button>
              <button className="sl-legacy-choice" type="submit" name="sky-sign-up-credential-choice" value="password">
                {msgStr("afterSignUpPassword")}
              </button>
              <button className="sl-legacy-choice sl-passkey-offer__later" type="submit" name="sky-sign-up-credential-choice" value="skip">
                {msgStr("afterSignUpSkip")}
              </button>
            </>
          )}
        </div>
      </form>
    </LegacyFrame>
  );
}
