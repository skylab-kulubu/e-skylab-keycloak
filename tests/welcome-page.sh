#!/usr/bin/env bash
# Real-Keycloak contract for the e-skylab-welcome theme, the landing page at https://e.yildizskylab.com/.
# Stand-alone: starts the stock Keycloak image this repository builds on (the Dockerfile's
# KEYCLOAK_IMAGE, tag and digest) in dev mode with docker run --rm, the built theme
# (theme/dist_welcome/e-skylab-welcome, `npm run build-welcome-theme`) mounted read-only at
# /opt/keycloak/themes/e-skylab-welcome, and the welcome theme selected by the same environment
# variable the Dockerfile sets (KC_SPI_THEME__WELCOME_THEME, read from the Dockerfile). An admin
# exists from the first second (KC_BOOTSTRAP_ADMIN_*), as in production, where Keycloak's own
# welcome theme answers / with a 302 to /admin/. The container is removed on exit (docker rm -fv).
#
# What it proves:
#   - GET / answers 200 text/html, not cacheable, with the landing page itself: its title, heading,
#     the ADR-0063 trust sentence, the Account Center and KVKK links; GET /index.html and a path
#     without the trailing slash are not a second copy;
#   - the page as Keycloak serves it has no script, form, frame or inline handler, no Admin
#     Console link, no FreeMarker leftovers, and links only to the allowed addresses;
#   - every resource it references (stylesheet, three fonts, icon) answers 200 with its type under
#     /resources/<version>/welcome/e-skylab-welcome/, and the stylesheet's fonts resolve there;
#   - Keycloak's own paths are what they were: a realm's OpenID configuration and login page,
#     /admin/ (still Keycloak's redirect to its console; restricting it is a separate edge task)
#     and the master realm; POST / (the admin creation form's target) creates no admin.
# Requirements on the host: docker, curl, grep. WELCOME_PAGE_TEST_PORT (default 18096),
# WELCOME_PAGE_TEST_CONTAINER (default welcome-page-test-<pid>), WELCOME_THEME_DIR (default
# theme/dist_welcome/e-skylab-welcome).
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPOSITORY_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
IMAGE=$(sed -n 's/^ARG KEYCLOAK_IMAGE=//p' "$REPOSITORY_ROOT/Dockerfile")
WELCOME_ENV=$(sed -n 's/^ENV KC_SPI_THEME__WELCOME_THEME=//p' "$REPOSITORY_ROOT/Dockerfile")
THEME_DIR=${WELCOME_THEME_DIR:-$REPOSITORY_ROOT/theme/dist_welcome/e-skylab-welcome}
PORT=${WELCOME_PAGE_TEST_PORT:-18096}
BASE_URL="http://127.0.0.1:$PORT"
CONTAINER=${WELCOME_PAGE_TEST_CONTAINER:-welcome-page-test-$$}
ADMIN_PASSWORD=harness-admin-password
WORK=$(mktemp -d "${TMPDIR:-/tmp}/welcome-page.XXXXXX")
CURRENT_STAGE=startup

