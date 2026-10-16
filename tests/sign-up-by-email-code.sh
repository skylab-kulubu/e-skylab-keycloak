#!/usr/bin/env bash
# Real-Keycloak contract for Self-registration on "E-postayla devam et" (eskylab-login-ux 09, ADR-0063
# decision 1, CONTEXT "Self-registration"): the sign-up branch of the SPI step sky-email-code and the
# reconciler's sign-up setting (config/reconcile-account-center.sh, KEYCLOAK_EMAIL_CODE_SIGN_UP, part of
# the operator step KEYCLOAK_RECONCILE_ONLY=email-code-login). Stand-alone like
# tests/login-by-email-code.sh, whose shape it follows: the stock Keycloak image this repository builds
# on (the Dockerfile's KEYCLOAK_IMAGE) in dev mode with docker run --rm and no volume, this repository's
# SPI jar in /opt/keycloak/providers and config/ mounted read-only. No SKY LAB theme runs here: the
# pages are Keycloak's own and the SPI's fallback templates (sky-email-code.ftl,
# sky-email-code-sign-up.ftl), driven with curl. Mail leaves as in production, through SkyMail: the
# integration harness's SkyMail fixture (tests/skymail-server.mjs) takes the mail tasks with a real
# client-credentials token of keycloak-mailer; its records give the codes. Recipients the fixture
# refuses prove the SMTP fallback into Mailpit, in the language of the sign-in page.
#
# The SPI jar: SIGN_UP_BY_EMAIL_CODE_SPI_JAR names one already built (mvn -f spi/pom.xml package);
# without it the jar is built from spi/ in the Dockerfile's Maven image (tests skipped: the image
# build runs them).
#
# The realm has production's login settings (e-mail login, registrationAllowed=false, verifyEmail=true,
# brute-force protection of config/account-center-realm-security.json, the production User Profile) and
# a browser flow in production's shape ('browser plus passkey': forms holds the 'password flow' subflow
# and passwordless WebAuthn, both ALTERNATIVE).
#
# What it proves:
#   - KEYCLOAK_EMAIL_CODE_SIGN_UP: keep reports off; on without the e-mail code step is refused with
#     nothing written; on with KEYCLOAK_EMAIL_CODE_LOGIN=on in one call adds the step and the setting
#     (Keycloak authenticator config 'sky email code sign-up', sign-up=true), under an identity with
#     exactly the reconciler's realm-management roles; a second on changes nothing; keep reports on;
#     registrationAllowed stays false;
#   - with the setting off an address that names nobody is mailed nothing;
#   - a new address: the sign-up code goes to it through SkyMail's keycloak.login-code (purpose=signup,
#     subjectKey skySignUpCodeSubject, no link), the right code opens the sign-up form, the names open
#     the account: the address as verified Primary e-mail and proven Personal e-mail
#     (personalEmailVerifiedAt), the username from the names on the form, no credential, no group, only the
#     realm's default roles, a REGISTER event (register_method and sky_method email_code), a LOGIN
#     event with sky_method=email_code; the token carries what core's JIT reads (sub, email,
#     email_verified, given_name, family_name, preferred_username) and no school_email (the welcome
#     mail is core's: core is not part of this harness, so this is its contract); then the new account
#     signs in with a Login code;
#   - a username that is taken gets a number; names with prohibited characters are refused with no
#     account;
#   - the code page is the same for an address with and without an account (ids and data
#     attributes), and the time to answer is printed for both;
#   - "Hesap aç" (sky-email-code-intent=sign-up with Keycloak's execution switch) for an address that
#     has an account: a Login code to its Primary e-mail, then the existing stage, "Devam et" signs in,
#     no second account;
#   - a YTÜ school address: a sign-up code, then the YTÜ stage with the OBS broker link, no account;
#   - two sign-ups of one address submitted at the same moment open one account;
#   - SkyMail refuses: the sign-up code still comes through Keycloak's SMTP with the sign-up text, in
#     Turkish or in English as the sign-in page was (Accept-Language), no link, no code in the subject;
#   - the server log holds no code, no address of the run and not the client's IP;
#   - off: the setting false, an address that names nobody is mailed nothing again, the accounts
#     opened stay and sign in.
# The harness also proves transaction-level ownership exclusion (commit and rollback) with a
# separate test-only provider jar; it never enters the production SPI or image.
# The ceilings, the overall budget pause, the race windows, the proof's lifetime and the stages'
# reloads are unit tests (EmailCodeAuthenticatorTest, SignUpUsernamesTest, EmailCodeSignUpTest).
# Requirements on the host: docker, jq, curl. SIGN_UP_BY_EMAIL_CODE_TEST_PORT (default 18101),
# SIGN_UP_BY_EMAIL_CODE_TEST_MAIL_PORT (default 18102), SIGN_UP_BY_EMAIL_CODE_TEST_CONTAINER (default
# sign-up-by-email-code-test-<pid>), SIGN_UP_BY_EMAIL_CODE_TEST_MEMORY (default 2g).
# shellcheck disable=SC2016  # jq programs name jq variables
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPOSITORY_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
IMAGE=$(sed -n 's/^ARG KEYCLOAK_IMAGE=//p' "$REPOSITORY_ROOT/Dockerfile")
MAVEN_IMAGE=$(sed -n 's/^FROM \(maven:[^ ]*\) AS providers$/\1/p' "$REPOSITORY_ROOT/Dockerfile")
MAILPIT_IMAGE=$(sed -n 's/^ *image: \(axllent\/mailpit:[^ ]*\)$/\1/p' "$SCRIPT_DIR/docker-compose.integration.yml")
NODE_IMAGE=$(sed -n 's/^ARG NODE_IMAGE=//p' "$REPOSITORY_ROOT/Dockerfile")
PORT=${SIGN_UP_BY_EMAIL_CODE_TEST_PORT:-18101}
MAIL_PORT=${SIGN_UP_BY_EMAIL_CODE_TEST_MAIL_PORT:-18102}
BASE_URL="http://127.0.0.1:$PORT"
MAIL_URL="http://127.0.0.1:$MAIL_PORT"
CONTAINER=${SIGN_UP_BY_EMAIL_CODE_TEST_CONTAINER:-sign-up-by-email-code-test-$$}
MAIL_CONTAINER="$CONTAINER-mail"
SKYMAIL_CONTAINER="$CONTAINER-skymail"
NETWORK="$CONTAINER-net"
MEMORY=${SIGN_UP_BY_EMAIL_CODE_TEST_MEMORY:-2g}
STATE_DIR=$(mktemp -d)
ADMIN_PASSWORD=harness-admin-password
OPERATOR_PASSWORD=harness-scoped-operator-password
MAILER_SECRET=harness-mailer-client-secret
PASSWORD=harness-person-password
ADMIN_CONFIG=/tmp/harness-admin-kcadm.config
SCOPED_CONFIG=/tmp/harness-scoped-kcadm.config
JACKSON_GLOB='/opt/keycloak/lib/lib/main/com.fasterxml.jackson.core.jackson-*.jar'
REALM=e-skylab
APP=sign-up-app
APP_REDIRECT=http://127.0.0.1:9/sign-up-callback
FLOW='browser plus passkey'
FORMS='browser plus passkey forms'
STEP=sky-email-code
CONFIG_ALIAS='sky email code sign-up'
CURRENT_STAGE=startup
STATUS=''
LOCATION=''
BODY=''
LANDED=''
APP_CODE=''
CODES=()
ADDRESSES=()

