import { lazy, Suspense } from "react";
import DefaultPage from "keycloakify/login/DefaultPage";
import type { ClassKey } from "keycloakify/login";
import type { KcContext } from "./KcContext";
import HandoffFailed from "./HandoffFailed";
import Login from "./Login";
import LoginPageExpired from "./LoginPageExpired";
import PasskeyOffer from "./PasskeyOffer";
import Template from "./Template";
import { useI18n } from "./i18n";
import { usePasskeyRememberMeBridge } from "./rememberMeBridge";
// One stylesheet, one token set: the login page design system for every page.
import "./legacy-login.css";

const UserProfileFormFields = lazy(() => import("keycloakify/login/UserProfileFormFields"));

export default function KcPage(props: { kcContext: KcContext }) {
  const { kcContext } = props;
  const { i18n } = useI18n({ kcContext });

  usePasskeyRememberMeBridge(kcContext);

  if (kcContext.pageId === "login.ftl") {
    return (
      <Suspense fallback={<main className="sl-loading" aria-live="polite">{i18n.msgStr("skylabLoading")}</main>}>
        <Login
          kcContext={kcContext}
          i18n={i18n}
          classes={classes}
          Template={Template}
          doUseDefaultCss={false}
        />
      </Suspense>
    );
  }

  if (kcContext.pageId === "login-page-expired.ftl") {
    return (
      <Suspense fallback={<main className="sl-loading" aria-live="polite">{i18n.msgStr("skylabLoading")}</main>}>
        <LoginPageExpired
          kcContext={kcContext}
          i18n={i18n}
          classes={classes}
          Template={Template}
          doUseDefaultCss={false}
        />
      </Suspense>
    );
  }

  if (kcContext.pageId === "passkey-offer.ftl") {
    return (
      <Suspense fallback={<main className="sl-loading" aria-live="polite">{i18n.msgStr("skylabLoading")}</main>}>
        <PasskeyOffer kcContext={kcContext} i18n={i18n} />
      </Suspense>
    );
  }

  if (kcContext.pageId === "sky-handoff-failed.ftl") {
    return (
      <Suspense fallback={<main className="sl-loading" aria-live="polite">{i18n.msgStr("skylabLoading")}</main>}>
        <HandoffFailed kcContext={kcContext} i18n={i18n} />
      </Suspense>
    );
  }

  return (
    <Suspense fallback={<main className="sl-loading" aria-live="polite">{i18n.msgStr("skylabLoading")}</main>}>
      <DefaultPage
        kcContext={kcContext}
        i18n={i18n}
        classes={classes}
        Template={Template}
        doUseDefaultCss={false}
        UserProfileFormFields={UserProfileFormFields}
        doMakeUserConfirmPassword
      />
    </Suspense>
  );
}

