/* eslint-disable @typescript-eslint/no-empty-object-type */
import type { ExtendKcContext } from "keycloakify/login";
import type { KcEnvName, ThemeName } from "../kc.gen";

export type KcContextExtension = {
  themeName: ThemeName;
  properties: Record<KcEnvName, string> & {};
  skyExistingAccountEscape?: boolean;
  // Set by the SPI only while this realm offers registration through the e-mail code step.
  skyEmailCodeSignUp?: string | boolean;
};

export type KcContextExtensionPerPage = {
  "sky-existing-account.ftl": {
    skyExistingAccountStage?: string;
    skyExistingAccountIdentifier?: string;
    skyExistingAccountError?: string;
    skyExistingAccountSchoolCandidate?: boolean;
    skyExistingAccountResendAfter?: string;
  };
  "passkey-offer.ftl": {};
  // Rendered by the SPI's sky-personal-email-offer required action (first YTÜ login, ticket 21).
  "sky-personal-email-offer.ftl": {
    skyOfferStage?: string;
    skyOfferAddress?: string;
    skyOfferError?: string;
    skyOfferAttemptsLeft?: string;
    skyOfferCodeMinutes?: string;
  };
  // Rendered by the SPI's sky-email-code step after the right sign-up code (Self-registration,
  // eskylab-login-ux 09): the stage (form, ytu, existing, unavailable), the proven address, the form's
  // error and what was typed, and the YTÜ identity provider's alias.
  "sky-email-code-sign-up.ftl": {
    skySignUpStage?: string;
    skySignUpAddress?: string;
    skySignUpError?: string;
    skySignUpFirstName?: string;
    skySignUpLastName?: string;
    skySignUpYtuAlias?: string;
    // Keycloak's identity providers, as on every page its login forms render: the YTÜ stage links to one.
    social?: {
      providers?: { alias: string; displayName: string; providerId: string; loginUrl: string }[];
    };
  };
  // Rendered by the SPI's sky-email-code step ("E-postayla devam et", eskylab-login-ux 08); on the
  // identifier stage also Keycloak's conditional passkey data (WebAuthnConditionalUIAuthenticator).
  "sky-email-code.ftl": {
    skyEmailCodeIntent?: string;
    skyEmailCodeStage?: string;
    skyEmailCodeIdentifier?: string;
    skyEmailCodeError?: string;
    skyEmailCodeAttemptsLeft?: string;
    skyEmailCodeMinutes?: string;
    skyEmailCodeResendAfter?: string;
    enableWebAuthnConditionalUI?: boolean;
    isUserIdentified?: string | boolean;
    challenge?: string;
    userVerification?: string;
    rpId?: string;
    createTimeout?: string | number;
    mediation?: string;
    authenticatorAttachment?: string;
  };
  // Rendered by the SPI's sky-stay-signed-in required action (after every YTÜ login): the
  // remember-me idle time and lifespan in whole days.
  "sky-stay-signed-in.ftl": {
    skyStaySignedInIdleDays?: string;
    skyStaySignedInMaxDays?: string;
  };
  // Rendered by the SPI's sky-handoff provider (GET v1/failed); the reason code is its only attribute.
  "sky-handoff-failed.ftl": {
    skyHandoffReason?: string;
  };
};

export type KcContext = ExtendKcContext<KcContextExtension, KcContextExtensionPerPage>;