fail() {
  [[ -z ${SIGN_UP_BY_EMAIL_CODE_TEST_PAGE_DUMP:-} ]] || printf '%s\n' "$BODY" >"$SIGN_UP_BY_EMAIL_CODE_TEST_PAGE_DUMP"
  printf 'sign-up-by-email-code failure during %s: %s\n' "$CURRENT_STAGE" "$1" >&2
  # The extension's own lines carry no address, code or IP; Keycloak's errors say what broke.
  docker logs "$CONTAINER" 2>&1 | grep -E 'sky_email_code|sky_mail|ERROR' | tail -n 20 >&2 || true
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
  printf 'sign-up-by-email-code command failed during %s (line %s)\n' "$CURRENT_STAGE" "$1" >&2
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
    --server "http://localhost:$PORT" --realm "$REALM" --user sbec-scoped-operator --password "$OPERATOR_PASSWORD" >/dev/null 2>&1 \
    || fail 'the scoped operator could not log in'
}

stage() {
  CURRENT_STAGE=$1
  sessions_login
}

# reconcile WANTED_STATUS [ENV=VALUE ...]: the reconciler's e-mail code step inside the container, with
# the scoped operator's kcadm session; prints its output.
reconcile() {
  local wanted=$1 output status=0
  shift
  local environment=(-e "KEYCLOAK_ADMIN_URL=http://localhost:$PORT" -e "KEYCLOAK_REALM=$REALM"
    -e KEYCLOAK_RECONCILE_ONLY=email-code-login -e "KEYCLOAK_RECONCILE_KCADM_CONFIG=$SCOPED_CONFIG")
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

exec_id() {
  flow "$FLOW" | jq -er --arg name "$1" '[.[] | select(.providerId == $name or (.authenticationFlow == true and .displayName == $name))] | if length == 1 then .[0].id else error("not exactly one") end'
}

set_requirement() {
  local body
  body=$(flow "$1" | jq -ce --arg name "$2" --arg requirement "$3" \
    'first(.[] | select(.providerId == $name or (.authenticationFlow == true and .displayName == $name)))
     | {id, requirement: $requirement, priority}')
  kcadm update "authentication/flows/${1// /%20}/executions" -r "$REALM" -n -b "$body" >/dev/null
}

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
  local title forms errors stage
  title=$(tr '\n' ' ' <<<"$BODY" | grep -Eo '<title>[^<]*</title>' | head -n 1 | sed -e 's/<[^>]*>//g' || true)
  forms=$(grep -Eo '<form[^>]*id="[^"]*"' <<<"$BODY" | grep -Eo 'id="[^"]*"' | paste -sd, - || true)
  errors=$(grep -Eo 'data-sky-(email-code|sign-up)-error="[a-z_]*"' <<<"$BODY" | paste -sd, - || true)
  stage=$(grep -Eo 'data-sky-sign-up-stage="[a-z]*"' <<<"$BODY" | head -n 1 || true)
  printf 'landed=%s HTTP %s title=%s forms=%s errors=%s %s' "$LANDED" "$STATUS" "${title:-?}" "${forms:-none}" "${errors:-none}" "$stage"
}

page_shape() {
  grep -Eo ' (id|data-[a-z-]+)="[^"]*"' <<<"$BODY" | grep -v -e 'http' -e 'session_code' | sort | paste -sd' ' -
}

sign_up_error() {
  grep -Eo 'data-sky-sign-up-error="[a-z_]*"' <<<"$BODY" | head -n 1 | sed -e 's/^data-sky-sign-up-error="//' -e 's/"$//' || true
}

sign_up_stage() {
  grep -Eo 'data-sky-sign-up-stage="[a-z]*"' <<<"$BODY" | head -n 1 | sed -e 's/^data-sky-sign-up-stage="//' -e 's/"$//' || true
}

auth_url() {
  printf '%s/realms/%s/protocol/openid-connect/auth?client_id=%s&response_type=code&scope=openid&redirect_uri=%s&state=s%s\n' \
    "$BASE_URL" "$REALM" "$APP" "$(jq -rn --arg u "$APP_REDIRECT" '$u | @uri')" "$RANDOM"
}

# open_code_page LABEL [sign-up]: a fresh browser at the application's sign-in, switched to the e-mail
# code step as the theme's "E-postayla devam et" does; with sign-up, as its "Hesap aç" does.
open_code_page() {
  local intent=()
  [[ ${2:-} != sign-up ]] || intent=(--data-urlencode sky-email-code-intent=sign-up)
  JAR="$STATE_DIR/$1.cookies"
  rm -f "$JAR"
  follow "$JAR" "$(auth_url)"
  on_form kc-form-login || fail "$1: the sign-in did not start at the password form ($(page_summary))"
  follow "$JAR" "$(form_action kc-form-login)" --data-urlencode "authenticationExecution=$STEP_ID" ${intent[@]+"${intent[@]}"}
  on_form kc-email-code-identifier-form || fail "$1: the e-mail code page did not open ($(page_summary))"
}

# ask_code IDENTIFIER [curl arguments...]: "Kod gönder" on the identifier page; must land on the code page.
ask_code() {
  local identifier=$1
  shift
  follow "$JAR" "$(form_action kc-email-code-identifier-form)" --data-urlencode "username=$identifier" \
    --data-urlencode sky-email-code-action=send "$@"
  on_form kc-email-code-form || fail "asking a code did not show the code page ($(page_summary))"
}

type_code() {
  follow "$JAR" "$(form_action kc-email-code-form)" --data-urlencode "code=$1" --data-urlencode sky-email-code-action=verify
}

# sign_up FIRST LAST: "Hesabı aç" on the sign-up form.
sign_up() {
  follow "$JAR" "$(form_action kc-email-code-sign-up-form)" --data-urlencode "firstName=$1" --data-urlencode "lastName=$2" \
    --data-urlencode sky-email-code-action=sign-up
}

finish() {
  if on_form kc-passkey-offer-form; then
    follow "$JAR" "$(form_action kc-passkey-offer-form)" --data-urlencode passkey-choice=no
  fi
}

mail_count() {
  curl -fsS "$MAIL_URL/api/v1/messages?limit=500" \
    | jq --arg to "$1" '[.messages[]? | select(any(.To[]?; .Address == $to))] | length'
}

skymail_records() {
  docker logs "$SKYMAIL_CONTAINER" 2>/dev/null | sed -n 's/^SKYMAIL_FIXTURE //p'
}

code_count() {
  skymail_records | jq -s --arg to "$1" \
    '[.[] | select(.event == "mail_task" and .template_key == "keycloak.login-code" and .recipient_email == $to)] | length'
}

# await_code ADDRESS BEFORE PURPOSE: waits for a code mail task to the address beyond BEFORE and prints
# its code. The task must carry the code, the purpose, its subject key, the ten minutes and no link.
await_code() {
  local task code subject_key=skyLoginCodeSubject
  [[ $3 != signup ]] || subject_key=skySignUpCodeSubject
  for _ in $(seq 1 30); do
    (($(code_count "$1") > $2)) && break
    sleep 1
  done
  (($(code_count "$1") > $2)) || fail "no $3 code reached SkyMail for the address"
  task=$(skymail_records | jq -s -c --arg to "$1" \
    '[.[] | select(.event == "mail_task" and .template_key == "keycloak.login-code" and .recipient_email == $to)] | last')
  jq -e --arg purpose "$3" --arg subject "$subject_key" '.body_variables | .purpose == $purpose and .link == ""
      and .codeExpirationMinutes == "10" and .subjectKey == $subject and (.code | test("^[0-9]{6}$"))' <<<"$task" >/dev/null \
    || fail "the code mail task does not carry the code, purpose=$3, $subject_key and the ten minutes without a link"
  jq -e '.missing_variables == [] and (.roles | index("skymail:mails:send")) != null' <<<"$task" >/dev/null \
    || fail 'the code mail task lacks a variable or the send role'
  code=$(jq -r '.body_variables.code' <<<"$task")
  printf '%s\n' "$code"
}

# await_smtp_code ADDRESS BEFORE TEXT: the code from a mail Keycloak's own SMTP delivered to Mailpit
# (the fallback): TEXT in it, the code on its own line, no link, no code in the subject.
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
  jq -e --arg text "$3" '(.Text // "") | contains($text)' <<<"$message" >/dev/null \
    || fail "the fallback mail does not say '$3'"
  jq -e '((.Text // "") + (.HTML // "")) | test("https?://[^ ]*(login-actions|action-token)") | not' <<<"$message" >/dev/null \
    || fail 'the code mail carries a link'
  code=$(jq -r '.Text // "" | split("\n")[] | select(test("^\\s*[0-9]{6}\\s*$")) | gsub("\\s"; "")' <<<"$message" | head -n 1)
  [[ $code =~ ^[0-9]{6}$ ]] || fail 'the code mail carries no six-digit code'
  subject=$(jq -r '.Subject // ""' <<<"$message")
  [[ $subject != *"$code"* ]] || fail 'the code is in the subject line'
  printf '%s\n' "$code"
}

