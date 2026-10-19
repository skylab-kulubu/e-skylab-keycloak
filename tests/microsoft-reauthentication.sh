#!/usr/bin/env bash
# Real-Keycloak contract for the SPI's Microsoft identity provider (com.skylab.broker,
# SkyMicrosoftIdentityProviderFactory): Keycloak's re-authentication goes on to Microsoft as
# prompt=login. Stand-alone: starts the stock Keycloak image this repository builds on (the
# Dockerfile's KEYCLOAK_IMAGE) in dev mode with docker run --rm and no volume, with this
# repository's SPI jar in /opt/keycloak/providers.
#
# The SPI jar: MICROSOFT_REAUTH_SPI_JAR names one already built (mvn -f spi/pom.xml package);
# without it the jar is built from spi/ in the Dockerfile's Maven image (tests skipped: the image
# build runs them).
#
# The identity provider OBS is of Keycloak's type microsoft with a tenant, as production's is. The
# test never goes to Microsoft: it reads only the redirect Keycloak sends (the Location header of
# the YTÜ button, /broker/OBS/login, or of the identity provider redirector with kc_idp_hint=OBS),
# the same read-only look production's redirect was checked with. The SSO session comes from a
# password login in the same browser. Logins are driven with curl through Keycloak's own pages.
#
# What it proves, with SKY_FORWARD_REAUTHENTICATION unset (the default):
#   - the type microsoft is the SPI's (the factory replaces Keycloak's own under the same ID): an
#     identity provider made through the admin API keeps providerId microsoft and its tenant;
#   - a browser without a Keycloak session: no prompt on the YTÜ button, and none through
#     kc_idp_hint=OBS, also when the client sends max_age (an ordinary first login is unchanged);
#   - with a live session and no max_age the client gets a code without any page (SSO unchanged);
#   - with a live session and max_age exceeded: Keycloak shows its login page (OBS is the linked
#     provider it offers), and both the YTÜ button and kc_idp_hint=OBS send exactly one
#     prompt=login to Microsoft;
#   - the client's own prompt=login is forwarded once (Keycloak's own behaviour, as Account
#     Center's Sudo fallback uses it);
# and with SKY_FORWARD_REAUTHENTICATION=false (the rollback), after max_age no prompt again.
# Requirements on the host: docker, jq, curl. MICROSOFT_REAUTH_TEST_PORT (default 18099),
# MICROSOFT_REAUTH_TEST_CONTAINER (default microsoft-reauth-test-<pid>), MICROSOFT_REAUTH_TEST_MEMORY
# (default 1536m).
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=kcadm-jvm.sh
source "$SCRIPT_DIR/kcadm-jvm.sh"
REPOSITORY_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
IMAGE=$(sed -n 's/^ARG KEYCLOAK_IMAGE=//p' "$REPOSITORY_ROOT/Dockerfile")
MAVEN_IMAGE=$(sed -n 's/^FROM \(maven:[^ ]*\) AS providers$/\1/p' "$REPOSITORY_ROOT/Dockerfile")
PORT=${MICROSOFT_REAUTH_TEST_PORT:-18099}
BASE_URL="http://127.0.0.1:$PORT"
CONTAINER=${MICROSOFT_REAUTH_TEST_CONTAINER:-microsoft-reauth-test-$$}
MEMORY=${MICROSOFT_REAUTH_TEST_MEMORY:-1536m}
STATE_DIR=$(mktemp -d)
ADMIN_PASSWORD=harness-admin-password
LOCAL_PASSWORD=harness-local-password
ADMIN_CONFIG=/tmp/harness-admin-kcadm.config
REALM=e-skylab
APP=microsoft-reauth-app
APP_REDIRECT=http://127.0.0.1:9/microsoft-reauth-callback
TENANT=00000000-0000-4000-8000-000000000001
MICROSOFT_AUTHORIZE="https://login.microsoftonline.com/$TENANT/oauth2/v2.0/authorize"
CURRENT_STAGE=startup
STATUS=''
LOCATION=''
BODY=''
LANDED=''

