import type { KcContext } from "./KcContext";
import type { I18n } from "./i18n";
import LegacyFrame from "./LegacyFrame";
import { toHandoffFailureReason, type HandoffFailureReason } from "./handoffFailure";
import { getLegacyChromeProps, useLegacyChrome } from "./legacyChrome";

type HandoffFailedProps = {
  kcContext: Extract<KcContext, { pageId: "sky-handoff-failed.ftl" }>;
  i18n: I18n;
};

const sentenceKey = {
  expired: "skyHandoffFailed.expired",
  used: "skyHandoffFailed.used",
  invalid: "skyHandoffFailed.invalid",
  target_disabled: "skyHandoffFailed.target_disabled",
  account_unavailable: "skyHandoffFailed.account_unavailable",
  unavailable: "skyHandoffFailed.unavailable"
} as const satisfies Record<HandoffFailureReason, string>;

/**
 * Where a failed Web handoff lands inside SkyApp's WebView
 * (`/realms/{realm}/sky-handoff/v1/failed?reason=`): one sentence for the
 * reason and "go back to the app". The person can do nothing here, so there is
 * no form, no link to the login and no language switch; SkyApp may close the
 * WebView as soon as it sees the path.
 */
export default function HandoffFailed(props: HandoffFailedProps) {
  const { kcContext, i18n } = props;
  const { msgStr } = i18n;
  const reason = toHandoffFailureReason(kcContext.skyHandoffReason);
  const sentence = msgStr(sentenceKey[reason]);

  // The heading is a full sentence; the tab title drops its final period ("… · SKY LAB").
  useLegacyChrome(i18n, sentence.replace(/\.$/, ""));

  return (
    <LegacyFrame
      {...getLegacyChromeProps(i18n, { kvkk: "action", languageMenu: false })}
      mainId="sl-handoff-failed-main"
      titleId="sl-handoff-failed-title"
      title={sentence}
      description={msgStr("skyHandoffFailedRetry")}
    >
      {null}
    </LegacyFrame>
  );
}