fail() {
  printf 'welcome-page failure during %s: %s\n' "$CURRENT_STAGE" "$1" >&2
  exit 1
}
cleanup() {
  docker rm -fv "$CONTAINER" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap 'status=$?; trap - EXIT; cleanup; exit "$status"' EXIT
on_error() {
  local status=$?
  printf 'welcome-page command failed during %s (line %s)\n' "$CURRENT_STAGE" "$1" >&2
  exit "$status"
}
trap 'on_error "$LINENO"' ERR

# fetch PATH NAME [CURL ARGS...]: the response headers to WORK/NAME.headers and the body to
# WORK/NAME.body, without following redirects; prints the status.
fetch() {
  local path=$1 name=$2
  shift 2
  curl -sS -o "$WORK/$name.body" -D "$WORK/$name.headers" -w '%{http_code}' "$@" "$BASE_URL$path"
}

header() {
  grep -i "^$2:" "$WORK/$1.headers" | head -n 1 | cut -d: -f2- | tr -d '\r' | sed 's/^ *//'
}

expect_in_page() {
  grep -Fq -- "$1" "$WORK/root.body" || fail "the page lost: $1"
}

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='Keycloak start'
[[ -n $IMAGE ]] || fail 'Dockerfile has no ARG KEYCLOAK_IMAGE'
[[ $WELCOME_ENV == e-skylab-welcome ]] \
  || fail "the Dockerfile must select the welcome theme with ENV KC_SPI_THEME__WELCOME_THEME=e-skylab-welcome (found '$WELCOME_ENV')"
[[ -f $THEME_DIR/welcome/index.ftl ]] || fail "no built theme at $THEME_DIR (cd theme && npm run build-welcome-theme)"
bash "$SCRIPT_DIR/check-welcome-theme.sh" >/dev/null
docker run --rm -d --name "$CONTAINER" -p "127.0.0.1:$PORT:8080" \
  -e KC_BOOTSTRAP_ADMIN_USERNAME=admin -e KC_BOOTSTRAP_ADMIN_PASSWORD="$ADMIN_PASSWORD" \
  -e KC_SPI_THEME__WELCOME_THEME="$WELCOME_ENV" \
  -v "$THEME_DIR:/opt/keycloak/themes/e-skylab-welcome:ro" \
  "$IMAGE" start-dev >/dev/null
for _ in $(seq 1 90); do
  curl -fsS "$BASE_URL/realms/master" >/dev/null 2>&1 && break
  sleep 2
done
curl -fsS "$BASE_URL/realms/master" >/dev/null || fail "Keycloak did not start ($IMAGE)"

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='the landing page at /'
status=$(fetch / root)
[[ $status == 200 ]] || fail "GET / answered $status (Location: $(header root location))"
[[ $(header root content-type) == text/html* ]] || fail "GET / is $(header root content-type), not HTML"
grep -Eiq 'no-cache|no-store' <<<"$(header root cache-control)" || fail 'GET / may be cached'
expect_in_page '<html lang="tr" class="sl-html">'
expect_in_page "<title>e-SKY LAB · SKY LAB'in giriş hizmeti</title>"
expect_in_page '<h1 id="sl-welcome-title">Tek hesap, <span>bütün SKY LAB.</span></h1>'
expect_in_page 'Okul şifreni yalnız Microsoft&#x27;un sayfasına yazarsın; SKY LAB onu hiçbir zaman görmez.'
expect_in_page 'href="https://my.yildizskylab.com/"'
expect_in_page 'href="https://yildizskylab.com/kvkk-metni.pdf"'
expect_in_page 'data-skylab-logo-animation="draw"'
printf '    / answers 200 with the landing page (no redirect to /admin/); X-Frame-Options: %s; CSP: %s\n' \
  "$(header root x-frame-options)" "$(header root content-security-policy)"

CURRENT_STAGE='the page as served'
if grep -Eiq '<script|<form|<iframe|<object|<embed|<input|<button|[[:space:]]on[a-z]+=' "$WORK/root.body"; then
  fail 'the served page is not static'
fi
if grep -Eq '([^/]|^)/admin([/"?#]|$)|realms/master|skyl\.app|<#|\$\{|#noparse' "$WORK/root.body"; then
  fail 'the served page links to the Admin Console or carries FreeMarker leftovers'
fi
while IFS= read -r link; do
  case $link in
    'href="https://my.yildizskylab.com/"' | 'href="https://forms.yildizskylab.com/"' | \
      'href="https://admin.yildizskylab.com/"' | 'href="https://mail.yildizskylab.com/"' | \
      'href="https://place.yildizskylab.com/"' | 'href="https://yildizskylab.com/"' | \
      'href="https://yildizskylab.com/kvkk-metni.pdf"' | 'href="#'*'"') ;;
    'href="resources/'*'/welcome/e-skylab-welcome/'*'"') ;;
    *) fail "the served page links outside the allowlist: $link" ;;
  esac
