/* eslint-disable @typescript-eslint/no-empty-object-type */
import type { ExtendKcContext } from "keycloakify/login";
import type { KcEnvName, ThemeName } from "../kc.gen";

export type KcContextExtension = {
  themeName: ThemeName;
  properties: Record<KcEnvName, string> & {};
};

export type KcContextExtensionPerPage = {
  "passkey-offer.ftl": {};
  // Rendered by the SPI's sky-handoff provider (GET v1/failed); the reason code is its only attribute.
  "sky-handoff-failed.ftl": {
    skyHandoffReason?: string;
  };
};

export type KcContext = ExtendKcContext<KcContextExtension, KcContextExtensionPerPage>;