token_claims() {
  local response
  response=$(curl -fsS -X POST "$BASE_URL/realms/$REALM/protocol/openid-connect/token" \
    --data-urlencode grant_type=authorization_code --data-urlencode "client_id=$APP" \
    --data-urlencode "code=$APP_CODE" --data-urlencode "redirect_uri=$APP_REDIRECT")
  jq -r '.access_token' <<<"$response" | cut -d. -f2 | tr '_-' '/+' | awk '{ while (length($0) % 4) $0 = $0 "="; print }' \
    | base64 -d 2>/dev/null | jq -S -c .
}

user_by_email() {
  kcadm get users -r "$REALM" -q "email=$1" -q exact=true -q briefRepresentation=false
}

person() { # person USERNAME EMAIL -> id; an account with a password
  jq -n --arg username "$1" --arg email "$2" --arg password "$PASSWORD" '{
      username: $username, enabled: true, firstName: "Kod", lastName: "Kişi", emailVerified: true, email: $email,
      credentials: [{type: "password", value: $password, temporary: false}]}' \
    | kcadm create users -r "$REALM" -i -f -
}

# sign_up_new ADDRESS FIRST LAST LABEL: the whole sign-up of a new address in a fresh browser; lands
# in the application. Prints nothing; APP_CODE is the application's code.
sign_up_new() {
  local before code address
  address=$(tr '[:upper:]' '[:lower:]' <<<"$1")
  open_code_page "$4"
  before=$(code_count "$address")
  ask_code "$1"
  code=$(await_code "$address" "$before" signup)
  CODES+=("$code")
  ADDRESSES+=("$address")
  type_code "$code"
  on_form kc-email-code-sign-up-form || fail "$4: the right sign-up code did not open the form ($(page_summary))"
  sign_up "$2" "$3"
  finish
  [[ $LANDED == app ]] || fail "$4: the sign-up did not reach the application ($(page_summary))"
}

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='SPI jar'
[[ -n $IMAGE ]] || fail 'Dockerfile has no ARG KEYCLOAK_IMAGE'
command -v jq >/dev/null || fail 'jq is required'
SPI_JAR=${SIGN_UP_BY_EMAIL_CODE_SPI_JAR:-}
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
grep -q 'com/skylab/account/EmailCodeSignUp.class' <<<"$spi_listing" || fail 'the SPI jar does not hold the sign-up branch'
grep -q 'theme-resources/templates/sky-email-code-sign-up.ftl' <<<"$spi_listing" || fail 'the SPI jar has no sign-up page'
if grep -q 'EmailAddressOwnershipProbe' <<<"$spi_listing"; then
  fail 'the test-only ownership probe leaked into the production SPI jar'
