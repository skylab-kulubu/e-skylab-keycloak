import { createGetKcContextMock } from "keycloakify/login/KcContext";
import type { Attribute } from "keycloakify/login/KcContext";
import { kcEnvDefaults, themeNames } from "./kc.gen";
import type {
  KcContext,
  KcContextExtension,
  KcContextExtensionPerPage
} from "./login/KcContext";
import { isThemedPageId, themedPageIds, type ThemedPageId } from "./login/pageIds";

// The person used by every preview: a Verified YTÜ account of the club.
const previewUser = {
  username: "ayse.yilmaz",
  email: "ayse.yilmaz@std.yildiz.edu.tr",
  firstName: "Ayşe",
  lastName: "Yılmaz"
};

// The YTÜ Microsoft identity provider: alias `OBS`, provider type `microsoft`.
const microsoftProvider = {
  alias: "OBS",
  displayName: "YTÜ Microsoft",
  providerId: "microsoft",
  loginUrl: "#microsoft"
};

const passkeyAuthenticators = [
  {
    credentialId: "sl-passkey-macbook",
    label: "MacBook Touch ID",
    createdAt: "12 Eyl 2026, 14:03",
    transports: { iconClass: "kcWebAuthnInternal", displayNameProperties: ["internal"] }
  },
  {
    credentialId: "sl-passkey-iphone",
    label: "iPhone Face ID",
    createdAt: "3 Ağu 2026, 09:41",
    transports: { iconClass: "kcWebAuthnInternal", displayNameProperties: ["internal"] }
  }
];

type MockAttribute = Omit<Attribute, "validators"> & {
  validators: { [Key in keyof Attribute["validators"]]?: Attribute["validators"][Key] | undefined };
};

function profileAttribute(
  name: string,
  displayName: string,
  value: string,
  options: Partial<MockAttribute> = {}
): MockAttribute {
  return {
    name,
    displayName,
    value,
    required: true,
    readOnly: false,
    validators: { length: { max: "255", "ignore.empty.value": true } },
    annotations: {},
    ...options
  };
}

const profileAttributesByName = {
  username: profileAttribute("username", "${username}", previewUser.username, {
    autocomplete: "username",
    validators: { length: { min: "3", max: "255", "ignore.empty.value": true } }
  }),
  email: profileAttribute("email", "${email}", previewUser.email, {
    autocomplete: "email",
    readOnly: true,
    // Keycloakify's sample profile carries a gmail-only pattern; drop it so the form is submittable.
    validators: { email: { "ignore.empty.value": true }, pattern: undefined }
  }),
  firstName: profileAttribute("firstName", "${firstName}", previewUser.firstName),
  lastName: profileAttribute("lastName", "${lastName}", previewUser.lastName)
};

