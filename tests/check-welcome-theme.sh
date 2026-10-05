#!/usr/bin/env bash
# Contract of the built e-skylab-welcome theme (theme/dist_welcome, `npm run build-welcome-theme`):
# the landing page Keycloak serves at / instead of its welcome page, which redirects to the Admin
# Console once an admin exists. Run after the build; tests/welcome-page.sh then serves the same
# files from a real Keycloak.
# The FreeMarker expressions below (${resourcesPath}) are text to find, not shell expansions:
# shellcheck disable=SC2016
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
KEYCLOAK_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
WELCOME_DIR=${WELCOME_THEME_DIR:-$KEYCLOAK_DIR/theme/dist_welcome/e-skylab-welcome}

fail() {
  printf 'welcome theme contract failure: %s\n' "$1" >&2
  exit 1
}

[[ -d $WELCOME_DIR ]] || fail "no built theme at $WELCOME_DIR (npm run build-welcome-theme)"
TEMPLATE="$WELCOME_DIR/welcome/index.ftl"
PROPERTIES="$WELCOME_DIR/welcome/theme.properties"
RESOURCES="$WELCOME_DIR/welcome/resources"
STYLESHEET="$RESOURCES/welcome.css"

# Only the welcome type, only these files: no script, no second page, nothing else Keycloak would serve.
actual_files=$(cd "$WELCOME_DIR" && find . -type f | LC_ALL=C sort)
expected_files=$(LC_ALL=C sort <<'EOF'
./welcome/index.ftl
./welcome/resources/skylab-logo.png
./welcome/resources/space-grotesk-latin-ext-wght-normal.woff2
./welcome/resources/space-grotesk-latin-wght-normal.woff2
./welcome/resources/space-grotesk-vietnamese-wght-normal.woff2
./welcome/resources/welcome.css
./welcome/theme.properties
EOF
)
[[ $actual_files == "$expected_files" ]] \
  || fail "unexpected theme files:"$'\n'"$(diff <(printf '%s\n' "$expected_files") <(printf '%s\n' "$actual_files") || true)"

# Keycloak redirects / to the Admin Console when the theme says so; this one must not.
grep -qx 'redirectToAdmin=false' "$PROPERTIES" || fail 'theme.properties must set redirectToAdmin=false'
if grep -Ev '^(#|$|redirectToAdmin=false$)' "$PROPERTIES" | grep -q .; then
  fail 'theme.properties carries more than redirectToAdmin=false'
fi

# A static page: the only FreeMarker it uses is the resource path; the body is copied verbatim.
head -n 1 "$TEMPLATE" | grep -Eq '^<#-- .* -->$' || fail 'index.ftl lost its generated-file comment'
interpolations=$(grep -o '\${[^}]*}' "$TEMPLATE" | LC_ALL=C sort -u)
[[ $interpolations == '${resourcesPath}' ]] || fail "index.ftl uses Keycloak values other than resourcesPath: $interpolations"
[[ $(grep -c '^<#noparse>$' "$TEMPLATE") == 1 && $(grep -c '^</#noparse>$' "$TEMPLATE") == 1 ]] \
  || fail 'index.ftl must wrap the body in exactly one <#noparse> block'
if grep -Eq 'adminUrl|localAdminUrl|stateChecker|bootstrap|<#if|<#list|<#include|<#import|<@' "$TEMPLATE"; then
  fail 'index.ftl reaches for the Admin Console link, the admin creation form or other FreeMarker'
fi
if grep -Eiq '<script|<form|<iframe|<object|<embed|<input|<button|[[:space:]]on[a-z]+=' "$TEMPLATE"; then
  fail 'index.ftl must stay static: no script, form, frame or inline handler'
fi
if grep -Eq '([^/]|^)/admin([/"?#]|$)|realms/master|skyl\.app' "$TEMPLATE"; then
  fail 'index.ftl links to the Admin Console, the master realm or a short link'
fi
grep -Fq '<html lang="tr" class="sl-html">' "$TEMPLATE" || fail 'index.ftl lost its Turkish root element'
grep -Fq '<link rel="stylesheet" href="${resourcesPath}/welcome.css">' "$TEMPLATE" || fail 'index.ftl does not load welcome.css'
grep -Fq '<link rel="icon" type="image/png" href="${resourcesPath}/skylab-logo.png">' "$TEMPLATE" || fail 'index.ftl lost its icon'
grep -Fq 'data-skylab-logo-animation="draw"' "$TEMPLATE" || fail 'index.ftl lost the animated SKY LAB logo'
grep -Fq "Okul şifreni yalnız Microsoft&#x27;un sayfasına yazarsın; SKY LAB onu hiçbir zaman görmez." "$TEMPLATE" \
  || fail 'index.ftl lost the trust sentence of ADR-0063'
links=$(grep -o 'href="[^"]*"' "$TEMPLATE" | grep -v 'resourcesPath' | LC_ALL=C sort -u)
while IFS= read -r link; do
  case $link in
    'href="https://my.yildizskylab.com/"' | 'href="https://forms.yildizskylab.com/"' | \
      'href="https://admin.yildizskylab.com/"' | 'href="https://mail.yildizskylab.com/"' | \
      'href="https://place.yildizskylab.com/"' | 'href="https://yildizskylab.com/"' | \
      'href="https://yildizskylab.com/kvkk-metni.pdf"' | 'href="#'*'"') ;;
    *) fail "index.ftl links to an address outside the allowlist: $link" ;;
  esac
done <<<"$links"

# One design system: the stylesheet is the login theme's tokens, typeface and chrome plus the
# landing layout, with no request outside the theme's own resources.
for token in '--skylab-500:' 'Space Grotesk Variable' '--sl-legacy-accent:' '.sl-legacy-shell' '.sl-legacy-logo__svg path' \
  'sl-legacy-logo-draw' '.sl-welcome-hero' 'prefers-reduced-motion' 'forced-colors'; do
  grep -Fq -- "$token" "$STYLESHEET" || fail "welcome.css lost $token"
done
references=$(grep -o 'url([^)]*)' "$STYLESHEET" | grep -v '^url(\"\{0,1\}data:' | LC_ALL=C sort -u)
expected_references=$(LC_ALL=C sort <<'EOF'
url(./space-grotesk-latin-ext-wght-normal.woff2)
url(./space-grotesk-latin-wght-normal.woff2)
url(./space-grotesk-vietnamese-wght-normal.woff2)
EOF
)
[[ $references == "$expected_references" ]] || fail "welcome.css points outside its fonts: $references"
# The inline SVG icons name their XML namespace (http://www.w3.org/2000/svg); nothing else is a URL.
if grep -q '@import' "$STYLESHEET" || grep -oE 'https?://[^ )"'"'"'%]*' "$STYLESHEET" | grep -vqx 'http://www.w3.org/2000/svg'; then
  fail 'welcome.css must be one bundled file with no remote request'
fi

# The source keeps one token set: the welcome stylesheet imports the login one and adds no :root.
WELCOME_SOURCE="$KEYCLOAK_DIR/theme/src/welcome/welcome.css"
grep -Fq '@import "../login/legacy-login.css";' "$WELCOME_SOURCE" || fail 'welcome.css must import the login stylesheet'
if grep -q ':root' "$WELCOME_SOURCE"; then
  fail 'welcome.css must not define a token set of its own'
fi

printf 'Welcome theme (landing page at /) contract passed.\n'
