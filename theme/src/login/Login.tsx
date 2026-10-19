import { useState } from "react";
import { kcSanitize } from "keycloakify/lib/kcSanitize";
import type { PageProps } from "keycloakify/login/pages/PageProps";
import { useScript } from "keycloakify/login/pages/Login.useScript";
import type { KcContext } from "./KcContext";
import type { I18n } from "./i18n";
import YtuMark from "./YtuMark";
import LegacyFrame from "./LegacyFrame";
import PageMessage from "./PageMessage";
import BrokerLinkEscape from "./BrokerLinkEscape";
import { BackArrow } from "./BackToChoice";
import { withViewTransition } from "./pageTransitions";
import { getLegacyChromeProps, useLegacyChrome } from "./legacyChrome";
import { chooseExecution, emailCodeExecutionId, takePasswordChoice } from "./emailCodeChoice";

type LoginProps = PageProps<Extract<KcContext, { pageId: "login.ftl" }>, I18n>;

/** YTÜ's self-service reset of the school (Microsoft) password. */
const SCHOOL_PASSWORD_RESET_URL = "https://passwordreset.microsoftonline.com/";

export default function Login(props: LoginProps) {
  const { kcContext, i18n } = props;
  const {
    auth,
    authenticators,
    enableWebAuthnConditionalUI,
    login,
    messagesPerField,
    realm,
    social,
    url,
    usernameHidden
  } = kcContext;
  const { msg, msgStr } = i18n;
  const webAuthnButtonId = "authenticateWebAuthnButton";
  const hasPasskey =
    enableWebAuthnConditionalUI === true ||
    (authenticators !== undefined && authenticators.authenticators.length > 0);
  const microsoftProvider = social?.providers?.find(provider => provider.providerId === "microsoft");
  const hasCredentialsError = messagesPerField.existsError("username", "password");
  const isBrokerProof = kcContext.skyExistingAccountEscape === true;
  // Wrong credentials belong to the fields (shown once, under them); every other message is page-wide.
  const pageMessage = hasCredentialsError ? undefined : kcContext.message;
  const resetPasswordUrl = !isBrokerProof && realm.password && realm.resetPasswordAllowed
    ? url.loginResetCredentialsUrl : undefined;
  // With the e-mail code step on (eskylab-login-ux 08) the e-mail button goes there, and that page's
  // "Parolanla gir" comes back here straight to the password view, the field filled.
  const emailCodeExecution = emailCodeExecutionId(kcContext);
  const signUpExecution = !isBrokerProof && (kcContext.skyEmailCodeSignUp === "true" || kcContext.skyEmailCodeSignUp === true)
    ? emailCodeExecution : undefined;
  const [passwordChoice] = useState(takePasswordChoice);
  const [view, setView] = useState<"choice" | "password">(
    hasCredentialsError || passwordChoice !== undefined || isBrokerProof ? "password" : "choice"
  );
  const [isLoginButtonDisabled, setIsLoginButtonDisabled] = useState(false);
  const [isPasswordVisible, setIsPasswordVisible] = useState(false);

  useScript({ webAuthnButtonId, kcContext, i18n });
  useLegacyChrome(i18n, msgStr("loginTitle", realm.displayName || realm.name), { brandedTitle: true });

  return (
    <LegacyFrame
      {...getLegacyChromeProps(i18n, { brand: true })}
      mainId="sl-legacy-main"
      titleId="sl-legacy-title"
      title={msgStr("skylabTitle")}
      description={msgStr("skylabDesc")}
      headerExtras={pageMessage !== undefined && <PageMessage message={pageMessage} />}
    >
            {view === "choice" && (
              <>
                <div className="sl-legacy-choices">
                  {microsoftProvider !== undefined && (
                    <a className="sl-legacy-choice sl-legacy-choice--row sl-legacy-choice--primary" href={microsoftProvider.loginUrl}>
                      <span className="sl-legacy-choice__icon">
                        <YtuMark />
                      </span>
                      <span className="sl-legacy-choice__label">
                        {msgStr("microsoft")}{" "}
                        <span className="sl-legacy-choice__hint">{msgStr("microsoftHint")}</span>
                      </span>
                      <svg className="sl-legacy-choice__arrow" aria-hidden="true" viewBox="0 0 24 24" fill="none">
                        <path d="m9 6 6 6-6 6" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" />
                      </svg>
                    </a>
                  )}

                  <button
                    className="sl-legacy-choice sl-legacy-choice--row"
                    type="button"
                    onClick={() =>
                      emailCodeExecution === undefined
                        ? withViewTransition(() => setView("password"))
                        : chooseExecution(url.loginAction, emailCodeExecution)
                    }
                  >
                    <span className="sl-legacy-choice__icon">
                      <svg aria-hidden="true" viewBox="0 0 24 24" fill="none">
                        <path
                          d="M16 7a4 4 0 1 1-8 0 4 4 0 0 1 8 0ZM12 14a7 7 0 0 0-7 7h14a7 7 0 0 0-7-7Z"
                          stroke="currentColor"
                          strokeLinecap="round"
                          strokeLinejoin="round"
                          strokeWidth="2"
                        />
                      </svg>
                    </span>
                    <span className="sl-legacy-choice__label">{msgStr("continueWithEmail")}</span>
                    <svg className="sl-legacy-choice__arrow" aria-hidden="true" viewBox="0 0 24 24" fill="none">
                      <path d="m9 6 6 6-6 6" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" />
                    </svg>
                  </button>
                </div>

                {/*
                  The other ways in, on one quiet line under the two main choices. "Parolanı mı
                  unuttun?" lives in the password form, under the password field.
                */}
                {(hasPasskey || signUpExecution !== undefined) && (
                  <div className="sl-legacy-alternatives">
                    {hasPasskey && (
                      <button
                        id={webAuthnButtonId}
                        className="sl-legacy-passkey"
                        type="button"
                      >
                        <span className="sl-key-icon" aria-hidden="true" />
                        {msgStr("passkeyChoice")}
                      </button>
                    )}
                    {signUpExecution !== undefined && (
                      <p className="sl-legacy-alternatives__sign-up">
                        {msgStr("noAccount")}{" "}
                        <button className="sl-text-button" type="button"
                          onClick={() => chooseExecution(url.loginAction, signUpExecution, "sign-up")}>
                          {msgStr("emailCodeSignUpShort")}
                        </button>
                      </p>
                    )}
                  </div>
                )}

                {/* The one functional thing left of the YTÜ help: a plain link to reset the school password. */}
                {microsoftProvider !== undefined && (
                  <p className="sl-legacy-school-reset">
                    <a href={SCHOOL_PASSWORD_RESET_URL} target="_blank" rel="noopener noreferrer">
                      {msgStr("skylabSchoolPasswordResetLink")}
                    </a>
                  </p>
                )}
              </>
            )}

            {view === "password" && (
              <div className="sl-legacy-password-view">
                {!isBrokerProof && <button
                  className="sl-legacy-back"
                  type="button"
                  onClick={() => withViewTransition(() => setView("choice"), "back")}
                >
                  <BackArrow />
                  {msgStr("goBack")}
                </button>}

                <form
                  id="kc-form-login"
                  action={url.loginAction}
                  method="post"
                  onSubmit={() => setIsLoginButtonDisabled(true)}
                >
                  {!usernameHidden && (
                    <div className="sl-legacy-field">
                      <label htmlFor="username">
                        {!realm.loginWithEmailAllowed
                          ? msg("username")
                          : realm.registrationEmailAsUsername
                            ? msg("email")
                            : msg("usernameOrEmail")}
                      </label>
                      <input
                        id="username"
                        className="sl-legacy-input"
                        name="username"
                        type="text"
                        autoFocus
                        autoComplete={enableWebAuthnConditionalUI ? "username webauthn" : "username"}
                        defaultValue={login.username ?? passwordChoice?.identifier ?? ""}
                        aria-invalid={hasCredentialsError}
                        aria-describedby={hasCredentialsError ? "input-error" : undefined}
                      />
                    </div>
                  )}

                  {realm.password && (
                    <div className="sl-legacy-field">
                      <label htmlFor="password">{msg("password")}</label>
                      <div className="sl-legacy-password-input">
                        <input
                          id="password"
                          className="sl-legacy-input"
                          name="password"
                          type={isPasswordVisible ? "text" : "password"}
                          autoComplete="current-password"
                          aria-invalid={hasCredentialsError}
                          aria-describedby={hasCredentialsError ? "input-error" : undefined}
                        />
                        <button
                          className="sl-legacy-password-toggle"
                          type="button"
                          aria-label={msgStr(isPasswordVisible ? "hidePassword" : "showPassword")}
                          aria-controls="password"
                          onClick={() => setIsPasswordVisible(current => !current)}
                        >
                          <span aria-hidden="true" className={`sl-eye sl-eye--${isPasswordVisible ? "hide" : "show"}`} />
                        </button>
                      </div>
                    </div>
                  )}

                  {hasCredentialsError && (
                    <p
                      id="input-error"
                      className="sl-legacy-field-error sl-legacy-field-error--after-field"
                      aria-live="polite"
                      dangerouslySetInnerHTML={{
                        __html: kcSanitize(messagesPerField.getFirstError("username", "password"))
                      }}
                    />
                  )}

                  {/* Directly below the password field: remember me on the left, the reset link on the right. */}
                  {((realm.rememberMe && !usernameHidden && !isBrokerProof) || resetPasswordUrl !== undefined) && (
                    <div className="sl-legacy-form-options">
                      {realm.rememberMe && !usernameHidden && !isBrokerProof && (
                        <label className="sl-legacy-remember" htmlFor="rememberMe">
                          <input
                            id="rememberMe"
                            name="rememberMe"
                            type="checkbox"
                            defaultChecked={Boolean(login.rememberMe)}
                          />
                          <span>{msg("rememberMe")}</span>
                        </label>
                      )}
                      {resetPasswordUrl !== undefined && (
                        <a className="sl-legacy-forgot" href={resetPasswordUrl}>
                          {msg("doForgotPassword")}
                        </a>
                      )}
                    </div>
                  )}

                  <input
                    id="id-hidden-input"
                    name="credentialId"
                    type="hidden"
                    value={auth.selectedCredential}
                  />
                  <button
                    id="kc-login"
                    className="sl-legacy-submit"
                    type="submit"
                    disabled={isLoginButtonDisabled}
                  >
                    {msg("doLogIn")}
                  </button>
                </form>

                {/*
                  No link to Keycloak's registration page, even if the realm allowed it: ADR-0063 keeps it
                  closed and opens accounts by e-mail code only. Without that step's registration
                  option, someone with a YTÜ account can still continue through Microsoft.
                */}
                {microsoftProvider !== undefined && !isBrokerProof && signUpExecution === undefined && (
                  <div className="sl-legacy-no-account">
                    <p className="sl-legacy-no-account__title">{msgStr("noAccount")}</p>
                    <p>
                      {msgStr("skylabNoAccountYtu")}{" "}
                      <a href={microsoftProvider.loginUrl}>{msgStr("skylabNoAccountYtuLink")}</a>.
                    </p>
                  </div>
                )}
              </div>
            )}

            {view === "password" && signUpExecution !== undefined && (
              <div className="sl-legacy-no-account">
                <p className="sl-legacy-no-account__title">{msgStr("noAccount")}</p>
                <p>
                  <button className="sl-text-button" type="button"
                    onClick={() => chooseExecution(url.loginAction, signUpExecution, "sign-up")}>
                    {msgStr("emailCodeSignUpLink")}
                  </button>
                </p>
              </div>
            )}

            <BrokerLinkEscape kcContext={kcContext} i18n={i18n} />

            {hasPasskey && (
              <>
                <form id="webauth" action={url.loginAction} method="post" hidden>
                  <input type="hidden" id="clientDataJSON" name="clientDataJSON" />
                  <input type="hidden" id="authenticatorData" name="authenticatorData" />
                  <input type="hidden" id="signature" name="signature" />
                  <input type="hidden" id="credentialId" name="credentialId" />
                  <input type="hidden" id="userHandle" name="userHandle" />
                  <input type="hidden" id="error" name="error" />
                </form>
                {authenticators !== undefined && authenticators.authenticators.length > 0 && (
                  <form id="authn_select" hidden>
                    {authenticators.authenticators.map(authenticator => (
                      <input
                        key={authenticator.credentialId}
                        type="hidden"
                        name="authn_use_chk"
                        readOnly
                        value={authenticator.credentialId}
                      />
                    ))}
                  </form>
                )}
              </>
            )}
    </LegacyFrame>
  );
}
