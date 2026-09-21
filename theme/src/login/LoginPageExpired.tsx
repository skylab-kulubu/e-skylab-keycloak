import type { PageProps } from "keycloakify/login/pages/PageProps";
import type { KcContext } from "./KcContext";
import type { I18n } from "./i18n";

type LoginPageExpiredProps = PageProps<Extract<KcContext, { pageId: "login-page-expired.ftl" }>, I18n>;

/**
 * Keycloak's default markup interleaves "click here" links with sentence
 * fragments, which cannot be phrased naturally in Turkish. The two choices are
 * rendered as full-width actions instead; the element ids stay Keycloak's.
 */
export default function LoginPageExpired(props: LoginPageExpiredProps) {
  const { kcContext, i18n, doUseDefaultCss, Template, classes } = props;
  const { url } = kcContext;
  const { msg } = i18n;

  return (
    <Template
      kcContext={kcContext}
      i18n={i18n}
      doUseDefaultCss={doUseDefaultCss}
      classes={classes}
      headerNode={msg("pageExpiredTitle")}
    >
      <div className="sl-legacy-choices">
        <a id="loginRestartLink" className="sl-legacy-submit sl-legacy-submit--link" href={url.loginRestartFlowUrl}>
          {msg("pageExpiredRestart")}
        </a>
        <a id="loginContinueLink" className="sl-legacy-choice" href={url.loginAction}>
          {msg("pageExpiredContinue")}
        </a>
      </div>
    </Template>
  );
}
