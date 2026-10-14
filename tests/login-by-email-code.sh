#!/usr/bin/env bash
# Real-Keycloak contract for "E-postayla devam et", sign-in with a Login code (eskylab-login-ux 08,
# ADR-0063 decision 2, CONTEXT "Login code"): the SPI step sky-email-code and the reconciler's e-mail
# code step (config/reconcile-account-center.sh, KEYCLOAK_RECONCILE_ONLY=email-code-login and
# KEYCLOAK_EMAIL_CODE_LOGIN). Stand-alone like tests/ytu-first-login.sh: the stock Keycloak image
# this repository builds on (the Dockerfile's KEYCLOAK_IMAGE) in dev mode with docker run --rm and no
# volume, this repository's SPI jar in /opt/keycloak/providers and config/ mounted read-only. No
# SKY LAB theme runs here: the pages are Keycloak's own and the SPI's fallback templates, driven
# with curl. Mail leaves as in production, through SkyMail: the integration harness's SkyMail
# fixture (tests/skymail-server.mjs) takes the mail tasks, with a real client-credentials token of
# keycloak-mailer whose endpoint Keycloak derives from the request (no SKY_MAIL_TOKEN_URL), so the
# background send of the code is proved to reach SkyMail; the codes are read from its records. One
# recipient the fixture refuses proves the SMTP fallback into the integration harness's Mailpit.
# Keycloak listens on the published port inside its container too, so the derived address works
# from both sides.
#
# The SPI jar: LOGIN_BY_EMAIL_CODE_SPI_JAR names one already built (mvn -f spi/pom.xml package);
# without it the jar is built from spi/ in the Dockerfile's Maven image (tests skipped: the image
# build runs them).
#
# The realm has production's login settings (e-mail login, brute-force protection of
# config/account-center-realm-security.json, the production User Profile, verifyEmail=true) and a
# browser flow in production's shape ('browser plus passkey': forms holds the 'password flow' subflow
# (SKY LAB password form, conditional OTP, passkey offer) and passwordless WebAuthn, both
# ALTERNATIVE). SKY_EMAIL_CODE_DAILY_LIMIT is small here so the operator alarm fires within the run.
#
# What it proves:
#   - keep adds nothing; on, under an identity with exactly the reconciler's realm-management roles,
#     adds the ALTERNATIVE subflow 'sky email code' (sky-email-code, conditional OTP, passkey offer)
#     next to the password flow and touches nothing else; a second on changes nothing;
#   - a person without TOTP signs in with the code typed after their username: the code went to the
#     Primary e-mail through SkyMail's keycloak.login-code (code, purpose=login, no link), no TOTP page, the token carries the same audience and claims as after a password
#     login, the LOGIN event says sky_method=email_code;
#   - the School e-mail of a Verified YTÜ account and a proven Personal e-mail as the identifier: the
#     code goes to the Primary e-mail; without a Primary e-mail it goes to the School e-mail;
#   - an address that names nobody: the same page and no mail;
#   - a code does not work in another browser; five wrong codes kill it; a person locked by
#     brute-force protection is not signed in by the right code;
#   - the fourth code to one address within a quarter hour is not mailed, the page is the same, a
#     rate_limited_address event is written; the overall daily budget mails the operator at half
#     and when used up, and sign-in codes still go;
#   - a person with TOTP is asked for it after the code;
#   - when SkyMail refuses, the code still arrives through Keycloak's SMTP (the SPI's FreeMarker
#     copy: the code on its own line, no link, no code in the subject) and signs the person in;
#   - "Parolanla gir" (Keycloak's execution selection) reaches the password form, and a password
#     login still works with the subflow on;
#   - the failure events carry no IP and no typed identifier; the server log holds no code, no
#     address of the run and not the client's IP;
#   - off makes the subflow DISABLED and Keycloak no longer offers it; on brings it back; a run cut
#     in the middle is finished by the next; a REQUIRED execution next to the password flow is
#     refused with nothing written;
#   - a realm bound to Keycloak's built-in browser flow (the sandbox may be): keep reports it, on is
#     refused with nothing written; after runbook §29's copy and binding, an operator session's on
#     adds the subflow next to the copy's forms and the login page offers the step.
# The expiry after ten minutes, the single use of the right code, the per-session and IP class
# budgets and the code for nobody are unit tests (EmailCodeAuthenticatorTest, LoginCodesTest).
# Requirements on the host: docker, jq, curl, node. LOGIN_BY_EMAIL_CODE_TEST_PORT (default 18099),
# LOGIN_BY_EMAIL_CODE_TEST_MAIL_PORT (default 18100), LOGIN_BY_EMAIL_CODE_TEST_CONTAINER (default
# login-by-email-code-test-<pid>), LOGIN_BY_EMAIL_CODE_TEST_MEMORY (default 2g).
# shellcheck disable=SC2016  # jq programs name jq variables
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPOSITORY_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
IMAGE=$(sed -n 's/^ARG KEYCLOAK_IMAGE=//p' "$REPOSITORY_ROOT/Dockerfile")
MAVEN_IMAGE=$(sed -n 's/^FROM \(maven:[^ ]*\) AS providers$/\1/p' "$REPOSITORY_ROOT/Dockerfile")
MAILPIT_IMAGE=$(sed -n 's/^ *image: \(axllent\/mailpit:[^ ]*\)$/\1/p' "$SCRIPT_DIR/docker-compose.integration.yml")
NODE_IMAGE=$(sed -n 's/^ARG NODE_IMAGE=//p' "$REPOSITORY_ROOT/Dockerfile")
PORT=${LOGIN_BY_EMAIL_CODE_TEST_PORT:-18099}
MAIL_PORT=${LOGIN_BY_EMAIL_CODE_TEST_MAIL_PORT:-18100}
BASE_URL="http://127.0.0.1:$PORT"
MAIL_URL="http://127.0.0.1:$MAIL_PORT"
CONTAINER=${LOGIN_BY_EMAIL_CODE_TEST_CONTAINER:-login-by-email-code-test-$$}
MAIL_CONTAINER="$CONTAINER-mail"
SKYMAIL_CONTAINER="$CONTAINER-skymail"
NETWORK="$CONTAINER-net"
MEMORY=${LOGIN_BY_EMAIL_CODE_TEST_MEMORY:-2g}
STATE_DIR=$(mktemp -d)
ADMIN_PASSWORD=harness-admin-password
OPERATOR_PASSWORD=harness-scoped-operator-password
MAILER_SECRET=harness-mailer-client-secret
PASSWORD=harness-person-password
OTP_SECRET='lbec-otp-fixture-secret-0123456789'
ADMIN_CONFIG=/tmp/harness-admin-kcadm.config
SCOPED_CONFIG=/tmp/harness-scoped-kcadm.config
JACKSON_GLOB='/opt/keycloak/lib/lib/main/com.fasterxml.jackson.core.jackson-*.jar'
REALM=e-skylab
APP=email-code-app
APP_REDIRECT=http://127.0.0.1:9/email-code-callback
FLOW='browser plus passkey'
FORMS='browser plus passkey forms'
SUBFLOW='sky email code'
OTP_SUBFLOW='sky email code conditional otp'
STEP=sky-email-code
DAILY_LIMIT=6
ALARM_TO=ops@example.invalid
CURRENT_STAGE=startup
STATUS=''
LOCATION=''
BODY=''
LANDED=''
APP_CODE=''
CODES=()

