#!/usr/bin/env bash
# Real-Keycloak contract for the sky-account SPI (/realms/{realm}/sky-account/v1).
# Invoked by run-integration.sh once the reconciled realm, the account-center client and the
# fixture user exist. Inputs: SKY_ACCOUNT_COMPOSE_FILE, SKY_ACCOUNT_ADMIN_CONFIG,
# SKY_ACCOUNT_CLIENT_SECRET, TEST_STATE_DIR. Leaves the fixture user as it found it.
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
COMPOSE_FILE=${SKY_ACCOUNT_COMPOSE_FILE:?set SKY_ACCOUNT_COMPOSE_FILE}
ADMIN_CONFIG=${SKY_ACCOUNT_ADMIN_CONFIG:?set SKY_ACCOUNT_ADMIN_CONFIG}
CLIENT_SECRET=${SKY_ACCOUNT_CLIENT_SECRET:?set SKY_ACCOUNT_CLIENT_SECRET}
STATE_DIR=${TEST_STATE_DIR:?set TEST_STATE_DIR}
BASE_URL=${SKY_ACCOUNT_BASE_URL:-http://localhost:18080}
REALM=${SKY_ACCOUNT_REALM:-e-skylab-test}
API="$BASE_URL/realms/$REALM/sky-account/v1"
TOKEN_URL="$BASE_URL/realms/$REALM/protocol/openid-connect/token"
CALLBACK=https://my.yildizskylab.com/api/auth/callback
FIXTURE_USER_UUID=11111111-1111-4111-8111-111111111111
FIXTURE_USERNAME=account-fixture
FIXTURE_PASSWORD=fixture-password-change-me
ROTATED_PASSWORD=fixture-password-rotated-by-sky-account
TAKEN_USERNAME=taken.fixture
CHANGED_USERNAME=sky.fixture
REAUTH_USERNAME=reauth-fixture
REAUTH_PASSWORD=reauth-password-change-me
REAUTH_ROTATED_PASSWORD=reauth-password-set-after-authentication
EMAIL_USERNAME=email-fixture
EMAIL_OTHER_USERNAME=email-other
EMAIL_SCHOOL_ADDRESS=email-fixture@std.yildiz.edu.tr
EMAIL_OTHER_SCHOOL_ADDRESS=email-other@std.yildiz.edu.tr
EMAIL_OTHER_PRIMARY_ADDRESS=email-other@example.invalid
EMAIL_PERSONAL_ADDRESS=email-fixture-personal@example.invalid
EMAIL_OTHER_PERSONAL_ADDRESS=email-other-personal@example.invalid
EMAIL_TAKEN_PERSONAL_ADDRESS=taken-personal@example.invalid
MAILPIT_URL=${SKY_ACCOUNT_MAILPIT_URL:-http://localhost:18025}
COMPOSE=(docker compose -f "$COMPOSE_FILE")
CURRENT_STAGE='sky-account fixture'
TOTP_USED_STEPS_FILE="$STATE_DIR/sky-account-totp-steps"
: >"$TOTP_USED_STEPS_FILE"

fail() {
  printf 'sky-account contract failure during %s: %s\n' "$CURRENT_STAGE" "$1" >&2
  "${COMPOSE[@]}" logs --no-color --tail=40 keycloak >&2 || true
  exit 1
}
trap 'status=$?; printf "sky-account command failed during %s (line %s)\n" "$CURRENT_STAGE" "$LINENO" >&2; exit "$status"' ERR

kcadm() {
  local command=$1
  shift
  "${COMPOSE[@]}" exec -T keycloak /opt/keycloak/bin/kcadm.sh "$command" --config "$ADMIN_CONFIG" "$@"
}

json_assert() {
  local json=$1
  local expression=$2
  local message=$3
  shift 3
  jq -e "$@" "$expression" <<<"$json" >/dev/null || fail "$message"
}

decode_jwt_segment() {
  local segment
  segment=$(cut -d. -f"$2" <<<"$1")
  case $((${#segment} % 4)) in
    2) segment="${segment}==" ;;
    3) segment="${segment}=" ;;
  esac
  tr '_-' '/+' <<<"$segment" | base64 --decode
}

# sky <method> <path> <bearer|-> <sudo|-> [json body] -> SKY_STATUS, SKY_BODY, SKY_HEADERS (file)
sky() {
  local method=$1 path=$2 bearer=$3 sudo=$4 body=${5:-}
  local args=(--silent --show-error --request "$method"
    --output "$STATE_DIR/sky-account.body"
    --dump-header "$STATE_DIR/sky-account.headers"
    --write-out '%{http_code}')
  [[ $bearer != - ]] && args+=(--header "Authorization: Bearer $bearer")
  [[ $sudo != - ]] && args+=(--header "X-Sky-Sudo: $sudo")
  if [[ -n $body ]]; then
    args+=(--header 'Content-Type: application/json' --data-binary "$body")
  fi
  SKY_STATUS=$(curl "${args[@]}" "$API/$path")
  SKY_BODY=$(cat "$STATE_DIR/sky-account.body")
  SKY_HEADERS="$STATE_DIR/sky-account.headers"
}

# expect <status> <problem code or -> <message>: never echoes a body, only its problem code.
expect() {
  local status=$1 code=$2 message=$3 actual_code
  actual_code=$(jq -r '.code // "-"' <<<"$SKY_BODY" 2>/dev/null || printf -- '-')
  [[ $SKY_STATUS == "$status" ]] \
    || fail "$message (expected HTTP $status, got $SKY_STATUS code=$actual_code)"
  if [[ $code != - ]]; then
    [[ $actual_code == "$code" ]] || fail "$message (expected code $code, got $actual_code)"
    grep -Eiq '^content-type:[[:space:]]*application/problem\+json' "$SKY_HEADERS" \
      || fail "$message (problem responses must be application/problem+json)"
    json_assert "$SKY_BODY" '(.detail | type) == "string" and (.detail | length) > 0 and .status == ($status | tonumber) and (.type | startswith("tag:yildizskylab.com,2026:sky-account:"))' \
      "$message (RFC 7807 shape)" --arg status "$status"
  fi
}

header_value() {
  awk -v name="$1" '
    tolower($1) == tolower(name) ":" {
      sub(/^[^:]*:[[:space:]]*/, "")
      sub(/\r$/, "")
      print
      exit
    }
  ' "$SKY_HEADERS"
}

# browser_login <label> <password> [otp code] [username]
#   -> LOGIN_ACCESS_TOKEN, LOGIN_ID_TOKEN, LOGIN_SESSION_ID
browser_login() {
  local label=$1 password=$2 otp=${3:-} username=${4:-$FIXTURE_USERNAME}
  local verifier challenge par request_uri request_uri_query cookies page action headers redirect code tokens id_payload
  verifier="sky-account-$label-verifier-0123456789abcdefghijklmnopqrstuvwxyz"
  challenge=$(printf '%s' "$verifier" | openssl dgst -binary -sha256 | openssl base64 -A | tr '+/' '-_' | tr -d '=')
  par=$(curl --fail --silent --show-error \
    --user "account-center:$CLIENT_SECRET" \
    --data-urlencode client_id=account-center \
    --data-urlencode response_type=code \
    --data-urlencode scope=openid \
    --data-urlencode "redirect_uri=$CALLBACK" \
    --data-urlencode "code_challenge=$challenge" \
    --data-urlencode code_challenge_method=S256 \
    --data-urlencode "state=$label-state" \
    --data-urlencode "nonce=$label-nonce" \
    "$BASE_URL/realms/$REALM/protocol/openid-connect/ext/par/request")
  request_uri=$(jq -r .request_uri <<<"$par")
  request_uri_query=$(jq -rn --arg value "$request_uri" '$value | @uri')
  cookies="$STATE_DIR/sky-account-$label.cookies"
  rm -f "$cookies"
  page=$(curl --fail --silent --show-error --location \
    --cookie-jar "$cookies" --cookie "$cookies" \
    "$BASE_URL/realms/$REALM/protocol/openid-connect/auth?client_id=account-center&request_uri=$request_uri_query")
  action=$(login_action_of "$page")
  headers="$STATE_DIR/sky-account-$label.headers"
  local status
  status=$(curl --silent --show-error \
    --output "$STATE_DIR/sky-account-$label.page" \
    --dump-header "$headers" \
    --write-out '%{http_code}' \
    --cookie-jar "$cookies" --cookie "$cookies" \
    --data-urlencode "username=$username" \
    --data-urlencode "password=$password" \
    --data-urlencode credentialId= \
    "$action")
  if [[ -n $otp ]]; then
    [[ $status == 200 ]] || fail "browser login $label did not reach the OTP form (HTTP $status)"
    grep -Fq 'name="otp"' "$STATE_DIR/sky-account-$label.page" \
      || grep -Fq '"login-otp.ftl"' "$STATE_DIR/sky-account-$label.page" \
      || fail "browser login $label did not render the OTP form"
    action=$(login_action_of "$(cat "$STATE_DIR/sky-account-$label.page")")
    status=$(curl --silent --show-error \
      --output "$STATE_DIR/sky-account-$label.page" \
      --dump-header "$headers" \
      --write-out '%{http_code}' \
      --cookie-jar "$cookies" --cookie "$cookies" \
      --data-urlencode "otp=$otp" \
      "$action")
  fi
  [[ $status == 302 ]] || fail "browser login $label did not redirect (HTTP $status)"
  redirect=$(awk 'tolower($1) == "location:" { sub(/^[^:]*:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit }' "$headers")
  [[ $redirect == "$CALLBACK"?* ]] || fail "browser login $label redirected outside the callback"
  code=$(sed -n 's/.*[?&]code=\([^&]*\).*/\1/p' <<<"$redirect")
  [[ -n $code ]] || fail "browser login $label returned no authorization code"
  tokens=$(curl --fail --silent --show-error \
    --user "account-center:$CLIENT_SECRET" \
    --data-urlencode grant_type=authorization_code \
    --data-urlencode client_id=account-center \
    --data-urlencode "code=$code" \
    --data-urlencode "redirect_uri=$CALLBACK" \
    --data-urlencode "code_verifier=$verifier" \
    "$TOKEN_URL")
  LOGIN_ACCESS_TOKEN=$(jq -r .access_token <<<"$tokens")
  LOGIN_ID_TOKEN=$(jq -r .id_token <<<"$tokens")
  id_payload=$(decode_jwt_segment "$LOGIN_ID_TOKEN" 2)
  LOGIN_SESSION_ID=$(jq -r .sid <<<"$id_payload")
  [[ -n $LOGIN_ACCESS_TOKEN && $LOGIN_ACCESS_TOKEN != null && -n $LOGIN_SESSION_ID ]] \
    || fail "browser login $label did not yield an access token with a session id"
}

login_action_of() {
  local literal
  literal=$(grep -Eo '"loginAction"[[:space:]]*:[[:space:]]*"[^"]*"' <<<"$1" | head -n 1 \
    | sed -E 's/^"loginAction"[[:space:]]*:[[:space:]]*//')
  [[ -n $literal ]] || fail 'login page did not expose a login action'
  jq -r . <<<"$literal"
}

# skyapp_access_token <username> <password> -> the decoded payload of a fresh skyapp access
# token. The account-center client keeps only its own two default scopes, so the e-mail claim
# every other service sees is read here instead.
skyapp_access_token() {
  local grant token
  grant=$(curl --silent --show-error \
    --data-urlencode grant_type=password \
    --data-urlencode client_id=skyapp \
    --data-urlencode "username=$1" \
    --data-urlencode "password=$2" \
    --data-urlencode scope=openid \
    "$TOKEN_URL")
  token=$(jq -r '.access_token // empty' <<<"$grant")
  [[ -n $token ]] || fail 'a fresh skyapp token could not be obtained'
  decode_jwt_segment "$token" 2
}

# direct_grant_status <password> [username]
direct_grant_status() {
  curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
    --data-urlencode grant_type=password \
    --data-urlencode client_id=skyapp \
    --data-urlencode "username=${2:-$FIXTURE_USERNAME}" \
    --data-urlencode "password=$1" \
    --data-urlencode scope=openid \
    "$TOKEN_URL"
}

brute_force_state() {
  kcadm get "attack-detection/brute-force/users/$FIXTURE_USER_UUID" -r "$REALM" -c
}

wait_for_failures() {
  local expected=$1 attempt state
  for attempt in $(seq 1 40); do
    state=$(brute_force_state)
    if [[ $(jq -r '.numFailures' <<<"$state") -ge $expected ]]; then
      printf '%s' "$state"
      return 0
    fi
    sleep 0.5
  done
  fail "brute-force protector did not record $expected failure(s)"
}

# user_events <type> [user uuid]
user_events() {
  kcadm get events -r "$REALM" -c -q "user=${2:-$FIXTURE_USER_UUID}" -q "type=$1" -q max=100
}

# totp_code <base32 secret> <step offset> -> code for that 30-second step. Used steps are
# recorded in a file (the calls run in command substitutions) so no code is presented twice:
# Keycloak refuses a reused code inside its look-ahead window.
totp_code() {
  local step=$(( $(date -u +%s) / 30 + $2 ))
  printf '%s\n' "$step" >>"$TOTP_USED_STEPS_FILE"
  node "$SCRIPT_DIR/totp-code.mjs" "$1" "@$step"
}

# The next step (+1) stays inside Keycloak's look-ahead window even if the clock ticks over
# between generating and validating; when that step was already used, wait for the next one.
fresh_totp_offset() {
  local now
  now=$(date -u +%s)
  if grep -qx "$(( now / 30 + 1 ))" "$TOTP_USED_STEPS_FILE"; then
    sleep $(( 30 - now % 30 + 1 ))
  fi
  printf '1'
}

# The harness mail sink (tests/docker-compose.integration.yml service "mailpit"): every mail
# the realm sends lands here instead of a real mailbox. Neither address nor code is printed.
mailpit_reset() {
  curl --fail --silent --show-error --request DELETE "$MAILPIT_URL/api/v1/messages" >/dev/null
}

# mailpit_message_id <address> -> the newest message delivered to that address
mailpit_message_id() {
  local address=$1 attempt messages id
  for attempt in $(seq 1 30); do
    messages=$(curl --fail --silent --show-error "$MAILPIT_URL/api/v1/messages?limit=50") || messages='{"messages":[]}'
    id=$(jq -r --arg to "$address" \
      'first(.messages[]? | select(any(.To[]?; .Address == $to)) | .ID) // empty' <<<"$messages")
    if [[ -n $id ]]; then
      printf '%s' "$id"
      return 0
    fi
    sleep 1
  done
  fail 'no personal e-mail confirmation reached the mail sink'
}

# confirmation_code_of <message id> -> the six-digit code of the verification mail. The mail
# must carry the code and no link: a link would work outside the requester's session (ADR-0044).
confirmation_code_of() {
  local message code
  message=$(curl --fail --silent --show-error "$MAILPIT_URL/api/v1/message/$1")
  jq -e '(.Subject == "Kişisel e-posta adresini doğrula") and (.HTML | length) > 0 and (.Text | length) > 0' \
    <<<"$message" >/dev/null \
    || fail 'the confirmation mail is not the SKY LAB template with a resolved Turkish subject'
  # jq alone, no pipes: under pipefail an early-exiting grep -q can fail the pipeline by SIGPIPE.
  jq -e '((.Text // "") + (.HTML // "")) | contains("email/confirm") | not' <<<"$message" >/dev/null \
    || fail 'the confirmation mail must not carry a confirmation link'
  jq -e '(.Text // "") | contains("kimseyle paylaşma")' <<<"$message" >/dev/null \
    || fail 'the confirmation mail must tell the person never to share the code'
  code=$(jq -r '[(.HTML // "") | scan(">\\s*([0-9]{6})\\s*</div>")][0][0] // empty' <<<"$message")
  if [[ -z $code ]] || ! jq -e --arg code "$code" \
      '(.Text // "") | test("(^|[^0-9])" + $code + "([^0-9]|$)")' <<<"$message" >/dev/null; then
    # Digits masked: the shape of the mail is what explains a failure, not the code.
    jq -r '"text: " + ((.Text // "") | gsub("[0-9]"; "#") | .[0:600]),
           "html: " + ((.HTML // "") | gsub("[0-9]"; "#") | gsub("\\s+"; " ") | .[0:600])' \
      <<<"$message" >&2
    fail 'the confirmation mail must show one six-digit code, the same in the text and the HTML part'
  fi
  printf '%s' "$code"
}

# a_code_other_than <code> -> a six-digit code that is certainly not <code>
a_code_other_than() {
  if [[ $1 == 000000 ]]; then printf '000001'; else printf '000000'; fi
}

# email_person <username> <school address> <primary address> -> EMAIL_USER_UUID, EMAIL_PASSWORD
email_person() {
  local username=$1 school=$2 primary=$3 stale
  while IFS= read -r stale; do
    [[ -n $stale ]] || continue
    kcadm delete "users/$stale" -r "$REALM" >/dev/null
  done < <(kcadm get users -r "$REALM" -c -q "username=$username" -q exact=true | jq -r '.[].id')
  EMAIL_USER_UUID=$(kcadm create users -r "$REALM" -i \
    -s "username=$username" -s enabled=true -s emailVerified=true \
    -s firstName=Email -s lastName=Fixture -s "email=$primary" \
    -s "attributes.schoolEmail=[\"$school\"]")
  EMAIL_PASSWORD=$(openssl rand -base64 24 | tr -d '\n')
  kcadm set-password -r "$REALM" --userid "$EMAIL_USER_UUID" \
    --new-password "$EMAIL_PASSWORD" --temporary=false >/dev/null
}

# ---------------------------------------------------------------------------------------
CURRENT_STAGE='sky-account fixture'
user_profile_before=$(kcadm get users/profile -r "$REALM" -c)
jq '.unmanagedAttributePolicy = "ADMIN_EDIT"' <<<"$user_profile_before" \
  | kcadm update users/profile -r "$REALM" -f - >/dev/null
kcadm update "users/$FIXTURE_USER_UUID" -r "$REALM" \
  -s 'attributes.schoolEmail=["fixture@std.yildiz.edu.tr"]' \
  -s 'attributes.personalEmail=["account-fixture@example.invalid"]' >/dev/null
realm_before=$(kcadm get "realms/$REALM" -c \
  | jq -c '{bruteForceProtected, failureFactor, permanentLockout, passwordPolicy: (.passwordPolicy // ""), editUsernameAllowed}')
[[ $(jq -r .editUsernameAllowed <<<"$realm_before") == false ]] \
  || fail 'the reconciled realm must keep editUsernameAllowed=false so only the SPI changes usernames'
kcadm update "realms/$REALM" \
  -s bruteForceProtected=true \
  -s failureFactor=2 \
  -s permanentLockout=false \
  -s 'passwordPolicy=length(12) and notUsername' >/dev/null
kcadm delete "attack-detection/brute-force/users/$FIXTURE_USER_UUID" -r "$REALM" >/dev/null
# The Chromium stage leaves a TOTP credential behind. The contract starts from a
# password-only account so browser logins and direct grants need no OTP challenge.
while IFS= read -r otp_credential_id; do
  [[ -n $otp_credential_id ]] || continue
  kcadm delete "users/$FIXTURE_USER_UUID/credentials/$otp_credential_id" -r "$REALM" >/dev/null
done < <(kcadm get "users/$FIXTURE_USER_UUID/credentials" -r "$REALM" -c \
  | jq -r '.[] | select(.type == "otp") | .id')
# Idempotent fixture objects, so a rerun on a dirty sandbox realm does not trip here.
kcadm delete identity-provider/instances/OBS -r "$REALM" >/dev/null 2>&1 || true
kcadm create identity-provider/instances -r "$REALM" \
  -s alias=OBS -s providerId=microsoft -s enabled=true \
  -s 'config.clientId=integration-client' -s 'config.clientSecret=integration-secret' >/dev/null
while IFS= read -r stale_user_uuid; do
  [[ -n $stale_user_uuid ]] || continue
  kcadm delete "users/$stale_user_uuid" -r "$REALM" >/dev/null
done < <(kcadm get users -r "$REALM" -c -q "username=$TAKEN_USERNAME" -q exact=true | jq -r '.[].id')
taken_user_uuid=$(kcadm create users -r "$REALM" -i \
  -s "username=$TAKEN_USERNAME" -s enabled=true -s email=taken@example.invalid)

CURRENT_STAGE='sky-account bearer guard'
sky GET identity - -
expect 401 unauthorized 'anonymous request must be refused'
[[ $(header_value WWW-Authenticate) == 'Bearer realm="'"$REALM"'", error="invalid_token"' ]] \
  || fail 'anonymous 401 lacks the WWW-Authenticate challenge'
skyapp_grant=$(curl --silent --show-error \
  --data-urlencode grant_type=password \
  --data-urlencode client_id=skyapp \
  --data-urlencode "username=$FIXTURE_USERNAME" \
  --data-urlencode "password=$FIXTURE_PASSWORD" \
  --data-urlencode scope=openid \
  "$TOKEN_URL")
skyapp_token=$(jq -r '.access_token // empty' <<<"$skyapp_grant")
[[ -n $skyapp_token ]] \
  || fail "skyapp direct grant failed: $(jq -r '.error_description // .error // "no error description"' <<<"$skyapp_grant")"
sky GET identity "$skyapp_token" -
expect 401 unauthorized 'a token issued to another client must be refused'
sky GET identity "not-a-token" -
expect 401 unauthorized 'garbage bearer must be refused'

browser_login a "$FIXTURE_PASSWORD"
token_a=$LOGIN_ACCESS_TOKEN
id_token_a=$LOGIN_ID_TOKEN
session_a=$LOGIN_SESSION_ID
sky GET identity "$token_a" -
expect 200 - 'identity must be readable with an Account Center session'
json_assert "$SKY_BODY" \
  '.sub == $sub and .username == "account-fixture" and .firstName == "Account" and .lastName == "Fixture" and .email == "account-fixture@example.invalid" and .emailVerified == true and .schoolEmail == "fixture@std.yildiz.edu.tr" and .personalEmail == "account-fixture@example.invalid" and .primary == "personal" and .verifiedYtu == false and .nameLocked == false and .usernameChangeAvailableAt == null and .credentials.password == true and .credentials.totp == [] and (.credentials.passkeys | type) == "array"' \
  'identity contract differs' --arg sub "$FIXTURE_USER_UUID"
passkeys_before=$(jq '.credentials.passkeys | length' <<<"$SKY_BODY")
grep -Eiq '^cache-control:[[:space:]]*no-store' "$SKY_HEADERS" || fail 'identity must not be cacheable'

CURRENT_STAGE='sky-account user profile fail-closed'
jq '.unmanagedAttributePolicy = "ENABLED"' <<<"$user_profile_before" \
  | kcadm update users/profile -r "$REALM" -f - >/dev/null
sky PATCH identity/name "$token_a" - '{"firstName":"Ada","lastName":"Lovelace"}'
expect 503 unmanaged_attributes_enabled 'mutations must stop while people may edit unmanaged attributes'
sky GET identity "$token_a" -
expect 200 - 'reads must continue while mutations are paused'
jq '.unmanagedAttributePolicy = "ADMIN_EDIT"' <<<"$user_profile_before" \
  | kcadm update users/profile -r "$REALM" -f - >/dev/null

CURRENT_STAGE='sky-account verified YTÜ lock and name change'
kcadm create "users/$FIXTURE_USER_UUID/federated-identity/OBS" -r "$REALM" \
  -b '{"identityProvider":"OBS","userId":"ms-object-id","userName":"fixture@std.yildiz.edu.tr"}' >/dev/null
sky GET identity "$token_a" -
expect 200 - 'identity must be readable for a linked account'
json_assert "$SKY_BODY" '.verifiedYtu == true and .nameLocked == true' 'OBS link must make the account a Verified YTÜ account'
sky PATCH identity/name "$token_a" - '{"firstName":"Ada","lastName":"Lovelace"}'
expect 403 name_locked 'a Verified YTÜ account must not change its name'
kcadm delete "users/$FIXTURE_USER_UUID/federated-identity/OBS" -r "$REALM" >/dev/null
sky PATCH identity/name "$token_a" - '{"firstName":"Ada<script>","lastName":"Lovelace"}'
expect 400 invalid_name 'prohibited characters must be refused'
json_assert "$SKY_BODY" '.field == "firstName"' 'invalid_name must name the field'
sky PATCH identity/name "$token_a" - '{"firstName":"  Ada ","lastName":"Lovelace-Çelik"}'
expect 200 - 'an unverified account must change its name'
json_assert "$SKY_BODY" '.firstName == "Ada" and .lastName == "Lovelace-Çelik" and .nameLocked == false' 'name change must be trimmed and reflected'
kcadm get "users/$FIXTURE_USER_UUID" -r "$REALM" -c \
  | jq -e '.firstName == "Ada" and .lastName == "Lovelace-Çelik"' >/dev/null \
  || fail 'name change did not persist in Keycloak'
json_assert "$(user_events UPDATE_PROFILE)" \
  '[.[] | select(.clientId == "account-center" and .details.updated_first_name == "Ada" and .details.previous_first_name == "Account")] | length >= 1' \
  'UPDATE_PROFILE event for the name change is missing'

CURRENT_STAGE='sky-account sudo password and brute force'
sky POST sudo/password "$token_a" - '{"password":"definitely-wrong"}'
expect 401 invalid_credentials 'wrong password must be refused'
state=$(wait_for_failures 1)
sky POST sudo/password "$token_a" - '{"password":"definitely-wrong-again"}'
expect 401 invalid_credentials 'second wrong password must be refused'
state=$(wait_for_failures 2)
json_assert "$state" '.numFailures == 2 and .disabled == true' 'two failures must trip the temporary lockout'
sky POST sudo/password "$token_a" - "{\"password\":\"$FIXTURE_PASSWORD\"}"
expect 401 user_temporarily_locked 'a locked account must not obtain sudo even with the right password'
json_assert "$(user_events LOGIN_ERROR)" \
  '([.[] | select(.clientId == "account-center" and .error == "invalid_user_credentials" and .details.auth_method == "sky-account-sudo" and .details.credential_type == "password")] | length >= 2) and ([.[] | select(.clientId == "account-center" and .error == "user_temporarily_disabled")] | length >= 1)' \
  'LOGIN_ERROR events for the sudo failures are missing'
kcadm delete "attack-detection/brute-force/users/$FIXTURE_USER_UUID" -r "$REALM" >/dev/null
sky POST sudo/password "$token_a" - '{"password":"","extra":1}'
expect 400 invalid_request 'unknown fields must be refused'
sky POST sudo/password "$token_a" - "{\"password\":\"$FIXTURE_PASSWORD\"}"
expect 200 - 'the right password must issue a sudo token'
sudo_a=$(jq -r .sudoToken <<<"$SKY_BODY")
now_epoch=$(date -u +%s)
json_assert "$SKY_BODY" \
  '(.sudoToken | type) == "string" and (.expiresAt | fromdateiso8601) > $now + 240 and (.expiresAt | fromdateiso8601) <= $now + 301' \
  'sudo token must expire in five minutes' --argjson now "$now_epoch"
sudo_header=$(decode_jwt_segment "$sudo_a" 1)
json_assert "$sudo_header" '.alg == "HS512" and (.kid | length) > 0' 'sudo token must be an HS512 internal token with a realm key id'
sudo_payload=$(decode_jwt_segment "$sudo_a" 2)
json_assert "$sudo_payload" \
  '.typ == "sky-sudo" and .aud == "sky-account" and .azp == "account-center" and .sub == $sub and .sid == $sid and (.jti | length) > 0 and .amr == ["pwd"] and .iss == ($base + "/realms/" + $realm) and .exp - .iat == 300' \
  'sudo token claims differ' --arg sub "$FIXTURE_USER_UUID" --arg sid "$session_a" --arg base "$BASE_URL" --arg realm "$REALM"
json_assert "$(user_events CUSTOM_REQUIRED_ACTION)" \
  '[.[] | select(.clientId == "account-center" and .sessionId == $sid and .details.action == "sky-sudo" and .details.method == "password")] | length == 1' \
  'exactly one sky-sudo audit event must record the password proof' --arg sid "$session_a"

CURRENT_STAGE='sky-account sudo binding'
browser_login b "$FIXTURE_PASSWORD"
token_b=$LOGIN_ACCESS_TOKEN
session_b=$LOGIN_SESSION_ID
[[ $session_b != "$session_a" ]] || fail 'second login reused the first session'
sky POST credentials/password "$token_b" "$sudo_a" "{\"newPassword\":\"$ROTATED_PASSWORD\",\"logoutOtherSessions\":false}"
expect 401 sudo_required 'a sudo token from another session must be refused'
sky POST credentials/password "$token_a" - "{\"newPassword\":\"$ROTATED_PASSWORD\",\"logoutOtherSessions\":false}"
expect 401 sudo_required 'mutations without a sudo token must be refused'
sky POST credentials/password "$token_a" "$token_a" "{\"newPassword\":\"$ROTATED_PASSWORD\",\"logoutOtherSessions\":false}"
expect 401 sudo_required 'an access token is not a sudo token'
sky POST sudo/password "$token_b" - "{\"password\":\"$FIXTURE_PASSWORD\"}"
expect 200 - 'the second session must obtain its own sudo token'
sudo_b=$(jq -r .sudoToken <<<"$SKY_BODY")
sky POST credentials/password "$token_b" "$sudo_b" '{"newPassword":"short","logoutOtherSessions":false}'
expect 400 password_policy 'a sudo token bound to its own session must be accepted'

# The Microsoft fallback: a person without password, TOTP or passkey re-authenticates on
# Keycloak and the BFF proves that with the ID token of its callback. Budget note: the
# proof shares the `sudo` budget (10 / 15 min per person), which the stages above and the
# rate-limit stage below spend on the fixture user, so this block gets its own throwaway
# person. It logs in twice (two sessions) to prove the session binding.
CURRENT_STAGE='sky-account sudo from a fresh authentication'
while IFS= read -r stale_reauth_user_uuid; do
  [[ -n $stale_reauth_user_uuid ]] || continue
  kcadm delete "users/$stale_reauth_user_uuid" -r "$REALM" >/dev/null
done < <(kcadm get users -r "$REALM" -c -q "username=$REAUTH_USERNAME" -q exact=true | jq -r '.[].id')
reauth_user_uuid=$(kcadm create users -r "$REALM" -i \
  -s "username=$REAUTH_USERNAME" -s enabled=true -s emailVerified=true \
  -s firstName=Reauth -s lastName=Fixture -s email=reauth-fixture@example.invalid)
kcadm set-password -r "$REALM" --userid "$reauth_user_uuid" \
  --new-password "$REAUTH_PASSWORD" --temporary=false >/dev/null
browser_login reauth-1 "$REAUTH_PASSWORD" '' "$REAUTH_USERNAME"
reauth_token_1=$LOGIN_ACCESS_TOKEN
reauth_id_token_1=$LOGIN_ID_TOKEN
reauth_session_1=$LOGIN_SESSION_ID
browser_login reauth-2 "$REAUTH_PASSWORD" '' "$REAUTH_USERNAME"
reauth_token_2=$LOGIN_ACCESS_TOKEN
reauth_id_token_2=$LOGIN_ID_TOKEN
[[ $LOGIN_SESSION_ID != "$reauth_session_1" ]] || fail 'second reauth login reused the first session'
reauth_auth_time=$(decode_jwt_segment "$reauth_id_token_1" 2 | jq -r '.auth_time // empty')
[[ $reauth_auth_time =~ ^[0-9]+$ ]] || fail 'the ID token carries no integer auth_time'
sky POST sudo/authentication "$reauth_token_1" - '{"idToken":""}'
expect 400 invalid_request 'an empty ID token must be a client error'
sky POST sudo/authentication "$reauth_token_1" - "{\"idToken\":\"$reauth_id_token_2\"}"
expect 401 sudo_required 'the ID token of another session of the same person must be refused'
sky POST sudo/authentication "$reauth_token_1" - "{\"idToken\":\"$id_token_a\"}"
expect 401 sudo_required 'the ID token of another person must be refused'
# Flip the first signature character (its bits are all significant, unlike the padding bits
# of the last one), so the claims stay intact and only the signature is wrong.
reauth_signature=${reauth_id_token_1##*.}
if [[ ${reauth_signature:0:1} == A ]]; then flipped_char=B; else flipped_char=A; fi
tampered_id_token="${reauth_id_token_1%.*}.${flipped_char}${reauth_signature:1}"
sky POST sudo/authentication "$reauth_token_1" - "{\"idToken\":\"$tampered_id_token\"}"
expect 401 sudo_required 'a tampered signature must be refused'
sky POST sudo/authentication "$reauth_token_1" - "{\"idToken\":\"$reauth_token_1\"}"
expect 401 sudo_required 'an access token is not a proof of authentication'
sky POST sudo/authentication "$reauth_token_1" - "{\"idToken\":\"$reauth_id_token_1\"}"
expect 200 - 'the ID token of the bearer session must issue a sudo token'
sudo_reauth=$(jq -r .sudoToken <<<"$SKY_BODY")
json_assert "$SKY_BODY" \
  '(.sudoToken | type) == "string" and (.expiresAt | fromdateiso8601) == $auth_time + 300' \
  'the sudo window must start at the authentication, not at the call' --argjson auth_time "$reauth_auth_time"
json_assert "$(decode_jwt_segment "$sudo_reauth" 2)" \
  '.typ == "sky-sudo" and .aud == "sky-account" and .azp == "account-center" and .amr == ["idp"] and .sub == $sub and .sid == $sid and .exp == $auth_time + 300' \
  'authentication sudo token claims differ' --arg sub "$reauth_user_uuid" --arg sid "$reauth_session_1" --argjson auth_time "$reauth_auth_time"
sky POST credentials/password "$reauth_token_2" "$sudo_reauth" "{\"newPassword\":\"$REAUTH_ROTATED_PASSWORD\",\"logoutOtherSessions\":false}"
expect 401 sudo_required 'the authentication sudo token is bound to the session that authenticated'
sky POST credentials/password "$reauth_token_1" "$sudo_reauth" "{\"newPassword\":\"$REAUTH_ROTATED_PASSWORD\",\"logoutOtherSessions\":false}"
expect 204 - 'a password must be settable with the authentication sudo token'
[[ $(direct_grant_status "$REAUTH_ROTATED_PASSWORD" "$REAUTH_USERNAME") == 200 ]] \
  || fail 'the password set after the authentication proof does not sign in'
json_assert "$(user_events CUSTOM_REQUIRED_ACTION "$reauth_user_uuid")" \
  '[.[] | select(.clientId == "account-center" and .sessionId == $sid and .details.action == "sky-sudo" and .details.method == "authentication" and .details.auth_time == $auth_time)] | length == 1' \
  'exactly one sky-sudo audit event must record the authentication proof' --arg sid "$reauth_session_1" --arg auth_time "$reauth_auth_time"
json_assert "$(user_events UPDATE_PASSWORD "$reauth_user_uuid")" \
  '[.[] | select(.clientId == "account-center" and .sessionId == $sid)] | length >= 1' \
  'UPDATE_PASSWORD event for the authenticated person is missing' --arg sid "$reauth_session_1"
json_assert "$(kcadm get "attack-detection/brute-force/users/$reauth_user_uuid" -r "$REALM" -c)" \
  '.numFailures == 0 and .disabled == false' \
  'refused authentication proofs must not count as failed logins'

CURRENT_STAGE='sky-account password change'
sky POST credentials/password "$token_a" "$sudo_a" '{"newPassword":"short","logoutOtherSessions":false}'
expect 400 password_policy 'password policy must be enforced'
json_assert "$SKY_BODY" '.policy == "invalidPasswordMinLengthMessage" and .params == [12] and (.detail | contains("12"))' 'password policy problem must carry the Keycloak message key, its parameters and a Turkish detail'
sky POST credentials/password "$token_a" "$sudo_a" "{\"newPassword\":\"$FIXTURE_USERNAME\",\"logoutOtherSessions\":false}"
expect 400 password_policy 'notUsername policy must be enforced'
json_assert "$SKY_BODY" '.policy == "invalidPasswordNotUsernameMessage"' 'notUsername policy key differs'
sky POST credentials/password "$token_a" "$sudo_a" "{\"newPassword\":\"$ROTATED_PASSWORD\"}"
expect 400 invalid_request 'logoutOtherSessions must be explicit'
sky POST credentials/password "$token_a" "$sudo_a" "{\"newPassword\":\"$ROTATED_PASSWORD\",\"logoutOtherSessions\":true}"
expect 204 - 'a policy-compliant password change must succeed'
sky GET identity "$token_b" -
expect 401 unauthorized 'the other session must be logged out'
sky GET identity "$token_a" -
expect 200 - 'the current session must survive its own password change'
[[ $(direct_grant_status "$FIXTURE_PASSWORD") =~ ^40[01]$ ]] || fail 'the old password still signs in'
[[ $(direct_grant_status "$ROTATED_PASSWORD") == 200 ]] || fail 'the new password does not sign in'
kcadm delete "attack-detection/brute-force/users/$FIXTURE_USER_UUID" -r "$REALM" >/dev/null
json_assert "$(user_events UPDATE_PASSWORD)" \
  '[.[] | select(.clientId == "account-center" and .sessionId == $sid)] | length >= 1' \
  'UPDATE_PASSWORD event is missing' --arg sid "$session_a"
json_assert "$(user_events UPDATE_CREDENTIAL)" \
  '[.[] | select(.clientId == "account-center" and .sessionId == $sid and .details.credential_type == "password")] | length >= 1' \
  'UPDATE_CREDENTIAL event is missing' --arg sid "$session_a"
json_assert "$(user_events LOGOUT)" \
  '[.[] | select(.sessionId == $sid)] | length >= 1' \
  'LOGOUT event for the other session is missing' --arg sid "$session_b"

CURRENT_STAGE='sky-account TOTP'
sky POST credentials/totp/setup "$token_a" -
expect 401 sudo_required 'TOTP setup requires sudo'
sky POST credentials/totp/setup "$token_a" "$sudo_a"
expect 200 - 'TOTP setup must start'
json_assert "$SKY_BODY" \
  '(.setupHandle | test("^[A-Za-z0-9_-]{43}$")) and (.secret | test("^[A-Z2-7]{32}$")) and (.otpauthUri | startswith("otpauth://totp/")) and (.secret as $secret | .otpauthUri | contains("secret=" + $secret)) and (.otpauthUri | contains("digits=6")) and (.otpauthUri | contains("period=30")) and .policy.type == "totp" and .policy.digits == 6 and .policy.period == 30 and .policy.algorithm == "SHA1"' \
  'TOTP setup response differs'
setup_handle=$(jq -r .setupHandle <<<"$SKY_BODY")
totp_secret=$(jq -r .secret <<<"$SKY_BODY")
sky POST credentials/totp/confirm "$token_a" "$sudo_a" "{\"setupHandle\":\"$setup_handle\",\"code\":\"000000\",\"label\":\"Telefon\"}"
expect 400 invalid_totp_code 'a wrong confirmation code must be refused'
sky GET identity "$token_a" -
json_assert "$SKY_BODY" '.credentials.totp == []' 'a refused confirmation must not create a credential'
sky POST credentials/totp/confirm "$token_a" "$sudo_a" "{\"setupHandle\":\"$(printf 'A%.0s' $(seq 1 43))\",\"code\":\"123456\",\"label\":\"Telefon\"}"
expect 400 totp_setup_expired 'an unknown setup handle must be refused'
confirmation_code=$(totp_code "$totp_secret" 0)
sky POST credentials/totp/confirm "$token_a" "$sudo_a" "{\"setupHandle\":\"$setup_handle\",\"code\":\"$confirmation_code\",\"label\":\"Telefon\"}"
expect 201 - 'the right confirmation code must register TOTP'
json_assert "$SKY_BODY" '(.id | length) > 0 and .type == "otp" and .label == "Telefon" and (.createdAt | length) > 0' 'TOTP confirmation response differs'
totp_credential_id=$(jq -r .id <<<"$SKY_BODY")
sky POST credentials/totp/confirm "$token_a" "$sudo_a" "{\"setupHandle\":\"$setup_handle\",\"code\":\"$confirmation_code\",\"label\":\"Telefon 2\"}"
expect 400 totp_setup_expired 'a setup handle must be single-use'
sky GET identity "$token_a" -
json_assert "$SKY_BODY" '(.credentials.totp | length) == 1 and .credentials.totp[0].id == $id and .credentials.totp[0].type == "otp" and .credentials.totp[0].label == "Telefon" and (.credentials.totp[0].createdAt | length) > 0' \
  'identity must list the new TOTP credential' --arg id "$totp_credential_id"
sky POST credentials/totp/setup "$token_a" "$sudo_a"
expect 200 - 'a second TOTP setup must start'
duplicate_handle=$(jq -r .setupHandle <<<"$SKY_BODY")
duplicate_code=$(totp_code "$(jq -r .secret <<<"$SKY_BODY")" 0)
sky POST credentials/totp/confirm "$token_a" "$sudo_a" "{\"setupHandle\":\"$duplicate_handle\",\"code\":\"$duplicate_code\",\"label\":\"Telefon\"}"
expect 409 duplicate_label 'a duplicate label must be refused'
sky GET identity "$token_a" -
json_assert "$SKY_BODY" '(.credentials.totp | length) == 1' 'a refused duplicate must not create a credential'
sky POST sudo/totp "$token_a" - "{\"code\":\"$confirmation_code\"}"
expect 401 invalid_credentials 'a TOTP code must not be reusable'
sky POST sudo/totp "$token_a" - "{\"code\":\"$(totp_code "$totp_secret" 1)\"}"
expect 200 - 'a fresh TOTP code must issue a sudo token'
sudo_totp=$(jq -r .sudoToken <<<"$SKY_BODY")
json_assert "$(decode_jwt_segment "$sudo_totp" 2)" '.amr == ["otp"]' 'TOTP sudo must record amr otp'
json_assert "$(user_events CUSTOM_REQUIRED_ACTION)" \
  '[.[] | select(.clientId == "account-center" and .sessionId == $sid and .details.action == "sky-sudo" and .details.method == "totp")] | length == 1' \
  'exactly one sky-sudo audit event must record the TOTP proof' --arg sid "$session_a"
json_assert "$(user_events UPDATE_TOTP)" \
  '[.[] | select(.clientId == "account-center" and .details.credential_user_label == "Telefon")] | length >= 1' \
  'UPDATE_TOTP event is missing'
browser_login c "$ROTATED_PASSWORD" "$(totp_code "$totp_secret" "$(fresh_totp_offset)")"
sky GET identity "$LOGIN_ACCESS_TOKEN" -
expect 200 - 'a browser login with the SPI-registered TOTP must work'

CURRENT_STAGE='sky-account credential deletion'
password_credential_id=$(kcadm get "users/$FIXTURE_USER_UUID/credentials" -r "$REALM" -c \
  | jq -r '.[] | select(.type == "password") | .id')
sky DELETE "credentials/$totp_credential_id" "$token_a" -
expect 401 sudo_required 'credential deletion requires sudo'
sky DELETE "credentials/$password_credential_id" "$token_a" "$sudo_totp"
expect 404 credential_not_found 'the password credential must never be deletable'
sky DELETE "credentials/00000000-0000-4000-8000-000000000000" "$token_a" "$sudo_totp"
expect 404 credential_not_found 'unknown credentials must be reported as not found'
sky DELETE "credentials/$totp_credential_id" "$token_a" "$sudo_totp"
expect 204 - 'the person must delete their own TOTP credential'
sky GET identity "$token_a" -
json_assert "$SKY_BODY" '.credentials.totp == [] and .credentials.password == true' 'TOTP deletion must be reflected'
json_assert "$(user_events REMOVE_TOTP)" \
  '[.[] | select(.clientId == "account-center" and .details.selected_credential_id == $id)] | length >= 1' \
  'REMOVE_TOTP event is missing' --arg id "$totp_credential_id"
if [[ $passkeys_before -gt 0 ]]; then
  passkey_id=$(jq -r '.credentials.passkeys[0].id' <<<"$SKY_BODY")
  sky DELETE "credentials/$passkey_id" "$token_a" "$sudo_totp"
  expect 204 - 'the person must delete their own passkey'
  sky GET identity "$token_a" -
  json_assert "$SKY_BODY" '(.credentials.passkeys | length) == ($before - 1)' \
    'passkey deletion must be reflected' --argjson before "$passkeys_before"
  json_assert "$(user_events REMOVE_CREDENTIAL)" \
    '[.[] | select(.clientId == "account-center" and .details.selected_credential_id == $id and .details.credential_type == "webauthn-passwordless")] | length >= 1' \
    'REMOVE_CREDENTIAL event for the passkey is missing' --arg id "$passkey_id"
fi

# Passkey endpoint shape, sudo gating and error mapping. The cryptographic ceremony
# (create/register/get with a real authenticator) runs in the Playwright stage; here
# we prove options shaping, sudo gating, that the challenge is consumed atomically in
# the real single-use store, and that verification failures map to codes.
# Budget note: the contract runs inside one 15-minute window per user, so this block
# must stay within the headroom the earlier stages leave: 4 of the 30 `mutation`
# slots (options x2, register x2), none of the 10 `sudo` slots (it reuses sudo_totp and
# passkey sudo has its own `sudo-passkey` budget), one `sudo-options` slot.
CURRENT_STAGE='sky-account passkey endpoints'
base64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
bogus_rawid=$(head -c 32 /dev/urandom | base64url)
bogus_client=$(printf '{"type":"webauthn.create","challenge":"x","origin":"http://localhost:18081"}' | base64url)
bogus_attestation=$(printf 'bogus-attestation-object' | base64url)
register_body() {
  jq -cn --arg id "$1" --arg cdj "$2" --arg att "$3" --arg label "$4" \
    '{id:$id, rawId:$id, type:"public-key", label:$label, response:{clientDataJSON:$cdj, attestationObject:$att}}'
}
sky POST credentials/webauthn/options "$token_a" -
expect 401 sudo_required 'passkey creation options require sudo'
sky POST credentials/webauthn/options "$token_a" "$sudo_totp"
expect 200 - 'creation options are returned with sudo'
json_assert "$SKY_BODY" \
  '(.rp.id | type) == "string" and (.rp.id | length) > 0 and .rp.name == "SKY LAB" and (.challenge | test("^[A-Za-z0-9_-]{43}$")) and (.user.id | test("^[A-Za-z0-9_-]+$")) and .user.name == "account-fixture" and (.user.displayName | length) > 0 and (.pubKeyCredParams | length) >= 1 and (.pubKeyCredParams[0].type) == "public-key" and (.pubKeyCredParams[0].alg | type) == "number" and .extensions.credProps == true and (.excludeCredentials | type) == "array" and .authenticatorSelection.userVerification == "required" and .authenticatorSelection.residentKey == "required"' \
  'creation options shape differs from the passwordless policy'
grep -Eiq '^cache-control:[[:space:]]*no-store' "$SKY_HEADERS" || fail 'creation options must not be cacheable'
sky POST credentials/webauthn/register "$token_a" "$sudo_totp" "$(register_body "$bogus_rawid" "$bogus_client" "$bogus_attestation" 'MacBook')"
expect 400 webauthn_invalid 'a bogus attestation must be refused and consume the challenge'
sky POST credentials/webauthn/register "$token_a" "$sudo_totp" "$(register_body "$bogus_rawid" "$bogus_client" "$bogus_attestation" 'MacBook')"
expect 400 webauthn_challenge_expired 'a second registration without fresh options finds no challenge'
sky GET identity "$token_a" -
json_assert "$SKY_BODY" '.credentials.passkeys == []' 'a refused registration must not create a passkey'
json_assert "$(user_events UPDATE_CREDENTIAL_ERROR)" \
  '[.[] | select(.clientId == "account-center" and .details.credential_type == "webauthn-passwordless" and .error == "invalid_registration")] | length >= 2' \
  'UPDATE_CREDENTIAL_ERROR events for the refused passkey registrations are missing'
sky POST sudo/webauthn/options "$token_a" -
expect 400 passkey_not_registered 'assertion options need at least one passkey'
sky POST sudo/webauthn/verify "$token_a" - '{"id":"AA","rawId":"AA","type":"public-key","response":{"clientDataJSON":"e30","authenticatorData":"AQID","signature":"BAUG","userHandle":"invalid base64!"}}'
expect 400 invalid_request 'a malformed assertion must be refused'
json_assert "$SKY_BODY" '.field == "response.userHandle"' 'invalid_request must name the nested field'
sky POST sudo/webauthn/verify "$token_a" - "$(jq -cn --arg id "$bogus_rawid" '{id:$id, rawId:$id, type:"public-key", response:{clientDataJSON:"e30", authenticatorData:"AQID", signature:"BAUG"}}')"
expect 400 passkey_not_registered 'a passkey assertion needs at least one passkey'

CURRENT_STAGE='sky-account username'
sky POST identity/username "$token_a" - "{\"username\":\"$CHANGED_USERNAME\"}"
expect 401 sudo_required 'username change requires sudo'
sky POST identity/username "$token_a" "$sudo_totp" '{"username":"Ada Lovelace"}'
expect 400 invalid_username 'usernames must match the allowed pattern'
sky POST identity/username "$token_a" "$sudo_totp" "{\"username\":\"$TAKEN_USERNAME\"}"
expect 409 username_taken 'a username owned by another person must be refused'
sky POST identity/username "$token_a" "$sudo_totp" "{\"username\":\"$(tr '[:lower:]' '[:upper:]' <<<"$CHANGED_USERNAME")\"}"
expect 200 - 'a free username must be accepted'
json_assert "$SKY_BODY" '.username == $name and (.usernameChangeAvailableAt | fromdateiso8601) > ($now + 13 * 86400)' \
  'username change must lowercase and start the cooldown' --arg name "$CHANGED_USERNAME" --argjson now "$(date -u +%s)"
sky POST identity/username "$token_a" "$sudo_totp" '{"username":"another.name"}'
expect 409 username_cooldown 'a second change inside the cooldown must be refused'
json_assert "$SKY_BODY" '.retryAfter > 0 and (.availableAt | length) > 0' 'username_cooldown must say when to retry'
[[ $(header_value Retry-After) -gt 0 ]] || fail 'username_cooldown must set Retry-After'
sky POST identity/username "$token_a" "$sudo_totp" "{\"username\":\"$CHANGED_USERNAME\"}"
expect 200 - 'repeating the current username is a no-op'
kcadm get "users/$FIXTURE_USER_UUID" -r "$REALM" -c \
  | jq -e --arg name "$CHANGED_USERNAME" '.username == $name' >/dev/null \
  || fail 'username change did not persist although editUsernameAllowed is false'
json_assert "$(user_events UPDATE_PROFILE)" \
  '[.[] | select(.clientId == "account-center" and .details.updated_username == $name and .details.previous_username == "account-fixture")] | length >= 1' \
  'UPDATE_PROFILE event for the username change is missing' --arg name "$CHANGED_USERNAME"

# Personal e-mail: add → verification mail → confirm → Primary selection → removal (ADR-0044).
# Budget note: change requests have their own tight budget (3 / hour per person) and the
# fixture person's sudo budget is spent by the stages above, so this block gets two throwaway
# people. The fixture person is left untouched here.
CURRENT_STAGE='sky-account personal e-mail'
mailpit_reset
kcadm update "users/$taken_user_uuid" -r "$REALM" \
  -s "attributes.personalEmail=[\"$EMAIL_TAKEN_PERSONAL_ADDRESS\"]" >/dev/null
email_person "$EMAIL_USERNAME" "$EMAIL_SCHOOL_ADDRESS" "$EMAIL_SCHOOL_ADDRESS"
email_user_uuid=$EMAIL_USER_UUID
email_password=$EMAIL_PASSWORD
email_person "$EMAIL_OTHER_USERNAME" "$EMAIL_OTHER_SCHOOL_ADDRESS" "$EMAIL_OTHER_PRIMARY_ADDRESS"
email_other_uuid=$EMAIL_USER_UUID
email_other_password=$EMAIL_PASSWORD

browser_login email-1 "$email_password" '' "$EMAIL_USERNAME"
token_e=$LOGIN_ACCESS_TOKEN
sky POST sudo/password "$token_e" - "{\"password\":\"$email_password\"}"
expect 200 - 'the e-mail fixture person must obtain a sudo token'
sudo_e=$(jq -r .sudoToken <<<"$SKY_BODY")
browser_login email-2 "$email_other_password" '' "$EMAIL_OTHER_USERNAME"
token_o=$LOGIN_ACCESS_TOKEN
sky POST sudo/password "$token_o" - "{\"password\":\"$email_other_password\"}"
expect 200 - 'the second e-mail person must obtain a sudo token'
sudo_o=$(jq -r .sudoToken <<<"$SKY_BODY")

sky GET identity "$token_e" -
expect 200 - 'the e-mail fixture identity must be readable'
json_assert "$SKY_BODY" \
  '.schoolEmail == $school and .personalEmail == null and .personalEmailVerified == false and .primary == "school" and .email == $school' \
  'a person with only a school address must start with a school primary' --arg school "$EMAIL_SCHOOL_ADDRESS"

# An address written straight into the attribute was proven by nobody, so it cannot be primary.
kcadm update "users/$email_user_uuid" -r "$REALM" \
  -s "attributes.personalEmail=[\"$EMAIL_PERSONAL_ADDRESS\"]" >/dev/null
sky GET identity "$token_e" -
json_assert "$SKY_BODY" '.personalEmail == $personal and .personalEmailVerified == false' \
  'an unproven personal address must not be reported as verified' --arg personal "$EMAIL_PERSONAL_ADDRESS"
sky POST email/primary "$token_e" "$sudo_e" '{"which":"personal"}'
expect 409 email_not_verified 'an unproven personal address must not become the primary'
sky DELETE email/personal "$token_e" "$sudo_e"
expect 200 - 'a personal address that is not the primary must be removable'
json_assert "$SKY_BODY" '.personalEmail == null and .primary == "school"' 'the removal is not reflected'
sky DELETE email/personal "$token_e" "$sudo_e"
expect 200 - 'removing a personal address nobody has is a no-op'
json_assert "$SKY_BODY" '.personalEmail == null and .primary == "school"' 'the no-op removal changed the identity'
sky POST email/primary "$token_e" "$sudo_e" '{"which":"personal"}'
expect 400 invalid_request 'a personal address the person never added cannot be chosen'
sky POST email/primary "$token_e" "$sudo_e" '{"which":"work"}'
expect 400 invalid_request 'the primary can only be the school or the personal address'

# 1 / 3 of the change budget: the address that carries the flow.
sky POST email/change-request "$token_e" - "{\"address\":\"$EMAIL_PERSONAL_ADDRESS\"}"
expect 401 sudo_required 'a change request requires sudo'
sky POST email/change-request "$token_e" "$sudo_e" "{\"address\":\"$EMAIL_PERSONAL_ADDRESS\",\"makePrimary\":false}"
expect 202 - 'a free, valid address must be accepted'
json_assert "$SKY_BODY" '(.expiresAt | fromdateiso8601) > ($now + 9 * 60) and (.expiresAt | fromdateiso8601) <= ($now + 10 * 60 + 5)' \
  'the pending change must live for ten minutes' --argjson now "$(date -u +%s)"
sky GET identity "$token_e" -
json_assert "$SKY_BODY" '.personalEmail == null and .email == $school' \
  'a change request must not touch the person before the address is proven' --arg school "$EMAIL_SCHOOL_ADDRESS"
confirm_code=$(confirmation_code_of "$(mailpit_message_id "$EMAIL_PERSONAL_ADDRESS")")

# 2 / 3 and 3 / 3, then the budget is spent.
sky POST email/change-request "$token_e" "$sudo_e" '{"address":"not an address"}'
expect 400 invalid_request 'Keycloak e-mail validation must refuse a malformed address'
json_assert "$SKY_BODY" '.field == "address"' 'invalid_request must name the address field'
sky POST email/change-request "$token_e" "$sudo_e" "{\"address\":\"$EMAIL_OTHER_PRIMARY_ADDRESS\"}"
expect 409 email_taken 'an address that is another person primary must be refused'
sky POST email/change-request "$token_e" "$sudo_e" "{\"address\":\"second-$EMAIL_PERSONAL_ADDRESS\"}"
expect 429 rate_limited 'the fourth change request of the hour must be refused'
[[ $(header_value Retry-After) -gt 0 ]] || fail 'rate_limited must set Retry-After'

# The second person spends its own budget on the refusals the first one could not reach and
# on the pending change the cross-account checks need.
sky POST email/change-request "$token_o" "$sudo_o" "{\"address\":\"$EMAIL_OTHER_SCHOOL_ADDRESS\"}"
expect 400 invalid_request 'the own school address is not a personal address'
sky POST email/change-request "$token_o" "$sudo_o" "{\"address\":\"$EMAIL_TAKEN_PERSONAL_ADDRESS\"}"
expect 409 email_taken 'an address that is another person personal e-mail must be refused'
sky POST email/change-request "$token_o" "$sudo_o" "{\"address\":\"$EMAIL_OTHER_PERSONAL_ADDRESS\",\"makePrimary\":true}"
expect 202 - 'the second person must start its own change'
foreign_code=$(confirmation_code_of "$(mailpit_message_id "$EMAIL_OTHER_PERSONAL_ADDRESS")")

# The code proves the mailbox and the session proves the person, so confirming needs no sudo;
# a code is only ever compared with the pending change of the person whose session sends it.
sky POST email/confirm - - "{\"code\":\"$confirm_code\"}"
expect 401 unauthorized 'confirming without an Account Center session must be refused'
sky POST email/confirm "$token_e" - '{"code":"12345"}'
expect 400 invalid_request 'a code that is not six digits must be refused'
json_assert "$SKY_BODY" '.field == "code"' 'invalid_request must name the code field'
wrong_e=$(a_code_other_than "$confirm_code")
sky POST email/confirm "$token_e" - "{\"code\":\"$wrong_e\"}"
expect 400 invalid_email_code 'a wrong code must be refused'
json_assert "$SKY_BODY" '.attemptsLeft == 4' 'a wrong code must cost exactly one of five tries (a malformed one costs none)'
# A page reloaded between the mail and the code reads what is waiting instead of asking for a new code.
sky GET email/pending "$token_e" -
expect 200 - 'the waiting change must be readable'
json_assert "$SKY_BODY" \
  '.address == $personal and .attemptsLeft == 4 and ((.expiresAt | fromdateiso8601) > $now) and (keys | sort) == ["address","attemptsLeft","expiresAt"]' \
  'the waiting change must show address, deadline and tries, and never the code' \
  --arg personal "$EMAIL_PERSONAL_ADDRESS" --argjson now "$(date -u +%s)"
# The address-squatting attack the link allowed: this person's code typed into the other
# person's session only ever meets the other person's own change.
if [[ $confirm_code != "$foreign_code" ]]; then
  sky POST email/confirm "$token_o" - "{\"code\":\"$confirm_code\"}"
  expect 400 invalid_email_code 'a code must never confirm a change of another account'
else
  sky POST email/confirm "$token_o" - "{\"code\":\"$(a_code_other_than "$foreign_code")\"}"
  expect 400 invalid_email_code 'a wrong code must be refused'
fi
wrong_o=$(a_code_other_than "$foreign_code")
for left in 3 2 1 0; do
  sky POST email/confirm "$token_o" - "{\"code\":\"$wrong_o\"}"
  expect 400 invalid_email_code 'a wrong code must be refused'
  json_assert "$SKY_BODY" '.attemptsLeft == $left' 'every wrong code must cost one try' --argjson left "$left"
done
sky POST email/confirm "$token_o" - "{\"code\":\"$foreign_code\"}"
expect 404 no_pending_email_change 'the right code must not work after the fifth wrong try'
sky GET identity "$token_o" -
json_assert "$SKY_BODY" '.personalEmail == null and .email == $primary' \
  'a refused confirmation must not change the person' --arg primary "$EMAIL_OTHER_PRIMARY_ADDRESS"
sky GET identity "$token_e" -
json_assert "$SKY_BODY" '.personalEmail == null' \
  'attempts in another session must not touch this person' 

sky POST email/confirm "$token_e" - "{\"code\":\" ${confirm_code:0:3} ${confirm_code:3:3} \"}"
expect 200 - 'the code from the mail must finish the change, spaces and all'
json_assert "$SKY_BODY" \
  '.personalEmail == $personal and .personalEmailVerified == true and .primary == "school" and .email == $school and .emailVerified == true' \
  'confirming without makePrimary must add the address without moving the primary' \
  --arg personal "$EMAIL_PERSONAL_ADDRESS" --arg school "$EMAIL_SCHOOL_ADDRESS"
sky POST email/confirm "$token_e" - "{\"code\":\"$confirm_code\"}"
expect 404 no_pending_email_change 'a used code must not work a second time'
sky GET email/pending "$token_e" -
expect 404 no_pending_email_change 'nothing waits once the change is confirmed'
kcadm get "users/$email_user_uuid" -r "$REALM" -c \
  | jq -e --arg personal "$EMAIL_PERSONAL_ADDRESS" --arg school "$EMAIL_SCHOOL_ADDRESS" \
    '.email == $school and .attributes.personalEmail == [$personal] and (.attributes.personalEmailVerifiedAt[0] | length) > 0' >/dev/null \
  || fail 'the proven personal address did not persist in Keycloak'
json_assert "$(user_events UPDATE_PROFILE "$email_user_uuid")" \
  '[.[] | select(.clientId == "account-center" and .details.context == "ACCOUNT")] | length >= 1' \
  'UPDATE_PROFILE event for the confirmed personal address is missing'
json_assert "$(skyapp_access_token "$EMAIL_USERNAME" "$email_password")" '.email == $school' \
  'adding a personal address must not move the e-mail claim of other clients' \
  --arg school "$EMAIL_SCHOOL_ADDRESS"

# The primary is what Keycloak, the tokens, core and SkyMail see.
sky POST email/primary "$token_e" - '{"which":"personal"}'
expect 401 sudo_required 'the primary selection requires sudo'
# Sudo lasts five minutes and the mail round trip above eats into it.
sky POST sudo/password "$token_e" - "{\"password\":\"$email_password\"}"
expect 200 - 'the e-mail fixture person must renew its sudo token'
sudo_e=$(jq -r .sudoToken <<<"$SKY_BODY")
sky POST email/primary "$token_e" "$sudo_e" '{"which":"personal"}'
expect 200 - 'a proven personal address must become the primary'
json_assert "$SKY_BODY" '.primary == "personal" and .email == $personal and .emailVerified == true' \
  'the primary switch is not reflected in the identity' --arg personal "$EMAIL_PERSONAL_ADDRESS"
json_assert "$(user_events UPDATE_EMAIL "$email_user_uuid")" \
  '[.[] | select(.clientId == "account-center" and .details.updated_email == $personal and .details.previous_email == $school)] | length >= 1' \
  'UPDATE_EMAIL event for the primary switch is missing' \
  --arg personal "$EMAIL_PERSONAL_ADDRESS" --arg school "$EMAIL_SCHOOL_ADDRESS"
json_assert "$(skyapp_access_token "$EMAIL_USERNAME" "$email_password")" '.email == $personal and .email_verified == true' \
  'a fresh token does not carry the new primary e-mail' --arg personal "$EMAIL_PERSONAL_ADDRESS"
[[ $(direct_grant_status "$email_password" "$EMAIL_PERSONAL_ADDRESS") == 200 ]] \
  || fail 'the new primary address must sign in'

# Removing the personal address while it is the primary needs an address to fall back to.
# The sudo window is five minutes and the stages above spent most of it, so take a fresh one.
sky POST sudo/password "$token_e" - "{\"password\":\"$email_password\"}"
expect 200 - 'the e-mail fixture person must obtain a second sudo token'
sudo_e=$(jq -r .sudoToken <<<"$SKY_BODY")
# The school attribute alone proves nothing (CONTEXT, Verified YTÜ account): only the YTÜ link does.
sky POST email/primary "$token_e" "$sudo_e" '{"which":"school"}'
expect 409 email_not_verified 'a school address without the YTÜ link must not become the primary'
kcadm get "users/$email_user_uuid" -r "$REALM" -c \
  | jq 'del(.attributes.schoolEmail)' \
  | kcadm update "users/$email_user_uuid" -r "$REALM" -n -f - >/dev/null
sky DELETE email/personal "$token_e" "$sudo_e"
expect 409 no_fallback_email 'the only address of a person must not be removable'
sky GET identity "$token_e" -
json_assert "$SKY_BODY" '.personalEmail == $personal and .primary == "personal"' \
  'a refused removal must not change the person' --arg personal "$EMAIL_PERSONAL_ADDRESS"
# Only the chosen address has to exist; a person without a school address is not stuck.
sky POST email/primary "$token_e" "$sudo_e" '{"which":"personal"}'
expect 200 - 'choosing the personal address must not require a school address as well'
json_assert "$SKY_BODY" '.primary == "personal" and .email == $personal' \
  'choosing the current primary must leave it as it is' --arg personal "$EMAIL_PERSONAL_ADDRESS"
kcadm update "users/$email_user_uuid" -r "$REALM" \
  -s "attributes.schoolEmail=[\"$EMAIL_SCHOOL_ADDRESS\"]" >/dev/null
sky DELETE email/personal "$token_e" "$sudo_e"
expect 409 no_fallback_email 'a school attribute without the YTÜ link must not take over the primary'
kcadm create "users/$email_user_uuid/federated-identity/OBS" -r "$REALM" \
  -b "{\"identityProvider\":\"OBS\",\"userId\":\"ms-object-id-email\",\"userName\":\"$EMAIL_SCHOOL_ADDRESS\"}" >/dev/null
sky DELETE email/personal "$token_e" -
expect 401 sudo_required 'removing the personal address requires sudo'
sky DELETE email/personal "$token_e" "$sudo_e"
expect 200 - 'the personal address must be removable when the school address can take over'
json_assert "$SKY_BODY" \
  '.personalEmail == null and .personalEmailVerified == false and .primary == "school" and .email == $school and .emailVerified == true' \
  'the removal must hand the primary back to the school address' --arg school "$EMAIL_SCHOOL_ADDRESS"
kcadm get "users/$email_user_uuid" -r "$REALM" -c \
  | jq -e --arg school "$EMAIL_SCHOOL_ADDRESS" \
    '.email == $school and ((.attributes.personalEmail // []) | length) == 0 and ((.attributes.personalEmailVerifiedAt // []) | length) == 0' >/dev/null \
  || fail 'the removed personal address is still stored in Keycloak'
kcadm delete "users/$email_user_uuid/federated-identity/OBS" -r "$REALM" >/dev/null

# Replacing the personal address that is the primary must move the primary with it: otherwise
# Keycloak email keeps an address the person no longer has and the primary reads "none".
email_person email-third email-third@std.yildiz.edu.tr email-third-old@example.invalid
email_third_uuid=$EMAIL_USER_UUID
email_third_password=$EMAIL_PASSWORD
kcadm update "users/$email_third_uuid" -r "$REALM" \
  -s 'attributes.personalEmail=["email-third-old@example.invalid"]' \
  -s 'attributes.personalEmailVerifiedAt=["2026-09-01T12:00:00Z"]' >/dev/null
browser_login email-3 "$email_third_password" '' email-third
token_t=$LOGIN_ACCESS_TOKEN
sky GET identity "$token_t" -
json_assert "$SKY_BODY" '.primary == "personal" and .personalEmailVerified == true' \
  'the third person must start with a proven personal primary'
sky POST sudo/password "$token_t" - "{\"password\":\"$email_third_password\"}"
expect 200 - 'the third e-mail person must obtain a sudo token'
sudo_t=$(jq -r .sudoToken <<<"$SKY_BODY")
sky POST email/change-request "$token_t" "$sudo_t" '{"address":"email-third-new@example.invalid","makePrimary":false}'
expect 202 - 'a replacement personal address must be accepted'
sky GET email/pending "$token_t" -
expect 200 - 'the replacement must be waiting'
json_assert "$SKY_BODY" '.address == "email-third-new@example.invalid" and .attemptsLeft == 5' \
  'the waiting replacement must show its address and all five tries'
third_code=$(confirmation_code_of "$(mailpit_message_id email-third-new@example.invalid)")
sky POST email/confirm "$token_t" - "{\"code\":\"$third_code\"}"
expect 200 - 'the replacement code must finish the change'
json_assert "$SKY_BODY" \
  '.personalEmail == "email-third-new@example.invalid" and .primary == "personal" and .email == "email-third-new@example.invalid" and .emailVerified == true' \
  'replacing the personal primary must move the primary to the new address'
kcadm delete "users/$email_third_uuid" -r "$REALM" >/dev/null

CURRENT_STAGE='sky-account rate limit'
rate_limited=''
for attempt in $(seq 1 11); do
  sky POST sudo/totp "$token_a" - '{"code":"000000"}'
  if [[ $SKY_STATUS == 429 ]]; then
    rate_limited=$attempt
    break
  fi
  expect 400 totp_not_configured 'sudo/totp without a TOTP credential must be a client error'
done
[[ -n $rate_limited ]] || fail 'the sudo rate limit never triggered'
expect 429 rate_limited 'exhausted sudo budget must answer 429'
retry_after=$(header_value Retry-After)
[[ $retry_after -ge 1 && $retry_after -le 900 ]] || fail 'Retry-After must fit the 15 minute window'
json_assert "$SKY_BODY" '.retryAfter == ($retry | tonumber)' 'retryAfter must match the header' --arg retry "$retry_after"

CURRENT_STAGE='sky-account secrets in logs'
keycloak_logs=$("${COMPOSE[@]}" logs --no-color keycloak 2>&1)
for secret_value in "$totp_secret" "$sudo_a" "$sudo_totp" "$sudo_reauth" "$sudo_e" "$sudo_o" \
  "$reauth_id_token_1" "$ROTATED_PASSWORD" "$REAUTH_ROTATED_PASSWORD" "$email_password" \
  "$email_other_password" "$setup_handle"; do
  [[ $keycloak_logs != *"$secret_value"* ]] || fail 'a secret, sudo token, password or e-mail token leaked into Keycloak logs'
done
# Six digits turn up in any log by chance, so the codes are looked for next to what would carry them.
for code_value in "$confirm_code" "$foreign_code" "$third_code"; do
  [[ $keycloak_logs != *"code\":\"$code_value"* && $keycloak_logs != *"code=$code_value"* && $keycloak_logs != *"code: $code_value"* ]] \
    || fail 'an e-mail verification code leaked into Keycloak logs'
done

CURRENT_STAGE='sky-account cleanup'
# Admin REST cannot rename a user while editUsernameAllowed=false (User Profile applies the
# realm switch to admins too); the SPI writes at model level. Lift it only for the restore.
kcadm update "realms/$REALM" -s editUsernameAllowed=true >/dev/null
kcadm update "users/$FIXTURE_USER_UUID" -r "$REALM" \
  -s "username=$FIXTURE_USERNAME" -s firstName=Account -s lastName=Fixture \
  -s 'attributes={}' >/dev/null
kcadm set-password -r "$REALM" --userid "$FIXTURE_USER_UUID" \
  --new-password "$FIXTURE_PASSWORD" --temporary=false >/dev/null
printf '%s' "$realm_before" | kcadm update "realms/$REALM" -f - >/dev/null
kcadm delete "attack-detection/brute-force/users/$FIXTURE_USER_UUID" -r "$REALM" >/dev/null
kcadm delete identity-provider/instances/OBS -r "$REALM" >/dev/null
kcadm delete "users/$taken_user_uuid" -r "$REALM" >/dev/null
kcadm delete "users/$reauth_user_uuid" -r "$REALM" >/dev/null
kcadm delete "users/$email_user_uuid" -r "$REALM" >/dev/null
kcadm delete "users/$email_other_uuid" -r "$REALM" >/dev/null
mailpit_reset
printf '%s' "$user_profile_before" | kcadm update users/profile -r "$REALM" -f - >/dev/null
kcadm get "users/$FIXTURE_USER_UUID" -r "$REALM" -c \
  | jq -e '.username == "account-fixture" and .firstName == "Account"' >/dev/null \
  || fail 'fixture user was not restored'

printf 'sky-account SPI contract passed.\n'