fi

# A separate test-only jar exposes deterministic transaction barriers. It never enters spi/ or the
# production image: only this throwaway Keycloak mounts it, and it additionally requires SKY_HARNESS.
CURRENT_STAGE='ownership probe jar'
mkdir -p "$STATE_DIR/ownership-probe"
docker run --rm --memory 512m --user "$(id -u):$(id -g)" --entrypoint bash \
  -v "$SPI_JAR:/fixture/spi.jar:ro" \
  -v "$SCRIPT_DIR/fixtures/EmailAddressOwnershipProbe.java:/fixture/EmailAddressOwnershipProbe.java:ro" \
  -v "$STATE_DIR/ownership-probe:/out" "$IMAGE" -ec '
    jars=(/opt/keycloak/lib/lib/main/*.jar); IFS=:
    java -m jdk.compiler/com.sun.tools.javac.Main -proc:none -cp "/fixture/spi.jar:${jars[*]}" -d /out /fixture/EmailAddressOwnershipProbe.java
    mkdir -p /out/META-INF/services
    printf "%s\n" com.skylab.account.EmailAddressOwnershipProbe > /out/META-INF/services/org.keycloak.services.resource.RealmResourceProviderFactory
    java -m jdk.jartool/sun.tools.jar.Main --create --file /out/probe.jar -C /out com -C /out META-INF
  '

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='Keycloak start'
[[ -n $MAILPIT_IMAGE ]] || fail 'tests/docker-compose.integration.yml has no Mailpit image'
[[ -n $NODE_IMAGE ]] || fail 'Dockerfile has no ARG NODE_IMAGE'
docker network create "$NETWORK" >/dev/null
docker run --rm -d --name "$MAIL_CONTAINER" --network "$NETWORK" --memory 256m --tmpfs /tmp:rw,size=64m,mode=1777 -p "127.0.0.1:$MAIL_PORT:8025" \
  "$MAILPIT_IMAGE" >/dev/null
docker run --rm -d --name "$SKYMAIL_CONTAINER" --network "$NETWORK" --memory 128m --read-only \
  -e SKYMAIL_HTTP_PORT=8080 -e SKYMAIL_SMTP_PORT=1025 \
  -v "$SCRIPT_DIR/skymail-server.mjs:/fixture/skymail-server.mjs:ro" \
  "$NODE_IMAGE" node /fixture/skymail-server.mjs >/dev/null
docker run --rm -d --name "$CONTAINER" --network "$NETWORK" --memory "$MEMORY" --tmpfs /opt/keycloak/data:rw,size=512m,mode=1777 -p "127.0.0.1:$PORT:$PORT" \
  -e KC_BOOTSTRAP_ADMIN_USERNAME=admin -e KC_BOOTSTRAP_ADMIN_PASSWORD="$ADMIN_PASSWORD" \
  -e SKY_HARNESS=1 -e SKY_MAIL_ENABLED=true -e "SKY_MAIL_BASE_URL=http://$SKYMAIL_CONTAINER:8080" \
  -e SKY_MAIL_CLIENT_ID=keycloak-mailer -e "SKY_MAIL_CLIENT_SECRET=$MAILER_SECRET" -e SKY_MAIL_TIMEOUT_MILLISECONDS=3000 \
  -v "$SPI_JAR:/opt/keycloak/providers/e-skylab-spi.jar:ro" \
  -v "$STATE_DIR/ownership-probe/probe.jar:/opt/keycloak/providers/ownership-probe.jar:ro" \
  -v "$REPOSITORY_ROOT/config:/opt/keycloak/sky-config:ro" \
  "$IMAGE" start-dev --http-port "$PORT" >/dev/null
for _ in $(seq 1 120); do
  curl -fsS "$BASE_URL/realms/master" >/dev/null 2>&1 && break
  sleep 2
done
curl -fsS "$BASE_URL/realms/master" >/dev/null || { docker logs "$CONTAINER" 2>&1 | tail -n 40 >&2; fail "Keycloak did not start ($IMAGE)"; }
sessions_login
printf '    stock Keycloak in dev mode with the SPI jar (%s), SkyMail fixture, Mailpit\n' "$(basename -- "$SPI_JAR")"

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
kcadm create identity-provider/instances -r "$REALM" -f - >/dev/null <<JSON
{"alias": "OBS", "providerId": "oidc", "enabled": true, "trustEmail": true,
 "config": {"clientId": "unused", "clientSecret": "unused", "authorizationUrl": "http://127.0.0.1:9/auth",
   "tokenUrl": "http://127.0.0.1:9/token", "defaultScope": "openid", "disableUserInfo": "true", "validateSignature": "false"}}
JSON
kcadm create clients -r "$REALM" -s "clientId=$APP" -s publicClient=true -s standardFlowEnabled=true \
  -s directAccessGrantsEnabled=false -s "redirectUris=[\"$APP_REDIRECT\"]" >/dev/null
skymail_client=$(kcadm create clients -r "$REALM" -i -s clientId=skymail -s publicClient=false -s bearerOnly=true)
for role in skymail:access skymail:mails:send; do
  kcadm create "clients/$skymail_client/roles" -r "$REALM" -s "name=$role" >/dev/null
done
kcadm create clients -r "$REALM" -s clientId=keycloak-mailer -s publicClient=false -s serviceAccountsEnabled=true \
  -s standardFlowEnabled=false -s directAccessGrantsEnabled=false -s "secret=$MAILER_SECRET" >/dev/null
kcadm add-roles -r "$REALM" --uusername service-account-keycloak-mailer --cclientid skymail \
  --rolename skymail:access --rolename skymail:mails:send >/dev/null

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

operator_id=$(kcadm create users -r "$REALM" -i -s username=sbec-scoped-operator -s enabled=true \
  -s firstName=Scoped -s lastName=Operator -s email=sbec-scoped-operator@example.invalid -s emailVerified=true)
kcadm set-password -r "$REALM" --userid "$operator_id" --new-password "$OPERATOR_PASSWORD" --temporary=false >/dev/null
kcadm add-roles -r "$REALM" --uid "$operator_id" --cclientid realm-management \
  --rolename manage-clients --rolename view-clients --rolename manage-realm --rolename view-realm >/dev/null
SCOPED_READY=1
sessions_login
ada=$(person ada ada@example.invalid)
printf '    e-skylab with the production login settings, User Profile and browser flow shape; ada has an account\n'

# ---------------------------------------------------------------------------------------------------
stage 'reconciler: the sign-up setting'
output=$(reconcile 0)
expect_line "$output" "[reconcile] e-mail code sign-up of flow '$FLOW': unchanged (no $STEP step)" 'keep did not report the missing step'
output=$(reconcile 1 KEYCLOAK_EMAIL_CODE_SIGN_UP=on)
grep -Fq "Flow '$FLOW' has no $STEP step for the sign-up setting; KEYCLOAK_EMAIL_CODE_LOGIN=on adds it" <<<"$output" \
  || { printf '%s\n' "$output" >&2; fail 'on without the step was not refused'; }
flow "$FLOW" | jq -e --arg step "$STEP" 'all(.[]; .providerId != $step)' >/dev/null || fail 'the refused run wrote something'
output=$(reconcile 0 KEYCLOAK_EMAIL_CODE_LOGIN=on)
expect_line "$output" "[reconcile] e-mail code sign-up of flow '$FLOW': unchanged (off; KEYCLOAK_EMAIL_CODE_SIGN_UP=on or off changes it)" \
  'keep did not report the setting off'
STEP_ID=$(exec_id "$STEP")
kcadm get "authentication/executions/$STEP_ID" -r "$REALM" | jq -e '(.authenticatorConfig // "") == ""' >/dev/null \
  || fail 'the sign-in step came with a config'
printf '    keep reports no step, then off; on without the step is refused with nothing written\n'

# ---------------------------------------------------------------------------------------------------
stage 'ownership writes: database transactions'
probe_base="$BASE_URL/realms/$REALM/email-ownership-probe"
for slot in personal email username school signup rollback; do
  label="commit-$slot"
  probe_slot=$slot
  rollback=false
  expected=true
  if [[ $slot == rollback ]]; then probe_slot=personal; rollback=true; expected=false; fi
  if [[ $slot != signup ]]; then person "ownership-$label" "original-$label@example.invalid" >/dev/null; fi
  curl -fsS -X POST "$probe_base/$label/hold?slot=$probe_slot&rollback=$rollback" >"$STATE_DIR/$label.holder" &
  holder_pid=$!
  for _ in $(seq 1 50); do
    curl -fsS "$probe_base/$label" | jq -e '.locked' >/dev/null && break
    sleep 0.1
  done
  curl -fsS "$probe_base/$label" | jq -e '.locked and (.finished | not)' >/dev/null \
    || fail 'the holder did not reach its uncommitted write'
  curl -fsS -X POST "$probe_base/$label/check" >"$STATE_DIR/$label.waiter" &
  waiter_pid=$!
  for _ in $(seq 1 50); do
    curl -fsS "$probe_base/$label" | jq -e '.waiting and .blocked' >/dev/null && break
    sleep 0.1
  done
  curl -fsS "$probe_base/$label" | jq -e '.waiting and .blocked and (.finished | not)' >/dev/null \
    || fail 'another transaction passed the ownership lock before commit/rollback'
  curl -fsS -X POST "$probe_base/$label/release" >/dev/null
  wait "$holder_pid" || fail 'the holder transaction failed'
  wait "$waiter_pid" || fail 'the waiting transaction failed'
  jq -e --argjson expected "$expected" '.before == false and .after == $expected' "$STATE_DIR/$label.waiter" >/dev/null \
    || fail 'the fresh ownership check did not see exactly the committed state'
done
printf '    real independent transactions: wait through uncommitted personal/email/username/school/signup writes; fresh check sees committed holder despite old model; rollback releases lock and leaves address free\n'

# ---------------------------------------------------------------------------------------------------
stage 'Account center ownership writes'
# A test-only account-center client gets a real session bearer. The production client remains PAR
# only; this local fixture allows direct grants to keep these focused API regressions independent.
account_center_id=$(kcadm create clients -r "$REALM" -i -s clientId=account-center -s publicClient=true \
  -s directAccessGrantsEnabled=true -s standardFlowEnabled=false)
kcadm create "clients/$account_center_id/protocol-mappers/models" -r "$REALM" -f - >/dev/null <<'JSON'
{"name":"fixture-account-audience","protocol":"openid-connect","protocolMapper":"oidc-audience-mapper",
 "config":{"included.client.audience":"account","access.token.claim":"true","id.token.claim":"false"}}
JSON
kcadm create "clients/$account_center_id/protocol-mappers/models" -r "$REALM" -f - >/dev/null <<'JSON'
{"name":"fixture-account-role","protocol":"openid-connect","protocolMapper":"oidc-hardcoded-role-mapper",
 "config":{"role":"account.manage-account","access.token.claim":"true","id.token.claim":"false"}}
JSON
person ownership-api api-original@example.invalid >/dev/null
api_token=$(curl -fsS "$BASE_URL/realms/$REALM/protocol/openid-connect/token" \
  --data-urlencode grant_type=password --data-urlencode client_id=account-center \
  --data-urlencode username=ownership-api --data-urlencode "password=$PASSWORD" | jq -er '.access_token')
api_base="$BASE_URL/realms/$REALM/sky-account/v1"
api_sudo=''
api_call() {
  local path=$1 data=$2 expected_status=$3 actual_status
  actual_status=$(curl -sS -X POST "$api_base/$path" -H "Authorization: Bearer $api_token" \
    -H "X-Sky-Sudo: $api_sudo" -H 'Content-Type: application/json' --data "$data" \
    -o "$STATE_DIR/api.body" -w '%{http_code}')
  [[ $actual_status == "$expected_status" ]] || fail "Account center $path returned HTTP $actual_status, expected $expected_status"
}
api_personal_code() {
  local address=$1 task
  for _ in $(seq 1 30); do
    task=$(skymail_records | jq -s -c --arg to "$address" \
      '[.[] | select(.event == "mail_task" and .template_key == "keycloak.personal-email-confirm" and .recipient_email == $to)] | last')
    [[ $task == null ]] || break
    sleep 1
  done
  [[ $task != null ]] || fail 'the personal e-mail code did not arrive'
  jq -er '.body_variables.code | select(test("^[0-9]{6}$"))' <<<"$task"
}
api_call sudo/password "{\"password\":\"$PASSWORD\"}" 200
api_sudo=$(jq -er '.sudoToken' "$STATE_DIR/api.body")
api_call email/change-request '{"address":"api-personal@example.invalid","makePrimary":false}' 202
personal_code=$(api_personal_code api-personal@example.invalid)
CODES+=("$personal_code")
ADDRESSES+=(api-personal@example.invalid)
api_call email/confirm "{\"code\":\"$personal_code\"}" 200
jq -e '.personalEmail == "api-personal@example.invalid" and .personalEmailVerified == true and .email == "api-original@example.invalid"' \
  "$STATE_DIR/api.body" >/dev/null || fail 'a personal-only confirmation changed the primary address'
api_call email/primary '{"which":"personal"}' 200
jq -e '.primary == "personal" and .email == "api-personal@example.invalid" and .emailVerified == true' \
  "$STATE_DIR/api.body" >/dev/null || fail 'the primary address could not be chosen under the ownership lock'
api_call email/change-request '{"address":"api-replaced@example.invalid","makePrimary":true}' 202
personal_code=$(api_personal_code api-replaced@example.invalid)
CODES+=("$personal_code")
ADDRESSES+=(api-replaced@example.invalid)
api_call email/confirm "{\"code\":\"$personal_code\"}" 200
jq -e '.primary == "personal" and .email == "api-replaced@example.invalid" and .personalEmail == "api-replaced@example.invalid"' \
  "$STATE_DIR/api.body" >/dev/null || fail 'confirmation plus primary replacement could not reenter the transaction lock'
api_call email/change-request '{"address":"api-race@example.invalid","makePrimary":false}' 202
personal_code=$(api_personal_code api-race@example.invalid)
CODES+=("$personal_code")
ADDRESSES+=(api-race@example.invalid)
# This conflicting holder is committed between the change request and its final confirmation.
person ownership-api-race api-race@example.invalid >/dev/null
api_call email/confirm "{\"code\":\"$personal_code\"}" 409
jq -e '.code == "email_taken"' "$STATE_DIR/api.body" >/dev/null || fail 'a final ownership conflict did not return email_taken'
unset api_token api_sudo personal_code
printf '    real Account center bearer+sudo: personal-only confirm, choose primary, nested confirm+primary replacement; final ownership conflict refused with 409\n'

# ---------------------------------------------------------------------------------------------------
stage 'off: nobody is mailed'
open_code_page off-unknown
ask_code nobody-off@example.invalid
sleep 4
(($(code_count nobody-off@example.invalid) == 0)) || fail 'a code was mailed to an address without an account while sign-up is off'
printf '    sign-up off: an address that names nobody is mailed nothing\n'

# ---------------------------------------------------------------------------------------------------
stage 'reconciler: on'
output=$(reconcile 0 KEYCLOAK_EMAIL_CODE_SIGN_UP=on)
expect_line "$output" "[reconcile] e-mail code sign-up of flow '$FLOW': updated (off -> on)" 'on did not turn sign-up on'
config_id=$(kcadm get "authentication/executions/$STEP_ID" -r "$REALM" | jq -er '.authenticatorConfig')
kcadm get "authentication/config/$config_id" -r "$REALM" \
  | jq -e --arg alias "$CONFIG_ALIAS" '.alias == $alias and .config == {"sign-up": "true"}' >/dev/null \
  || fail 'the step has not the sign-up config'
output=$(reconcile 0 KEYCLOAK_EMAIL_CODE_SIGN_UP=on)
expect_line "$output" "[reconcile] e-mail code sign-up of flow '$FLOW': unchanged (on)" 'a second on changed something'
output=$(reconcile 0)
expect_line "$output" "[reconcile] e-mail code sign-up of flow '$FLOW': unchanged (on; KEYCLOAK_EMAIL_CODE_SIGN_UP=on or off changes it)" \
  'keep did not report the setting on'
kcadm get "realms/$REALM" | jq -e '.registrationAllowed == false' >/dev/null || fail "Keycloak's own registration page went on"
printf '    on adds the step config (sign-up=true) with the reconciler identity; again unchanged; registrationAllowed stays false\n'

# ---------------------------------------------------------------------------------------------------
stage 'a new address opens an account'
sign_up_new Yeni.Kisi@example.invalid '  Ayşe ' 'Yılmaz' yeni
claims=$(token_claims)
account=$(user_by_email yeni.kisi@example.invalid)
[[ $(jq length <<<"$account") == 1 ]] || fail 'not exactly one account for the address'
account=$(jq -c '.[0]' <<<"$account")
new_id=$(jq -r '.id' <<<"$account")
jq -e '.username == "ayse.yilmaz" and .email == "yeni.kisi@example.invalid" and .emailVerified == true and .enabled == true
    and .firstName == "Ayşe" and .lastName == "Yılmaz"
    and .attributes.personalEmail == ["yeni.kisi@example.invalid"]
    and (.attributes.personalEmailVerifiedAt[0] | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    and ((.requiredActions // []) == [])' <<<"$account" >/dev/null \
  || { jq -c '{username, email, emailVerified, firstName, lastName, attributes, requiredActions}' <<<"$account" >&2; fail 'the account is not the proven address, the names and the derived username'; }
[[ $(kcadm get "users/$new_id/credentials" -r "$REALM" | jq length) == 0 ]] || fail 'the new account has a credential'
[[ $(kcadm get "users/$new_id/groups" -r "$REALM" | jq length) == 0 ]] || fail 'the new account is in a group'
kcadm get "users/$new_id/role-mappings/realm" -r "$REALM" | jq -e 'map(.name) == ["default-roles-e-skylab"]' >/dev/null \
  || fail 'the new account has realm roles beyond the defaults'
[[ $(kcadm get "users/$new_id/role-mappings" -r "$REALM" | jq '.clientMappings // {} | length') == 0 ]] \
  || fail 'the new account has client roles'
kcadm get events -r "$REALM" -q type=REGISTER -q "user=$new_id" \
  | jq -e 'length == 1 and .[0].details.register_method == "email_code" and .[0].details.sky_method == "email_code"
      and .[0].details.username == "ayse.yilmaz"' >/dev/null || fail 'no REGISTER event with register_method and sky_method email_code'
kcadm get events -r "$REALM" -q type=LOGIN -q "user=$new_id" | jq -e '.[0].details.sky_method == "email_code"' >/dev/null \
  || fail 'the LOGIN event after the sign-up does not say sky_method=email_code'
jq -e --arg sub "$new_id" '.sub == $sub and .email == "yeni.kisi@example.invalid" and .email_verified == true
    and .given_name == "Ayşe" and .family_name == "Yılmaz" and .preferred_username == "ayse.yilmaz"
    and (has("school_email") | not) and (has("university") | not)' <<<"$claims" >/dev/null \
  || { printf '%s\n' "$claims" >&2; fail "the token does not carry what core's JIT reads"; }
open_code_page yeni-again
before=$(code_count yeni.kisi@example.invalid)
ask_code YENI.KISI@example.invalid
code=$(await_code yeni.kisi@example.invalid "$before" login)
CODES+=("$code")
type_code "$code"
finish
[[ $LANDED == app ]] || fail "the new account did not sign in with a Login code ($(page_summary))"
printf '    code (purpose=signup) -> form -> account: verified Primary and Personal e-mail, username ayse.yilmaz, no credential, group or extra role; REGISTER and LOGIN events; JIT claims; signs in again by code\n'

# ---------------------------------------------------------------------------------------------------
stage 'usernames and names'
person ada.lovelace someone@example.invalid >/dev/null
sign_up_new private.mailbox@other.invalid Ada Lovelace lovelace
user_by_email private.mailbox@other.invalid | jq -e '.[0].username == "ada.lovelace2"' >/dev/null \
  || fail 'a taken username was not numbered'
open_code_page bad-name
before=$(code_count badname@example.invalid)
ask_code badname@example.invalid
code=$(await_code badname@example.invalid "$before" signup)
CODES+=("$code")
ADDRESSES+=(badname@example.invalid)
type_code "$code"
sign_up '<script>' 'Yılmaz'
on_form kc-email-code-sign-up-form || fail "a refused name did not keep the form ($(page_summary))"
[[ $(sign_up_error) == first_name_invalid ]] || fail "a prohibited character gave '$(sign_up_error)', not first_name_invalid"
[[ $(user_by_email badname@example.invalid | jq length) == 0 ]] || fail 'an account was opened with a refused name'
sign_up '李' '王'
finish
[[ $LANDED == app ]] || fail "the corrected names did not open the account ($(page_summary))"
user_by_email badname@example.invalid | jq -e '.[0].username == "uye" and .[0].firstName == "李" and .[0].lastName == "王"' >/dev/null \
  || fail 'valid Unicode names were not preserved with a neutral username'
printf '    names determine the username independently of the address; collisions get a number; prohibited names open nothing; Unicode names keep their profile with a neutral username\n'

# ---------------------------------------------------------------------------------------------------
stage 'the same page for an address with and without an account'
# time_send LABEL IDENTIFIER: "Kod gönder" in a fresh browser; TAKEN is its seconds, BODY its page.
TAKEN=''
time_send() {
  open_code_page "$1"
  TAKEN=$(curl -s -o "$STATE_DIR/timed.body" -w '%{time_total}' --cookie "$JAR" --cookie-jar "$JAR" \
    --data-urlencode "username=$2" --data-urlencode sky-email-code-action=send "$(form_action kc-email-code-identifier-form)")
  BODY=$(cat "$STATE_DIR/timed.body")
  LANDED=page
  on_form kc-email-code-form || fail "$1: asking a code did not show the code page ($(page_summary))"
}
median() { printf '%s\n' "$@" | sort -n | awk '{ a[NR] = $1 } END { print (NR % 2 ? a[(NR + 1) / 2] : (a[NR / 2] + a[NR / 2 + 1]) / 2) }'; }
known_times=()
unknown_times=()
for i in 1 2 3 4 5 6; do
  person "timing-known-$i" "timing-known-$i@example.invalid" >/dev/null
  time_send "known-$i" "timing-known-$i@example.invalid"
  known_page=$(page_shape)
  known_times+=("$TAKEN")
  time_send "unknown-$i" "timing-new-$i@example.invalid"
  unknown_times+=("$TAKEN")
  [[ $known_page == "$(page_shape)" ]] \
    || { printf 'known:   %s\nunknown: %s\n' "$known_page" "$(page_shape)" >&2; fail 'the code page tells an address without an account apart'; }
  ADDRESSES+=("timing-known-$i@example.invalid" "timing-new-$i@example.invalid")
done
[[ $known_page == *'id="kc-email-code-form"'* && $known_page == *'data-sky-email-code-resend-after='* ]] \
  || fail "the code page has not the expected shape ($known_page)"
sleep 4
for i in 1 2 3 4 5 6; do
  (($(code_count "timing-known-$i@example.invalid") == 1 && $(code_count "timing-new-$i@example.invalid") == 1)) \
    || fail 'an address with or without an account did not get exactly one code'
done
printf '    same ids and data attributes with and without an account; "Kod gönder" median %ss (account, Login code) vs %ss (none, sign-up code), 6 each\n' \
  "$(median "${known_times[@]}")" "$(median "${unknown_times[@]}")"

# ---------------------------------------------------------------------------------------------------
stage '"Hesap aç" for an address that has an account'
open_code_page hesap-ac sign-up
before=$(code_count ada@example.invalid)
ask_code ada@example.invalid
code=$(await_code ada@example.invalid "$before" login)
CODES+=("$code")
type_code "$code"
on_form kc-email-code-sign-up-existing-form || fail "'Hesap aç' with an account did not show the existing stage ($(page_summary))"
grep -Fq 'Bu adresle zaten hesabın vardı, giriş yaptın.' <<<"$BODY" || fail 'the existing stage does not say ticket 09 sentence'
follow "$JAR" "$(form_action kc-email-code-sign-up-existing-form)" --data-urlencode sky-email-code-action=continue
finish
[[ $LANDED == app ]] || fail "'Devam et' did not sign in ($(page_summary))"
token_claims | jq -e --arg sub "$ada" '.sub == $sub' >/dev/null || fail "'Hesap aç' signed in someone other than ada"
[[ $(user_by_email ada@example.invalid | jq length) == 1 ]] || fail "'Hesap aç' opened a second account"
open_code_page plain
before=$(code_count ada@example.invalid)
ask_code ada
code=$(await_code ada@example.invalid "$before" login)
CODES+=("$code")
type_code "$code"
finish
[[ $LANDED == app ]] || fail "without 'Hesap aç' the code did not sign in directly ($(page_summary))"
printf "    'Hesap aç' + an account: Login code, the existing stage, 'Devam et' signs ada in, no second account; plain sign-in has no stage\n"

# ---------------------------------------------------------------------------------------------------
stage 'a YTÜ school address'
open_code_page ytu
before=$(code_count yeni.ogrenci@std.yildiz.edu.tr)
ask_code Yeni.Ogrenci@STD.yildiz.edu.tr
code=$(await_code yeni.ogrenci@std.yildiz.edu.tr "$before" signup)
CODES+=("$code")
ADDRESSES+=(yeni.ogrenci@std.yildiz.edu.tr)
type_code "$code"
on_form kc-email-code-sign-up-ytu-form || fail "a school address did not get the YTÜ stage ($(page_summary))"
grep -Eq 'id="sky-sign-up-ytu" href="[^"]*/broker/OBS/login' <<<"$BODY" || fail 'the YTÜ stage has no OBS sign-in link'
[[ $(user_by_email yeni.ogrenci@std.yildiz.edu.tr | jq length) == 0 ]] || fail 'an account was opened for a school address'
kcadm get events -r "$REALM" -q type=REGISTER_ERROR | jq -e 'any(.[]; .details.sky_email_code == "school_domain" and .ipAddress == null)' >/dev/null \
  || fail 'no REGISTER_ERROR school_domain event without the IP'
printf '    a school address: sign-up code, then the YTÜ stage with the OBS link; no account; REGISTER_ERROR school_domain\n'

# ---------------------------------------------------------------------------------------------------
stage 'two sign-ups of one address at once'
race_jars=()
race_actions=()
for side in a b; do
  open_code_page "race-$side"
  before=$(code_count race@example.invalid)
  ask_code race@example.invalid
  code=$(await_code race@example.invalid "$before" signup)
  CODES+=("$code")
  type_code "$code"
  on_form kc-email-code-sign-up-form || fail "race $side: no form ($(page_summary))"
  race_jars+=("$JAR")
  race_actions+=("$(form_action kc-email-code-sign-up-form)")
done
ADDRESSES+=(race@example.invalid)
for side in 0 1; do
  curl -s -o "$STATE_DIR/race-$side.body" -w '%{http_code}' --cookie "${race_jars[$side]}" --cookie-jar "${race_jars[$side]}" \
    --data-urlencode firstName=Yarış --data-urlencode lastName=Kişi --data-urlencode sky-email-code-action=sign-up \
    "${race_actions[$side]}" >"$STATE_DIR/race-$side.status" &
done
wait
for side in 0 1; do
  [[ $(cat "$STATE_DIR/race-$side.status") != 5* ]] || fail "race $side: a server error"
done
[[ $(user_by_email race@example.invalid | jq length) == 1 ]] || fail 'two sign-ups of one address opened two accounts'
printf '    two sign-ups of one address at the same moment: one account, no server error\n'

# ---------------------------------------------------------------------------------------------------
stage 'SkyMail refuses: the SMTP fallback'
open_code_page fallback-tr
before=$(mail_count skymail-fallback@example.invalid)
ask_code skymail-fallback@example.invalid
code=$(await_smtp_code skymail-fallback@example.invalid "$before" 'hesabını açmak için kodun')
CODES+=("$code")
ADDRESSES+=(skymail-fallback@example.invalid)
type_code "$code"
on_form kc-email-code-sign-up-form || fail "the SMTP code did not open the form ($(page_summary))"
open_code_page fallback-en
before=$(mail_count skymail-fallback@example.org)
ask_code skymail-fallback@example.org --header 'Accept-Language: en'
code=$(await_smtp_code skymail-fallback@example.org "$before" 'create your')
CODES+=("$code")
ADDRESSES+=(skymail-fallback@example.org)
docker logs "$CONTAINER" >"$STATE_DIR/server.log" 2>&1
grep -Fq 'sky_mail_fallback reason=unavailable template=keycloak.login-code' "$STATE_DIR/server.log" \
  || fail 'the fallback left no sky_mail_fallback line'
! grep -Eq 'sky_mail_fallback reason=(config|token|disabled)' "$STATE_DIR/server.log" \
  || fail 'a mail fell back for want of a token or a configuration'
! grep -Fq 'sky_email_code_send_failed' "$STATE_DIR/server.log" || fail 'a sign-up code could not be sent'
printf '    SkyMail refused: the sign-up code came through SMTP with the sign-up text, Turkish or English as the page was\n'

# ---------------------------------------------------------------------------------------------------
stage 'the server log'
remote=$(kcadm get events -r "$REALM" -q type=LOGIN -q "user=$new_id" | jq -r '.[0].ipAddress // ""')
docker logs "$CONTAINER" >"$STATE_DIR/server.log" 2>&1
for code in "${CODES[@]}"; do
  ! grep -Fq "$code" "$STATE_DIR/server.log" || fail 'a code reached the server log'
done
for address in "${ADDRESSES[@]}" nobody-off@example.invalid; do
  ! grep -Fiq "$address" "$STATE_DIR/server.log" || fail 'an address of the run reached the server log'
done
[[ -n $remote ]] || fail 'no client IP in the LOGIN event to look for'
! grep -Fq "$remote" "$STATE_DIR/server.log" || fail "the client's IP reached the server log"
printf '    no code, no address of the run and not the client IP in the server log\n'

# ---------------------------------------------------------------------------------------------------
stage 'off'
output=$(reconcile 0 KEYCLOAK_EMAIL_CODE_SIGN_UP=off)
expect_line "$output" "[reconcile] e-mail code sign-up of flow '$FLOW': updated (on -> off)" 'off did not turn sign-up off'
output=$(reconcile 0 KEYCLOAK_EMAIL_CODE_SIGN_UP=off)
expect_line "$output" "[reconcile] e-mail code sign-up of flow '$FLOW': unchanged (off)" 'a second off changed something'
open_code_page off-again
ask_code nobody-off-again@example.invalid
sleep 4
(($(code_count nobody-off-again@example.invalid) == 0)) || fail 'a sign-up code was mailed after off'
open_code_page yeni-after-off
before=$(code_count yeni.kisi@example.invalid)
ask_code ayse.yilmaz
code=$(await_code yeni.kisi@example.invalid "$before" login)
type_code "$code"
finish
[[ $LANDED == app ]] || fail "an account opened by sign-up did not sign in after off ($(page_summary))"
printf '    off: no sign-up code any more; the accounts opened stay and sign in\n'

printf 'sign-up-by-email-code: all checks passed\n'