fail() {
  [[ -z ${LOGIN_BY_EMAIL_CODE_TEST_PAGE_DUMP:-} ]] || printf '%s\n' "$BODY" >"$LOGIN_BY_EMAIL_CODE_TEST_PAGE_DUMP"
  printf 'login-by-email-code failure during %s: %s\n' "$CURRENT_STAGE" "$1" >&2
  exit 1
}
cleanup() {
  docker rm -fv "$CONTAINER" "$MAIL_CONTAINER" "$SKYMAIL_CONTAINER" >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
  rm -rf "$STATE_DIR"
}
trap 'status=$?; trap - EXIT; cleanup; exit "$status"' EXIT
on_error() {
  local status=$?
  printf 'login-by-email-code command failed during %s (line %s)\n' "$CURRENT_STAGE" "$1" >&2
  exit "$status"
}
trap 'on_error "$LINENO"' ERR

kcadm() {
  local command=$1
  shift
  docker exec -i "$CONTAINER" /opt/keycloak/bin/kcadm.sh "$command" --config "$ADMIN_CONFIG" "$@" \
    2> >(grep -v -e '^Created new ' -e '^$' >&2 || true)
}

SCOPED_READY=''
sessions_login() {
  docker exec "$CONTAINER" /opt/keycloak/bin/kcadm.sh config credentials --config "$ADMIN_CONFIG" \
    --server "http://localhost:$PORT" --realm master --user admin --password "$ADMIN_PASSWORD" >/dev/null 2>&1 \
    || fail 'kcadm login failed'
  [[ -n $SCOPED_READY ]] || return 0
  docker exec "$CONTAINER" /opt/keycloak/bin/kcadm.sh config credentials --config "$SCOPED_CONFIG" \
    --server "http://localhost:$PORT" --realm "$REALM" --user lbec-scoped-operator --password "$OPERATOR_PASSWORD" >/dev/null 2>&1 \
    || fail 'the scoped operator could not log in'
}

stage() {
  CURRENT_STAGE=$1
  sessions_login
}

# reconcile CONFIG WANTED_STATUS [ENV=VALUE ...]: the reconciler's e-mail code step inside the
# container, with a kcadm session as an operator runs it; prints its output.
reconcile() {
  local config=$1 wanted=$2 output status=0
  shift 2
  local environment=(-e "KEYCLOAK_ADMIN_URL=http://localhost:$PORT" -e "KEYCLOAK_REALM=${RECONCILE_REALM:-$REALM}"
    -e KEYCLOAK_RECONCILE_ONLY=email-code-login -e "KEYCLOAK_RECONCILE_KCADM_CONFIG=$config")
  local assignment
  for assignment in "$@"; do
    environment+=(-e "$assignment")
  done
  trap - ERR
  output=$(docker exec "${environment[@]}" "$CONTAINER" bash /opt/keycloak/sky-config/reconcile-account-center.sh 2>&1) \
    || status=$?
  trap 'on_error "$LINENO"' ERR
  [[ $status == "$wanted" ]] || { printf '%s\n' "$output" >&2; fail "the reconciler did not exit $wanted (exit $status)"; }
  printf '%s\n' "$output"
}

expect_line() {
  grep -Fxq -- "$2" <<<"$1" || { printf '%s\n' "$1" >&2; fail "$3: $2"; }
}

flow() {
  kcadm get "authentication/flows/${1// /%20}/executions" -r "$REALM"
}

# The id of the one execution of the browser flow with that provider or subflow alias.
exec_id() {
  flow "$FLOW" | jq -er --arg name "$1" '[.[] | select(.providerId == $name or (.authenticationFlow == true and .displayName == $name))] | if length == 1 then .[0].id else error("not exactly one") end'
}