done < <(grep -o 'href="[^"]*"' "$WORK/root.body" | LC_ALL=C sort -u)
printf '    the served page is static and links only to the allowed addresses\n'

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='resources'
stylesheet=$(grep -o 'href="resources/[^"]*/welcome\.css"' "$WORK/root.body" | sed 's/^href="//; s/"$//')
icon=$(grep -o 'href="resources/[^"]*/skylab-logo\.png"' "$WORK/root.body" | sed 's/^href="//; s/"$//')
[[ $stylesheet == resources/*/welcome/e-skylab-welcome/welcome.css ]] || fail "unexpected stylesheet path: $stylesheet"
[[ $icon == resources/*/welcome/e-skylab-welcome/skylab-logo.png ]] || fail "unexpected icon path: $icon"
[[ $(fetch "/$stylesheet" css) == 200 ]] || fail "the stylesheet $stylesheet did not load"
[[ $(header css content-type) == text/css* ]] || fail "the stylesheet is $(header css content-type)"
grep -Fq '.sl-welcome-hero' "$WORK/css.body" || fail 'the served stylesheet is not the welcome stylesheet'
[[ $(fetch "/$icon" icon) == 200 ]] || fail "the icon $icon did not load"
[[ $(header icon content-type) == image/png* ]] || fail "the icon is $(header icon content-type)"
fonts=0
while IFS= read -r font; do
  [[ $(fetch "/${stylesheet%/welcome.css}/${font#./}" font) == 200 ]] || fail "the font $font did not load"
  [[ $(header font content-type) == font/woff2* || $(header font content-type) == application/octet-stream* ]] \
    || fail "the font $font is $(header font content-type)"
  fonts=$((fonts + 1))
done < <(grep -o 'url(\./[^)]*\.woff2)' "$WORK/css.body" | sed 's/^url(//; s/)$//' | LC_ALL=C sort -u)
[[ $fonts == 3 ]] || fail "the stylesheet references $fonts fonts, not 3"
printf '    stylesheet, icon and %s fonts load from /%s\n' "$fonts" "${stylesheet%/welcome.css}"

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='Keycloak paths unchanged'
[[ $(fetch /index.html index) == 404 ]] || fail '/index.html is a second copy of the page'
[[ $(fetch /realms/master/.well-known/openid-configuration discovery) == 200 ]] || fail 'the OpenID configuration moved'
grep -Fq "\"issuer\":\"$BASE_URL/realms/master\"" "$WORK/discovery.body" || fail 'the OpenID configuration changed'
[[ $(fetch /admin/ admin) == 302 && $(header admin location) == */admin/master/console/ ]] \
  || fail '/admin/ is no longer Keycloak'\''s own redirect to its console'
[[ $(fetch /admin/master/console/ console) == 200 ]] || fail 'the Admin Console page changed'
[[ $(fetch '/realms/master/protocol/openid-connect/auth?client_id=security-admin-console&redirect_uri=http%3A%2F%2F127.0.0.1%3A'"$PORT"'%2Fadmin%2Fmaster%2Fconsole%2F&response_type=code&scope=openid&code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&code_challenge_method=S256' login) == 200 ]] \
  || fail 'the login page of a realm changed'
# The bundled welcome page's form posts here; with an admin present Keycloak refuses, and the
# landing page has no form, so nothing is created.
post_status=$(fetch / post -X POST --data 'username=intruder&password=x&passwordConfirmation=x&stateChecker=x')
token=$(curl -fsS -d grant_type=password -d client_id=admin-cli -d username=admin --data-urlencode "password=$ADMIN_PASSWORD" \
  "$BASE_URL/realms/master/protocol/openid-connect/token" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
[[ -n $token ]] || fail 'the bootstrap admin cannot sign in'
users=$(curl -fsS -H "Authorization: Bearer $token" "$BASE_URL/admin/realms/master/users?username=intruder&exact=true")
[[ $users == '[]' ]] || fail 'POST / created an admin'
printf '    realm discovery and login, /admin/ and its console unchanged; POST / (status %s) created no admin\n' "$post_status"

printf 'welcome-page: all checks passed.\n'
