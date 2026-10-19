import type { KcContext } from "./KcContext";
import { startNavigationLoading } from "./navigationLoading";

/**
 * "E-postayla devam et" (eskylab-login-ux 08): the SPI's sky-email-code step runs in its own
 * ALTERNATIVE subflow of the realm's browser flow, next to the password form. Keycloak lists the
 * steps a person may switch to on every page of that flow (auth.authenticationSelections) and takes
 * a switch as a POST of authenticationExecution to the page's own action. The step's option is
 * named by its provider id, the display name sky-email-code-display-name; when it is missing (the
 * realm has no such subflow, or it is off: KEYCLOAK_EMAIL_CODE_LOGIN=off), the login page keeps its
 * password view.
 */
export const EMAIL_CODE_DISPLAY_NAME = "sky-email-code-display-name";
const PASSWORD_FORM_DISPLAY_NAMES = [
  "sky-username-password-form-display-name",
  "auth-username-password-form-display-name"
];

type Selection = { authExecId: string; displayName: string };

function isSelection(value: unknown): value is Selection {
  return (
    typeof value === "object" &&
    value !== null &&
    typeof (value as Selection).authExecId === "string" &&
    typeof (value as Selection).displayName === "string"
  );
}

function selections(kcContext: KcContext): Selection[] {
  const list = (kcContext as { auth?: { authenticationSelections?: unknown } }).auth?.authenticationSelections;
  return Array.isArray(list) ? list.filter(isSelection) : [];
}

/** The execution of the e-mail code step Keycloak offers on this page, if it offers it. */
export function emailCodeExecutionId(kcContext: KcContext): string | undefined {
  return selections(kcContext).find(selection => selection.displayName === EMAIL_CODE_DISPLAY_NAME)?.authExecId;
}

/** The execution of the password form Keycloak offers on this page ("Parolanla gir"). */
export function passwordFormExecutionId(kcContext: KcContext): string | undefined {
  return selections(kcContext).find(selection => PASSWORD_FORM_DISPLAY_NAMES.includes(selection.displayName))?.authExecId;
}

/**
 * Switches steps as Keycloak's "try another way" list does. "Hesap aç" uses the same e-mail
 * code step with its existing SPI intent; ordinary sign-in switches carry no registration intent.
 */
export function chooseExecution(action: string, executionId: string, intent?: "sign-up"): void {
  const form = document.createElement("form");
  form.method = "post";
  form.action = action;
  form.hidden = true;
  const input = document.createElement("input");
  input.type = "hidden";
  input.name = "authenticationExecution";
  input.value = executionId;
  form.appendChild(input);
  if (intent === "sign-up") {
    const signUp = document.createElement("input");
    signUp.type = "hidden";
    signUp.name = "sky-email-code-intent";
    signUp.value = intent;
    form.appendChild(signUp);
  }
  document.body.appendChild(form);
  // form.submit() fires no submit event, so the loading state is started here.
  startNavigationLoading();
  form.submit();
}

/**
 * "Parolanla gir" lands on Keycloak's login page, whose first screen offers "E-postayla devam et"
 * again; the choice and what was typed travel in this tab's session storage so that page opens on
 * its password view with the field filled. Read once; a choice older than a few minutes is ignored.
 */
const PASSWORD_CHOICE_KEY = "sl-email-code-password-choice";
const PASSWORD_CHOICE_LIFETIME_MS = 5 * 60 * 1000;

export function rememberPasswordChoice(identifier: string): void {
  try {
    window.sessionStorage.setItem(PASSWORD_CHOICE_KEY, JSON.stringify({ identifier, at: Date.now() }));
  } catch {
    // Without storage the login page opens on its first screen; nothing else changes.
  }
}

export function takePasswordChoice(): { identifier: string } | undefined {
  try {
    const stored = window.sessionStorage.getItem(PASSWORD_CHOICE_KEY);
    window.sessionStorage.removeItem(PASSWORD_CHOICE_KEY);
    if (stored === null) {
      return undefined;
    }
    const choice = JSON.parse(stored) as { identifier?: unknown; at?: unknown };
    if (typeof choice.at !== "number" || Date.now() - choice.at > PASSWORD_CHOICE_LIFETIME_MS) {
      return undefined;
    }
    return { identifier: typeof choice.identifier === "string" ? choice.identifier : "" };
  } catch {
    return undefined;
  }
}

// The error codes of the SPI's sky-email-code page (EmailCodeAuthenticator.Problem in spi/): each
// becomes one sentence; anything else is shown as no error at all.
export const emailCodeErrors = [
  "invalid_identifier",
  "rate_limited",
  "resend_too_soon",
  "malformed_code",
  "wrong_code",
  "code_expired",
  "too_many_tries",
  "account_disabled",
  "account_locked",
  "unavailable"
] as const;

export type EmailCodeError = (typeof emailCodeErrors)[number];

export function toEmailCodeError(value: string | undefined): EmailCodeError | undefined {
  return (emailCodeErrors as readonly string[]).includes(value ?? "") ? (value as EmailCodeError) : undefined;
}