# set_requirement FLOW_ALIAS PROVIDER_OR_ALIAS REQUIREMENT: one execution of the flow, its priority kept.
set_requirement() {
  local body
  body=$(flow "$1" | jq -ce --arg name "$2" --arg requirement "$3" \
    'first(.[] | select(.providerId == $name or (.authenticationFlow == true and .displayName == $name)))
     | {id, requirement: $requirement, priority}')
  kcadm update "authentication/flows/${1// /%20}/executions" -r "$REALM" -n -b "$body" >/dev/null
}

# add_execution PARENT_ALIAS PROVIDER PRIORITY REQUIREMENT / add_subflow PARENT_ALIAS ALIAS PRIORITY REQUIREMENT
add_execution() {
  kcadm create "authentication/flows/${1// /%20}/executions/execution" -r "$REALM" -b "{\"provider\":\"$2\",\"priority\":$3}" >/dev/null
  set_requirement "$1" "$2" "$4"
}
add_subflow() {
  kcadm create "authentication/flows/${1// /%20}/executions/flow" -r "$REALM" \
    -b "{\"alias\":\"$2\",\"type\":\"basic-flow\",\"priority\":$3}" >/dev/null
  set_requirement "$1" "$2" "$4"
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

# follow JAR URL [curl arguments...]: the request, then every redirect by hand until a page
# (LANDED=page) or the application's redirect URI (LANDED=app; APP_CODE is its code).
follow() {
  local jar=$1 url=$2 hops=0
  shift 2
  request "$jar" "$url" "$@"
  while [[ $STATUS == 30[1237] ]]; do
    if [[ $LOCATION == "$APP_REDIRECT"* ]]; then
      [[ $LOCATION == *'code='* ]] || fail "the application was sent back without a code: ${LOCATION%%\?*}?…"
      APP_CODE=$(sed -E 's/.*[?&]code=([^&]*).*/\1/' <<<"$LOCATION")
      LANDED=app
      return 0
    fi
    [[ $LOCATION == http* ]] || LOCATION="$BASE_URL$LOCATION"
    request "$jar" "$LOCATION"
    hops=$((hops + 1))
    ((hops < 25)) || fail 'too many redirects'
  done
  LANDED=page
}

# The action of the page's form whose id is $1.
form_action() {
  local action
  action=$(tr '\n' ' ' <<<"$BODY" | grep -Eo "<form[^>]*id=\"$1\"[^>]*>" | grep -Eo 'action="[^"]*"' | head -n 1 \
    | sed -e 's/^action="//' -e 's/"$//' -e 's/&amp;/\&/g')
  [[ -n $action ]] || { printf '%s\n' "$BODY" | head -c 3000 >&2; fail "the page has no form #$1 ($(page_summary))"; }
  printf '%s\n' "$action"
}

on_form() {
  [[ $LANDED == page ]] && grep -Eq "<form[^>]*id=\"$1\"" <<<"$BODY"
}

# What the browser is looking at, for a failure message: no address or code, only the page's shape.
page_summary() {
  local title forms errors
  title=$(tr '\n' ' ' <<<"$BODY" | grep -Eo '<title>[^<]*</title>' | head -n 1 | sed -e 's/<[^>]*>//g' || true)
  forms=$(grep -Eo '<form[^>]*id="[^"]*"' <<<"$BODY" | grep -Eo 'id="[^"]*"' | paste -sd, - || true)
  errors=$(grep -Eo 'data-sky-email-code-error="[a-z_]*"' <<<"$BODY" | paste -sd, - || true)
  printf 'landed=%s HTTP %s title=%s forms=%s errors=%s' "$LANDED" "$STATUS" "${title:-?}" "${forms:-none}" "${errors:-none}"
}

# The page's element ids and data attributes, without anything that carries a URL (session codes).
page_shape() {
  grep -Eo ' (id|data-[a-z-]+)="[^"]*"' <<<"$BODY" | grep -v -e 'http' -e 'session_code' | sort | paste -sd' ' -
}

code_error() {
  grep -Eo 'data-sky-email-code-error="[a-z_]*"' <<<"$BODY" | head -n 1 | sed -e 's/^data-sky-email-code-error="//' -e 's/"$//' || true
}

expect_error() { # expect_error FORM_ID ERROR LABEL
  on_form "$1" || fail "$3: not the page with #$1 ($(page_summary))"
  [[ $(code_error) == "$2" ]] || fail "$3: the page shows error '$(code_error)', not '$2'"
}

auth_url() {
  printf '%s/realms/%s/protocol/openid-connect/auth?client_id=%s&response_type=code&scope=openid&redirect_uri=%s&state=s%s\n' \
    "$BASE_URL" "$REALM" "$APP" "$(jq -rn --arg u "$APP_REDIRECT" '$u | @uri')" "$RANDOM"
}

# open_code_page LABEL: a fresh browser at the application's sign-in, switched to the e-mail code
# step as the theme's "E-postayla devam et" does (Keycloak's authenticationExecution selection).
open_code_page() {
  JAR="$STATE_DIR/$1.cookies"
  rm -f "$JAR"
  follow "$JAR" "$(auth_url)"
  on_form kc-form-login || fail "$1: the sign-in did not start at the password form ($(page_summary))"
  follow "$JAR" "$(form_action kc-form-login)" --data-urlencode "authenticationExecution=$STEP_ID"
  on_form kc-email-code-identifier-form || fail "$1: the e-mail code page did not open ($(page_summary))"
}

# ask_code IDENTIFIER: "Kod gönder" on the identifier page; must land on the code page.
ask_code() {
  follow "$JAR" "$(form_action kc-email-code-identifier-form)" --data-urlencode "username=$1" \
    --data-urlencode sky-email-code-action=send
  on_form kc-email-code-form || fail "asking a code for an identifier did not show the code page ($(page_summary))"
  [[ -z $(code_error) ]] || fail "asking a code showed error '$(code_error)'"
}

type_code() { # type_code CODE
  LAST_CODE_ACTION=$(form_action kc-email-code-form)
  follow "$JAR" "$LAST_CODE_ACTION" --data-urlencode "code=$1" --data-urlencode sky-email-code-action=verify
}

# finish: the pages after the code that are not asked about (the passkey offer: "30 gün sorma").
finish() {
  if on_form kc-passkey-offer-form; then
    follow "$JAR" "$(form_action kc-passkey-offer-form)" --data-urlencode passkey-choice=no
  fi
}

# mail_count ADDRESS: how many mails Mailpit holds for the address (the SMTP fallback).
mail_count() {
  curl -fsS "$MAIL_URL/api/v1/messages?limit=500" \
    | jq --arg to "$1" '[.messages[]? | select(any(.To[]?; .Address == $to))] | length'
}

# The SkyMail fixture's records, one JSON object per line.
skymail_records() {
  docker logs "$SKYMAIL_CONTAINER" 2>/dev/null | sed -n 's/^SKYMAIL_FIXTURE //p'
}

# code_count ADDRESS: how many Login code mail tasks SkyMail got for the address.
code_count() {
  skymail_records | jq -s --arg to "$1" \
    '[.[] | select(.event == "mail_task" and .template_key == "keycloak.login-code" and .recipient_email == $to)] | length'
}

# await_code ADDRESS BEFORE: waits for a Login code mail task to the address beyond BEFORE (the code
# leaves after the request, in the background) and prints its code. The task must carry the code,
# purpose=login, the ten minutes and no link. Nothing is printed on failure.
await_code() {
  local task code
  for _ in $(seq 1 30); do
    (($(code_count "$1") > $2)) && break
    sleep 1
  done
  (($(code_count "$1") > $2)) || fail 'no code reached SkyMail for the address'
  task=$(skymail_records | jq -s -c --arg to "$1" \
    '[.[] | select(.event == "mail_task" and .template_key == "keycloak.login-code" and .recipient_email == $to)] | last')
  jq -e '.body_variables | .purpose == "login" and .link == "" and .codeExpirationMinutes == "10"
      and .subjectKey == "skyLoginCodeSubject" and (.code | test("^[0-9]{6}$"))' <<<"$task" >/dev/null \
    || fail 'the Login code mail task does not carry the code, purpose=login and the ten minutes without a link'
  jq -e '.missing_variables == [] and (.roles | index("skymail:mails:send")) != null' <<<"$task" >/dev/null \
    || fail 'the Login code mail task lacks a variable or the send role'
  code=$(jq -r '.body_variables.code' <<<"$task")
  printf '%s\n' "$code"
}

# await_smtp_code ADDRESS BEFORE: the same from a mail Keycloak's own SMTP delivered to Mailpit (the
# fallback): the code on its own line, no link, no code in the subject.
await_smtp_code() {
  local id message code subject
  for _ in $(seq 1 30); do
    (($(mail_count "$1") > $2)) && break
    sleep 1
  done
  (($(mail_count "$1") > $2)) || fail 'no code reached the address through the SMTP fallback'
  id=$(curl -fsS "$MAIL_URL/api/v1/messages?limit=500" \
    | jq -r --arg to "$1" 'first(.messages[]? | select(any(.To[]?; .Address == $to)) | .ID)')
  message=$(curl -fsS "$MAIL_URL/api/v1/message/$id")
  jq -e '((.Text // "") + (.HTML // "")) | test("https?://[^ ]*(login-actions|action-token)") | not' <<<"$message" >/dev/null \
    || fail 'the code mail carries a link'
  code=$(jq -r '.Text // "" | split("\n")[] | select(test("^\\s*[0-9]{6}\\s*$")) | gsub("\\s"; "")' <<<"$message" | head -n 1)
  [[ $code =~ ^[0-9]{6}$ ]] || fail 'the code mail carries no six-digit code'
  subject=$(jq -r '.Subject // ""' <<<"$message")
  [[ $subject != *"$code"* ]] || fail 'the code is in the subject line'
  printf '%s\n' "$code"
}

other_code() {
  [[ $1 == 000000 ]] && printf '000001\n' || printf '000000\n'
}

# token_claims: redeems APP_CODE and prints the access token's claims that must not depend on how
# the person signed in.
token_claims() {
  local response
  response=$(curl -fsS -X POST "$BASE_URL/realms/$REALM/protocol/openid-connect/token" \
    --data-urlencode grant_type=authorization_code --data-urlencode "client_id=$APP" \
    --data-urlencode "code=$APP_CODE" --data-urlencode "redirect_uri=$APP_REDIRECT")
  jq -r '.access_token' <<<"$response" | cut -d. -f2 | tr '_-' '/+' | awk '{ while (length($0) % 4) $0 = $0 "="; print }' \
    | base64 -d 2>/dev/null \
    | jq -S -c '{aud, azp, typ, scope, acr, preferred_username, email, email_verified, given_name, family_name, name, realm_access, resource_access, sub}'
}

user_by_username() {
  kcadm get users -r "$REALM" -q "username=$1" -q exact=true -q briefRepresentation=false | jq -c '.[0] // empty'
}

# person USERNAME EMAIL [JSON attributes] -> id; an account with a password.
person() {
  local attributes=${3:-'{}'}
  jq -n --arg username "$1" --arg email "$2" --arg password "$PASSWORD" --argjson attributes "$attributes" '{
      username: $username, enabled: true, firstName: "Kod", lastName: "Kişi", emailVerified: true,
      attributes: $attributes, credentials: [{type: "password", value: $password, temporary: false}]}
      + (if $email == "" then {} else {email: $email} end)' \
    | kcadm create users -r "$REALM" -i -f -
}

link_ytu() { # link_ytu USER_ID: the YTÜ Microsoft link that makes the School e-mail an identifier
  kcadm create "users/$1/federated-identity/OBS" -r "$REALM" \
    -b "{\"identityProvider\":\"OBS\",\"userId\":\"ms-$1\",\"userName\":\"ms-$1\"}" >/dev/null
}

login_events() { # login_events USER_ID: the user's LOGIN events, newest first
  kcadm get events -r "$REALM" -q type=LOGIN -q "user=$1"
}

# The Base32 form of a raw OTP secret, as an authenticator app gets it.
base32() {
  node -e '
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
    let bits = 0, value = 0, out = "";
    for (const byte of Buffer.from(process.argv[1], "utf8")) {
      value = ((value << 8) | byte) & 0xffff;
      bits += 8;
      while (bits >= 5) { out += alphabet[(value >>> (bits - 5)) & 31]; bits -= 5; }
    }
    if (bits > 0) out += alphabet[(value << (5 - bits)) & 31];
    console.log(out);' "$1"
}

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='SPI jar'
[[ -n $IMAGE ]] || fail 'Dockerfile has no ARG KEYCLOAK_IMAGE'
command -v jq >/dev/null || fail 'jq is required'
command -v node >/dev/null || fail 'node is required (TOTP codes)'
SPI_JAR=${LOGIN_BY_EMAIL_CODE_SPI_JAR:-}
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
grep -q 'com/skylab/account/EmailCodeAuthenticator.class' <<<"$spi_listing" \
  || fail "the SPI jar does not hold the $STEP step"

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='Keycloak start'
[[ -n $MAILPIT_IMAGE ]] || fail 'tests/docker-compose.integration.yml has no Mailpit image'
docker network create "$NETWORK" >/dev/null
[[ -n $NODE_IMAGE ]] || fail 'Dockerfile has no ARG NODE_IMAGE'
docker run --rm -d --name "$MAIL_CONTAINER" --network "$NETWORK" --memory 256m -p "127.0.0.1:$MAIL_PORT:8025" \
  "$MAILPIT_IMAGE" >/dev/null
docker run --rm -d --name "$SKYMAIL_CONTAINER" --network "$NETWORK" --memory 128m --read-only \
  -e SKYMAIL_HTTP_PORT=8080 -e SKYMAIL_SMTP_PORT=1025 \
  -v "$SCRIPT_DIR/skymail-server.mjs:/fixture/skymail-server.mjs:ro" \
  "$NODE_IMAGE" node /fixture/skymail-server.mjs >/dev/null
# No SKY_MAIL_TOKEN_URL: as in production, the token endpoint comes from the request's issuer.
docker run --rm -d --name "$CONTAINER" --network "$NETWORK" --memory "$MEMORY" -p "127.0.0.1:$PORT:$PORT" \
  -e KC_BOOTSTRAP_ADMIN_USERNAME=admin -e KC_BOOTSTRAP_ADMIN_PASSWORD="$ADMIN_PASSWORD" \
  -e SKY_EMAIL_CODE_DAILY_LIMIT="$DAILY_LIMIT" -e SKY_EMAIL_CODE_ALARM_EMAIL="$ALARM_TO" \
  -e SKY_HARNESS=1 -e SKY_MAIL_ENABLED=true -e "SKY_MAIL_BASE_URL=http://$SKYMAIL_CONTAINER:8080" \
  -e SKY_MAIL_CLIENT_ID=keycloak-mailer -e "SKY_MAIL_CLIENT_SECRET=$MAILER_SECRET" -e SKY_MAIL_TIMEOUT_MILLISECONDS=3000 \
  -v "$SPI_JAR:/opt/keycloak/providers/e-skylab-spi.jar:ro" \
  -v "$REPOSITORY_ROOT/config:/opt/keycloak/sky-config:ro" \
  "$IMAGE" start-dev --http-port "$PORT" >/dev/null
for _ in $(seq 1 120); do
  curl -fsS "$BASE_URL/realms/master" >/dev/null 2>&1 && break
  sleep 2
done
curl -fsS "$BASE_URL/realms/master" >/dev/null || { docker logs "$CONTAINER" 2>&1 | tail -n 40 >&2; fail "Keycloak did not start ($IMAGE)"; }
sessions_login
docker logs "$CONTAINER" >"$STATE_DIR/server.log" 2>&1
grep -Fq 'sky_mail_enabled client=keycloak-mailer' "$STATE_DIR/server.log" || fail 'the SkyMail provider is not on'
printf '    stock Keycloak in dev mode with the SPI jar (%s), daily limit %s, SkyMail fixture\n' "$(basename -- "$SPI_JAR")" "$DAILY_LIMIT"

# ---------------------------------------------------------------------------------------------------
stage 'e-skylab fixture'
security=$(jq -c 'del(.passwordPolicy)' "$REPOSITORY_ROOT/config/account-center-realm-security.json")
kcadm create realms -s "realm=$REALM" -s enabled=true -s loginWithEmailAllowed=true -s duplicateEmailsAllowed=false \
  -s verifyEmail=true -s registrationAllowed=false -s eventsEnabled=true -s adminEventsEnabled=true \
  -s internationalizationEnabled=true -s 'supportedLocales=["tr","en"]' -s defaultLocale=tr >/dev/null
kcadm update "realms/$REALM" -f - <<<"$security" >/dev/null
kcadm update "realms/$REALM" -s "smtpServer.host=$MAIL_CONTAINER" -s smtpServer.port=1025 \
  -s smtpServer.from=keycloak@example.invalid >/dev/null
docker exec "$CONTAINER" bash -c 'jars=('"$JACKSON_GLOB"'); IFS=:; mkdir -p /tmp/rj
  java -m jdk.compiler/com.sun.tools.javac.Main -d /tmp/rj -cp "${jars[*]}" /opt/keycloak/sky-config/ReconcileJson.java' >/dev/null
desired=$(kcadm get users/profile -r "$REALM" | docker exec -i "$CONTAINER" bash -c 'jars=('"$JACKSON_GLOB"'); IFS=:
  java -cp "/tmp/rj:${jars[*]}" ReconcileJson user-profile /opt/keycloak/sky-config/account-center-user-profile.json; [ $? = 3 ]')
kcadm update users/profile -r "$REALM" -n -f - <<<"$desired" >/dev/null
# YTÜ's identity provider: only its links matter here (a School e-mail is an identifier and a code
# destination only for a Verified YTÜ account); nobody signs in through it.
kcadm create identity-provider/instances -r "$REALM" -f - >/dev/null <<JSON
{"alias": "OBS", "providerId": "oidc", "enabled": true, "trustEmail": true,
 "config": {"clientId": "unused", "clientSecret": "unused", "authorizationUrl": "http://127.0.0.1:9/auth",
   "tokenUrl": "http://127.0.0.1:9/token", "defaultScope": "openid", "disableUserInfo": "true", "validateSignature": "false"}}
JSON
kcadm create clients -r "$REALM" -s "clientId=$APP" -s publicClient=true -s standardFlowEnabled=true \
  -s directAccessGrantsEnabled=false -s "redirectUris=[\"$APP_REDIRECT\"]" >/dev/null
# SkyMail's roles and Keycloak's mailer service account (config/create-mailer-client.sh in production).
skymail_client=$(kcadm create clients -r "$REALM" -i -s clientId=skymail -s publicClient=false -s bearerOnly=true)
for role in skymail:access skymail:mails:send; do
  kcadm create "clients/$skymail_client/roles" -r "$REALM" -s "name=$role" >/dev/null
done
kcadm create clients -r "$REALM" -s clientId=keycloak-mailer -s publicClient=false -s serviceAccountsEnabled=true \
  -s standardFlowEnabled=false -s directAccessGrantsEnabled=false -s "secret=$MAILER_SECRET" >/dev/null
kcadm add-roles -r "$REALM" --uusername service-account-keycloak-mailer --cclientid skymail \
  --rolename skymail:access --rolename skymail:mails:send >/dev/null

# Production's browser flow shape (runbook §15): forms -> password flow (SKY LAB password form,
# conditional OTP, passkey offer) and passwordless WebAuthn, both ALTERNATIVE.
kcadm create authentication/flows -r "$REALM" -s "alias=$FLOW" -s providerId=basic-flow -s topLevel=true \
  -s builtIn=false -s 'description=production shape' >/dev/null
add_execution "$FLOW" auth-cookie 10 ALTERNATIVE
add_execution "$FLOW" identity-provider-redirector 25 ALTERNATIVE
add_subflow "$FLOW" "$FORMS" 30 ALTERNATIVE
add_subflow "$FORMS" 'password flow' 0 ALTERNATIVE
add_execution "$FORMS" webauthn-authenticator-passwordless 1 ALTERNATIVE
add_execution 'password flow' sky-username-password-form 0 REQUIRED
add_subflow 'password flow' 'conditional 2fa' 1 CONDITIONAL
add_execution 'conditional 2fa' conditional-user-configured 0 REQUIRED
add_execution 'conditional 2fa' auth-otp-form 1 REQUIRED
add_execution 'password flow' passkey-offer-authenticator 2 REQUIRED
kcadm update "realms/$REALM" -s "browserFlow=$FLOW" >/dev/null
password_flow_before=$(flow 'password flow' | jq -S -c 'map(del(.index))')

# An identity with exactly the reconciler's realm-management roles (config/bootstrap-reconciler.sh).
operator_id=$(kcadm create users -r "$REALM" -i -s username=lbec-scoped-operator -s enabled=true \
  -s firstName=Scoped -s lastName=Operator -s email=lbec-scoped-operator@example.invalid -s emailVerified=true)
kcadm set-password -r "$REALM" --userid "$operator_id" --new-password "$OPERATOR_PASSWORD" --temporary=false >/dev/null
kcadm add-roles -r "$REALM" --uid "$operator_id" --cclientid realm-management \
  --rolename manage-clients --rolename view-clients --rolename manage-realm --rolename view-realm >/dev/null
SCOPED_READY=1
sessions_login
printf '    e-skylab with the production login settings, User Profile and browser flow shape\n'

# ---------------------------------------------------------------------------------------------------
stage 'reconciler: keep, then on'
output=$(reconcile "$SCOPED_CONFIG" 0)
expect_line "$output" "[reconcile] e-mail code sign-in of flow '$FLOW': unchanged (no subflow; KEYCLOAK_EMAIL_CODE_LOGIN=on adds it)" \
  'keep did not report the missing subflow'
flow "$FLOW" | jq -e --arg step "$STEP" 'all(.[]; .providerId != $step)' >/dev/null || fail 'keep added the step'

output=$(reconcile "$SCOPED_CONFIG" 0 KEYCLOAK_EMAIL_CODE_LOGIN=on)
grep -Fq "[reconcile] e-mail code sign-in of flow '$FLOW': updated (added subflow '$SUBFLOW' to '$FORMS' at priority 11; added $STEP; added subflow '$OTP_SUBFLOW'; added passkey-offer-authenticator; added conditional-user-configured; added auth-otp-form;" <<<"$output" \
  || { printf '%s\n' "$output" >&2; fail 'on did not add the subflow and its parts'; }
grep -Fq "subflow '$SUBFLOW' DISABLED -> ALTERNATIVE)" <<<"$output" || { printf '%s\n' "$output" >&2; fail 'on did not turn the subflow on last'; }
shape=$(flow "$FLOW" | jq -c '[.[] | {level, requirement, what: (if .authenticationFlow then .displayName else .providerId end)}]')
jq -e --arg forms "$FORMS" --arg subflow "$SUBFLOW" --arg otp "$OTP_SUBFLOW" --arg step "$STEP" '
  . as $all
  | ($all | map(.what) | index($subflow)) as $at
  | $all[$at] == {level: 1, requirement: "ALTERNATIVE", what: $subflow}
    and $all[$at + 1] == {level: 2, requirement: "REQUIRED", what: $step}
    and $all[$at + 2] == {level: 2, requirement: "CONDITIONAL", what: $otp}
    and $all[$at + 3] == {level: 3, requirement: "REQUIRED", what: "conditional-user-configured"}
    and $all[$at + 4] == {level: 3, requirement: "REQUIRED", what: "auth-otp-form"}
    and $all[$at + 5] == {level: 2, requirement: "REQUIRED", what: "passkey-offer-authenticator"}' <<<"$shape" >/dev/null \
  || { printf '%s\n' "$shape" >&2; fail 'the subflow is not in the expected shape'; }
[[ $(flow 'password flow' | jq -S -c 'map(del(.index))') == "$password_flow_before" ]] || fail 'on changed the password flow'
output=$(reconcile "$SCOPED_CONFIG" 0 KEYCLOAK_EMAIL_CODE_LOGIN=on)
expect_line "$output" "[reconcile] e-mail code sign-in of flow '$FLOW': unchanged (subflow '$SUBFLOW' ALTERNATIVE)" 'a second on changed something'
output=$(reconcile "$SCOPED_CONFIG" 0)
expect_line "$output" "[reconcile] e-mail code sign-in of flow '$FLOW': unchanged (subflow '$SUBFLOW' ALTERNATIVE; KEYCLOAK_EMAIL_CODE_LOGIN=on or off changes it)" \
  'keep did not report the subflow'
STEP_ID=$(exec_id "$STEP")
PASSWORD_FORM_ID=$(exec_id sky-username-password-form)
printf '    keep adds nothing; on adds the ALTERNATIVE subflow next to the password flow (untouched); again unchanged\n'

# ---------------------------------------------------------------------------------------------------
stage 'a code instead of a password'
ada=$(person ada ada@example.invalid)
JAR="$STATE_DIR/ada-password.cookies"
rm -f "$JAR"
follow "$JAR" "$(auth_url)"
follow "$JAR" "$(form_action kc-form-login)" --data-urlencode username=ada --data-urlencode "password=$PASSWORD" \
  --data-urlencode credentialId=
finish
[[ $LANDED == app ]] || fail "the password login did not reach the application ($(page_summary))"
password_claims=$(token_claims)

open_code_page ada-code
before=$(code_count ada@example.invalid)
ask_code ada
code=$(await_code ada@example.invalid "$before")
CODES+=("$code")
type_code "$code"
on_form kc-otp-login-form && fail 'a person without TOTP was asked for it'
finish
[[ $LANDED == app ]] || fail "the code did not sign the person in ($(page_summary))"
code_claims=$(token_claims)
jq -e '.preferred_username == "ada" and .email == "ada@example.invalid" and .azp == "email-code-app" and .sub != null' \
  <<<"$password_claims" >/dev/null || fail "the password login's token is not the person's ($password_claims)"
[[ $code_claims == "$password_claims" ]] || { printf 'password: %s\ncode:     %s\n' "$password_claims" "$code_claims" >&2; fail 'the token differs from the password login'; }
login_events "$ada" | jq -e '.[0].details.sky_method == "email_code" and .[0].details.username == "ada"' >/dev/null \
  || fail 'the LOGIN event does not say sky_method=email_code'
printf '    username -> code at the Primary e-mail -> application; no TOTP page; same token claims; LOGIN sky_method=email_code\n'

# ---------------------------------------------------------------------------------------------------
stage 'which address the code goes to'
ytu=$(person ytu ytu.personal@example.invalid '{"schoolEmail":["Ytu.Okul@STD.yildiz.edu.tr"],"personalEmail":["ytu.personal@example.invalid"],"personalEmailVerifiedAt":["2026-10-01T10:00:00Z"]}')
link_ytu "$ytu"
for typed in Ytu.Okul@std.yildiz.edu.tr YTU.PERSONAL@example.invalid; do
  open_code_page "ytu-$typed"
  before=$(code_count ytu.personal@example.invalid)
  ask_code "$typed"
  code=$(await_code ytu.personal@example.invalid "$before")
  CODES+=("$code")
  type_code "$code"
  finish
  [[ $LANDED == app ]] || fail "the code for '$typed' did not sign in ($(page_summary))"
done
(($(code_count ytu.okul@std.yildiz.edu.tr) == 0 && $(code_count Ytu.Okul@STD.yildiz.edu.tr) == 0)) \
  || fail 'a code went to the School e-mail of an account with a Primary e-mail'
school_only=$(person school-only '' '{"schoolEmail":["only.okul@std.yildiz.edu.tr"]}')
link_ytu "$school_only"
open_code_page school-only
ask_code school-only
code=$(await_code only.okul@std.yildiz.edu.tr 0)
CODES+=("$code")
type_code "$code"
finish
[[ $LANDED == app ]] || fail "the School e-mail code did not sign in ($(page_summary))"
printf '    School and Personal e-mail as identifiers -> the Primary e-mail; no Primary -> the School e-mail\n'

# ---------------------------------------------------------------------------------------------------
stage 'an address that names nobody'
open_code_page known
ask_code ada@example.invalid
known_page=$(page_shape)
open_code_page nobody
ask_code nobody@example.invalid
nobody_page=$(page_shape)
[[ $known_page == *'id="kc-email-code-form"'* && $known_page == *'data-sky-email-code-resend-after='* ]] \
  || fail "the code page has not the expected shape ($known_page)"
[[ $known_page == "$nobody_page" ]] || { printf 'known:  %s\nnobody: %s\n' "$known_page" "$nobody_page" >&2; fail 'the page tells an unknown address apart'; }
sleep 5
(($(code_count nobody@example.invalid) == 0 && $(mail_count nobody@example.invalid) == 0)) \
  || fail 'a code was mailed for an address that names nobody'
printf '    same page (ids, data attributes) for a known and an unknown address; nothing mailed to the unknown one\n'

# ---------------------------------------------------------------------------------------------------
stage 'the code works only where it was asked for'
person bea bea@example.invalid >/dev/null
open_code_page bea-first
first_jar=$JAR
ask_code bea
first_action=$(form_action kc-email-code-form)
code=$(await_code bea@example.invalid 0)
CODES+=("$code")
open_code_page bea-second
ask_code nobody@example.invalid
type_code "$code"
[[ $LANDED != app ]] || fail 'a code worked in another browser'
expect_error kc-email-code-form wrong_code 'a code from another browser'
JAR=$first_jar
follow "$JAR" "$first_action" --data-urlencode "code=$code" --data-urlencode sky-email-code-action=verify
finish
[[ $LANDED == app ]] || fail "the other browser's attempt cost this one its code ($(page_summary))"
printf '    a code from one browser is a wrong code in another and still works where it was asked for\n'

# ---------------------------------------------------------------------------------------------------
stage 'five wrong codes, and a locked person'
cem=$(person cem cem@example.invalid)
open_code_page cem
ask_code cem
code=$(await_code cem@example.invalid 0)
CODES+=("$code")
for attempt in 1 2 3 4; do
  type_code "$(other_code "$code")"
  expect_error kc-email-code-form wrong_code "wrong code $attempt"
done
type_code "$(other_code "$code")"
expect_error kc-email-code-identifier-form too_many_tries 'the fifth wrong code'
follow "$JAR" "$LAST_CODE_ACTION" --data-urlencode "code=$code" --data-urlencode sky-email-code-action=verify
[[ $LANDED != app ]] || fail 'the right code worked after five wrong ones'
kcadm get events -r "$REALM" -q type=LOGIN_ERROR -q "user=$cem" \
  | jq -e 'length >= 5 and all(.[]; .details.sky_method == "email_code" and .ipAddress == null and (.details.username // "") == "")' >/dev/null \
  || fail 'the wrong-code events name the IP or the typed identifier, or are missing'
dila=$(person dila dila@example.invalid)
open_code_page dila
ask_code dila
code=$(await_code dila@example.invalid 0)
CODES+=("$code")
# Two failures within quickLoginCheckMilliSeconds lock the person for minimumQuickLoginWaitSeconds.
type_code "$(other_code "$code")"
type_code "$(other_code "$code")"
for _ in $(seq 1 20); do
  kcadm get "attack-detection/brute-force/users/$dila" -r "$REALM" | jq -e '.disabled == true' >/dev/null && break
  sleep 1
done
kcadm get "attack-detection/brute-force/users/$dila" -r "$REALM" | jq -e '.disabled == true' >/dev/null \
  || fail 'wrong codes did not reach the brute-force protector'
type_code "$code"
[[ $LANDED != app ]] || fail 'a locked person signed in with the right code'
expect_error kc-email-code-identifier-form account_locked 'the right code of a locked person'
printf '    five wrong codes kill the code; failures count toward the lock; a locked person is refused\n'

# ---------------------------------------------------------------------------------------------------
stage 'sending budgets'
eda=$(person eda eda@example.invalid)
pages=()
for attempt in 1 2 3 4; do
  open_code_page "eda-$attempt"
  ask_code eda
  pages+=("$(page_shape)")
done
[[ ${pages[3]} == "${pages[0]}" ]] || fail 'the fourth request shows another page'
sleep 5
(($(code_count eda@example.invalid) == 3)) || fail "the address got $(code_count eda@example.invalid) codes in a quarter hour, not 3"
kcadm get events -r "$REALM" -q type=LOGIN_ERROR -q "user=$eda" \
  | jq -e 'any(.[]; .details.sky_email_code == "rate_limited_address")' >/dev/null || fail 'no event for the address budget'
alarm_subjects() {
  skymail_records | jq -s -c --arg to "$ALARM_TO" \
    '[.[] | select(.event == "mail_task" and .template_key == "keycloak.login-code-alarm" and .recipient_email == $to)
      | .body_variables.subjectKey] | sort'
}
for _ in $(seq 1 30); do
  [[ $(alarm_subjects) == '["skyLoginCodeAlarmFullSubject","skyLoginCodeAlarmHalfSubject"]' ]] && break
  sleep 1
done
[[ $(alarm_subjects) == '["skyLoginCodeAlarmFullSubject","skyLoginCodeAlarmHalfSubject"]' ]] \
  || fail "the operator did not get the half and full alarms through SkyMail: $(alarm_subjects)"
open_code_page after-limit
before=$(code_count ada@example.invalid)
ask_code ada
code=$(await_code ada@example.invalid "$before")
CODES+=("$code")
printf '    a fourth code to one address is not mailed (same page, event); the operator alarm at half and full; codes go on\n'

# ---------------------------------------------------------------------------------------------------
stage 'SkyMail refuses: the SMTP fallback'
person fallback skymail-fallback@example.invalid >/dev/null
open_code_page fallback
before=$(mail_count skymail-fallback@example.invalid)
ask_code fallback
code=$(await_smtp_code skymail-fallback@example.invalid "$before")
CODES+=("$code")
type_code "$code"
finish
[[ $LANDED == app ]] || fail "the code from the SMTP fallback did not sign in ($(page_summary))"
docker logs "$CONTAINER" >"$STATE_DIR/server.log" 2>&1
grep -Fq 'sky_mail_fallback reason=unavailable template=keycloak.login-code' "$STATE_DIR/server.log" \
  || fail 'the fallback left no sky_mail_fallback line'
! grep -Eq 'sky_mail_fallback reason=(config|token|disabled)' "$STATE_DIR/server.log" \
  || fail 'a mail fell back for want of a token or a configuration (the background send lost the request)'
printf '    SkyMail refused: the code still came through SMTP (no link, not in the subject) and signed in; no config/token fallbacks\n'

# ---------------------------------------------------------------------------------------------------
stage 'TOTP after the code'
totp_person=$(jq -n --arg password "$PASSWORD" --arg secret "$OTP_SECRET" '{
    username: "fikret", enabled: true, emailVerified: true, firstName: "Kod", lastName: "TOTP", email: "fikret@example.invalid",
    credentials: [{type: "password", value: $password, temporary: false},
      {type: "otp", userLabel: "lbec fixture authenticator", secretData: ({value: $secret} | tojson),
       credentialData: ({subType: "totp", digits: 6, counter: 0, period: 30, algorithm: "HmacSHA1"} | tojson)}]}' \
  | kcadm create users -r "$REALM" -i -f -)
open_code_page fikret
ask_code fikret
code=$(await_code fikret@example.invalid 0)
CODES+=("$code")
type_code "$code"
on_form kc-otp-login-form || fail "a person with TOTP was not asked for it after the code ($(page_summary))"
follow "$JAR" "$(form_action kc-otp-login-form)" --data-urlencode "otp=$(node "$SCRIPT_DIR/totp-code.mjs" "$(base32 "$OTP_SECRET")")"
finish
[[ $LANDED == app ]] || fail "TOTP after the code did not reach the application ($(page_summary))"
login_events "$totp_person" | jq -e '.[0].details.sky_method == "email_code"' >/dev/null \
  || fail 'the LOGIN event after TOTP does not say sky_method=email_code'
printf '    a person with TOTP types it after the code; the LOGIN event still says sky_method=email_code\n'

# ---------------------------------------------------------------------------------------------------
stage 'the password form stays one choice away'
open_code_page to-password
follow "$JAR" "$(form_action kc-email-code-identifier-form)" --data-urlencode "authenticationExecution=$PASSWORD_FORM_ID"
on_form kc-form-login || fail "Parolanla gir did not reach the password form ($(page_summary))"
follow "$JAR" "$(form_action kc-form-login)" --data-urlencode username=ada@example.invalid --data-urlencode "password=$PASSWORD" \
  --data-urlencode credentialId=
finish
[[ $LANDED == app ]] || fail "the password login from the code page did not reach the application ($(page_summary))"
printf '    the identifier page switches to the password form; a password login works with the subflow on\n'

# ---------------------------------------------------------------------------------------------------
stage 'the server log'
remote=$(login_events "$ada" | jq -r '.[0].ipAddress // ""')
docker logs "$CONTAINER" >"$STATE_DIR/server.log" 2>&1
for code in "${CODES[@]}"; do
  ! grep -Fq "$code" "$STATE_DIR/server.log" || fail 'a code reached the server log'
done
for address in ada@example.invalid ytu.personal@example.invalid ytu.okul@std.yildiz.edu.tr only.okul@std.yildiz.edu.tr \
  nobody@example.invalid bea@example.invalid cem@example.invalid dila@example.invalid eda@example.invalid fikret@example.invalid \
  skymail-fallback@example.invalid; do
  ! grep -Fiq "$address" "$STATE_DIR/server.log" || fail 'an address of the run reached the server log'
done
[[ -n $remote ]] || fail 'no client IP in the LOGIN event to look for'
! grep -Fq "$remote" "$STATE_DIR/server.log" || fail "the client's IP reached the server log"
grep -Fq "sky_email_code_budget level=half daily_limit=$DAILY_LIMIT realm=$REALM" "$STATE_DIR/server.log" \
  || fail 'the alarm left no log line'
printf '    no code, no address of the run and not the client IP in the log; the alarm line is there\n'

# ---------------------------------------------------------------------------------------------------
stage 'off, on, a cut run and a refusal'
output=$(reconcile "$SCOPED_CONFIG" 0 KEYCLOAK_EMAIL_CODE_LOGIN=off)
expect_line "$output" "[reconcile] e-mail code sign-in of flow '$FLOW': updated (subflow '$SUBFLOW' ALTERNATIVE -> DISABLED)" 'off did not turn the subflow off'
JAR="$STATE_DIR/off.cookies"
rm -f "$JAR"
follow "$JAR" "$(auth_url)"
follow "$JAR" "$(form_action kc-form-login)" --data-urlencode "authenticationExecution=$STEP_ID"
on_form kc-email-code-identifier-form && fail 'Keycloak still offered the e-mail code after off'
output=$(reconcile "$SCOPED_CONFIG" 0 KEYCLOAK_EMAIL_CODE_LOGIN=off)
expect_line "$output" "[reconcile] e-mail code sign-in of flow '$FLOW': unchanged (subflow '$SUBFLOW' DISABLED)" 'a second off changed something'
offer_id=$(flow "$FLOW" | jq -r --arg subflow "$SUBFLOW" '
  (map(.authenticationFlow == true and .displayName == $subflow) | index(true)) as $at | .[$at + 5].id')
kcadm delete "authentication/executions/$offer_id" -r "$REALM" >/dev/null
output=$(reconcile "$SCOPED_CONFIG" 0 KEYCLOAK_EMAIL_CODE_LOGIN=on)
expect_line "$output" "[reconcile] e-mail code sign-in of flow '$FLOW': updated (added passkey-offer-authenticator; passkey-offer-authenticator DISABLED -> REQUIRED; subflow '$SUBFLOW' DISABLED -> ALTERNATIVE)" \
  'on did not finish a cut subflow'
open_code_page back-on
set_requirement "$FORMS" webauthn-authenticator-passwordless REQUIRED
flow_before=$(flow "$FLOW" | jq -S -c .)
output=$(reconcile "$SCOPED_CONFIG" 1 KEYCLOAK_EMAIL_CODE_LOGIN=off)
grep -Fq 'webauthn-authenticator-passwordless next to the password form'"'"'s subflow is REQUIRED: an ALTERNATIVE beside it would never run' <<<"$output" \
  || { printf '%s\n' "$output" >&2; fail 'a REQUIRED neighbour was not refused'; }
[[ $(flow "$FLOW" | jq -S -c .) == "$flow_before" ]] || fail 'the refused run wrote something'
output=$(reconcile "$SCOPED_CONFIG" 0)
grep -Fq "WARNING: e-mail code sign-in of flow '$FLOW' could not be planned (webauthn-authenticator-passwordless next to the password form's subflow is REQUIRED" <<<"$output" \
  || { printf '%s\n' "$output" >&2; fail 'keep did not report the flow it could not plan'; }
set_requirement "$FORMS" webauthn-authenticator-passwordless ALTERNATIVE
printf '    off turns it off (and Keycloak stops offering it); on finishes a cut subflow and turns it back on; a REQUIRED neighbour is refused (keep only warns)\n'

# ---------------------------------------------------------------------------------------------------
stage "a realm bound to Keycloak's built-in browser flow"
SANDBOX=e-skylab-sandbox
kcadm create realms -s "realm=$SANDBOX" -s enabled=true -s loginWithEmailAllowed=true >/dev/null
kcadm create clients -r "$SANDBOX" -s "clientId=$APP" -s publicClient=true -s standardFlowEnabled=true \
  -s directAccessGrantsEnabled=false -s "redirectUris=[\"$APP_REDIRECT\"]" >/dev/null
# The sandbox realm has no reconciler identity: an operator session (here the administrator's) runs the step.
RECONCILE_REALM=$SANDBOX
output=$(reconcile "$ADMIN_CONFIG" 0)
expect_line "$output" "[reconcile] e-mail code sign-in of flow 'browser': unchanged (Keycloak's built-in flow)" \
  'keep did not report the built-in flow'
output=$(reconcile "$ADMIN_CONFIG" 1 KEYCLOAK_EMAIL_CODE_LOGIN=on)
grep -Fq "Realm $SANDBOX is bound to Keycloak's built-in browser flow 'browser', which cannot be edited; nothing was changed" <<<"$output" \
  || { printf '%s\n' "$output" >&2; fail 'on was not refused on the built-in flow'; }
# Runbook §29, sandbox: copy the built-in flow under production's name, bind the realm to it, then on.
kcadm create authentication/flows/browser/copy -r "$SANDBOX" -s "newName=$FLOW" >/dev/null
kcadm update "realms/$SANDBOX" -s "browserFlow=$FLOW" >/dev/null
output=$(reconcile "$ADMIN_CONFIG" 0 KEYCLOAK_EMAIL_CODE_LOGIN=on)
grep -Fq "[reconcile] e-mail code sign-in of flow '$FLOW': updated (added subflow '$SUBFLOW' to '$FLOW' at priority " <<<"$output" \
  || { printf '%s\n' "$output" >&2; fail 'on did not add the subflow to the copied flow'; }
output=$(reconcile "$ADMIN_CONFIG" 0 KEYCLOAK_EMAIL_CODE_LOGIN=on)
expect_line "$output" "[reconcile] e-mail code sign-in of flow '$FLOW': unchanged (subflow '$SUBFLOW' ALTERNATIVE)" \
  'a second on changed the copied flow'
RECONCILE_REALM=$REALM
sandbox_step=$(kcadm get "authentication/flows/${FLOW// /%20}/executions" -r "$SANDBOX" \
  | jq -er --arg step "$STEP" '[.[] | select(.providerId == $step)] | if length == 1 then .[0].id else error("not one") end')
JAR="$STATE_DIR/sandbox.cookies"
rm -f "$JAR"
follow "$JAR" "$(printf '%s/realms/%s/protocol/openid-connect/auth?client_id=%s&response_type=code&scope=openid&redirect_uri=%s&state=s%s' \
  "$BASE_URL" "$SANDBOX" "$APP" "$(jq -rn --arg u "$APP_REDIRECT" '$u | @uri')" "$RANDOM")"
on_form kc-form-login || fail "the copied flow does not start at the password form ($(page_summary))"
follow "$JAR" "$(form_action kc-form-login)" --data-urlencode "authenticationExecution=$sandbox_step"
on_form kc-email-code-identifier-form || fail "the copied flow does not offer the e-mail code ($(page_summary))"
printf "    built-in flow: keep reports, on refused; after copy and binding (runbook §29) on adds the subflow and the login page offers it\n"

printf 'login-by-email-code: all checks passed\n'
