import { kcSanitize } from "keycloakify/lib/kcSanitize";
import type { TemplateProps } from "keycloakify/login/TemplateProps";
import { useInitialize } from "keycloakify/login/Template.useInitialize";
import type { KcContext } from "./KcContext";
import type { I18n } from "./i18n";
import LegacyFrame from "./LegacyFrame";
import { getLegacyChromeProps, getLegacyPageDescription, reactNodeToText, useLegacyChrome } from "./legacyChrome";

/**
 * The chrome for every Keycloakify `DefaultPage`: the same animated SKY LAB
 * logo, glass card, background and KVKK footer as the login page. Page bodies
 * keep Keycloak's element ids and the `sl-*` class contract from `KcPage`.
 */
export default function Template(props: TemplateProps<KcContext, I18n>) {
  const {
    displayInfo = false,
    displayMessage = true,
    displayRequiredFields = false,
    headerNode,
    socialProvidersNode = null,
    infoNode = null,
    documentTitle,
    kcContext,
    i18n,
    doUseDefaultCss,
    children
  } = props;

  const { auth, url, message, isAppInitiatedAction } = kcContext;
  const { msg, msgStr } = i18n;

  // Keycloakify never passes documentTitle, so the browser tab shows the page heading.
  useLegacyChrome(i18n, documentTitle ?? reactNodeToText(headerNode));

  const { isReadyToRender } = useInitialize({ kcContext, doUseDefaultCss });

  if (!isReadyToRender) {
    return null;
  }

  const showAttemptedUsername = auth?.showUsername && !auth.showResetCredentials;
  const messageIsVisible =
    displayMessage &&
    message !== undefined &&
    (message.type !== "warning" || !isAppInitiatedAction);

  return (
    <LegacyFrame
      {...getLegacyChromeProps(i18n, { kvkk: "action" })}
      mainId="sl-main-content"
      titleId="kc-page-title"
      title={headerNode}
      description={getLegacyPageDescription(i18n, kcContext.pageId)}
      headerExtras={
        <>
          {showAttemptedUsername && (
            <div className="sl-legacy-attempted-user">
              <span className="sl-legacy-attempted-user__label">{msgStr("skylabAttemptedUserLabel")}</span>
              <span id="kc-attempted-username">{auth.attemptedUsername}</span>
              <a id="reset-login" href={url.loginRestartFlowUrl}>
                {msg("restartLoginTooltip")}
              </a>
            </div>
          )}

          {displayRequiredFields && (
            <p className="sl-legacy-required-note">
              <span aria-hidden="true">*</span> {msg("requiredFields")}
            </p>
          )}

          {messageIsVisible && (
            <div
              className={`sl-legacy-alert sl-legacy-alert--${message.type}`}
              role={message.type === "error" ? "alert" : "status"}
              aria-live={message.type === "error" ? "assertive" : "polite"}
              dangerouslySetInnerHTML={{ __html: kcSanitize(message.summary) }}
            />
          )}
        </>
      }
    >
      <div className="sl-legacy-content">{children}</div>

      {auth?.showTryAnotherWayLink && (
        <form
          id="kc-select-try-another-way-form"
          className="sl-legacy-try-another-way"
          action={url.loginAction}
          method="post"
        >
          <input type="hidden" name="tryAnotherWay" value="on" />
          <button className="sl-text-button" type="submit" id="try-another-way">
            {msg("doTryAnotherWay")}
          </button>
        </form>
      )}

      {socialProvidersNode}

      {displayInfo && infoNode !== null && (
        <aside id="kc-info" className="sl-info" aria-label={msgStr("skylabInfoLabel")}>
          {infoNode}
        </aside>
      )}
    </LegacyFrame>
  );
}
