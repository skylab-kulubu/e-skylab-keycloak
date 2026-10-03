export type CustomTranslations = Record<string, Record<string, string>>;
export const LOGIN_SRC_DIR: string;
export function findI18nFile(loginSrcDir: string): string;
export function readCustomTranslations(i18nFile: string): CustomTranslations;
