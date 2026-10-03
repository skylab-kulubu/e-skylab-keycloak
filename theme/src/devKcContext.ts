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

type PreviewLanguageTag = "tr" | "en";
type PreviewMessage = { type: "success" | "warning" | "error" | "info"; summary: Record<PreviewLanguageTag, string> };
type PreviewState = { message: PreviewMessage; fieldErrors?: Record<string, PreviewMessage["summary"]>; username?: string };

// Keycloak's own wording for each state (its tr/en message bundles), so the preview shows what the server sends.
const invalidUserMessage = { tr: "Geçersiz kullanıcı adı veya şifre.", en: "Invalid username or password." };
const missingUsernameMessage = { tr: "Lütfen kullanıcı adını belirtin.", en: "Please specify username." };

/**
 * Server-side states of a page, previewed with `?page=<id>&state=<name>`: the page-wide
 * message Keycloak sends and, for a failed form, the field errors it attaches.
 */
export const previewStates = {
  "login.ftl": {
    // reset-credential-email forks back to the login page with this success message.
    "reset-email-sent": {
      message: {
        type: "success",
        summary: {
          tr: "Daha fazla talimatla kısa sürede bir e-posta almalısınız.",
          en: "You should receive an email shortly with further instructions."
        }
      }
    },
    "invalid-credentials": {
      message: { type: "error", summary: invalidUserMessage },
      fieldErrors: { username: invalidUserMessage },
      username: previewUser.username
    },
    // A failed YTÜ Microsoft sign-in comes back to the login page with a page-wide error.
    "idp-error": {
      message: {
        type: "error",
        summary: {
          tr: "Kimlik sağlayıcıyla kimlik doğrulaması yapılırken beklenmeyen bir hata oluştu",
          en: "Unexpected error when authenticating with identity provider"
        }
      }
    }
  },
  "login-reset-password.ftl": {
    "missing-username": {
      message: { type: "error", summary: missingUsernameMessage },
      fieldErrors: { username: missingUsernameMessage }
    }
  }
} satisfies Partial<Record<ThemedPageId, Record<string, PreviewState>>>;

export type PreviewStateName<PageId extends keyof typeof previewStates> = keyof (typeof previewStates)[PageId];

function previewMessagesPerField(fieldErrors: Record<string, string>): KcContext["messagesPerField"] {
  const get = (fieldName: string) => fieldErrors[fieldName] ?? "";
  const existsError = (...fieldNames: string[]) => fieldNames.some(fieldName => fieldErrors[fieldName] !== undefined);

  return {
    get,
    existsError,
    exists: fieldName => fieldErrors[fieldName] !== undefined,
    printIfExists: (fieldName, text) => (fieldErrors[fieldName] !== undefined ? text : undefined),
    getFirstError: (...fieldNames) => {
      const fieldName = fieldNames.find(name => fieldErrors[name] !== undefined);
      return fieldName === undefined ? "" : get(fieldName);
    }
  };
}

function applyPreviewState(kcContext: KcContext, state: string | null, languageTag: PreviewLanguageTag): KcContext {
  const states: Record<string, PreviewState> | undefined = (
    previewStates as Partial<Record<string, Record<string, PreviewState>>>
  )[kcContext.pageId];
  const previewState = state === null ? undefined : states?.[state];
  if (previewState === undefined) {
    return kcContext;
  }

  const fieldErrors = Object.fromEntries(
    Object.entries(previewState.fieldErrors ?? {}).map(([fieldName, summary]) => [fieldName, summary[languageTag]])
  );
  const withState = {
    ...kcContext,
    message: { type: previewState.message.type, summary: previewState.message.summary[languageTag] },
    messagesPerField: previewMessagesPerField(fieldErrors)
  } as KcContext;
  if (previewState.username !== undefined && withState.pageId === "login.ftl") {
    withState.login = { ...withState.login, username: previewState.username };
  }

  return withState;
}

export function getDevKcContextForPage(
  pageId: ThemedPageId,
  languageTag: PreviewLanguageTag = "tr",
  state: string | null = null
): KcContext {
  const kcContext = getKcContextMock({
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

  return applyPreviewState(kcContext, state, languageTag);
}

export function getDevKcContext(): KcContext {
  const searchParams = new URLSearchParams(window.location.search);
  const requestedPage = searchParams.get("page");
  const pageId = requestedPage !== null && isThemedPageId(requestedPage) ? requestedPage : "login.ftl";
  const languageTag = searchParams.get("lang") === "en" ? "en" : "tr";
  const kcContext = getDevKcContextForPage(pageId, languageTag, searchParams.get("state"));

  // `?page=sky-handoff-failed.ftl&reason=used` previews one failure reason; the value is passed
  // on unchecked, as the SPI would, so the page's own handling of unknown reasons is exercised.
  const reason = searchParams.get("reason");
  if (kcContext.pageId === "sky-handoff-failed.ftl" && reason !== null) {
    kcContext.skyHandoffReason = reason;
  }

  return kcContext;
}
