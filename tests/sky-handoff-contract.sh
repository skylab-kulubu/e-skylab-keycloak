#!/usr/bin/env bash
# Real-Keycloak contract for the Web handoff (/realms/{realm}/sky-handoff/v1, ADR-0048).
# Invoked by run-integration.sh next to the native handoff stage, once the reconciled realm,
# the account-center client and the fixture user exist. Inputs: SKY_HANDOFF_COMPOSE_FILE,
# SKY_HANDOFF_ADMIN_CONFIG, SKY_HANDOFF_CLIENT_SECRET (account-center), TEST_STATE_DIR.
# Leaves account-center enabled as a Handoff target and removes the users it creates.
set -Eeuo pipefail

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
PATH_MARKER=/web-handoff-path-marker-7f3a9c
COMPOSE=(docker compose -f "$COMPOSE_FILE")
SECRETS_FILE="$STATE_DIR/sky-handoff-secrets"
: >"$SECRETS_FILE"
chmod 0600 "$SECRETS_FILE"
CURRENT_STAGE='web handoff fixture'

fail() {
  printf 'web handoff contract failure during %s: %s\n' "$CURRENT_STAGE" "$1" >&2
  "${COMPOSE[@]}" logs --no-color --tail=60 keycloak 2>&1 \
    | sed -E 's/[A-Za-z0-9_-]{43}/[REDACTED-43]/g' >&2 || true
  exit 1
}
trap 'status=$?; printf "web handoff command failed during %s (line %s)\n" "$CURRENT_STAGE" "$LINENO" >&2; exit "$status"' ERR

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
  APP_TOKENS=$(curl --fail --silent --show-error \
    --data-urlencode grant_type=authorization_code \
    --data-urlencode client_id=skyapp \
    --data-urlencode "code=$code" \
    --data-urlencode "redirect_uri=$APP_CALLBACK" \
    --data-urlencode "code_verifier=$verifier" \
    "$TOKEN_URL")
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
  local reason=$1 message=$2 page status
  [[ $OPEN_LOCATION == "$API/failed?reason=$reason" ]] \
    || fail "$message (landed on ${OPEN_LOCATION%%\?*} instead of the $reason failure page)"
  page="$STATE_DIR/sky-handoff-failed.html"
  status=$(curl --silent --show-error --output "$page" \
    --dump-header "$STATE_DIR/sky-handoff-failed.headers" --write-out '%{http_code}' "$OPEN_LOCATION")
  [[ $status == 200 ]] || fail "$message (the $reason page answered HTTP $status)"
  if grep -Eqi '<form' "$page"; then
    fail "$message (the failure page must not offer a form)"
  fi
  grep -Fq 'Uygulamaya dönüp tekrar dene.' "$page" || fail "$message (the failure page lacks the retry hint)"
  grep -Fq "data-reason=\"$reason\"" "$page" || fail "$message (the failure page shows another reason)"
  [[ $(header_value "$STATE_DIR/sky-handoff-failed.headers" cache-control) == no-store ]] \
    || fail "$message (the failure page must not be cached)"
  [[ $(header_value "$STATE_DIR/sky-handoff-failed.headers" x-frame-options) == DENY ]] \
    || fail "$message (the failure page must not be framed)"
}

# silent_login <cookie jar> <label> -> ID_PAYLOAD, ACCESS_PAYLOAD: account-center's own OIDC login
# from the browser session alone. Any login page on the way is a failure.
silent_login() {
  local jar=$1 label=$2 verifier challenge par request_uri_query url attempt status location headers code tokens
  verifier="web-handoff-$label-verifier-0123456789abcdefghijklmnopqrstuvwxyz"
  challenge=$(printf '%s' "$verifier" | openssl dgst -binary -sha256 | openssl base64 -A | tr '+/' '-_' | tr -d '=')
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
  request_uri_query=$(jq -r '.request_uri | @uri' <<<"$par")
  url="$BASE_URL/realms/$REALM/protocol/openid-connect/auth?client_id=account-center&request_uri=$request_uri_query"
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
  [[ $location == "$CALLBACK"\?* ]] || fail "silent login $label never reached the callback"
  [[ $location == *"state=web-handoff-$label"* ]] || fail "silent login $label lost its state"
  code=$(sed -n 's/.*[?&]code=\([^&]*\).*/\1/p' <<<"$location")
  [[ -n $code ]] || fail "silent login $label returned no authorization code"
  tokens=$(curl --fail --silent --show-error \
    --user "account-center:$CLIENT_SECRET" \
    --data-urlencode grant_type=authorization_code \
    --data-urlencode client_id=account-center \
    --data-urlencode "code=$code" \
    --data-urlencode "redirect_uri=$CALLBACK" \
    --data-urlencode "code_verifier=$verifier" \
    "$TOKEN_URL")
  ID_PAYLOAD=$(jwt_payload "$(jq -r .id_token <<<"$tokens")")
  ACCESS_PAYLOAD=$(jwt_payload "$(jq -r .access_token <<<"$tokens")")
}

set_target_attribute() {
  kcadm update "clients/$1" -r "$REALM" -s "attributes.\"$2\"=$3" >/dev/null
}

session_ids() {
  kcadm get "users/$1/sessions" -r "$REALM" -c | jq -c '[.[].id] | sort'
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
json_assert "$fixture_sessions_after" 'index($app) != null' 'a handoff ended the SkyApp session it came from' \
  --arg app "$(jq -r .sid <<<"$app_payload")"
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
CURRENT_STAGE='web handoff cleanup'
kcadm delete "users/$other_uuid" -r "$REALM" >/dev/null
unset other_password
rm -f "$SECRETS_FILE"

printf 'Web handoff contract passed.\n'