// Keycloakify's class contract, pointed at the login page's own class names so
// DefaultPage controls share the exact rules of Login.tsx instead of copies.
export const classes = {
  kcFormClass: "sl-form",
  kcFormGroupClass: "sl-legacy-field",
  kcFormGroupErrorClass: "sl-legacy-field--error",
  kcLabelClass: "sl-legacy-label",
  kcLabelWrapperClass: "sl-label-wrap",
  kcInputWrapperClass: "sl-input-wrap",
  kcInputClass: "sl-legacy-input",
  kcInputLargeClass: "sl-legacy-input--large",
  kcTextareaClass: "sl-legacy-input sl-textarea",
  kcInputGroup: "sl-legacy-password-input",
  kcInputErrorMessageClass: "sl-legacy-field-error",
  kcInputHelperTextBeforeClass: "sl-helper-text",
  kcInputHelperTextAfterClass: "sl-helper-text",
  kcFormOptionsClass: "sl-options",
  kcFormOptionsWrapperClass: "sl-options__item",
  kcFormSettingClass: "sl-settings",
  kcFormButtonsClass: "sl-actions",
  kcFormButtonsWrapperClass: "sl-actions",
  kcButtonClass: "sl-legacy-button",
  kcButtonPrimaryClass: "sl-legacy-submit",
  kcButtonSecondaryClass: "sl-legacy-choice",
  kcButtonDefaultClass: "sl-legacy-choice",
  kcButtonLargeClass: "sl-legacy-button--large",
  kcButtonBlockClass: "sl-legacy-button--block",
  kcFormPasswordVisibilityButtonClass: "sl-legacy-password-toggle",
  kcFormPasswordVisibilityIconShow: "sl-eye sl-eye--show",
  kcFormPasswordVisibilityIconHide: "sl-eye sl-eye--hide",
  kcAlertClass: "sl-legacy-alert",
  kcAlertTitleClass: "sl-legacy-alert__title",
  kcFeedbackSuccessIcon: "sl-feedback-icon sl-feedback-icon--success",
  kcFeedbackWarningIcon: "sl-feedback-icon sl-feedback-icon--warning",
  kcFeedbackErrorIcon: "sl-feedback-icon sl-feedback-icon--error",
  kcFeedbackInfoIcon: "sl-feedback-icon sl-feedback-icon--info",
  kcSignUpClass: "sl-sign-up",
  kcInfoAreaWrapperClass: "sl-info__inner",
  kcFormSocialAccountSectionClass: "sl-social",
  kcFormSocialAccountListClass: "sl-social__list",
  kcFormSocialAccountListGridClass: "sl-social__list--grid",
  kcFormSocialAccountListButtonClass: "sl-legacy-button sl-legacy-choice sl-legacy-button--block",
  kcFormSocialAccountNameClass: "sl-social__name",
  kcFormSocialAccountGridItem: "sl-social__item",
  kcFormSocialAccountLinkClass: "sl-social__link",
  kcSelectAuthListClass: "sl-auth-list",
  kcSelectAuthListItemClass: "sl-auth-item",
  kcSelectAuthListItemIconClass: "sl-auth-item__icon",
  kcSelectAuthListItemIconPropertyClass: "sl-auth-item__icon-mark",
  kcSelectAuthListItemBodyClass: "sl-auth-item__body",
  kcSelectAuthListItemHeadingClass: "sl-auth-item__title",
  kcSelectAuthListItemDescriptionClass: "sl-auth-item__description",
  kcSelectAuthListItemFillClass: "sl-auth-item__fill",
  kcSelectAuthListItemArrowClass: "sl-auth-item__arrow",
  kcSelectAuthListItemArrowIconClass: "sl-auth-item__arrow-mark",
  kcSelectAuthListItemTitle: "sl-auth-list__title",
  kcWebAuthnKeyIcon: "sl-key-icon",
  kcWebAuthnDefaultIcon: "sl-key-icon",
  kcWebAuthnUnknownIcon: "sl-key-icon",
  kcWebAuthnUSB: "sl-key-icon",
  kcWebAuthnNFC: "sl-key-icon",
  kcWebAuthnBLE: "sl-key-icon",
  kcWebAuthnInternal: "sl-key-icon",
  kcAuthenticatorDefaultClass: "sl-authenticator-icon",
  kcAuthenticatorPasswordClass: "sl-authenticator-icon sl-authenticator-icon--password",
  kcAuthenticatorOTPClass: "sl-authenticator-icon sl-authenticator-icon--otp",
  kcAuthenticatorWebAuthnClass: "sl-authenticator-icon sl-authenticator-icon--passkey",
  kcAuthenticatorWebAuthnPasswordlessClass: "sl-authenticator-icon sl-authenticator-icon--passkey",
  kcLoginOTPListClass: "sl-otp-list",
  kcLoginOTPListInputClass: "sl-otp-list__input",
  kcLoginOTPListItemHeaderClass: "sl-otp-list__header",
  kcLoginOTPListItemIconBodyClass: "sl-otp-list__icon",
  kcLoginOTPListItemIconClass: "sl-authenticator-icon sl-authenticator-icon--otp",
  kcLoginOTPListItemTitleClass: "sl-otp-list__title",
  kcInputClassRadio: "sl-choice",
  kcInputClassRadioInput: "sl-choice__input",
  kcInputClassRadioLabel: "sl-choice__label",
  kcInputClassCheckbox: "sl-choice",
  kcInputClassCheckboxInput: "sl-choice__input",
  kcInputClassCheckboxLabel: "sl-choice__label",
  kcInputClassRadioCheckboxLabelDisabled: "sl-choice__label--disabled",
  kcCheckboxInputClass: "sl-choice__input",
  kcCheckClass: "sl-choice",
  kcCheckInputClass: "sl-choice__input",
  kcCheckLabelClass: "sl-choice__label",
  kcRecoveryCodesWarning: "sl-recovery-warning",
  kcRecoveryCodesList: "sl-recovery-list",
  kcRecoveryCodesActions: "sl-actions",
  kcRecoveryCodesConfirmation: "sl-choice",
  kcSrOnlyClass: "sl-sr-only",
  kcResetFlowIcon: "sl-reset-icon",
  kcFormGroupHeader: "sl-section-title",
  kcContentWrapperClass: "sl-content-grid"
} satisfies { [key in ClassKey]?: string };
