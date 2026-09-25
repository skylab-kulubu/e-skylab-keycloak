#!/usr/bin/env bash
# Real-Keycloak contract for the Web handoff (/realms/{realm}/sky-handoff/v1, ADR-0048).
# Invoked by run-integration.sh once the reconciled realm,
# the account-center client and the fixture user exist. Inputs: SKY_HANDOFF_COMPOSE_FILE,
# SKY_HANDOFF_ADMIN_CONFIG, SKY_HANDOFF_CLIENT_SECRET (account-center), TEST_STATE_DIR.
# Leaves account-center enabled as a Handoff target and removes the users it creates.
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
COMPOSE_FILE=${SKY_HANDOFF_COMPOSE_FILE:?set SKY_HANDOFF_COMPOSE_FILE}
ADMIN_CONFIG=${SKY_HANDOFF_ADMIN_CONFIG:?set SKY_HANDOFF_ADMIN_CONFIG}
CLIENT_SECRET=${SKY_HANDOFF_CLIENT_SECRET:?set SKY_HANDOFF_CLIENT_SECRET}
STATE_DIR=${TEST_STATE_DIR:?set TEST_STATE_DIR}
BASE_URL=${SKY_HANDOFF_BASE_URL:-http://localhost:18080}
REALM=${SKY_HANDOFF_REALM:-e-skylab-test}
API="$BASE_URL/realms/$REALM/sky-handoff/v1"
TOKEN_URL="$BASE_URL/realms/$REALM/protocol/openid-connect/token"
CALLBACK=https://my.yildizskylab.com/api/auth/callback
APP_CALLBACK=com.yildizskylab.skyapp:/oauth/callback
ACCOUNT_CENTER_ENTRY='https://my.yildizskylab.com/api/auth/login?returnTo='
FIXTURE_USER_UUID=11111111-1111-4111-8111-111111111111
FIXTURE_USERNAME=account-fixture
FIXTURE_PASSWORD=fixture-password-change-me
OTHER_USERNAME=handoff-other
# The admin endpoints' fixture (tests/fixture-realm.json): a member of /ADMIN, an empty subgroup
# of /ADMIN and superadmin's client admin (public, direct grants; fixture only).
ADMIN_FIXTURE_UUID=44444444-4444-4444-8444-444444444444
ADMIN_USERNAME=handoff-admin-fixture
ADMIN_PASSWORD=handoff-admin-password-change-me
ADMIN_CLIENT=admin
ADMIN_SUBGROUP=handoff-admin-subgroup-fixture
PATH_MARKER=/web-handoff-path-marker-7f3a9c
COMPOSE=(docker compose -f "$COMPOSE_FILE")
SECRETS_FILE="$STATE_DIR/sky-handoff-secrets"
: >"$SECRETS_FILE"
chmod 0600 "$SECRETS_FILE"
CURRENT_STAGE='web handoff fixture'

# The Keycloak log tail for a failure, with every 43-character value (codes, proofs) redacted.
keycloak_log_tail() {
  "${COMPOSE[@]}" logs --no-color --tail=60 keycloak 2>&1 \
    | sed -E 's/[A-Za-z0-9_-]{43}/[REDACTED-43]/g' >&2 || true
}

fail() {
  printf 'web handoff contract failure during %s: %s\n' "$CURRENT_STAGE" "$1" >&2
  keycloak_log_tail
  exit 1
}
trap 'status=$?; printf "web handoff command failed during %s (line %s)\n" "$CURRENT_STAGE" "$LINENO" >&2; keycloak_log_tail; exit "$status"' ERR

kcadm() {
  local command=$1
  shift
  "${COMPOSE[@]}" exec -T keycloak /opt/keycloak/bin/kcadm.sh "$command" --config "$ADMIN_CONFIG" "$@"
}

json_assert() {
  local json=$1 expression=$2 message=$3
  shift 3
  jq -e "$@" "$expression" <<<"$json" >/dev/null || fail "$message"
}

jwt_payload() {
  local segment
  segment=$(cut -d. -f2 <<<"$1")
  case $((${#segment} % 4)) in
    2) segment="${segment}==" ;;
    3) segment="${segment}=" ;;
  esac
  tr '_-' '/+' <<<"$segment" | base64 --decode
}

header_value() {
  awk -v name="$2" '
    tolower($1) == tolower(name) ":" {
      sub(/^[^:]*:[[:space:]]*/, "")
      sub(/\r$/, "")
      print
      exit
    }
  ' "$1"
}

client_uuid() {
  kcadm get clients -r "$REALM" -q "clientId=$1" -c | jq -r --arg id "$1" '.[] | select(.clientId == $id) | .id'
}

# skyapp_tokens <username> <password> [scope] -> the token response of a SkyApp direct grant
skyapp_tokens() {
  curl --fail --silent --show-error \
    --data-urlencode grant_type=password \
    --data-urlencode client_id=skyapp \
    --data-urlencode "username=$1" \
    --data-urlencode "password=$2" \
    --data-urlencode "scope=${3:-openid}" \
    "$TOKEN_URL"
}

# admin_tokens <username> <password> [scope] -> the token response of a direct grant of the
# fixture's superadmin client
admin_tokens() {
  curl --fail --silent --show-error \
    --data-urlencode grant_type=password \
    --data-urlencode "client_id=$ADMIN_CLIENT" \
    --data-urlencode "username=$1" \
    --data-urlencode "password=$2" \
    --data-urlencode "scope=${3:-openid}" \
    "$TOKEN_URL"
}

# skyapp_login <label> -> APP_TOKENS: SkyApp's real sign-in, an authorization code flow with PKCE
# and offline_access on Keycloak's login page, so the offline session carries Keycloak's own
# AUTH_TIME note (a direct grant writes none).
skyapp_login() {
  local label=$1 verifier challenge jar headers page literal action status location code
  verifier="web-handoff-app-$label-verifier-0123456789abcdefghijklmnopqrstuvwxyz"
  challenge=$(printf '%s' "$verifier" | openssl dgst -binary -sha256 | openssl base64 -A | tr '+/' '-_' | tr -d '=')
  jar="$STATE_DIR/web-handoff-app-$label.cookies"
  headers="$STATE_DIR/web-handoff-app-$label.headers"
  rm -f "$jar"
  page=$(curl --fail --silent --show-error --location --get \
    --cookie-jar "$jar" --cookie "$jar" \
    --data-urlencode client_id=skyapp \
    --data-urlencode response_type=code \
    --data-urlencode 'scope=openid offline_access' \
    --data-urlencode "redirect_uri=$APP_CALLBACK" \
    --data-urlencode "code_challenge=$challenge" \
    --data-urlencode code_challenge_method=S256 \
    --data-urlencode "state=app-$label" \
    "$BASE_URL/realms/$REALM/protocol/openid-connect/auth")
  literal=$(grep -Eo '"loginAction"[[:space:]]*:[[:space:]]*"[^"]*"' <<<"$page" | head -n 1 \
    | sed -E 's/^"loginAction"[[:space:]]*:[[:space:]]*//' || true)
  [[ -n $literal ]] || fail "SkyApp login $label: the login page exposed no login action"
  action=$(jq -r . <<<"$literal")
  status=$(curl --silent --show-error --output /dev/null --dump-header "$headers" --write-out '%{http_code}' \
    --cookie-jar "$jar" --cookie "$jar" \
    --data-urlencode "username=$FIXTURE_USERNAME" \
    --data-urlencode "password=$FIXTURE_PASSWORD" \
    --data-urlencode credentialId= \
    "$action")
  [[ $status == 302 ]] || fail "SkyApp login $label: the credential submission answered HTTP $status"
  location=$(header_value "$headers" location)
  [[ $location == "$APP_CALLBACK"\?* ]] || fail "SkyApp login $label did not return to the app"
  code=$(sed -n 's/.*[?&]code=\([^&]*\).*/\1/p' <<<"$location")
  [[ -n $code ]] || fail "SkyApp login $label returned no authorization code"
  APP_TOKENS=$(curl --silent --show-error \
    --data-urlencode grant_type=authorization_code \
    --data-urlencode client_id=skyapp \
    --data-urlencode "code=$code" \
    --data-urlencode "redirect_uri=$APP_CALLBACK" \
    --data-urlencode "code_verifier=$verifier" \
    "$TOKEN_URL")
  jq -e '.access_token and .refresh_token' <<<"$APP_TOKENS" >/dev/null 2>&1 \
    || fail "SkyApp login $label: the code exchange failed ($(jq -r '"\(.error // "-"): \(.error_description // "-")"' <<<"$APP_TOKENS" 2>/dev/null || true))"
}

# app_refresh: a fresh access token of the fixture's SkyApp login, refreshed the way the app does
# (access tokens live five minutes, this contract runs longer).
app_refresh() {
  curl --fail --silent --show-error \
    --data-urlencode grant_type=refresh_token \
    --data-urlencode client_id=skyapp \
    --data-urlencode "refresh_token=$(jq -r .refresh_token <<<"$APP_TOKENS")" \
    "$TOKEN_URL" | jq -r .access_token
}

# mint <bearer|-> <json body> -> MINT_STATUS, MINT_BODY, MINT_HEADERS; remembers issued secrets
mint() {
  local bearer=$1 body=$2
  local args=(--silent --show-error --request POST
    --output "$STATE_DIR/sky-handoff-mint.body"
    --dump-header "$STATE_DIR/sky-handoff-mint.headers"
    --write-out '%{http_code}'
    --header 'Content-Type: application/json'
    --data-binary "$body")
  [[ $bearer != - ]] && args+=(--header "Authorization: Bearer $bearer")
  MINT_STATUS=$(curl "${args[@]}" "$API/handoffs")
  MINT_BODY=$(cat "$STATE_DIR/sky-handoff-mint.body")
  MINT_HEADERS="$STATE_DIR/sky-handoff-mint.headers"
  if [[ $MINT_STATUS == 201 ]]; then
    jq -r '.proof, (.handoffUrl | sub("^.*[?&]code="; ""))' <<<"$MINT_BODY" >>"$SECRETS_FILE"
  fi
}

# mint_ok <bearer> <target> <path> -> HANDOFF_URL, HANDOFF_PROOF
mint_ok() {
  mint "$1" "$(jq -cn --arg target "$2" --arg path "$3" '{target: $target, path: $path}')"
  [[ $MINT_STATUS == 201 ]] \
    || fail "minting a $2 handoff failed (HTTP $MINT_STATUS code=$(jq -r '.code // "-"' <<<"$MINT_BODY" 2>/dev/null || true))"
  HANDOFF_URL=$(jq -r .handoffUrl <<<"$MINT_BODY")
  HANDOFF_PROOF=$(jq -r .proof <<<"$MINT_BODY")
}

# expect_problem <status> <code> <message>: RFC 7807 shape, never echoes the body
expect_problem() {
  local status=$1 code=$2 message=$3 actual
  actual=$(jq -r '.code // "-"' <<<"$MINT_BODY" 2>/dev/null || printf -- '-')
  [[ $MINT_STATUS == "$status" && $actual == "$code" ]] \
    || fail "$message (expected HTTP $status $code, got $MINT_STATUS $actual)"
  grep -Eiq '^content-type:[[:space:]]*application/problem\+json' "$MINT_HEADERS" \
    || fail "$message (problems must be application/problem+json)"
  json_assert "$MINT_BODY" \
    '(.type == ("tag:yildizskylab.com,2026:sky-handoff:" + .code)) and (.detail | length) > 0 and .status == ($status | tonumber)' \
    "$message (RFC 7807 shape)" --arg status "$status"
}

# open_handoff <url> <proof|-> <cookie jar> -> OPEN_STATUS, OPEN_LOCATION, OPEN_HEADERS
open_handoff() {
  local url=$1 proof=$2 jar=$3
  local args=(--silent --show-error
    --output /dev/null
    --dump-header "$STATE_DIR/sky-handoff-open.headers"
    --write-out '%{http_code}'
    --cookie-jar "$jar" --cookie "$jar")
  [[ $proof != - ]] && args+=(--header "X-Sky-Handoff-Proof: $proof")
  OPEN_STATUS=$(curl "${args[@]}" "$url")
  OPEN_HEADERS="$STATE_DIR/sky-handoff-open.headers"
  OPEN_LOCATION=$(header_value "$OPEN_HEADERS" location)
  [[ $OPEN_STATUS == 303 ]] || fail "opening a handoff answered HTTP $OPEN_STATUS instead of 303"
  [[ $(header_value "$OPEN_HEADERS" cache-control) == no-store ]] || fail 'the open redirect must not be cached'
  [[ $(header_value "$OPEN_HEADERS" referrer-policy) == no-referrer ]] || fail 'the open redirect must send no referrer'
}

# expect_failure <reason> <message>: the open landed on the failure page of that reason
expect_failure() {
  local reason=$1 message=$2
  [[ $OPEN_LOCATION == "$API/failed?reason=$reason" ]] \
    || fail "$message (landed on ${OPEN_LOCATION%%\?*} instead of the $reason failure page)"
  expect_failure_page "$OPEN_LOCATION" "$reason" "$message"
}

# expect_failure_page <url> <reason> <message>: HTTP 200, the SKY LAB login theme's failure page
# (Keycloakify renders it from the page context, so the context must name the reason), no form,
# and the page's own headers: never cached, framed or referred, only its own inline script.
expect_failure_page() {
  local url=$1 reason=$2 message=$3 page headers status policy script_src
  page="$STATE_DIR/sky-handoff-failed.html"
  headers="$STATE_DIR/sky-handoff-failed.headers"
  status=$(curl --silent --show-error --output "$page" --dump-header "$headers" --write-out '%{http_code}' "$url")
  [[ $status == 200 ]] || fail "$message (the $reason page answered HTTP $status)"
  if grep -Eqi '<form' "$page"; then
    fail "$message (the failure page must not offer a form)"
  fi
  grep -Fq 'kcContext.pageId = "sky-handoff-failed.ftl";' "$page" \
    || fail "$message (the failure page was not rendered by the SKY LAB login theme)"
  [[ $(grep -Ec '"skyHandoffReason"[[:space:]]*:' "$page" || true) == 1 ]] \
    && grep -Eq "\"skyHandoffReason\"[[:space:]]*:[[:space:]]*\"$reason\"" "$page" \
    || fail "$message (the failure page shows another reason than $reason)"
  [[ $(header_value "$headers" cache-control) == no-store ]] \
    || fail "$message (the failure page must not be cached)"
  [[ $(header_value "$headers" x-frame-options) == DENY ]] \
    || fail "$message (the failure page must not be framed)"
  [[ $(header_value "$headers" referrer-policy) == no-referrer ]] \
    || fail "$message (the failure page must send no referrer)"
  policy=$(header_value "$headers" content-security-policy)
  [[ $policy == *"frame-ancestors 'none'"* && $policy == *"form-action 'none'"* && $policy == *"default-src 'none'"* ]] \
    || fail "$message (the failure page policy lost its framing, form or default restriction: $policy)"
  script_src=$(tr ';' '\n' <<<"$policy" | sed -n 's/^[[:space:]]*script-src //p')
  [[ $script_src == "'self' 'sha256-"* && $script_src != *unsafe* ]] \
    || fail "$message (the failure page must allow only its own inline script, by hash: $script_src)"
}

# start_login <label> -> LOGIN_URL, LOGIN_VERIFIER: a pushed account-center authorization request
start_login() {
  local label=$1 challenge par
  LOGIN_VERIFIER="web-handoff-$label-verifier-0123456789abcdefghijklmnopqrstuvwxyz"
  challenge=$(printf '%s' "$LOGIN_VERIFIER" | openssl dgst -binary -sha256 | openssl base64 -A | tr '+/' '-_' | tr -d '=')
  par=$(curl --fail --silent --show-error \
    --user "account-center:$CLIENT_SECRET" \
    --data-urlencode client_id=account-center \
    --data-urlencode response_type=code \
    --data-urlencode scope=openid \
    --data-urlencode "redirect_uri=$CALLBACK" \
    --data-urlencode "code_challenge=$challenge" \
    --data-urlencode code_challenge_method=S256 \
    --data-urlencode "state=web-handoff-$label" \
    --data-urlencode "nonce=web-handoff-$label-nonce" \
    "$BASE_URL/realms/$REALM/protocol/openid-connect/ext/par/request")
  LOGIN_URL="$BASE_URL/realms/$REALM/protocol/openid-connect/auth?client_id=account-center&request_uri=$(jq -r '.request_uri | @uri' <<<"$par")"
}

# finish_login <label> <callback location> -> ID_PAYLOAD, ACCESS_PAYLOAD
finish_login() {
  local label=$1 location=$2 code tokens
  [[ $location == "$CALLBACK"\?* ]] || fail "login $label never reached the callback"
  [[ $location == *"state=web-handoff-$label"* ]] || fail "login $label lost its state"
  code=$(sed -n 's/.*[?&]code=\([^&]*\).*/\1/p' <<<"$location")
  [[ -n $code ]] || fail "login $label returned no authorization code"
  tokens=$(curl --fail --silent --show-error \
    --user "account-center:$CLIENT_SECRET" \
    --data-urlencode grant_type=authorization_code \
    --data-urlencode client_id=account-center \
    --data-urlencode "code=$code" \
    --data-urlencode "redirect_uri=$CALLBACK" \
    --data-urlencode "code_verifier=$LOGIN_VERIFIER" \
    "$TOKEN_URL")
  ID_PAYLOAD=$(jwt_payload "$(jq -r .id_token <<<"$tokens")")
  ACCESS_PAYLOAD=$(jwt_payload "$(jq -r .access_token <<<"$tokens")")
}

# password_login <label> <remember me: on|off> -> ID_PAYLOAD, ACCESS_PAYLOAD: an ordinary
# account-center login of the fixture person on Keycloak's own login page, in a fresh browser.
password_login() {
  local label=$1 remember=$2 jar page literal action status headers
  local form=(--data-urlencode "username=$FIXTURE_USERNAME" --data-urlencode "password=$FIXTURE_PASSWORD"
    --data-urlencode credentialId=)
  [[ $remember == on ]] && form+=(--data-urlencode rememberMe=on)
  jar="$STATE_DIR/web-handoff-$label.cookies"
  headers="$STATE_DIR/web-handoff-$label.headers"
  rm -f "$jar"
  start_login "$label"
  page=$(curl --fail --silent --show-error --location --cookie-jar "$jar" --cookie "$jar" "$LOGIN_URL")
  literal=$(grep -Eo '"loginAction"[[:space:]]*:[[:space:]]*"[^"]*"' <<<"$page" | head -n 1 \
    | sed -E 's/^"loginAction"[[:space:]]*:[[:space:]]*//' || true)
  [[ -n $literal ]] || fail "login $label: the login page exposed no login action"
  action=$(jq -r . <<<"$literal")
  status=$(curl --silent --show-error --output /dev/null --dump-header "$headers" --write-out '%{http_code}' \
    --cookie-jar "$jar" --cookie "$jar" "${form[@]}" "$action")
  [[ $status == 302 ]] || fail "login $label: the credential submission answered HTTP $status"
  finish_login "$label" "$(header_value "$headers" location)"
}

# silent_login <cookie jar> <label> -> ID_PAYLOAD, ACCESS_PAYLOAD: account-center's own OIDC login
# from the browser session alone. Any login page on the way is a failure.
silent_login() {
  local jar=$1 label=$2 url attempt status location headers
  start_login "$label"
  url=$LOGIN_URL
  headers="$STATE_DIR/web-handoff-$label.headers"
  location=''
  for attempt in $(seq 1 8); do
    status=$(curl --silent --show-error --output "$STATE_DIR/web-handoff-$label.body" \
      --dump-header "$headers" --write-out '%{http_code}' \
      --cookie-jar "$jar" --cookie "$jar" "$url")
    location=$(header_value "$headers" location)
    if [[ $location == "$CALLBACK"\?* ]]; then
      break
    fi
    if [[ $status =~ ^30[1237]$ && $location == "$BASE_URL"/* ]]; then
      url=$location
      continue
    fi
    fail "silent login $label stopped at HTTP $status instead of the account-center callback (a login page?)"
  done
  finish_login "$label" "$location"
}

# realm_max_lifespan <remember me: on|off>: the SSO session max Keycloak applies (its own defaults)
realm_max_lifespan() {
  local realm
  realm=$(kcadm get "realms/$REALM" -c)
  jq -r --arg remember "$1" '
    (if .ssoSessionMaxLifespan > 0 then .ssoSessionMaxLifespan else 36000 end) as $max
    | if $remember == "on" then ([$max, (.ssoSessionMaxLifespanRememberMe // 0)] | max) else $max end' <<<"$realm"
}

# expect_session_lifetime <payload> <remember me: on|off> <message>: sky_session_started is the
# session start and sky_session_expires the instant Keycloak's SSO max ends it.
expect_session_lifetime() {
  json_assert "$1" \
    '(.sky_session_started | type) == "number" and .sky_session_expires == .sky_session_started + ($max | tonumber)' \
    "$3" --arg max "$(realm_max_lifespan "$2")"
}

set_target_attribute() {
  kcadm update "clients/$1" -r "$REALM" -s "attributes.\"$2\"=$3" >/dev/null
}

session_ids() {
  kcadm get "users/$1/sessions" -r "$REALM" -c | jq -c '[.[].id] | sort'
}

# admin_call <GET|PUT> <path under v1/admin> <bearer|-> [json body] -> ADMIN_STATUS, ADMIN_BODY, ADMIN_HEADERS
admin_call() {
  local method=$1 path=$2 bearer=$3 body=${4:-}
  local args=(--silent --show-error --request "$method"
    --output "$STATE_DIR/sky-handoff-admin.body"
    --dump-header "$STATE_DIR/sky-handoff-admin.headers"
    --write-out '%{http_code}')
  [[ $bearer != - ]] && args+=(--header "Authorization: Bearer $bearer")
  if [[ -n $body ]]; then
    args+=(--header 'Content-Type: application/json' --data-binary "$body")
  fi
  ADMIN_STATUS=$(curl "${args[@]}" "$API/admin/$path")
  ADMIN_BODY=$(cat "$STATE_DIR/sky-handoff-admin.body")
  ADMIN_HEADERS="$STATE_DIR/sky-handoff-admin.headers"
}

# expect_admin_problem <status> <code> <message>
expect_admin_problem() {
  local actual
  actual=$(jq -r '.code // "-"' <<<"$ADMIN_BODY" 2>/dev/null || printf -- '-')
  [[ $ADMIN_STATUS == "$1" && $actual == "$2" ]] || fail "$3 (expected HTTP $1 $2, got $ADMIN_STATUS $actual)"
  grep -Eiq '^content-type:[[:space:]]*application/problem\+json' "$ADMIN_HEADERS" \
    || fail "$3 (problems must be application/problem+json)"
  json_assert "$ADMIN_BODY" '(.detail | length) > 0' "$3 (a Turkish detail is required)"
}

# client_without_handoff <client uuid>: the client representation minus the three handoff attributes.
# Keycloak lists the client's scope names from a hash map, so their order can change once the
# cached client is reloaded (skyforms carries skyforms-forms-audience next to basic); compare
# them as sets.
client_without_handoff() {
  kcadm get "clients/$1" -r "$REALM" -c \
    | jq -S -c 'del(.attributes["sky.handoff.enabled"], .attributes["sky.handoff.signInPath"], .attributes["sky.handoff.returnParam"])
      | (.defaultClientScopes, .optionalClientScopes) |= (if type == "array" then sort else . end)'
}

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='web handoff target fixture'
account_center_uuid=$(client_uuid account-center)
[[ -n $account_center_uuid ]] || fail 'account-center client is missing'
# What superadmin will do in production: account-center becomes a Handoff target.
set_target_attribute "$account_center_uuid" sky.handoff.enabled true
set_target_attribute "$account_center_uuid" sky.handoff.signInPath /api/auth/login
set_target_attribute "$account_center_uuid" sky.handoff.returnParam returnTo
json_assert "$(kcadm get "clients/$account_center_uuid" -r "$REALM" -c)" \
  '.rootUrl == "https://my.yildizskylab.com" and .attributes["sky.handoff.enabled"] == "true" and .attributes["sky.handoff.signInPath"] == "/api/auth/login" and .attributes["sky.handoff.returnParam"] == "returnTo"' \
  'account-center did not become a Handoff target'

while IFS= read -r stale_user; do
  [[ -n $stale_user ]] || continue
  kcadm delete "users/$stale_user" -r "$REALM" >/dev/null
done < <(kcadm get users -r "$REALM" -c -q "username=$OTHER_USERNAME" -q exact=true | jq -r '.[].id')
# Imported users do not receive the realm default roles; SkyApp's offline_access login needs
# the offline_access role every real account holds through them. Removed again at cleanup.
kcadm add-roles -r "$REALM" --uid "$FIXTURE_USER_UUID" --rolename offline_access >/dev/null

other_password=$(openssl rand -base64 24 | tr -d '\n')
other_uuid=$(kcadm create users -r "$REALM" -i \
  -s "username=$OTHER_USERNAME" -s enabled=true -s emailVerified=true \
  -s firstName=Handoff -s lastName=Other -s email=handoff-other@example.invalid)
kcadm set-password -r "$REALM" --userid "$other_uuid" --new-password "$other_password" --temporary=false >/dev/null

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='web handoff mint contract'
skyapp_login fixture
app_token=$(jq -r .access_token <<<"$APP_TOKENS")
app_payload=$(jwt_payload "$app_token")
[[ $(jq -r .typ <<<"$(jwt_payload "$(jq -r .refresh_token <<<"$APP_TOKENS")")") == Offline ]] \
  || fail 'the SkyApp login did not produce an offline session'
app_auth_time=$(jq -r '.auth_time // empty' <<<"$app_payload")
[[ $app_auth_time =~ ^[0-9]+$ ]] || fail 'the SkyApp token carries no auth_time'

mint "$app_token" '{"target":"account-center","path":"/"}'
[[ $MINT_STATUS == 201 ]] || fail "a SkyApp token could not mint an account-center handoff (HTTP $MINT_STATUS)"
grep -Eiq '^content-type:[[:space:]]*application/json' "$MINT_HEADERS" || fail 'the mint response is not JSON'
[[ $(header_value "$MINT_HEADERS" cache-control) == no-store ]] || fail 'the mint response must not be cached'
json_assert "$MINT_BODY" \
  '(.handoffUrl | test("^" + $api + "/open\\?code=[A-Za-z0-9_-]{43}$")) and (.proof | test("^[A-Za-z0-9_-]{43}$")) and .expiresIn == 45 and (keys | sort) == ["expiresIn", "handoffUrl", "proof"]' \
  'the mint response differs from {handoffUrl, proof, expiresIn: 45}' --arg api "$API"

mint - '{"target":"account-center","path":"/"}'
expect_problem 401 invalid_token 'a request without a bearer token must be refused'
[[ $(header_value "$MINT_HEADERS" www-authenticate) == *'error="invalid_token"'* ]] \
  || fail 'a 401 must carry WWW-Authenticate with invalid_token'
mint not-a-token '{"target":"account-center","path":"/"}'
expect_problem 401 invalid_token 'a malformed bearer token must be refused'
foreign_token=$(curl --fail --silent --show-error \
  --data-urlencode grant_type=password \
  --data-urlencode client_id=admin-cli \
  --data-urlencode "username=$FIXTURE_USERNAME" \
  --data-urlencode "password=$FIXTURE_PASSWORD" \
  "$TOKEN_URL" | jq -r .access_token)
mint "$foreign_token" '{"target":"account-center","path":"/"}'
expect_problem 401 invalid_token 'a live token of another client must not mint'
mint "$app_token" '{"target":"no-such-client","path":"/"}'
expect_problem 400 invalid_target 'an unknown target must be refused'
mint "$app_token" '{"target":"skyapp","path":"/"}'
expect_problem 400 invalid_target 'a client that is not a Handoff target must be refused'
mint "$app_token" '{"target":"account-center","path":"//evil.example/"}'
expect_problem 400 invalid_path 'a protocol-relative path must be refused'
mint "$app_token" '{"target":"account-center","path":"https://evil.example/"}'
expect_problem 400 invalid_path 'an absolute URL must be refused as a path'
mint "$app_token" '{"target":"account-center","path":"/a/../b"}'
expect_problem 400 invalid_path 'a dot-dot path must be refused'
mint "$app_token" '{"target":"account-center","path":"/","url":"https://evil.example/"}'
expect_problem 400 invalid_request 'fields outside the contract must be refused'

# The expiry case is minted now and opened after the reconciliation below, which takes longer
# than the 45-second lifetime.
mint_ok "$app_token" account-center /
expiring_url=$HANDOFF_URL
expiring_proof=$HANDOFF_PROOF
expiring_minted_at=$(date +%s)

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='web handoff target attributes survive reconciliation'
# A drift makes the reconciler rewrite the account-center client; the Handoff target
# attributes are not part of its desired state and must survive that write.
kcadm update "clients/$account_center_uuid" -r "$REALM" -s consentRequired=true >/dev/null
"${COMPOSE[@]}" run --rm --no-deps keycloak-config >"$STATE_DIR/reconcile-web-handoff.log" 2>&1 \
  || { tail -n 40 "$STATE_DIR/reconcile-web-handoff.log" >&2; fail 'reconciliation failed'; }
grep -Fq 'client account-center: updated' "$STATE_DIR/reconcile-web-handoff.log" \
  || fail 'the injected drift did not make the reconciler rewrite account-center'
json_assert "$(kcadm get "clients/$account_center_uuid" -r "$REALM" -c)" \
  '.consentRequired == false and .attributes["sky.handoff.enabled"] == "true" and .attributes["sky.handoff.signInPath"] == "/api/auth/login" and .attributes["sky.handoff.returnParam"] == "returnTo"' \
  'reconciliation dropped the Handoff target attributes'

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='web handoff open and silent login'
app_token=$(app_refresh)
mint_ok "$app_token" account-center /
first_url=$HANDOFF_URL
first_proof=$HANDOFF_PROOF
jar="$STATE_DIR/web-handoff-webview.cookies"
rm -f "$jar"
open_handoff "$first_url" - "$jar"
expect_failure invalid 'a link opened without its proof must be invalid'
open_handoff "$first_url" "$expiring_proof" "$jar"
expect_failure invalid 'a link opened with another code'"'"'s proof must be invalid'
if grep -Eq '[[:space:]]KEYCLOAK_IDENTITY[[:space:]]' "$jar" 2>/dev/null; then
  fail 'a refused open created a Keycloak session'
fi

open_handoff "$first_url" "$first_proof" "$jar"
[[ $OPEN_LOCATION == "${ACCOUNT_CENTER_ENTRY}%2F" ]] \
  || fail 'the open did not land on the account-center sign-in entry (a refused open must not have burned the code)'
grep -Eq '[[:space:]]KEYCLOAK_IDENTITY[[:space:]]' "$jar" || fail 'the open did not write the Keycloak identity cookie'
opened_at=$(date +%s)

silent_login "$jar" first
json_assert "$ID_PAYLOAD" '.sub == $sub and .auth_time == ($auth_time | tonumber)' \
  'the account-center ID token lost the person or the original SkyApp auth_time' \
  --arg sub "$FIXTURE_USER_UUID" --arg auth_time "$app_auth_time"
[[ $app_auth_time -lt $((opened_at - 5)) ]] || fail 'the fixture cannot tell the original auth_time from a fresh login'
handoff_sid=$(jq -r .sid <<<"$ID_PAYLOAD")
[[ $handoff_sid != "$(jq -r .sid <<<"$app_payload")" ]] || fail 'the browser session must be a new session, not the SkyApp one'

open_handoff "$first_url" "$first_proof" "$STATE_DIR/web-handoff-replay.cookies"
expect_failure used 'a code must not open twice'
open_handoff "$API/open?code=$(printf 'A%.0s' $(seq 1 43))" "$first_proof" "$STATE_DIR/web-handoff-unknown.cookies"
expect_failure invalid 'an unknown code must be invalid'
open_handoff "$API/open" - "$STATE_DIR/web-handoff-unknown.cookies"
expect_failure invalid 'an open without a code must be invalid'

CURRENT_STAGE='web handoff claims sky_embed and session lifetime'
for payload in "$ID_PAYLOAD" "$ACCESS_PAYLOAD"; do
  json_assert "$payload" '.sky_embed == "skyapp"' 'a handoff session must carry sky_embed=skyapp in ID and access tokens'
  json_assert "$payload" \
    '.sky_session_started >= ($opened | tonumber) - 5 and .sky_session_started <= ($opened | tonumber) + 1' \
    'sky_session_started must be the moment of the open, not the SkyApp login' --arg opened "$opened_at"
  json_assert "$payload" '.auth_time == ($auth_time | tonumber)' \
    'auth_time must stay the original SkyApp authentication time' --arg auth_time "$app_auth_time"
  expect_session_lifetime "$payload" off 'a handoff session must expire with the SSO session max'
done

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='web handoff expiry'
elapsed=$(( $(date +%s) - expiring_minted_at ))
if [[ $elapsed -lt 47 ]]; then
  sleep $((47 - elapsed))
fi
open_handoff "$expiring_url" "$expiring_proof" "$STATE_DIR/web-handoff-expired.cookies"
expect_failure expired 'a code must not open after 45 seconds'

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='web handoff refusals at open'
app_token=$(app_refresh)
mint_ok "$app_token" account-center "$PATH_MARKER"
set_target_attribute "$account_center_uuid" sky.handoff.enabled false
open_handoff "$HANDOFF_URL" "$HANDOFF_PROOF" "$STATE_DIR/web-handoff-disabled-target.cookies"
set_target_attribute "$account_center_uuid" sky.handoff.enabled true
expect_failure target_disabled 'a target switched off after the mint must be refused at open'

other_tokens=$(skyapp_tokens "$OTHER_USERNAME" "$other_password")
other_token=$(jq -r .access_token <<<"$other_tokens")
mint_ok "$other_token" account-center /
kcadm update "users/$other_uuid" -r "$REALM" -s enabled=false >/dev/null
open_handoff "$HANDOFF_URL" "$HANDOFF_PROOF" "$STATE_DIR/web-handoff-disabled-user.cookies"
kcadm update "users/$other_uuid" -r "$REALM" -s enabled=true >/dev/null
expect_failure account_unavailable 'a person disabled after the mint must be refused at open'

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='web handoff offline SkyApp session'
offline_tokens=$(skyapp_tokens "$OTHER_USERNAME" "$other_password" 'openid offline_access')
offline_token=$(jq -r .access_token <<<"$offline_tokens")
[[ $(jq -r .typ <<<"$(jwt_payload "$(jq -r .refresh_token <<<"$offline_tokens")")") == Offline ]] \
  || fail 'the fixture did not produce an offline SkyApp session'
mint_ok "$offline_token" account-center /
pending_url=$HANDOFF_URL
pending_proof=$HANDOFF_PROOF
curl --fail --silent --show-error \
  --data-urlencode client_id=skyapp \
  --data-urlencode "token=$(jq -r .refresh_token <<<"$offline_tokens")" \
  --data-urlencode token_type_hint=refresh_token \
  "$BASE_URL/realms/$REALM/protocol/openid-connect/revoke" >/dev/null
mint "$offline_token" '{"target":"account-center","path":"/"}'
expect_problem 401 invalid_token 'a revoked offline SkyApp session must not mint'
open_handoff "$pending_url" "$pending_proof" "$STATE_DIR/web-handoff-revoked.cookies"
expect_failure invalid 'a code of a SkyApp session that signed out must not open'

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='web handoff replaces another person in the WebView'
shared_jar="$STATE_DIR/web-handoff-shared.cookies"
rm -f "$shared_jar"
other_tokens=$(skyapp_tokens "$OTHER_USERNAME" "$other_password")
other_token=$(jq -r .access_token <<<"$other_tokens")
other_sessions_before=$(session_ids "$other_uuid")
mint_ok "$other_token" account-center /
open_handoff "$HANDOFF_URL" "$HANDOFF_PROOF" "$shared_jar"
[[ $OPEN_LOCATION == "${ACCOUNT_CENTER_ENTRY}%2F" ]] || fail 'the other person could not open a handoff'
other_sessions_with_webview=$(session_ids "$other_uuid")
[[ $(jq length <<<"$other_sessions_with_webview") == $(( $(jq length <<<"$other_sessions_before") + 1 )) ]] \
  || fail 'the other person did not get a browser session'

app_token=$(app_refresh)
mint_ok "$app_token" account-center /
open_handoff "$HANDOFF_URL" "$HANDOFF_PROOF" "$shared_jar"
[[ $OPEN_LOCATION == "${ACCOUNT_CENTER_ENTRY}%2F" ]] || fail 'the handoff into a WebView of another person failed'
[[ $(session_ids "$other_uuid") == "$other_sessions_before" ]] \
  || fail "the other person's browser session survived in the WebView"
silent_login "$shared_jar" replaced
json_assert "$ID_PAYLOAD" '.sub == $sub' 'the WebView is still signed in as the other person' --arg sub "$FIXTURE_USER_UUID"
json_assert "$(kcadm get events -r "$REALM" -c -q "user=$other_uuid" -q type=LOGOUT -q max=20)" \
  '[.[] | select(.details.action == "sky-handoff" and .details.reason == "replaced_by_another_user")] | length >= 1' \
  "the other person's replaced session left no LOGOUT event"

# The same person again in the same WebView: the older browser session is replaced, not kept
# beside the new one, and SkyApp's own session is left alone.
replaced_sid=$(jq -r .sid <<<"$ID_PAYLOAD")
fixture_sessions_before=$(session_ids "$FIXTURE_USER_UUID")
mint_ok "$app_token" account-center /
open_handoff "$HANDOFF_URL" "$HANDOFF_PROOF" "$shared_jar"
[[ $OPEN_LOCATION == "${ACCOUNT_CENTER_ENTRY}%2F" ]] || fail 'a second handoff of the same person failed'
fixture_sessions_after=$(session_ids "$FIXTURE_USER_UUID")
json_assert "$fixture_sessions_after" '(index($old) == null) and length == ($before | fromjson | length)' \
  'a second handoff of the same person kept the older browser session' \
  --arg old "$replaced_sid" --arg before "$fixture_sessions_before"
skyapp_offline_sessions=$(kcadm get "users/$FIXTURE_USER_UUID/offline-sessions/$(client_uuid skyapp)" -r "$REALM" -c)
json_assert "$skyapp_offline_sessions" '[.[].id] | index($app) != null' 'a handoff ended the SkyApp session it came from' \
  --arg app "$(jq -r .sid <<<"$app_payload")"
app_token=$(app_refresh)
[[ -n $app_token && $app_token != null ]] || fail 'SkyApp can no longer refresh its session after a handoff'
silent_login "$shared_jar" same-person
current_sid=$(jq -r .sid <<<"$ID_PAYLOAD")
[[ $current_sid != "$replaced_sid" ]] || fail 'the WebView still uses the older browser session'

# A stale identity cookie (its session ended on the server) must not shadow the new cookies.
kcadm delete "sessions/$current_sid" -r "$REALM" >/dev/null
mint_ok "$app_token" account-center /
open_handoff "$HANDOFF_URL" "$HANDOFF_PROOF" "$shared_jar"
[[ $OPEN_LOCATION == "${ACCOUNT_CENTER_ENTRY}%2F" ]] || fail 'a handoff into a WebView with a stale cookie failed'
silent_login "$shared_jar" stale-cookie
json_assert "$ID_PAYLOAD" '.sub == $sub and .sid != $stale' 'a stale identity cookie shadowed the new browser session' \
  --arg sub "$FIXTURE_USER_UUID" --arg stale "$current_sid"

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='web handoff rate limit'
limited=''
for _ in $(seq 1 62); do
  mint "$other_token" '{"target":"account-center","path":"/"}'
  if [[ $MINT_STATUS == 429 ]]; then
    limited=yes
    break
  fi
  [[ $MINT_STATUS == 201 ]] || fail "minting under the budget answered HTTP $MINT_STATUS"
done
[[ -n $limited ]] || fail 'minting is not rate limited per person'
expect_problem 429 rate_limited 'the budget refusal must be rate_limited'
retry_after=$(header_value "$MINT_HEADERS" retry-after)
[[ $retry_after =~ ^[0-9]+$ && $retry_after -ge 1 && $retry_after -le 300 ]] || fail 'Retry-After must fit the 5 minute window'
app_token=$(app_refresh)
mint "$app_token" '{"target":"account-center","path":"/"}'
[[ $MINT_STATUS == 201 ]] || fail 'the budget of one person must not limit another'

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='web handoff admin endpoints'
app_token=$(app_refresh)
# Admins are the members of the /ADMIN group (the group superadmin and core treat as admin; a
# subgroup counts) calling with a token of superadmin's own client, admin: the provider's
# defaults. Every other caller gets the same 403 body.
admin_group_id=$(kcadm get group-by-path/ADMIN -r "$REALM" -c | jq -r .id)
admin_subgroup_id=$(kcadm get "group-by-path/ADMIN/$ADMIN_SUBGROUP" -r "$REALM" -c | jq -r .id)
[[ -n $admin_group_id && $admin_group_id != null && -n $admin_subgroup_id && $admin_subgroup_id != null ]] \
  || fail 'the fixture /ADMIN group or its subgroup is missing'
admin_client_uuid=$(client_uuid "$ADMIN_CLIENT")
[[ -n $admin_client_uuid ]] || fail 'the fixture admin client is missing'
admin_token=$(admin_tokens "$ADMIN_USERNAME" "$ADMIN_PASSWORD" | jq -r .access_token)
json_assert "$(jwt_payload "$admin_token")" '.azp == "admin" and .sub == $sub and (.sid | length) > 0' \
  'the fixture admin token is not an online admin-client token of the /ADMIN member' --arg sub "$ADMIN_FIXTURE_UUID"
skyforms_uuid=$(client_uuid skyforms)
outside_uuid=$(client_uuid outside-fixture)
[[ -n $skyforms_uuid && -n $outside_uuid ]] || fail 'the skyforms and outside-fixture clients are missing'
skyforms_before=$(client_without_handoff "$skyforms_uuid")
outside_before=$(kcadm get "clients/$outside_uuid" -r "$REALM" -c | jq -S -c .)
enable_forms='{"enabled":true,"signInPath":"/auth/signin","returnParam":"callbackUrl"}'
disable_forms='{"enabled":false,"signInPath":"/auth/signin","returnParam":"callbackUrl"}'

# expect_admin_refused <bearer> <who>: the list and a change are both refused with the one 403 body
expect_admin_refused() {
  admin_call GET targets "$1"
  [[ $ADMIN_STATUS == 403 && $ADMIN_BODY == "$forbidden_list_body" ]] || fail "$2 must not list targets (HTTP $ADMIN_STATUS)"
  admin_call PUT targets/skyforms "$1" "$enable_forms"
  [[ $ADMIN_STATUS == 403 && $ADMIN_BODY == "$forbidden_list_body" ]] || fail "$2 must not change targets (HTTP $ADMIN_STATUS)"
}

admin_call GET targets -
expect_admin_problem 401 invalid_token 'the admin list must require a bearer token'
admin_call GET targets not-a-token
expect_admin_problem 401 invalid_token 'the admin list must refuse a malformed bearer token'
admin_call GET targets "$app_token"
expect_admin_problem 403 forbidden 'a person outside /ADMIN must not list targets with a SkyApp token'
forbidden_list_body=$ADMIN_BODY
admin_call PUT targets/skyforms "$app_token" "$enable_forms"
expect_admin_problem 403 forbidden 'a person outside /ADMIN must not change targets with a SkyApp token'
[[ $ADMIN_BODY == "$forbidden_list_body" ]] || fail 'every refused admin request must get the same 403 body'
admin_call PUT targets/no-such-client "$app_token" "$enable_forms"
[[ $ADMIN_STATUS == 403 && $ADMIN_BODY == "$forbidden_list_body" ]] \
  || fail 'a non-admin must not learn which clients exist'

# Not a member, right client.
person_admin_token=$(admin_tokens "$FIXTURE_USERNAME" "$FIXTURE_PASSWORD" | jq -r .access_token)
expect_admin_refused "$person_admin_token" 'a person outside /ADMIN with an admin-client token'
# A member, any other client.
member_skyapp_token=$(skyapp_tokens "$ADMIN_USERNAME" "$ADMIN_PASSWORD" | jq -r .access_token)
[[ $(jwt_payload "$member_skyapp_token" | jq -r .azp) == skyapp ]] || fail 'the SkyApp token of the admin has another azp'
expect_admin_refused "$member_skyapp_token" 'an /ADMIN member with a SkyApp token'
member_cli_token=$(curl --fail --silent --show-error \
  --data-urlencode grant_type=password \
  --data-urlencode client_id=admin-cli \
  --data-urlencode "username=$ADMIN_USERNAME" \
  --data-urlencode "password=$ADMIN_PASSWORD" \
  "$TOKEN_URL" | jq -r .access_token)
expect_admin_refused "$member_cli_token" 'an /ADMIN member with an admin-cli token'
# A member, right client, but an offline session: only a live online session is admitted.
# (Imported users lack the realm default roles; the role is removed again at cleanup.)
kcadm add-roles -r "$REALM" --uid "$ADMIN_FIXTURE_UUID" --rolename offline_access >/dev/null
admin_offline_tokens=$(admin_tokens "$ADMIN_USERNAME" "$ADMIN_PASSWORD" 'openid offline_access')
[[ $(jq -r .typ <<<"$(jwt_payload "$(jq -r .refresh_token <<<"$admin_offline_tokens")")") == Offline ]] \
  || fail 'the fixture did not produce an offline admin-client session'
admin_offline_token=$(jq -r .access_token <<<"$admin_offline_tokens")
expect_admin_refused "$admin_offline_token" 'an /ADMIN member with an admin-client token of an offline session'

# A member through a subgroup of /ADMIN is admitted, and only while a member.
kcadm update "users/$other_uuid/groups/$admin_subgroup_id" -r "$REALM" \
  -s "realm=$REALM" -s "userId=$other_uuid" -s "groupId=$admin_subgroup_id" -n >/dev/null
subgroup_admin_token=$(admin_tokens "$OTHER_USERNAME" "$other_password" | jq -r .access_token)
admin_call GET targets "$subgroup_admin_token"
[[ $ADMIN_STATUS == 200 ]] || fail "a member of a subgroup of /ADMIN could not list targets (HTTP $ADMIN_STATUS)"
kcadm delete "users/$other_uuid/groups/$admin_subgroup_id" -r "$REALM" >/dev/null
expect_admin_refused "$subgroup_admin_token" 'a person who left the /ADMIN subgroup'

# Without the /ADMIN group everyone is refused, and the missing group is logged once.
missing_group_since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
kcadm update "groups/$admin_group_id" -r "$REALM" -s name=ADMIN-renamed-by-handoff-contract >/dev/null
admin_call GET targets "$admin_token"
missing_first_status=$ADMIN_STATUS
missing_first_body=$ADMIN_BODY
admin_call PUT targets/skyforms "$admin_token" "$enable_forms"
missing_second_status=$ADMIN_STATUS
missing_second_body=$ADMIN_BODY
# The group name is restored before any assertion, whatever the requests did.
kcadm update "groups/$admin_group_id" -r "$REALM" -s name=ADMIN >/dev/null
[[ $missing_first_status == 403 && $missing_first_body == "$forbidden_list_body" \
  && $missing_second_status == 403 && $missing_second_body == "$forbidden_list_body" ]] \
  || fail "a missing /ADMIN group must refuse the admin (HTTP $missing_first_status, $missing_second_status)"
missing_group_warnings=$("${COMPOSE[@]}" logs --no-color --since "$missing_group_since" keycloak 2>&1 \
  | grep -Fc "sky-handoff: the admin group /ADMIN does not exist in realm $REALM" || true)
[[ $missing_group_warnings == 1 ]] \
  || fail "a missing /ADMIN group must be logged exactly once (logged $missing_group_warnings times)"

admin_call GET targets "$admin_token"
[[ $ADMIN_STATUS == 200 ]] || fail "the /ADMIN member could not list targets with an admin-client token (HTTP $ADMIN_STATUS)"
[[ $(header_value "$ADMIN_HEADERS" cache-control) == no-store ]] || fail 'the admin list must not be cached'
json_assert "$ADMIN_BODY" \
  '.targets | map(select(.clientId == "account-center"))[0] | .enabled == true and .signInPath == "/api/auth/login" and .returnParam == "returnTo" and .rootUrl == "https://my.yildizskylab.com" and .originAllowed == true and .clientEnabled == true' \
  'the admin list does not show account-center as an enabled target'
json_assert "$ADMIN_BODY" \
  '(.targets | map(select(.clientId == "skyforms"))[0] | .enabled == false and .signInPath == "/auth/signin" and .returnParam == "callbackUrl" and .originAllowed == true) and (.targets | map(select(.clientId == "outside-fixture"))[0] | .originAllowed == false) and (.targets | map(.clientId) | . == sort)' \
  'the admin list differs for skyforms or the outside client, or is not sorted'
json_assert "$ADMIN_BODY" '[.targets[] | keys | sort] | unique == [["clientEnabled", "clientId", "enabled", "name", "originAllowed", "returnParam", "rootUrl", "signInPath"]]' \
  'the admin list exposes more than the target fields'

mint "$app_token" '{"target":"skyforms","path":"/forms/abc"}'
expect_problem 400 invalid_target 'skyforms is not a target before the admin enables it'
admin_call PUT targets/skyforms "$admin_token" "$enable_forms"
[[ $ADMIN_STATUS == 200 ]] || fail "the admin could not enable skyforms (HTTP $ADMIN_STATUS)"
json_assert "$ADMIN_BODY" '.clientId == "skyforms" and .enabled == true' 'the enable answer does not show the new state'
mint_ok "$app_token" skyforms /forms/abc
open_handoff "$HANDOFF_URL" "$HANDOFF_PROOF" "$STATE_DIR/web-handoff-forms.cookies"
[[ $OPEN_LOCATION == 'https://forms.yildizskylab.com/auth/signin?callbackUrl=%2Fforms%2Fabc' ]] \
  || fail 'an enabled skyforms target did not land on the Forms sign-in entry'
admin_call PUT targets/skyforms "$admin_token" "$enable_forms"
[[ $ADMIN_STATUS == 200 ]] || fail 'repeating the same settings must succeed'
admin_call PUT targets/skyforms "$admin_token" "$disable_forms"
[[ $ADMIN_STATUS == 200 ]] || fail "the admin could not disable skyforms (HTTP $ADMIN_STATUS)"
mint "$app_token" '{"target":"skyforms","path":"/forms/abc"}'
expect_problem 400 invalid_target 'a disabled skyforms target must not mint'
[[ $(client_without_handoff "$skyforms_uuid") == "$skyforms_before" ]] \
  || fail 'the admin endpoint changed skyforms data other than the three handoff attributes'

admin_call PUT targets/outside-fixture "$admin_token" '{"enabled":true,"signInPath":"/login","returnParam":"next"}'
expect_admin_problem 400 origin_not_allowed 'a client outside yildizskylab.com must not become a target'
[[ $(kcadm get "clients/$outside_uuid" -r "$REALM" -c | jq -S -c .) == "$outside_before" ]] \
  || fail 'a refused enable changed the outside client'
admin_call PUT targets/skyforms "$admin_token" '{"enabled":true,"signInPath":"//evil.example/","returnParam":"callbackUrl"}'
expect_admin_problem 400 invalid_sign_in_path 'a sign-in path leaving the origin must be refused'
admin_call PUT targets/skyforms "$admin_token" '{"enabled":true,"signInPath":"/auth/signin","returnParam":"call back"}'
expect_admin_problem 400 invalid_return_param 'a malformed return parameter must be refused'
admin_call PUT targets/skyforms "$admin_token" '{"enabled":true,"signInPath":"/auth/signin","returnParam":"callbackUrl","redirectUris":["https://evil.example/*"]}'
expect_admin_problem 400 invalid_request 'fields other than the three settings must be refused'
admin_call PUT targets/no-such-client "$admin_token" "$enable_forms"
expect_admin_problem 404 client_not_found 'an unknown client is not found'
[[ $(client_without_handoff "$skyforms_uuid") == "$skyforms_before" ]] \
  || fail 'refused admin requests changed skyforms'

admin_events=$(kcadm get admin-events -r "$REALM" -c -q max=200)
json_assert "$admin_events" \
  '[.[] | select(.resourceType == "SKY_HANDOFF_TARGET" and .operationType == "UPDATE" and .authDetails.userId == $admin and .authDetails.clientId == $admin_client and .resourcePath == ("clients/" + $client + "/sky-handoff") and .details.clientId == "skyforms" and (.details.before | fromjson | .enabled == false) and (.details.after | fromjson | .enabled == true and .signInPath == "/auth/signin" and .returnParam == "callbackUrl"))] | length == 1' \
  'enabling skyforms left no admin event naming who changed it, through which client, from what to what' \
  --arg admin "$ADMIN_FIXTURE_UUID" --arg admin_client "$admin_client_uuid" --arg client "$skyforms_uuid"
json_assert "$admin_events" \
  '[.[] | select(.resourceType == "SKY_HANDOFF_TARGET" and .details.clientId == "skyforms")] | length == 2' \
  'every change and only a change must leave an admin event (enable, disable; the repeat is not a change)'
json_assert "$admin_events" \
  '[.[] | select(.resourceType == "SKY_HANDOFF_TARGET" and .details.clientId == "outside-fixture")] | length == 0' \
  'a refused change must not leave an admin event'

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='web handoff failure pages'
# Every reason lands on HTTP 200 with no form; anything else is the generic reason, never echoed.
failure_pages_since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
for reason in expired used invalid target_disabled account_unavailable unavailable; do
  expect_failure_page "$API/failed?reason=$reason" "$reason" "the $reason failure page"
done
expect_failure_page "$API/failed" unavailable 'a failure page without a reason must be the generic one'
expect_failure_page "$API/failed?reason=EXPIRED" unavailable 'an unknown reason must be the generic one'
expect_failure_page "$API/failed?reason=%3Cscript%3Ealert%28%27sky-reason-echo%27%29%3C%2Fscript%3E" unavailable \
  'a hostile reason must be the generic one'
if grep -Fq 'sky-reason-echo' "$STATE_DIR/sky-handoff-failed.html"; then
  fail 'the failure page echoed its reason parameter'
fi

CURRENT_STAGE='web handoff failure page in Chromium'
(
  cd "$SCRIPT_DIR/../theme"
  SKY_HANDOFF_FAILED_URL="$API/failed" \
    npx --no-install playwright test \
      --config=playwright.integration.config.ts \
      tests/integration/sky-handoff-failed.spec.ts
) || fail 'the failure page did not render every reason in Chromium'

CURRENT_STAGE='web handoff failure page without the SKY LAB login theme'
# A realm whose login theme lacks the page still gets the reason, from the built-in page.
login_theme_before=$(kcadm get "realms/$REALM" -c | jq -r '.loginTheme // ""')
kcadm update "realms/$REALM" -s loginTheme=keycloak.v2 >/dev/null
fallback_page="$STATE_DIR/sky-handoff-failed-fallback.html"
fallback_headers="$STATE_DIR/sky-handoff-failed-fallback.headers"
# The login theme is restored before any assertion, whatever the request did.
fallback_status=$(curl --silent --show-error --output "$fallback_page" --dump-header "$fallback_headers" \
  --write-out '%{http_code}' "$API/failed?reason=used" || printf 'unreachable')
kcadm update "realms/$REALM" -s "loginTheme=$login_theme_before" >/dev/null
[[ $fallback_status == 200 ]] || fail "the built-in failure page answered HTTP $fallback_status"
grep -Fq 'data-reason="used"' "$fallback_page" && grep -Fq 'Bu bağlantı zaten kullanıldı.' "$fallback_page" \
  && grep -Fq 'Uygulamaya dönüp tekrar dene.' "$fallback_page" \
  || fail 'the built-in failure page lost its reason or its sentences'
if grep -Eqi '<form|<script|<a[[:space:]]' "$fallback_page"; then
  fail 'the built-in failure page must offer no form, script or link'
fi
fallback_policy=$(header_value "$fallback_headers" content-security-policy)
[[ $fallback_policy == *"default-src 'none'"* && $fallback_policy != *script-src* && $fallback_policy == *"frame-ancestors 'none'"* ]] \
  || fail "the built-in failure page policy differs: $fallback_policy"
[[ $(header_value "$fallback_headers" x-frame-options) == DENY && $(header_value "$fallback_headers" cache-control) == no-store ]] \
  || fail 'the built-in failure page lost its framing or caching headers'
expect_failure_page "$API/failed?reason=used" used 'the themed failure page must return with the SKY LAB login theme'

failure_page_log=$("${COMPOSE[@]}" logs --no-color --since "$failure_pages_since" keycloak 2>&1 \
  | sed -E 's/[A-Za-z0-9_-]{43}/[REDACTED-43]/g')
# A failed render logs Keycloak's "Failed to process template" and the page's own fallback
# warning; either means the themed page did not render.
if grep -Ei 'failed to process template|sky-handoff: the login theme' <<<"$failure_page_log" >&2; then
  fail 'the themed failure page failed to render and fell back'
fi

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='web handoff audit events and secrecy'
events=$(kcadm get events -r "$REALM" -c -q "user=$FIXTURE_USER_UUID" -q type=CUSTOM_REQUIRED_ACTION -q max=100)
json_assert "$events" \
  '[.[] | select(.details.action == "sky-handoff" and .clientId == "account-center" and .sessionId == $sid)] | length == 1' \
  'the successful open left no sky-handoff event naming the person, the target and the session' \
  --arg sid "$handoff_sid"
error_events=$(kcadm get events -r "$REALM" -c -q type=CUSTOM_REQUIRED_ACTION_ERROR -q max=200)
for reason in used expired invalid target_disabled account_unavailable; do
  json_assert "$error_events" '[.[] | select(.details.action == "sky-handoff" and .error == $reason)] | length >= 1' \
    "no sky-handoff event recorded the $reason refusal" --arg reason "$reason"
done
json_assert "$error_events" \
  '[.[] | select(.details.action == "sky-handoff" and .error == "target_disabled" and .userId == $sub and .clientId == "account-center")] | length >= 1' \
  'a refusal of a known code must name the person and the target' --arg sub "$FIXTURE_USER_UUID"

keycloak_logs=$("${COMPOSE[@]}" logs --no-color keycloak 2>&1)
all_events="$events$error_events$(kcadm get events -r "$REALM" -c -q max=500)"
while IFS= read -r secret_value; do
  [[ -n $secret_value ]] || continue
  [[ $keycloak_logs != *"$secret_value"* ]] || fail 'a handoff code or proof leaked into the Keycloak log'
  [[ $all_events != *"$secret_value"* ]] || fail 'a handoff code or proof leaked into an event'
done <"$SECRETS_FILE"
[[ $keycloak_logs != *"$PATH_MARKER"* ]] || fail 'a handoff path leaked into the Keycloak log'
[[ $all_events != *"$PATH_MARKER"* ]] || fail 'a handoff path leaked into an event'

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='web handoff claims on ordinary logins'
# The realm keeps remember-me on in production (a 30-day SSO max next to the 8-hour one); the
# fixture realm switches it on for this stage only.
realm_session_before=$(kcadm get "realms/$REALM" -c | jq -c '{rememberMe, ssoSessionMaxLifespanRememberMe}')
kcadm update "realms/$REALM" -s rememberMe=true -s ssoSessionMaxLifespanRememberMe=2592000 >/dev/null
for remember in off on; do
  password_login "ordinary-remember-$remember" "$remember"
  for payload in "$ID_PAYLOAD" "$ACCESS_PAYLOAD"; do
    json_assert "$payload" 'has("sky_embed") | not' "an ordinary login (remember me $remember) must not carry sky_embed"
    json_assert "$payload" '(.sky_session_started - .auth_time) as $gap | $gap >= -2 and $gap <= 2' \
      "an ordinary login (remember me $remember) starts its session when the person authenticates"
    expect_session_lifetime "$payload" "$remember" \
      "an ordinary login (remember me $remember) must expire with the matching SSO session max"
  done
done
json_assert "$ACCESS_PAYLOAD" '.sky_session_expires - .sky_session_started == 2592000' \
  'a remember-me session must carry the 30-day remember-me max'
kcadm update "realms/$REALM" \
  -s "rememberMe=$(jq -r '.rememberMe // false' <<<"$realm_session_before")" \
  -s "ssoSessionMaxLifespanRememberMe=$(jq -r '.ssoSessionMaxLifespanRememberMe // 0' <<<"$realm_session_before")" >/dev/null

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='web handoff cleanup'
kcadm delete "users/$other_uuid" -r "$REALM" >/dev/null
kcadm remove-roles -r "$REALM" --uid "$FIXTURE_USER_UUID" --rolename offline_access >/dev/null
kcadm remove-roles -r "$REALM" --uid "$ADMIN_FIXTURE_UUID" --rolename offline_access >/dev/null
unset other_password
rm -f "$SECRETS_FILE"

printf 'Web handoff contract passed.\n'