const { getKcContextMock } = createGetKcContextMock({
  kcContextExtension: {
    themeName: themeNames[0],
    properties: { ...kcEnvDefaults }
  } satisfies KcContextExtension,
  kcContextExtensionPerPage: {
    "passkey-offer.ftl": {},
    "sky-handoff-failed.ftl": { skyHandoffReason: "expired" }
  } satisfies KcContextExtensionPerPage,
  overrides: {
    realm: {
      name: "e-skylab",
      displayName: "SKY LAB",
      displayNameHtml: "SKY LAB",
      internationalizationEnabled: true
    },
    locale: {
      currentLanguageTag: "tr",
      supported: [
        { languageTag: "tr", label: "Türkçe", url: "?lang=tr" },
        { languageTag: "en", label: "English", url: "?lang=en" }
      ]
    },
    client: {
      clientId: "account-center",
      name: "SKY LAB Hesap Merkezi",
      attributes: {}
    },
    isAppInitiatedAction: true
  },
  overridesPerPage: {
    "login.ftl": {
      enableWebAuthnConditionalUI: true,
      realm: { rememberMe: true },
      login: { rememberMe: "on" },
      social: {
        displayInfo: true,
        providers: [microsoftProvider]
      },
      authenticatorAttachment: "platform",
      mediation: "conditional"
    },
    "login-username.ftl": {
      enableWebAuthnConditionalUI: true,
      realm: { rememberMe: true, registrationAllowed: false },
      login: { rememberMe: "on" },
      social: {
        displayInfo: true,
        providers: [microsoftProvider]
      },
      authenticatorAttachment: "platform",
      mediation: "conditional"
    },
    "login-password.ftl": {
      auth: {
        showUsername: true,
        showResetCredentials: false,
        showTryAnotherWayLink: true,
        attemptedUsername: previewUser.email
      },
      enableWebAuthnConditionalUI: true
    },
    "login-update-password.ftl": {},
    "login-config-totp.ftl": {
      totp: {
        username: previewUser.username,
        supportedApplications: ["FreeOTP", "Google Authenticator", "Microsoft Authenticator"],
        otpCredentials: []
      }
    },
    "login-otp.ftl": {
      isAppInitiatedAction: false,
      otpLogin: {
        userOtpCredentials: [
          { id: "sl-otp-phone", userLabel: "iPhone" },
          { id: "sl-otp-backup", userLabel: "Yedek cihaz" }
        ],
        selectedCredentialId: "sl-otp-phone"
      }
    },
    "webauthn-register.ftl": {
      username: previewUser.username,
      rpEntityName: "SKY LAB",
      rpId: "yildizskylab.com",
      authenticatorAttachment: "platform",
      requireResidentKey: "true",
      residentKey: "required",
      userVerificationRequirement: "required"
    },
    "webauthn-authenticate.ftl": {
      isAppInitiatedAction: false,
      rpId: "yildizskylab.com",
      realm: { registrationAllowed: false },
      shouldDisplayAuthenticators: true,
      authenticators: { authenticators: passkeyAuthenticators }
    },
    "webauthn-error.ftl": {
      execution: "webauthn-execution-fixture",
      message: {
        type: "error",
        summary: "Erişim anahtarı kaydedilemedi. Cihazın isteği reddetti."
      }
    },
    "login-passkeys-conditional-authenticate.ftl": {
      isAppInitiatedAction: false,
      rpId: "yildizskylab.com",
      realm: { registrationAllowed: false },
      shouldDisplayAuthenticators: true,
      authenticators: { authenticators: passkeyAuthenticators }
    },
    "select-authenticator.ftl": {
      isAppInitiatedAction: false,
      auth: {
        authenticationSelections: [
          {
            authExecId: "sl-exec-password",
            displayName: "password-display-name",
            helpText: "password-help-text",
            iconCssClass: "kcAuthenticatorPasswordClass"
          },
          {
            authExecId: "sl-exec-otp",
            displayName: "otp-display-name",
            helpText: "otp-help-text",
            iconCssClass: "kcAuthenticatorOTPClass"
          },
          {
            authExecId: "sl-exec-passkey",
            displayName: "webauthn-passwordless-display-name",
            helpText: "webauthn-passwordless-help-text",
            iconCssClass: "kcAuthenticatorWebAuthnPasswordlessClass"
          }
        ]
      }
    },
    "login-reset-password.ftl": {
      isAppInitiatedAction: false,
      realm: { loginWithEmailAllowed: true, duplicateEmailsAllowed: false },
      auth: { attemptedUsername: previewUser.email }
    },
    "login-verify-email.ftl": {
      isAppInitiatedAction: false,
      user: { email: previewUser.email }
    },
    "login-update-profile.ftl": {
      profile: { attributesByName: profileAttributesByName }
    },
    "update-email.ftl": {
      profile: {
        attributesByName: {
          email: profileAttribute("email", "${email}", "", {
            autocomplete: "email",
            validators: { email: { "ignore.empty.value": true }, pattern: undefined }
          })
        }
      }
    },
    "login-page-expired.ftl": {
      isAppInitiatedAction: false
    },
    "error.ftl": {
      isAppInitiatedAction: false,
      client: { clientId: "account-center", baseUrl: "https://my.yildizskylab.com", attributes: {} },
      message: {
        type: "error",
        summary: "Giriş isteği geçersiz veya süresi dolmuş. Hesap Merkezi'ne dönüp yeniden dene."
      }
    },
    "info.ftl": {
      isAppInitiatedAction: false,
      messageHeader: "E-posta adresin doğrulandı",
      message: {
        type: "success",
        summary: "Artık SKY LAB hesabınla tüm kulüp uygulamalarına giriş yapabilirsin."
      },
      requiredActions: undefined,
      skipLink: false,
      actionUri: undefined,
      pageRedirectUri: "https://my.yildizskylab.com",
      client: { clientId: "account-center", baseUrl: "https://my.yildizskylab.com", attributes: {} }
    },
    "logout-confirm.ftl": {
      isAppInitiatedAction: false,
      url: { logoutConfirmAction: "#logout" },
      client: { clientId: "account-center", baseUrl: "https://my.yildizskylab.com", attributes: {} },
      logoutConfirm: { code: "sl-logout-code", skipLink: false }
    },
    "delete-credential.ftl": {
      credentialLabel: "MacBook Touch ID"
    },
    "terms.ftl": {
      isAppInitiatedAction: false,
      "x-keycloakify": {
        messages: {
          termsText:
            "<p>SKY LAB hesabın yalnızca kulüp etkinlikleri, üyelik ve yayın hizmetleri için kullanılır. Kişisel verilerin KVKK kapsamında işlenir; dilediğin zaman Hesap Merkezi'nden hesabını silebilirsin.</p><p>Devam ederek kulüp tüzüğüne ve topluluk kurallarına uyacağını kabul edersin.</p>"
        }
      }
    },
    "idp-review-user-profile.ftl": {
      isAppInitiatedAction: false,
      profile: { attributesByName: profileAttributesByName }
    },
    "login-idp-link-confirm.ftl": {
      isAppInitiatedAction: false,
      idpAlias: microsoftProvider.alias
    },
    "login-idp-link-email.ftl": {
      isAppInitiatedAction: false,
      idpAlias: microsoftProvider.alias,
      brokerContext: { username: previewUser.email }
    },
    "passkey-offer.ftl": {},
    // Rendered outside any login flow.
    "sky-handoff-failed.ftl": {
      isAppInitiatedAction: false
    }
  }
});