fail() {
  printf 'microsoft-reauthentication failure during %s: %s\n' "$CURRENT_STAGE" "$1" >&2
  exit 1
}
cleanup() {
  docker rm -fv "$CONTAINER" >/dev/null 2>&1 || true
  rm -rf "$STATE_DIR"
}
trap 'status=$?; trap - EXIT; cleanup; exit "$status"' EXIT
on_error() {
  local status=$?
  printf 'microsoft-reauthentication command failed during %s (line %s)\n' "$CURRENT_STAGE" "$1" >&2
  exit "$status"
}
trap 'on_error "$LINENO"' ERR

kcadm() {
  local command=$1
  shift
  docker exec -i "$CONTAINER" /opt/keycloak/bin/kcadm.sh "$command" --config "$ADMIN_CONFIG" "$@" \
    2> >(grep -v -e '^Created new ' -e '^$' >&2 || true)
}

# request JAR URL [curl arguments...]: one request; sets STATUS, LOCATION and BODY.
request() {
  local jar=$1 url=$2
  shift 2
  STATUS=$(curl --silent --show-error --output "$STATE_DIR/body" --dump-header "$STATE_DIR/headers" \
    --write-out '%{http_code}' --cookie "$jar" --cookie-jar "$jar" "$@" "$url")
  LOCATION=$(awk 'tolower($1) == "location:" { print $2 }' "$STATE_DIR/headers" | tr -d '\r' | tail -n 1)
  BODY=$(cat "$STATE_DIR/body")
}

