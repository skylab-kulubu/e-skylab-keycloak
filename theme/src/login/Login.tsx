import { useState } from "react";
import { kcSanitize } from "keycloakify/lib/kcSanitize";
import type { PageProps } from "keycloakify/login/pages/PageProps";
import { useScript } from "keycloakify/login/pages/Login.useScript";
import type { KcContext } from "./KcContext";
import type { I18n } from "./i18n";
import YtuMark from "./YtuMark";
import LegacyFrame from "./LegacyFrame";
import PageMessage from "./PageMessage";
import { getLegacyChromeProps, useLegacyChrome } from "./legacyChrome";

type LoginProps = PageProps<Extract<KcContext, { pageId: "login.ftl" }>, I18n>;

/** The club's public contact address (yildizskylab.com footer, SkyMail mails). */
const CLUB_CONTACT_EMAIL = "info@yildizskylab.com";
/** YTÜ's self-service reset of the school (Microsoft) password, then BİDB's help desk. */
const SCHOOL_PASSWORD_RESET_URL = "https://passwordreset.microsoftonline.com/";
const SCHOOL_SUPPORT_HOST = "teknikdestek.yildiz.edu.tr";
const SCHOOL_SUPPORT_URL = `https://${SCHOOL_SUPPORT_HOST}/`;

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
  // Wrong credentials belong to the fields (shown once, under them); every other message is page-wide.
  const pageMessage = hasCredentialsError ? undefined : kcContext.message;
  const resetPasswordUrl = realm.password && realm.resetPasswordAllowed ? url.loginResetCredentialsUrl : undefined;
  const [view, setView] = useState<"choice" | "password">(hasCredentialsError ? "password" : "choice");
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
                    onClick={() => setView("password")}
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

                <div className="sl-legacy-trust">
                  <p>{msgStr("skylabTrust")}</p>
                  <details>
                    <summary>{msgStr("skylabTrustMore")}</summary>
                    <ul>
                      <li>{msgStr("skylabTrustTakenId")}</li>
                      <li>{msgStr("skylabTrustTakenName")}</li>
                      <li>{msgStr("skylabTrustTakenEmail")}</li>
                      <li>{msgStr("skylabTrustTakenDepartment")}</li>
                    </ul>
                    <p>{msgStr("skylabTrustNotTaken")}</p>
                    <p>{msgStr("skylabTrustConsent")}</p>
                  </details>
                </div>

                {hasPasskey && (
                  <div className="sl-legacy-passkey-wrap">
                    <button
                      id={webAuthnButtonId}
                      className="sl-legacy-passkey"
                      type="button"
                    >
                      <span className="sl-key-icon" aria-hidden="true" />
                      {msgStr("passkeyChoice")}
                    </button>
                  </div>
                )}

                {resetPasswordUrl !== undefined && (
                  <p className="sl-legacy-choice-help">
                    <a href={resetPasswordUrl}>{msg("doForgotPassword")}</a>
                  </p>
                )}

                <details className="sl-legacy-school-help">
                  <summary>{msgStr("skylabSchoolPasswordHelp")}</summary>
                  <p>
                    <a href={SCHOOL_PASSWORD_RESET_URL} target="_blank" rel="noreferrer">
                      {msgStr("skylabSchoolPasswordReset")}
                    </a>
                    .{" "}
                    {msgStr("skylabSchoolPasswordSupport")}{" "}
                    <a href={SCHOOL_SUPPORT_URL} target="_blank" rel="noreferrer">
                      {SCHOOL_SUPPORT_HOST}
                    </a>
                  </p>
                  <p>{msgStr("skylabSchoolPasswordOwnPassword")}</p>
                </details>
              </>
            )}

            {view === "password" && (
              <div className="sl-legacy-password-view">
                <button
                  className="sl-legacy-back"
                  type="button"
                  onClick={() => setView("choice")}
                >
                  <svg aria-hidden="true" viewBox="0 0 24 24" fill="none">
                    <path
                      d="m15 19-7-7 7-7"
                      stroke="currentColor"
                      strokeLinecap="round"
                      strokeLinejoin="round"
                      strokeWidth="2"
                    />
                  </svg>
                  {msgStr("goBack")}
                </button>

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
                        defaultValue={login.username ?? ""}
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
                  {((realm.rememberMe && !usernameHidden) || resetPasswordUrl !== undefined) && (
                    <div className="sl-legacy-form-options">
                      {realm.rememberMe && !usernameHidden && (
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
                  closed and opens accounts by e-mail code only. When self-registration (eskylab-login-ux 09)
                  is live, this block becomes "Hesabın yok mu? E-postayla hesap aç" into that same door.
                */}
                <div className="sl-legacy-no-account">
                  <p className="sl-legacy-no-account__title">{msgStr("noAccount")}</p>
                  <p>{msgStr("skylabNoAccountYtu")}</p>
                  <p>
                    {msgStr("skylabNoAccountOthers")} {msgStr("skylabNoAccountContact")}{" "}
                    <a href={`mailto:${CLUB_CONTACT_EMAIL}`}>{CLUB_CONTACT_EMAIL}</a>
                  </p>
                </div>
              </div>
            )}

            <p className="sl-legacy-domain">{msgStr("skylabDomainNotice")}</p>

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