export { themedPageIds };

export function getDevKcContextForPage(pageId: ThemedPageId, languageTag: "tr" | "en" = "tr"): KcContext {
  return getKcContextMock({
    pageId,
    overrides: {
      locale: {
        currentLanguageTag: languageTag,
        supported: [
          { languageTag: "tr", label: "Türkçe", url: `?page=${pageId}&lang=tr` },
          { languageTag: "en", label: "English", url: `?page=${pageId}&lang=en` }
        ]
      }
    }
  }) as KcContext;
}

export function getDevKcContext(): KcContext {
  const searchParams = new URLSearchParams(window.location.search);
  const requestedPage = searchParams.get("page");
  const pageId = requestedPage !== null && isThemedPageId(requestedPage) ? requestedPage : "login.ftl";
  const languageTag = searchParams.get("lang") === "en" ? "en" : "tr";
  const kcContext = getDevKcContextForPage(pageId, languageTag);

  // `?page=sky-handoff-failed.ftl&reason=used` previews one failure reason; the value is passed
  // on unchecked, as the SPI would, so the page's own handling of unknown reasons is exercised.
  const reason = searchParams.get("reason");
  if (kcContext.pageId === "sky-handoff-failed.ftl" && reason !== null) {
    kcContext.skyHandoffReason = reason;
  }

  return kcContext;
}