# follow JAR URL [curl arguments...]: the request, then every redirect inside Keycloak by hand
# until a page (LANDED=page), the application (LANDED=app) or Microsoft (LANDED=microsoft, with
# LOCATION the authorization request; it is never sent).
follow() {
  local jar=$1 url=$2 hops=0
  shift 2
  request "$jar" "$url" "$@"
  while [[ $STATUS == 30[1237] ]]; do
    if [[ $LOCATION == "$APP_REDIRECT"* ]]; then
      [[ $LOCATION == *'code='* ]] || fail "the application was sent back without a code: ${LOCATION%%\?*}?…"
      LANDED=app
      return 0
    fi
    if [[ $LOCATION == https://login.microsoftonline.com/* ]]; then
      LANDED=microsoft
      return 0
    fi
    [[ $LOCATION == http* ]] || LOCATION="$BASE_URL$LOCATION"
    request "$jar" "$LOCATION"
    hops=$((hops + 1))
    ((hops < 25)) || fail 'too many redirects'
  done
  [[ $STATUS == 200 ]] || { printf '%s\n' "$BODY" | head -c 2000 >&2; fail "unexpected HTTP $STATUS"; }
  LANDED=page
}

# The action of the page's form whose id is $1 (Keycloak's own templates).
form_action() {
  local action
  action=$(tr '\n' ' ' <<<"$BODY" | grep -Eo "<form[^>]*id=\"$1\"[^>]*>" | grep -Eo 'action="[^"]*"' | head -n 1 \
    | sed -e 's/^action="//' -e 's/"$//' -e 's/&amp;/\&/g')
  [[ -n $action ]] || { printf '%s\n' "$BODY" | head -c 3000 >&2; fail "the page has no form #$1"; }
  printf '%s\n' "$action"
}

# The YTÜ button of the login page: its link to /broker/OBS/login.
ytu_button() {
  local link
  link=$( (grep -Eo 'href="[^"]*/broker/OBS/login[^"]*"' <<<"$BODY" || true) | head -n 1 \
    | sed -e 's/^href="//' -e 's/"$//' -e 's/&amp;/\&/g')
  [[ -n $link ]] || { printf '%s\n' "$BODY" | head -c 3000 >&2; fail 'the login page has no YTÜ button'; }
  [[ $link == http* ]] || link="$BASE_URL$link"
  printf '%s\n' "$link"
}

auth_url() { # auth_url [extra query]
  printf '%s/realms/%s/protocol/openid-connect/auth?client_id=%s&response_type=code&scope=openid&redirect_uri=%s&state=s%s%s\n' \
    "$BASE_URL" "$REALM" "$APP" "$(jq -rn --arg u "$APP_REDIRECT" '$u | @uri')" "$RANDOM" "${1:-}"
}

# prompts: the prompt values of the authorization request Keycloak sent to Microsoft, one per line.
prompts() {
  [[ $LOCATION == "$MICROSOFT_AUTHORIZE?"* ]] \
    || fail "the request does not go to the tenant's authorization endpoint: ${LOCATION%%\?*}"
  tr '&' '\n' <<<"${LOCATION#*\?}" | sed -n 's/^prompt=//p'
}

# expect_prompt LABEL WANTED: Keycloak is sending the browser to Microsoft with exactly WANTED as
# its prompt values ("" for none, "login" for one prompt=login).
expect_prompt() {
  local got
  [[ $LANDED == microsoft ]] || fail "$1: Keycloak did not send the browser to Microsoft (landed=$LANDED, HTTP $STATUS)"
  got=$(prompts | paste -sd, -)
  [[ $got == "$2" ]] || fail "$1: prompt sent to Microsoft is '${got}', wanted '$2'"
  printf '    %s: prompt=%s\n' "$1" "${2:-(none)}"
}

# ytu_button_prompt LABEL JAR AUTH_QUERY WANTED: the client's request, Keycloak's login page, the
# YTÜ button; then the same request through kc_idp_hint=OBS.
ytu_button_prompt() {
  local label=$1 jar=$2 query=$3 wanted=$4
  follow "$jar" "$(auth_url "$query")"
  [[ $LANDED == page ]] || fail "$label: no login page (landed=$LANDED)"
  follow "$jar" "$(ytu_button)"
  expect_prompt "$label, YTÜ button" "$wanted"
  follow "$jar" "$(auth_url "$query&kc_idp_hint=OBS")"
  expect_prompt "$label, kc_idp_hint=OBS" "$wanted"
}

# start_keycloak [ENV=VALUE ...]: a fresh dev-mode Keycloak with the SPI jar and the fixture realm:
# a person with a password, a public client, and OBS of type microsoft.
start_keycloak() {
  local environment=() assignment
  for assignment in "$@"; do
    environment+=(-e "$assignment")
  done
  docker rm -fv "$CONTAINER" >/dev/null 2>&1 || true
  docker run --rm -d --name "$CONTAINER" --memory "$MEMORY" -p "127.0.0.1:$PORT:8080" \
    -e KC_OPTS="$KCADM_JVM_OPTS" \
    -e KC_BOOTSTRAP_ADMIN_USERNAME=admin -e KC_BOOTSTRAP_ADMIN_PASSWORD="$ADMIN_PASSWORD" \
    ${environment[@]+"${environment[@]}"} \
    -v "$SPI_JAR:/opt/keycloak/providers/e-skylab-spi.jar:ro" \
    "$IMAGE" start-dev >/dev/null
  for _ in $(seq 1 120); do
    curl -fsS "$BASE_URL/realms/master" >/dev/null 2>&1 && break
    sleep 2
  done
  curl -fsS "$BASE_URL/realms/master" >/dev/null || { docker logs "$CONTAINER" 2>&1 | tail -n 40 >&2; fail "Keycloak did not start ($IMAGE)"; }
  docker exec "$CONTAINER" /opt/keycloak/bin/kcadm.sh config credentials --config "$ADMIN_CONFIG" \
    --server http://localhost:8080 --realm master --user admin --password "$ADMIN_PASSWORD" >/dev/null 2>&1 \
    || fail 'kcadm login failed'

  kcadm create realms -s "realm=$REALM" -s enabled=true >/dev/null
  kcadm create clients -r "$REALM" -s "clientId=$APP" -s publicClient=true -s standardFlowEnabled=true \
    -s directAccessGrantsEnabled=false -s "redirectUris=[\"$APP_REDIRECT\"]" >/dev/null
  local id
  id=$(kcadm create users -r "$REALM" -i -s username=yerel -s enabled=true -s firstName=Yerel -s lastName=Kişi \
    -s email=yerel@example.test -s emailVerified=true)
  kcadm set-password -r "$REALM" --userid "$id" --new-password "$LOCAL_PASSWORD" --temporary=false >/dev/null
  kcadm create identity-provider/instances -r "$REALM" -s alias=OBS -s providerId=microsoft -s enabled=true \
    -s config.clientId=ytu-app -s config.clientSecret=harness-not-a-secret -s "config.tenantId=$TENANT" >/dev/null
  # Linked to OBS, as every YTÜ account is: on re-authentication Keycloak's login page shows only
  # the identity providers the known person is linked to.
  kcadm create "users/$id/federated-identity/OBS" -r "$REALM" -s identityProvider=OBS \
    -s userId=ytu-object-id -s userName=yerel@std.yildiz.edu.tr >/dev/null
  kcadm get identity-provider/instances/OBS -r "$REALM" \
    | jq -e --arg tenant "$TENANT" '.providerId == "microsoft" and .config.tenantId == $tenant' >/dev/null \
    || fail 'OBS is not a microsoft identity provider with the tenant'
}

# signed_in_browser LABEL: a fresh browser signed in with the password; sets JAR.
signed_in_browser() {
  JAR="$STATE_DIR/$1.cookies"
  rm -f "$JAR"
  follow "$JAR" "$(auth_url)"
  [[ $LANDED == page ]] || fail "$1: no login page"
  follow "$JAR" "$(form_action kc-form-login)" --data-urlencode username=yerel \
    --data-urlencode "password=$LOCAL_PASSWORD" --data-urlencode credentialId=
  [[ $LANDED == app ]] || fail "$1: the password login did not reach the application (landed=$LANDED)"
}

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='SPI jar'
[[ -n $IMAGE ]] || fail 'Dockerfile has no ARG KEYCLOAK_IMAGE'
command -v jq >/dev/null || fail 'jq is required'
SPI_JAR=${MICROSOFT_REAUTH_SPI_JAR:-}
if [[ -z $SPI_JAR ]]; then
  [[ -n $MAVEN_IMAGE ]] || fail 'Dockerfile has no Maven providers stage'
  mkdir -p "$STATE_DIR/spi"
  docker run --rm -v "$REPOSITORY_ROOT/spi:/src:ro" -v "$STATE_DIR/spi:/out" "$MAVEN_IMAGE" \
    sh -ec 'cp -R /src /build && cd /build && mvn --batch-mode --no-transfer-progress -q -DskipTests package && cp target/e-skylab-spi-*.jar /out/' >&2
  SPI_JAR=$(find "$STATE_DIR/spi" -name 'e-skylab-spi-*.jar' | head -n 1)
fi
[[ -f $SPI_JAR ]] || fail "no SPI jar at ${SPI_JAR:-(unset)}"
SPI_JAR=$(cd -- "$(dirname -- "$SPI_JAR")" && pwd)/$(basename -- "$SPI_JAR")
spi_listing=$(unzip -l "$SPI_JAR")
grep -q 'com/skylab/broker/SkyMicrosoftIdentityProviderFactory.class' <<<"$spi_listing" \
  || fail 'the SPI jar does not hold the Microsoft identity provider'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='Keycloak start (default)'
start_keycloak
printf '    stock Keycloak in dev mode with the SPI jar (%s)\n' "$(basename -- "$SPI_JAR")"

CURRENT_STAGE='no Keycloak session'
fresh="$STATE_DIR/fresh.cookies"
ytu_button_prompt 'first login' "$fresh" '' ''
rm -f "$fresh"
ytu_button_prompt 'first login with max_age' "$fresh" '&max_age=1' ''

CURRENT_STAGE='live session'
signed_in_browser session
follow "$JAR" "$(auth_url)"
[[ $LANDED == app ]] || fail 'a live session without max_age did not reach the application without a page'
printf '    live session, no max_age: code without a page\n'
follow "$JAR" "$(auth_url '&kc_idp_hint=OBS')"
[[ $LANDED == app ]] || fail 'a live session with kc_idp_hint=OBS went to Microsoft'
printf '    live session, kc_idp_hint=OBS: code without a page\n'

CURRENT_STAGE='max_age exceeded'
sleep 2
ytu_button_prompt 'max_age exceeded' "$JAR" '&max_age=1' 'login'

CURRENT_STAGE="the client's prompt=login"
ytu_button_prompt 'client prompt=login' "$JAR" '&prompt=login' 'login'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='Keycloak start (SKY_FORWARD_REAUTHENTICATION=false)'
start_keycloak SKY_FORWARD_REAUTHENTICATION=false
signed_in_browser rollback
sleep 2
CURRENT_STAGE='rollback: max_age exceeded'
ytu_button_prompt 'switched off, max_age exceeded' "$JAR" '&max_age=1' ''
ytu_button_prompt 'switched off, client prompt=login' "$JAR" '&prompt=login' 'login'

printf 'microsoft-reauthentication: ok\n'
