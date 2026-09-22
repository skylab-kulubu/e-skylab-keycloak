#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
KEYCLOAK_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
THEME_DIR="$KEYCLOAK_DIR/theme"
THEME_JAR=${THEME_JAR:-$THEME_DIR/dist_keycloak/e-skylab-theme-2.0.1.jar}
THEME_JAR_DIR=$(cd -- "$(dirname -- "$THEME_JAR")" && pwd)
THEME_JAR="$THEME_JAR_DIR/$(basename -- "$THEME_JAR")"

fail() {
  printf 'theme contract failure: %s\n' "$1" >&2
  exit 1
}

[[ $(jq -r '.dependencies.keycloakify' "$THEME_DIR/package.json") == 11.16.0 ]] \
  || fail 'Keycloakify must stay pinned to 11.16.0 or a separately reviewed newer release'
[[ $(jq -r '.packages["node_modules/keycloakify"].version' "$THEME_DIR/package-lock.json") == 11.16.0 ]] \
  || fail 'package-lock does not resolve the reviewed Keycloakify release'

theme_jar_count=$(find "$THEME_JAR_DIR" -maxdepth 1 -type f -name '*.jar' -print | wc -l | tr -d ' ')
[[ $theme_jar_count == 1 ]] || fail 'theme build did not produce exactly one JAR'
actual_theme_jar=$(find "$THEME_JAR_DIR" -maxdepth 1 -type f -name '*.jar' -print)
[[ $actual_theme_jar == "$THEME_JAR" ]] || fail 'theme JAR has an unexpected name'

theme_entries=$(unzip -Z1 "$THEME_JAR")
[[ $(grep -c '^META-INF/keycloak-themes.json$' <<<"$theme_entries") == 1 ]] \
  || fail 'theme registry metadata is missing or duplicated'
[[ $(grep -c '^theme/e-skylab-theme/login/theme.properties$' <<<"$theme_entries") == 1 ]] \
  || fail 'the e-skylab-theme login theme is missing or duplicated'
[[ $(grep -c '^theme/e-skylab-theme/login/passkey-offer.ftl$' <<<"$theme_entries") == 1 ]] \
  || fail 'the branded passkey offer page is missing or duplicated'
[[ $(grep -c '^theme/e-skylab-theme/login/sky-handoff-failed.ftl$' <<<"$theme_entries") == 1 ]] \
  || fail 'the Web handoff failure page (sky-handoff v1/failed) is missing or duplicated'

theme_metadata=$(unzip -p "$THEME_JAR" META-INF/keycloak-themes.json)
jq -e '.themes == [{"name":"e-skylab-theme","types":["login"]}]' <<<"$theme_metadata" >/dev/null \
  || fail 'theme metadata exposes an unexpected name or theme type'

bundle_text=$(unzip -p "$THEME_JAR" 'theme/e-skylab-theme/login/resources/dist/assets/*.js')
bundle_css=$(unzip -p "$THEME_JAR" 'theme/e-skylab-theme/login/resources/dist/assets/*.css')
for required_token in \
  residentKey \
  requireResidentKey \
  authenticatorAttachment \
  authenticationExecution \
  isSetRetry \
  rememberMe \
  '30 gün boyunca tekrar sorma' \
  'Uygulamaya dönüp tekrar dene.' \
  skyHandoffReason \
  data-skylab-logo-animation \
  mediation; do
  grep -Fq "$required_token" <<<"$bundle_text" \
    || fail "generated theme bundle lost $required_token"
done

grep -Fq 'sl-legacy-logo-draw' <<<"$bundle_css" \
  || fail 'generated theme bundle lost the SKY LAB logo drawing animation'

if grep -Fq '\${execution}' <<<"$bundle_text"; then
  fail 'WebAuthn retry still contains the historical literal execution defect'
fi

# One design system: the login stylesheet is the only stylesheet and the only token set.
[[ ! -e "$THEME_DIR/src/login/theme.css" ]] \
  || fail 'theme.css must stay deleted; every page uses legacy-login.css'
[[ $(find "$THEME_DIR/src" -type f -name '*.css' | wc -l | tr -d ' ') == 1 ]] \
  || fail 'the theme must ship exactly one stylesheet'
[[ $(grep -c '^:root {' "$THEME_DIR/src/login/legacy-login.css") == 1 ]] \
  || fail 'legacy-login.css must define exactly one :root token set'
grep -Fq '@media (prefers-reduced-motion: reduce)' "$THEME_DIR/src/login/legacy-login.css" \
  || fail 'reduced-motion behavior is missing'
grep -Fq '.sl-legacy-choice' "$THEME_DIR/src/login/legacy-login.css" \
  || fail 'secondary button contrast contract is missing'
grep -Fq 'import "./legacy-login.css"' "$THEME_DIR/src/login/KcPage.tsx" \
  || fail 'the page router must import the single stylesheet'
grep -Fq 'mainId="sl-main-content"' "$THEME_DIR/src/login/Template.tsx" \
  || fail 'semantic main landmark is missing'
grep -Fq '<LegacyFrame' "$THEME_DIR/src/login/Template.tsx" \
  || fail 'Template must render the LegacyFrame chrome'
[[ $(find "$THEME_DIR/tests/browser/visual.spec.ts-snapshots" -maxdepth 1 -type f -name '*-desktop.png' | wc -l | tr -d ' ') -ge 25 ]] \
  || fail 'desktop screenshot baselines are missing'
[[ $(find "$THEME_DIR/tests/browser/visual.spec.ts-snapshots" -maxdepth 1 -type f -name '*-mobile.png' | wc -l | tr -d ' ') -ge 25 ]] \
  || fail 'mobile screenshot baselines are missing'

printf 'Keycloak theme source, artifact and WebAuthn contracts passed.\n'
