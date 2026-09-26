#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TEST_IMAGE=${KEYCLOAK_TEST_IMAGE:?set KEYCLOAK_TEST_IMAGE to the already-built candidate image}
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.integration.yml"
COMPOSE=(docker compose -f "$COMPOSE_FILE")
KCADM=("${COMPOSE[@]}" exec -T keycloak /opt/keycloak/bin/kcadm.sh)
ADMIN_CONFIG=/tmp/integration-kcadm.config
TEST_STATE_DIR=$(mktemp -d)
CURRENT_STAGE=startup
export TEST_STATE_DIR

cleanup() {
  "${COMPOSE[@]}" down --volumes --remove-orphans >/dev/null 2>&1 || true
  rm -rf "$TEST_STATE_DIR"
}
trap 'exit_code=$?; trap - EXIT; cleanup; exit "$exit_code"' EXIT

docker image inspect "$TEST_IMAGE" >/dev/null 2>&1 || {
  printf 'integration candidate image is not built locally: %s\n' "$TEST_IMAGE" >&2
  exit 1
}

trap 'status=$?; printf "integration command failed during %s (line %s)\n" "$CURRENT_STAGE" "$LINENO" >&2; exit "$status"' ERR

CURRENT_STAGE='SkyMail sender secret mount setup'
# The sky-mail sender validates its secret file when Keycloak starts, but the
# keycloak-mailer secret only exists once the operator script has run. The mount starts
# with a placeholder and the K5 stage writes the real secret into it; the provider reads
# the file on every token request, which is also how an operator rotates it.
sky_mail_dir="$TEST_STATE_DIR/sky-mail"
mkdir -p "$sky_mail_dir"
chmod 0755 "$sky_mail_dir"
printf 'placeholder-until-the-operator-script-runs\n' >"$sky_mail_dir/client.secret"
chmod 0644 "$sky_mail_dir/client.secret"

"$SCRIPT_DIR/check-version-consistency.sh"
"$SCRIPT_DIR/check-fresh-runner.sh"
"$SCRIPT_DIR/check-production-preflight.sh"
"$SCRIPT_DIR/check-account-center-origin.sh"
"$SCRIPT_DIR/check-operator-login-prompts.sh"

fail() {
  printf 'integration failure: %s\n' "$1" >&2
  exit 1
}

wait_for_url() {
  local url=$1
  local attempt
  for attempt in $(seq 1 90); do
    if curl --fail --silent --show-error "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  fail "timed out waiting for $url"
}

json_assert() {
  local json=$1
  local expression=$2
  local message=$3
  shift 3
  jq -e "$@" "$expression" <<<"$json" >/dev/null || fail "$message"
}

# The audience scopes of the skyforms and frontend-main login clients; stages called below.
# shellcheck source=login-client-audiences.sh
source "$SCRIPT_DIR/login-client-audiences.sh"

# ---------------------------------------------------------------------------
# v2 identity reconcile stages (passkey relying party id, realm login and brute
# force settings, User Profile, account-center scope, keycloak-mailer client,
# no-op proof and legacy passkey cleanup). Each stage is one function so the
# assertions stay separable from the v1 contract above and below.
# ---------------------------------------------------------------------------
V2_REALM=e-skylab-test
V2_FIXTURE_USER_UUID=11111111-1111-4111-8111-111111111111
V2_SWITCH_ATTRIBUTE=skylab.passkeyRpIdSwitchedAt
V2_ISO_UTC='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
V2_SWITCHED_AT_FIRST=''
V2_ACCESS_TOKEN=''
V2_ACCESS_PAYLOAD=''
V2_ID_PAYLOAD=''
v2_cleanup_run_options=()

v2_client_uuid() {
  kcadm get clients -r "$V2_REALM" -q "clientId=$1" -c \
    | jq -r --arg id "$1" '.[] | select(.clientId == $id) | .id'
}

v2_scope_uuid() {
  kcadm get client-scopes -r "$V2_REALM" -c \
    | jq -r --arg name "$1" '.[] | select(.name == $name) | .id'
}

v2_role_body() {
  kcadm get "clients/$1/roles" -r "$V2_REALM" -c \
    | jq -c --arg name "$2" '[.[] | select(.name == $name) | {id, name}]'
}

v2_switch_attribute() {
  kcadm get "realms/$V2_REALM" -c | jq -r --arg key "$V2_SWITCH_ATTRIBUTE" '.attributes[$key] // ""'
}

v2_fixture_passkey_ids() {
  kcadm get "users/$V2_FIXTURE_USER_UUID/credentials" -r "$V2_REALM" -c \
    | jq -r '.[] | select(.type == "webauthn-passwordless") | .id' | sort
}

v2_jwt_payload() {
  local segment
  segment=$(cut -d. -f2 <<<"$1")
  case $((${#segment} % 4)) in
    2) segment="${segment}==" ;;
    3) segment="${segment}=" ;;
  esac
  tr '_-' '/+' <<<"$segment" | base64 --decode
}

# PAR, Keycloak's own login form and the code exchange with curl, the way the browser stage
# below does it; leaves the access token in V2_ACCESS_TOKEN, its payload in V2_ACCESS_PAYLOAD
# and the ID token payload in V2_ID_PAYLOAD. The person is account-fixture unless a fourth
# argument names another username.
v2_login_account_center() {
  local label=$1 password=$2 client_secret=$3 username=${4:-account-fixture}
  local verifier challenge par request_uri_query page login_action status location code response id_token
  local cookies="$TEST_STATE_DIR/v2-login-$label.cookies" headers="$TEST_STATE_DIR/v2-login-$label.headers"
  verifier="v2-$label-verifier-0123456789abcdefghijklmnopqrstuvwxyz"
  challenge=$(printf '%s' "$verifier" | openssl dgst -binary -sha256 | openssl base64 -A | tr '+/' '-_' | tr -d '=')
  par=$(curl --fail --silent --show-error \
    --user "account-center:$client_secret" \
    --data-urlencode client_id=account-center \
    --data-urlencode response_type=code \
    --data-urlencode scope=openid \
    --data-urlencode redirect_uri=https://my.yildizskylab.com/api/auth/callback \
    --data-urlencode "code_challenge=$challenge" \
    --data-urlencode code_challenge_method=S256 \
    --data-urlencode "state=v2-$label" \
    --data-urlencode "nonce=v2-$label-nonce" \
    "http://localhost:18080/realms/$V2_REALM/protocol/openid-connect/ext/par/request")
  request_uri_query=$(jq -r '.request_uri | @uri' <<<"$par")
  page=$(curl --fail --silent --show-error --location \
    --cookie-jar "$cookies" --cookie "$cookies" \
    "http://localhost:18080/realms/$V2_REALM/protocol/openid-connect/auth?client_id=account-center&request_uri=$request_uri_query")
  login_action=$(grep -Eo '"loginAction"[[:space:]]*:[[:space:]]*"[^"]*"' <<<"$page" \
    | head -n 1 | sed -E 's/^"loginAction"[[:space:]]*:[[:space:]]*//' | jq -r . || true)
  [[ -n $login_action ]] || fail "v2 login $label: the login page exposed no login action"
  status=$(curl --silent --show-error \
    --output /dev/null \
    --dump-header "$headers" \
    --write-out '%{http_code}' \
    --cookie-jar "$cookies" --cookie "$cookies" \
    --data-urlencode "username=$username" \
    --data-urlencode "password=$password" \
    --data-urlencode credentialId= \
    "$login_action")
  [[ $status == 302 ]] || fail "v2 login $label: credential submission did not redirect (HTTP $status)"
  location=$(awk '
    tolower($1) == "location:" {
      sub(/^[^:]*:[[:space:]]*/, "")
      sub(/\r$/, "")
      print
    }
  ' "$headers")
  code=$(sed -n 's/.*[?&]code=\([^&]*\).*/\1/p' <<<"$location")
  [[ -n $code ]] || fail "v2 login $label: the authorization redirect lacks a code"
  response=$(curl --fail --silent --show-error \
    --user "account-center:$client_secret" \
    --data-urlencode grant_type=authorization_code \
    --data-urlencode client_id=account-center \
    --data-urlencode "code=$code" \
    --data-urlencode redirect_uri=https://my.yildizskylab.com/api/auth/callback \
    --data-urlencode "code_verifier=$verifier" \
    "http://localhost:18080/realms/$V2_REALM/protocol/openid-connect/token")
  V2_ACCESS_TOKEN=$(jq -r .access_token <<<"$response")
  [[ -n $V2_ACCESS_TOKEN && $V2_ACCESS_TOKEN != null ]] || fail "v2 login $label: no access token was issued"
  V2_ACCESS_PAYLOAD=$(v2_jwt_payload "$V2_ACCESS_TOKEN")
  id_token=$(jq -r .id_token <<<"$response")
  [[ -n $id_token && $id_token != null ]] || fail "v2 login $label: no ID token was issued"
  V2_ID_PAYLOAD=$(v2_jwt_payload "$id_token")
}

v2_admin_rest_status() {
  curl --silent --show-error \
    --output /dev/null \
    --write-out '%{http_code}' \
    -H "Authorization: Bearer $1" \
    "http://localhost:18080/admin/realms/$V2_REALM/$2"
}

v2_reconcile_log_must_be_quiet() {
  local log_file=$1
  grep -Fq 'Account Center Keycloak configuration is reconciled.' "$log_file" \
    || fail 'reconciliation did not report completion'
  # The reconciler identity has no user permissions, so the service-account roles of
  # keycloak-mailer and core-erasure are never readable from a reconcile run; those warnings
  # are the expected steady state.
  if grep -E '^\[reconcile\] ' "$log_file" \
    | grep -Ev 'unchanged|asserted|verified|WARNING: service-account roles of (keycloak-mailer|core-erasure) are not readable' >/dev/null; then
    grep -E '^\[reconcile\] ' "$log_file" \
      | grep -Ev 'unchanged|asserted|verified|WARNING: service-account roles of (keycloak-mailer|core-erasure) are not readable' >&2 || true
    fail 'a no-op reconciliation reported a change'
  fi
}

# The operator-run mailer provisioning script, non-interactive here because the fixture
# administrator password is known; the script accepts it only with SKY_HARNESS=1, in
# production kcadm prompts for it.
v2_create_mailer_client() {
  "${COMPOSE[@]}" run --rm --no-deps \
    -e KEYCLOAK_ADMIN_REALM=master \
    -e KEYCLOAK_MAILER_ADMIN_USERNAME=admin \
    -e KEYCLOAK_MAILER_ADMIN_PASSWORD=integration-admin-password \
    -e SKY_HARNESS=1 \
    --entrypoint /opt/keycloak/config/create-mailer-client.sh \
    keycloak-config "$@" 2>&1
}

# The legacy passkey cleanup, with the same harness-only password path. Extra compose run
# options (an injected kcadm, for example) come from v2_cleanup_run_options.
v2_cleanup_legacy_passkeys() {
  "${COMPOSE[@]}" run --rm --no-deps \
    -e KEYCLOAK_ADMIN_REALM=master \
    -e KEYCLOAK_CLEANUP_ADMIN_USERNAME=admin \
    -e KEYCLOAK_CLEANUP_ADMIN_PASSWORD=integration-admin-password \
    -e SKY_HARNESS=1 \
    ${v2_cleanup_run_options[@]+"${v2_cleanup_run_options[@]}"} \
    --entrypoint /opt/keycloak/config/cleanup-legacy-passkeys.sh \
    keycloak-config "$@" 2>&1
}

# The operator-run identity guardrails, with the same harness-only password path.
v2_identity_guardrails() {
  "${COMPOSE[@]}" run --rm --no-deps \
    -e KEYCLOAK_ADMIN_REALM=master \
    -e KEYCLOAK_GUARDRAILS_ADMIN_USERNAME=admin \
    -e KEYCLOAK_GUARDRAILS_ADMIN_PASSWORD=integration-admin-password \
    -e SKY_HARNESS=1 \
    --entrypoint /opt/keycloak/config/identity-guardrails.sh \
    keycloak-config "$@" 2>&1
}

# Runs after the first reconciliation. The reconciler must not create the
# keycloak-mailer client (it has no user permissions to assign its roles); it
# warns with the operator command instead. The harness then runs that script:
# dry run first, then apply. The fixture SkyMail client lacks skymail:mails:send
# (the role SkyMail creates in M1), which the script must report without creating
# it; the harness creates the role afterwards so the second pass proves the
# assignment.
stage_v2_after_first_reconciliation() {
  CURRENT_STAGE='v2 relying party id switch record and mailer client provisioning by the operator script'
  local skymail_uuid mailer_uuid service_user roles output
  # The fixture realm starts without a passwordless relying party id; the first run is the
  # switch production will see and must record its moment for the legacy passkey cleanup.
  grep -Fq "passkey relying party id switches from '(empty)' to 'localhost': realm attribute $V2_SWITCH_ATTRIBUTE=" \
    "$TEST_STATE_DIR/reconcile-first.log" \
    || fail 'first reconciliation did not report the relying party id switch'
  V2_SWITCHED_AT_FIRST=$(v2_switch_attribute)
  [[ $V2_SWITCHED_AT_FIRST =~ $V2_ISO_UTC ]] \
    || fail "realm attribute $V2_SWITCH_ATTRIBUTE was not recorded as an ISO-8601 UTC timestamp: '$V2_SWITCHED_AT_FIRST'"
  grep -Fq 'WARNING: client keycloak-mailer does not exist; run: docker compose -f docker-compose.yml run --rm --no-deps -it --entrypoint /opt/keycloak/config/create-mailer-client.sh keycloak-config --admin-user <admin> --apply' \
    "$TEST_STATE_DIR/reconcile-first.log" \
    || fail 'reconciler did not point at create-mailer-client.sh for the missing mailer client'
  [[ -z $(v2_client_uuid keycloak-mailer) ]] \
    || fail 'reconciler created the keycloak-mailer client on its own'
  # Outside the harness the administrator password never travels through the environment
  # (kcadm would receive it in argv); the script must refuse it without SKY_HARNESS=1.
  if "${COMPOSE[@]}" run --rm --no-deps \
    -e KEYCLOAK_ADMIN_REALM=master \
    -e KEYCLOAK_MAILER_ADMIN_USERNAME=admin \
    -e KEYCLOAK_MAILER_ADMIN_PASSWORD=integration-admin-password \
    --entrypoint /opt/keycloak/config/create-mailer-client.sh \
    keycloak-config >"$TEST_STATE_DIR/create-mailer-refused.log" 2>&1; then
    cat "$TEST_STATE_DIR/create-mailer-refused.log" >&2
    fail 'create-mailer-client.sh accepted an environment password without SKY_HARNESS=1'
  fi
  grep -Fq 'KEYCLOAK_MAILER_ADMIN_PASSWORD is accepted only by the test harness (SKY_HARNESS=1)' \
    "$TEST_STATE_DIR/create-mailer-refused.log" \
    || { cat "$TEST_STATE_DIR/create-mailer-refused.log" >&2; fail 'create-mailer-client.sh did not explain the refused environment password'; }
  [[ -z $(v2_client_uuid keycloak-mailer) ]] \
    || fail 'the refused mailer run created the client'
  # The dry run of a missing client plans the whole provisioning: client, roles scope, the
  # existing skymail:access assignment and scope mapping; skymail:mails:send is reported.
  output=$(v2_create_mailer_client)
  grep -Fq 'would create confidential service-account client keycloak-mailer' <<<"$output" \
    || { printf '%s\n' "$output" >&2; fail 'mailer dry run did not plan the client creation'; }
  grep -Fq 'would attach the roles default scope to keycloak-mailer' <<<"$output" \
    || { printf '%s\n' "$output" >&2; fail 'mailer dry run did not plan the roles default scope'; }
  grep -Fq 'would assign role skymail:access to the keycloak-mailer service account' <<<"$output" \
    || { printf '%s\n' "$output" >&2; fail 'mailer dry run did not plan the skymail:access assignment'; }
  grep -Fq 'would add scope mapping skymail:access to keycloak-mailer' <<<"$output" \
    || { printf '%s\n' "$output" >&2; fail 'mailer dry run did not plan the skymail:access scope mapping'; }
  grep -Fq 'WARNING: client skymail lacks the roles skymail:mails:send' <<<"$output" \
    || { printf '%s\n' "$output" >&2; fail 'mailer dry run did not report the missing skymail:mails:send role'; }
  grep -Fq 'dry run: 4 change(s) pending' <<<"$output" \
    || { printf '%s\n' "$output" >&2; fail 'mailer dry run did not count the client, scope and role steps'; }
  [[ -z $(v2_client_uuid keycloak-mailer) ]] \
    || fail 'mailer dry run created the client'
  output=$(v2_create_mailer_client --apply)
  printf '%s\n' "$output" >"$TEST_STATE_DIR/create-mailer-apply-1.log"
  grep -Fq 'client keycloak-mailer: created' <<<"$output" \
    || { printf '%s\n' "$output" >&2; fail 'mailer script did not create the client'; }
  grep -Fq 'WARNING: client skymail lacks the roles skymail:mails:send' <<<"$output" \
    || fail 'mailer script did not warn about the missing skymail:mails:send role'
  skymail_uuid=$(v2_client_uuid skymail)
  [[ $(kcadm get "clients/$skymail_uuid/roles" -r "$V2_REALM" -c \
    | jq '[.[] | select(.name == "skymail:mails:send")] | length') == 0 ]] \
    || fail 'mailer script created a SkyMail client role on its own'
  mailer_uuid=$(v2_client_uuid keycloak-mailer)
  [[ -n $mailer_uuid ]] || fail 'keycloak-mailer client was not created'
  service_user=$(kcadm get "clients/$mailer_uuid/service-account-user" -r "$V2_REALM" -c | jq -r .id)
  roles=$(kcadm get "users/$service_user/role-mappings/clients/$skymail_uuid" -r "$V2_REALM" -c)
  json_assert "$roles" '[.[].name] == ["skymail:access"]' \
    'keycloak-mailer service account did not receive the existing skymail:access role'
  output=$(v2_create_mailer_client)
  grep -Fq 'dry run: 0 change(s) pending' <<<"$output" \
    || { printf '%s\n' "$output" >&2; fail 'mailer script is not idempotent after apply'; }
  kcadm create "clients/$skymail_uuid/roles" -r "$V2_REALM" -s name=skymail:mails:send >/dev/null
}

# Drift injected before the second reconciliation, covering every v2 resource.
stage_v2_inject_drift() {
  CURRENT_STAGE='v2 drift injection'
  local scope_uuid core_mapper_uuid sky_mapper_uuid client_uuid account_uuid
  local mailer_uuid skymail_uuid service_user
  # A foreign realm attribute must survive the reconciler's own attribute write (Keycloak
  # drops every attribute a PUT with "attributes" leaves out).
  kcadm update "realms/$V2_REALM" \
    -s webAuthnPolicyPasswordlessRpId=drift.invalid \
    -s 'webAuthnPolicyPasswordlessExtraOrigins=["https://drift.invalid"]' \
    -s 'attributes."harness.keep"=kept' \
    -s bruteForceProtected=false \
    -s failureFactor=30 \
    -s permanentLockout=true \
    -s 'passwordPolicy=length(4)' >/dev/null
  kcadm get users/profile -r "$V2_REALM" -c \
    | jq '.unmanagedAttributePolicy = "ENABLED"
      | .attributes |= map(
          if .name == "email" then .permissions.edit = ["admin", "user"]
          elif .name == "schoolEmail" then .displayName = "Okul e-postası (özel)"
          elif .name == "lastName" then .permissions.edit = ["admin", "user"]
          else . end)
      | .attributes |= map(select(.name != "personalEmail"))
      | .attributes += [{"name": "legacyExtra", "displayName": "Legacy extra", "permissions": {"view": ["admin"], "edit": ["admin"]}, "multivalued": false}]' \
    | kcadm update users/profile -r "$V2_REALM" -n -f - >/dev/null
  scope_uuid=$(v2_scope_uuid account-center-account-api)
  core_mapper_uuid=$(kcadm get "client-scopes/$scope_uuid/protocol-mappers/models" -r "$V2_REALM" -c \
    | jq -r '.[] | select(.name == "account-api-core-audience") | .id')
  sky_mapper_uuid=$(kcadm get "client-scopes/$scope_uuid/protocol-mappers/models" -r "$V2_REALM" -c \
    | jq -r '.[] | select(.name == "account-api-sky-authorization") | .id')
  kcadm update "client-scopes/$scope_uuid/protocol-mappers/models/$core_mapper_uuid" \
    -r "$V2_REALM" -s 'config."included.client.audience"=drift-audience' >/dev/null
  kcadm delete "client-scopes/$scope_uuid/protocol-mappers/models/$sky_mapper_uuid" \
    -r "$V2_REALM" >/dev/null
  client_uuid=$(v2_client_uuid account-center)
  account_uuid=$(v2_client_uuid account)
  kcadm delete "clients/$client_uuid/scope-mappings/clients/$account_uuid" \
    -r "$V2_REALM" -b "$(v2_role_body "$account_uuid" manage-account-links)" >/dev/null
  kcadm update "clients/$client_uuid" -r "$V2_REALM" -s fullScopeAllowed=true >/dev/null
  # Mailer drift is repaired by the operator script (the reconciler only verifies);
  # the second reconciliation then has to report the repaired client as verified.
  mailer_uuid=$(v2_client_uuid keycloak-mailer)
  kcadm update "clients/$mailer_uuid" -r "$V2_REALM" \
    -s standardFlowEnabled=true -s directAccessGrantsEnabled=true -s fullScopeAllowed=true >/dev/null
  skymail_uuid=$(v2_client_uuid skymail)
  service_user=$(kcadm get "clients/$mailer_uuid/service-account-user" -r "$V2_REALM" -c | jq -r .id)
  kcadm delete "users/$service_user/role-mappings/clients/$skymail_uuid" \
    -r "$V2_REALM" -b "$(v2_role_body "$skymail_uuid" skymail:access)" >/dev/null
  local output
  output=$(v2_create_mailer_client --apply)
  printf '%s\n' "$output" >"$TEST_STATE_DIR/create-mailer-apply-2.log"
  grep -Fq 'update client keycloak-mailer flags' <<<"$output" \
    || { printf '%s\n' "$output" >&2; fail 'mailer script did not repair the drifted flags'; }
  grep -Fq 'assign role skymail:access' <<<"$output" \
    || fail 'mailer script did not re-assign skymail:access'
  grep -Fq 'assign role skymail:mails:send' <<<"$output" \
    || fail 'mailer script did not assign the newly created skymail:mails:send'
  if grep -Fq 'WARNING: client skymail lacks' <<<"$output"; then
    fail 'mailer script still warns about SkyMail roles after they were created'
  fi
}

stage_v2_assert_realm_identity() {
  CURRENT_STAGE='v2 passkey policy, login settings, brute force and password policy'
  local realm
  realm=$(kcadm get "realms/$V2_REALM" -c)
  json_assert "$realm" \
    '.webAuthnPolicyPasswordlessRpId == "localhost" and .webAuthnPolicyPasswordlessExtraOrigins == ["http://localhost:18080"]' \
    'passwordless relying party id or extra origins differ from the harness values'
  json_assert "$realm" \
    '.webAuthnPolicyPasswordlessRpEntityName == "SKY LAB" and (.webAuthnPolicyPasswordlessSignatureAlgorithms | sort) == ["ES256", "RS256"] and .webAuthnPolicyPasswordlessResidentKey == "required" and .webAuthnPolicyPasswordlessUserVerificationRequirement == "required" and .webAuthnPolicyPasswordlessPasskeysEnabled == true and .webAuthnPolicyPasswordlessMediation == "conditional" and .webAuthnPolicyPasswordlessAttestationConveyancePreference == "not specified" and .webAuthnPolicyPasswordlessAuthenticatorAttachment == "not specified" and .webAuthnPolicyPasswordlessCreateTimeout == 0 and .webAuthnPolicyPasswordlessAvoidSameAuthenticatorRegister == false and .webAuthnPolicyPasswordlessAcceptableAaguids == []' \
    'the rest of the passwordless policy was not preserved next to the relying party id'
  json_assert "$realm" \
    '.loginWithEmailAllowed == true and .duplicateEmailsAllowed == false and .editUsernameAllowed == false' \
    'realm login settings differ'
  json_assert "$realm" \
    '.bruteForceProtected == true and .permanentLockout == false and .failureFactor == 10 and .waitIncrementSeconds == 60 and .maxFailureWaitSeconds == 900 and .maxDeltaTimeSeconds == 43200 and .quickLoginCheckMilliSeconds == 1000 and .minimumQuickLoginWaitSeconds == 60' \
    'brute force protection differs'
  json_assert "$realm" '.passwordPolicy == "length(8) and notUsername and notEmail"' \
    'password policy differs'
  # Repairing the drifted relying party id is a switch: recorded again, later than the first
  # one, next to the foreign attribute that must not be dropped.
  json_assert "$realm" \
    '(.attributes[$key] | test($iso)) and .attributes["harness.keep"] == "kept"' \
    "realm attribute $V2_SWITCH_ATTRIBUTE is missing or the foreign realm attribute was dropped" \
    --arg key "$V2_SWITCH_ATTRIBUTE" --arg iso "$V2_ISO_UTC"
  [[ $(jq -r --arg key "$V2_SWITCH_ATTRIBUTE" '.attributes[$key]' <<<"$realm") > "$V2_SWITCHED_AT_FIRST" ]] \
    || fail "repairing the drifted relying party id did not advance $V2_SWITCH_ATTRIBUTE"
  grep -Fq "passkey relying party id switches from 'drift.invalid' to 'localhost'" \
    "$TEST_STATE_DIR/reconcile-second.log" \
    || fail 'second reconciliation did not report the relying party id repair as a switch'
}

stage_v2_assert_user_profile() {
  CURRENT_STAGE='v2 User Profile configuration'
  local profile attribute
  profile=$(kcadm get users/profile -r "$V2_REALM" -c)
  json_assert "$profile" '.unmanagedAttributePolicy == "ADMIN_VIEW"' \
    'unmanagedAttributePolicy is not ADMIN_VIEW'
  for attribute in firstName lastName email; do
    json_assert "$profile" \
      '[.attributes[] | select(.name == $name and (.permissions.edit | sort) == ["admin"] and (.permissions.view | sort) == ["admin", "user"])] | length == 1' \
      "$attribute is not user:view-only" --arg name "$attribute"
  done
  json_assert "$profile" \
    '[.attributes[] | select(.name == "username" and (.permissions.edit | sort) == ["admin", "user"])] | length == 1' \
    'username permissions were changed'
  for attribute in schoolEmail personalEmail personalEmailVerifiedAt skyNumber department university skyMail usernameChangedAt; do
    json_assert "$profile" \
      '[.attributes[] | select(.name == $name and (.permissions.view | sort) == ["admin", "user"] and (.permissions.edit | sort) == ["admin"] and (.displayName | length) > 0 and .group == "user-metadata")] | length == 1' \
      "SKY LAB attribute $attribute is missing or has wrong permissions" --arg name "$attribute"
  done
  json_assert "$profile" \
    '([.attributes[] | select((.name == "schoolEmail" or .name == "personalEmail") and (.validations | has("email")))] | length) == 2 and ([.attributes[] | select((.name == "usernameChangedAt" or .name == "personalEmailVerifiedAt") and (.validations.pattern.pattern | length) > 0)] | length) == 2' \
    'e-mail or timestamp validators are missing'
  json_assert "$profile" \
    '[.attributes[] | select(.name == "schoolEmail" and .displayName == "Okul e-postası (özel)")] | length == 1' \
    'an existing display name was overwritten instead of preserved'
  json_assert "$profile" \
    '([.attributes[] | select(.name == "legacyExtra")] | length) == 1 and ([.groups[] | select(.name == "user-metadata")] | length) == 1' \
    'an attribute or group outside the specification was dropped'
  json_assert "$profile" \
    '[.attributes[] | select(.name == "personalEmail" and .displayName == "Kişisel e-posta")] | length == 1' \
    'a missing attribute was not recreated with its Turkish display name'
}

stage_v2_assert_account_api_scope() {
  CURRENT_STAGE='v2 account-center-account-api scope and scope mappings'
  local scope_uuid mappers client client_uuid account_uuid account_roles
  scope_uuid=$(v2_scope_uuid account-center-account-api)
  mappers=$(kcadm get "client-scopes/$scope_uuid/protocol-mappers/models" -r "$V2_REALM" -c)
  json_assert "$mappers" \
    '[.[] | select(.name == "account-api-core-audience" and .protocolMapper == "oidc-audience-mapper" and .config["included.client.audience"] == "core" and .config["access.token.claim"] == "true" and .config["id.token.claim"] == "false")] | length == 1' \
    'core audience mapper differs'
  json_assert "$mappers" \
    '[.[] | select(.name == "account-api-manage-account-links" and .protocolMapper == "oidc-hardcoded-role-mapper" and .config.role == "account.manage-account-links")] | length == 1' \
    'manage-account-links role mapper differs'
  json_assert "$mappers" \
    '[.[] | select(.name == "account-api-sky-authorization" and .protocolMapper == "sky-authorization-mapper" and .config["access.token.claim"] == "true" and .config["id.token.claim"] == "false" and .config["userinfo.token.claim"] == "false" and .config["introspection.token.claim"] == "true")] | length == 1' \
    'sky_authorization SPI mapper differs'
  json_assert "$mappers" \
    '[.[] | select(.protocolMapper == "oidc-usermodel-client-role-mapper" and .name != "account-api-roles")] | length == 0' \
    'a client role mapper other than account-api-roles remains (it would need full scope)'
  json_assert "$mappers" \
    '[.[] | select(.protocolMapper == "oidc-audience-resolve-mapper")] | length == 0' \
    'an audience-resolve mapper was added'
  client_uuid=$(v2_client_uuid account-center)
  client=$(kcadm get "clients/$client_uuid" -r "$V2_REALM" -c)
  json_assert "$client" '.fullScopeAllowed == false' \
    'account-center must not have full scope: Admin REST would accept its tokens for realm-management role holders'
  account_uuid=$(v2_client_uuid account)
  account_roles=$(kcadm get "clients/$client_uuid/scope-mappings/clients/$account_uuid" -r "$V2_REALM" -c)
  json_assert "$account_roles" \
    '([.[].name] | sort) == ["manage-account", "manage-account-links", "view-profile"]' \
    'account client scope mappings differ from the allowlist'
}

stage_v2_assert_mailer_client() {
  CURRENT_STAGE='v2 keycloak-mailer service account'
  local mailer_uuid mailer skymail_uuid service_user roles scope_roles secret token payload
  mailer_uuid=$(v2_client_uuid keycloak-mailer)
  mailer=$(kcadm get "clients/$mailer_uuid" -r "$V2_REALM" -c)
  json_assert "$mailer" \
    '.publicClient == false and .serviceAccountsEnabled == true and .standardFlowEnabled == false and .directAccessGrantsEnabled == false and .implicitFlowEnabled == false and .fullScopeAllowed == false and .clientAuthenticatorType == "client-secret"' \
    'keycloak-mailer client contract differs'
  skymail_uuid=$(v2_client_uuid skymail)
  service_user=$(kcadm get "clients/$mailer_uuid/service-account-user" -r "$V2_REALM" -c | jq -r .id)
  [[ -n $service_user && $service_user != null ]] || fail 'keycloak-mailer service-account user is missing'
  roles=$(kcadm get "users/$service_user/role-mappings/clients/$skymail_uuid" -r "$V2_REALM" -c)
  json_assert "$roles" '([.[].name] | sort) == ["skymail:access", "skymail:mails:send"]' \
    'keycloak-mailer service account roles differ'
  scope_roles=$(kcadm get "clients/$mailer_uuid/scope-mappings/clients/$skymail_uuid" -r "$V2_REALM" -c)
  json_assert "$scope_roles" '([.[].name] | sort) == ["skymail:access", "skymail:mails:send"]' \
    'keycloak-mailer scope mappings differ'
  grep -Fq 'client keycloak-mailer: verified' "$TEST_STATE_DIR/reconcile-second.log" \
    || fail 'reconciler did not verify the provisioned mailer client'
  if grep -Fq 'scope mappings of keycloak-mailer are' "$TEST_STATE_DIR/reconcile-second.log"; then
    fail 'reconciler reports drifted mailer scope mappings after the operator script ran'
  fi
  grep -Fq 'WARNING: service-account roles of keycloak-mailer are not readable with the reconciler identity' \
    "$TEST_STATE_DIR/reconcile-second.log" \
    || fail 'reconciler identity unexpectedly reads user role mappings'
  secret=$(kcadm get "clients/$mailer_uuid/client-secret" -r "$V2_REALM" -c | jq -r .value)
  [[ -n $secret && $secret != null ]] || fail 'keycloak-mailer secret was not generated'
  for log_file in "$TEST_STATE_DIR"/reconcile-*.log "$TEST_STATE_DIR"/create-mailer-*.log; do
    [[ $(cat "$log_file") != *"$secret"* ]] || fail 'keycloak-mailer secret leaked into a log'
  done
  token=$(curl --fail --silent --show-error \
    --user "keycloak-mailer:$secret" \
    --data-urlencode grant_type=client_credentials \
    "http://localhost:18080/realms/$V2_REALM/protocol/openid-connect/token" | jq -r .access_token)
  [[ -n $token && $token != null ]] || fail 'keycloak-mailer client credentials grant failed'
  payload=$(cut -d. -f2 <<<"$token")
  case $((${#payload} % 4)) in
    2) payload="${payload}==" ;;
    3) payload="${payload}=" ;;
  esac
  payload=$(tr '_-' '/+' <<<"$payload" | base64 --decode)
  json_assert "$payload" \
    '.azp == "keycloak-mailer" and (.resource_access.skymail.roles | sort) == ["skymail:access", "skymail:mails:send"] and (.resource_access | keys) == ["skymail"]' \
    'keycloak-mailer token does not carry exactly the SkyMail roles'
}

# Wrong mailer flags are a security drift the reconciler cannot repair itself; it must
# fail and name the operator command, and the operator script must repair it.
stage_v2_mailer_drift_is_reported() {
  CURRENT_STAGE='v2 mailer flag drift detection'
  local mailer_uuid output
  mailer_uuid=$(v2_client_uuid keycloak-mailer)
  kcadm update "clients/$mailer_uuid" -r "$V2_REALM" -s directAccessGrantsEnabled=true >/dev/null
  if "${COMPOSE[@]}" run --rm --no-deps keycloak-config >"$TEST_STATE_DIR/reconcile-mailer-drift.log" 2>&1; then
    fail 'reconciliation succeeded although the mailer client allows direct grants'
  fi
  grep -Fq 'Client keycloak-mailer drifted' "$TEST_STATE_DIR/reconcile-mailer-drift.log" \
    || fail 'reconciler did not name the drifted mailer client'
  grep -Fq 'create-mailer-client.sh keycloak-config --admin-user <admin> --apply' \
    "$TEST_STATE_DIR/reconcile-mailer-drift.log" \
    || fail 'reconciler did not name the operator command for the mailer drift'
  output=$(v2_create_mailer_client --apply)
  printf '%s\n' "$output" >"$TEST_STATE_DIR/create-mailer-apply-3.log"
  grep -Fq 'applied 1 change(s)' <<<"$output" \
    || { printf '%s\n' "$output" >&2; fail 'mailer script did not repair exactly the drifted flag'; }
}

# The operator script for what the reconciler identity may not do (no user or identity
# provider permissions). The fixture reproduces production: core's service account holds
# realm-management manage-clients next to the roles core needs, core has one of its four
# certificate roles, and OBS (created here, like the sky-account contract does, so the login
# page stays without an identity provider button) has the department mapper on INHERIT next
# to two FORCE mappers that must not change. Dry run, apply, then a second run that writes
# nothing; core's own token then reads its roles and role holders but cannot create a role.
stage_v2_identity_guardrails() {
  CURRENT_STAGE='identity guardrails operator script (core certificate roles, OBS department sync, core least privilege)'
  local core_uuid realm_management_uuid service_user roles_before roles_after department_id output
  local other_mappers_before other_mappers_after idp_before idp_after newest_before new_events
  local core_secret core_token status
  core_uuid=$(v2_client_uuid core)
  realm_management_uuid=$(v2_client_uuid realm-management)
  service_user=$(kcadm get "clients/$core_uuid/service-account-user" -r "$V2_REALM" -c | jq -r .id)
  [[ -n $service_user && $service_user != null ]] || fail 'the core fixture has no service account'
  roles_before=$(kcadm get "users/$service_user/role-mappings/clients/$realm_management_uuid" -r "$V2_REALM" -c \
    | jq -c '[.[].name] | sort')
  json_assert "$roles_before" '. == ["manage-clients","manage-users","query-clients","query-groups","query-users","view-clients","view-users"]' \
    'the core service account fixture does not start with production realm-management roles'

  kcadm delete identity-provider/instances/OBS -r "$V2_REALM" >/dev/null 2>&1 || true
  kcadm create identity-provider/instances -r "$V2_REALM" \
    -s alias=OBS -s providerId=microsoft -s enabled=true -s config.syncMode=LEGACY \
    -s 'config.clientId=integration-client' -s 'config.clientSecret=integration-secret' >/dev/null
  kcadm create identity-provider/instances/OBS/mappers -r "$V2_REALM" \
    -b '{"name":"department mapper","identityProviderAlias":"OBS","identityProviderMapper":"microsoft-department-mapper","config":{"syncMode":"INHERIT"}}' >/dev/null
  kcadm create identity-provider/instances/OBS/mappers -r "$V2_REALM" \
    -b '{"name":"school-email-importer","identityProviderAlias":"OBS","identityProviderMapper":"microsoft-user-attribute-mapper","config":{"syncMode":"FORCE","jsonField":"mail","userAttribute":"schoolEmail"}}' >/dev/null
  kcadm create identity-provider/instances/OBS/mappers -r "$V2_REALM" \
    -b '{"name":"university","identityProviderAlias":"OBS","identityProviderMapper":"hardcoded-attribute-idp-mapper","config":{"syncMode":"FORCE","attribute":"university","attribute.value":"YTU"}}' >/dev/null
  department_id=$(kcadm get identity-provider/instances/OBS/mappers -r "$V2_REALM" -c \
    | jq -r '.[] | select(.name == "department mapper") | .id')
  other_mappers_before=$(kcadm get identity-provider/instances/OBS/mappers -r "$V2_REALM" -c \
    | jq -S -c '[.[] | select(.name != "department mapper")] | sort_by(.name)')
  idp_before=$(kcadm get identity-provider/instances/OBS -r "$V2_REALM" -c | jq -S -c '.')

  # Outside the harness the administrator password never travels through the environment.
  if "${COMPOSE[@]}" run --rm --no-deps \
    -e KEYCLOAK_ADMIN_REALM=master \
    -e KEYCLOAK_GUARDRAILS_ADMIN_USERNAME=admin \
    -e KEYCLOAK_GUARDRAILS_ADMIN_PASSWORD=integration-admin-password \
    --entrypoint /opt/keycloak/config/identity-guardrails.sh \
    keycloak-config >"$TEST_STATE_DIR/identity-guardrails-refused.log" 2>&1; then
    cat "$TEST_STATE_DIR/identity-guardrails-refused.log" >&2
    fail 'identity-guardrails.sh accepted an environment password without SKY_HARNESS=1'
  fi
  grep -Fq 'KEYCLOAK_GUARDRAILS_ADMIN_PASSWORD is accepted only by the test harness (SKY_HARNESS=1)' \
    "$TEST_STATE_DIR/identity-guardrails-refused.log" \
    || { cat "$TEST_STATE_DIR/identity-guardrails-refused.log" >&2; fail 'identity-guardrails.sh did not explain the refused environment password'; }

  output=$(v2_identity_guardrails)
  printf '%s\n' "$output" >"$TEST_STATE_DIR/identity-guardrails-dry-run.log"
  local expected
  for expected in \
    'would create client role certificate:template:manage on core' \
    'would create client role certificate:binding:manage on core' \
    'would create client role certificate:revoke on core' \
    "would set sync mode of identity provider OBS mapper 'department mapper' from INHERIT to FORCE" \
    'would remove realm-management role manage-clients from service-account-core once the certificate roles above exist' \
    'service-account-core keeps its other realm-management roles: ' \
    'dry run: 5 change(s) pending'; do
    grep -Fq -- "$expected" <<<"$output" \
      || { printf '%s\n' "$output" >&2; fail "identity guardrails dry run did not print: $expected"; }
  done
  if grep -Fq 'would create client role certificate:issue' <<<"$output"; then
    fail 'identity guardrails dry run planned an existing certificate role'
  fi
  [[ $(kcadm get "clients/$core_uuid/roles" -r "$V2_REALM" -c | jq '[.[] | select(.name | startswith("certificate:"))] | length') == 1 ]] \
    || fail 'identity guardrails dry run created a role'
  [[ $(kcadm get "identity-provider/instances/OBS/mappers/$department_id" -r "$V2_REALM" -c | jq -r .config.syncMode) == INHERIT ]] \
    || fail 'identity guardrails dry run changed the department mapper'
  [[ $(kcadm get "users/$service_user/role-mappings/clients/$realm_management_uuid" -r "$V2_REALM" -c | jq -c '[.[].name] | sort') == "$roles_before" ]] \
    || fail 'identity guardrails dry run changed the core service account roles'

  output=$(v2_identity_guardrails --apply)
  printf '%s\n' "$output" >"$TEST_STATE_DIR/identity-guardrails-apply.log"
  grep -Fq 'applied 5 change(s)' <<<"$output" \
    || { printf '%s\n' "$output" >&2; fail 'identity guardrails apply did not perform the five planned changes'; }
  json_assert "$(kcadm get "clients/$core_uuid/roles" -r "$V2_REALM" -c)" \
    '([.[] | select(.name | startswith("certificate:")) | .name] | sort) == ["certificate:binding:manage","certificate:issue","certificate:revoke","certificate:template:manage"] and ([.[] | select(.name | startswith("certificate:")) | .description // ""] | unique) == [""]' \
    'core does not hold exactly the four certificate roles without descriptions, the way core created them'
  json_assert "$(kcadm get "identity-provider/instances/OBS/mappers/$department_id" -r "$V2_REALM" -c)" \
    '.name == "department mapper" and .identityProviderMapper == "microsoft-department-mapper" and .config == {"syncMode": "FORCE"}' \
    'the OBS department mapper is not exactly the same mapper on sync mode FORCE'
  other_mappers_after=$(kcadm get identity-provider/instances/OBS/mappers -r "$V2_REALM" -c \
    | jq -S -c '[.[] | select(.name != "department mapper")] | sort_by(.name)')
  [[ $other_mappers_after == "$other_mappers_before" ]] || fail 'identity guardrails changed another OBS mapper'
  idp_after=$(kcadm get identity-provider/instances/OBS -r "$V2_REALM" -c | jq -S -c '.')
  [[ $idp_after == "$idp_before" ]] || fail 'identity guardrails changed the OBS identity provider itself'
  roles_after=$(kcadm get "users/$service_user/role-mappings/clients/$realm_management_uuid" -r "$V2_REALM" -c \
    | jq -c '[.[].name] | sort')
  json_assert "$roles_after" '. == ["manage-users","query-clients","query-groups","query-users","view-clients","view-users"]' \
    'the core service account did not lose exactly manage-clients (it must keep view-clients and query-clients)'
  json_assert "$(kcadm get "users/$service_user/role-mappings/clients/$realm_management_uuid/composite" -r "$V2_REALM" -c)" \
    '([.[].name] | index("manage-clients")) == null' \
    'the core service account still holds manage-clients effectively'

  # core's own token: what core does at startup and for certificates still works, a client
  # write does not.
  kcadm create "clients/$core_uuid/client-secret" -r "$V2_REALM" >/dev/null 2>&1
  core_secret=$(kcadm get "clients/$core_uuid/client-secret" -r "$V2_REALM" -c | jq -r .value)
  core_token=$(curl --fail --silent --show-error \
    --user "core:$core_secret" \
    -d grant_type=client_credentials \
    "http://localhost:18080/realms/$V2_REALM/protocol/openid-connect/token" | jq -r .access_token)
  [[ -n $core_token && $core_token != null ]] || fail 'core client credentials grant failed'
  for expected in "clients?clientId=core" "clients/$core_uuid/roles" \
    "clients/$core_uuid/roles/certificate:issue/users" "clients/$core_uuid/roles/certificate:issue/groups"; do
    status=$(v2_admin_rest_status "$core_token" "$expected")
    [[ $status == 200 ]] || fail "core lost read access to $expected (HTTP $status)"
  done
  status=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
    -X POST -H "Authorization: Bearer $core_token" -H 'Content-Type: application/json' \
    -d '{"name":"certificate:probe"}' \
    "http://localhost:18080/admin/realms/$V2_REALM/clients/$core_uuid/roles")
  [[ $status == 403 ]] || fail "core can still create client roles without manage-clients (HTTP $status)"

  newest_before=$(kcadm get admin-events -r "$V2_REALM" -q max=1 -c | jq -r '.[0].time // 0')
  output=$(v2_identity_guardrails)
  grep -Fq 'dry run: 0 change(s) pending' <<<"$output" \
    || { printf '%s\n' "$output" >&2; fail 'identity guardrails are not idempotent after apply'; }
  output=$(v2_identity_guardrails --apply)
  printf '%s\n' "$output" >"$TEST_STATE_DIR/identity-guardrails-noop.log"
  grep -Fq 'applied 0 change(s)' <<<"$output" \
    || { printf '%s\n' "$output" >&2; fail 'a second identity guardrails apply changed something'; }
  new_events=$(kcadm get admin-events -r "$V2_REALM" -q max=200 -c \
    | jq --argjson since "$newest_before" '[.[] | select(.time > $since)] | length')
  [[ $new_events == 0 ]] || fail "a no-op identity guardrails run produced $new_events admin event(s)"

  kcadm delete identity-provider/instances/OBS -r "$V2_REALM" >/dev/null
  output=$(v2_identity_guardrails)
  grep -Fq 'identity provider OBS does not exist in realm e-skylab-test; department mapper sync mode skipped' <<<"$output" \
    || { printf '%s\n' "$output" >&2; fail 'identity guardrails did not report the missing OBS identity provider'; }
  grep -Fq 'dry run: 0 change(s) pending' <<<"$output" \
    || { printf '%s\n' "$output" >&2; fail 'identity guardrails planned a change without the OBS identity provider'; }
}

# A further reconciliation of an already reconciled realm must write nothing:
# no admin event, no "updated" log line, identical state.
stage_v2_reconcile_noop() {
  CURRENT_STAGE='v2 no-op reconciliation'
  local newest_before snapshot_before snapshot_after new_events
  newest_before=$(kcadm get admin-events -r "$V2_REALM" -q max=1 -c | jq -r '.[0].time // 0')
  snapshot_before=$(v2_state_snapshot)
  "${COMPOSE[@]}" run --rm --no-deps keycloak-config >"$TEST_STATE_DIR/reconcile-noop.log" 2>&1
  v2_reconcile_log_must_be_quiet "$TEST_STATE_DIR/reconcile-noop.log"
  snapshot_after=$(v2_state_snapshot)
  [[ $snapshot_after == "$snapshot_before" ]] \
    || fail 'a no-op reconciliation changed the realm state'
  new_events=$(kcadm get admin-events -r "$V2_REALM" -q max=200 -c \
    | jq --argjson since "$newest_before" '[.[] | select(.time > $since)] | length')
  [[ $new_events == 0 ]] \
    || fail "a no-op reconciliation produced $new_events admin event(s)"
}

v2_state_snapshot() {
  local client_uuid mailer_uuid account_uuid skymail_uuid service_user scope_uuid
  client_uuid=$(v2_client_uuid account-center)
  mailer_uuid=$(v2_client_uuid keycloak-mailer)
  account_uuid=$(v2_client_uuid account)
  skymail_uuid=$(v2_client_uuid skymail)
  service_user=$(kcadm get "clients/$mailer_uuid/service-account-user" -r "$V2_REALM" -c | jq -r .id)
  {
    kcadm get "realms/$V2_REALM" -c
    kcadm get users/profile -r "$V2_REALM" -c
    kcadm get authentication/required-actions -r "$V2_REALM" -c
    kcadm get "clients/$client_uuid" -r "$V2_REALM" -c
    kcadm get "clients/$mailer_uuid" -r "$V2_REALM" -c
    kcadm get "clients/$client_uuid/default-client-scopes" -r "$V2_REALM" -c
    kcadm get "clients/$client_uuid/scope-mappings/clients/$account_uuid" -r "$V2_REALM" -c
    kcadm get "users/$service_user/role-mappings/clients/$skymail_uuid" -r "$V2_REALM" -c
    kcadm get "clients/$mailer_uuid/scope-mappings/clients/$skymail_uuid" -r "$V2_REALM" -c
    for scope_uuid in $(v2_scope_uuid account-center-account-api) $(v2_scope_uuid account-center-core-claims) $(v2_scope_uuid skyapp-account-center-audience); do
      kcadm get "client-scopes/$scope_uuid" -r "$V2_REALM" -c
      kcadm get "client-scopes/$scope_uuid/protocol-mappers/models" -r "$V2_REALM" -c
    done
    lca_state_snapshot
    kcadm get authentication/flows -r "$V2_REALM" -c
  } | jq -S -c '.'
}

stage_v2_assert_token_contract() {
  CURRENT_STAGE='v2 access token audience and sky_authorization contract'
  local payload=$1
  json_assert "$payload" \
    '((.aud | if type == "array" then . else [.] end) | sort) == ["account", "core"]' \
    'access token audience is not exactly account and core'
  json_assert "$payload" \
    '.sky_authorization.core.roles == ["url:create"]' \
    'sky_authorization does not carry the fixture client role'
  json_assert "$payload" \
    '(.resource_access.core == null) and ((.resource_access | keys) == ["account"]) and (.realm_access == null)' \
    'access token leaks core roles or realm roles'
  json_assert "$payload" \
    '((.resource_access.account.roles | index("manage-account")) != null) and ((.resource_access.account.roles | index("view-profile")) != null) and ((.resource_access.account.roles | index("manage-account-links")) != null)' \
    'access token lacks the account roles'
}

# fullScopeAllowed=false is what keeps a my. token out of Keycloak Admin REST: AdminAuth
# authorizes with user.hasRole(role) && client.hasScope(role), and client.hasScope is true
# for every role once full scope is on. The fixture person receives view-users; the positive
# control shows that a full-scope token would open Admin REST, the reconciled client's token
# is refused and its sky_authorization view still names no management client.
stage_v2_admin_rest_is_not_reachable_with_account_center_tokens() {
  CURRENT_STAGE='v2 Admin REST refuses account-center tokens of a realm-management role holder'
  local client_secret=$1
  local client_uuid realm_management_uuid role_body status
  client_uuid=$(v2_client_uuid account-center)
  realm_management_uuid=$(v2_client_uuid realm-management)
  role_body=$(v2_role_body "$realm_management_uuid" view-users)
  [[ $(jq length <<<"$role_body") == 1 ]] || fail 'realm-management view-users role is missing'
  kcadm create "users/$V2_FIXTURE_USER_UUID/role-mappings/clients/$realm_management_uuid" \
    -r "$V2_REALM" -b "$role_body" >/dev/null

  kcadm update "clients/$client_uuid" -r "$V2_REALM" -s fullScopeAllowed=true >/dev/null
  v2_login_account_center full-scope fixture-password-change-me "$client_secret"
  status=$(v2_admin_rest_status "$V2_ACCESS_TOKEN" 'users?max=1')
  kcadm update "clients/$client_uuid" -r "$V2_REALM" -s fullScopeAllowed=false >/dev/null
  [[ $status == 200 ]] \
    || fail "positive control: a full-scope account-center token did not open Admin REST (HTTP $status)"

  v2_login_account_center reconciled fixture-password-change-me "$client_secret"
  status=$(v2_admin_rest_status "$V2_ACCESS_TOKEN" 'users?max=1')
  [[ $status == 403 ]] \
    || fail "Admin REST accepted an account-center token of a view-users holder (HTTP $status)"
  status=$(v2_admin_rest_status "$V2_ACCESS_TOKEN" 'users/count')
  [[ $status == 403 ]] \
    || fail "Admin REST user count accepted an account-center token of a view-users holder (HTTP $status)"
  json_assert "$V2_ACCESS_PAYLOAD" \
    '.sky_authorization == {"core": {"roles": ["url:create"]}} and (.sky_authorization | has("realm-management") | not)' \
    'sky_authorization must list the core roles and never the realm-management client'
  json_assert "$V2_ACCESS_PAYLOAD" \
    '((.aud | if type == "array" then . else [.] end) | sort) == ["account", "core"] and (.resource_access | keys) == ["account"] and .realm_access == null' \
    'the view-users holder token widened its audience or roles'
  kcadm delete "users/$V2_FIXTURE_USER_UUID/role-mappings/clients/$realm_management_uuid" \
    -r "$V2_REALM" -b "$role_body" >/dev/null
  [[ $(kcadm get "users/$V2_FIXTURE_USER_UUID/role-mappings/clients/$realm_management_uuid" \
    -r "$V2_REALM" -c | jq length) == 0 ]] \
    || fail 'view-users was not removed from the fixture person'
}

# sky_authorization is an access token claim: absent from the ID token and userinfo, present
# in the introspection response the resource servers read. Keycloak 26.7 answers introspection
# only to a client in the token audience, so the core resource server introspects with its own
# secret; account-center itself (not an audience) must keep getting active=false.
stage_v2_assert_claim_surfaces() {
  CURRENT_STAGE='v2 sky_authorization claim surfaces'
  local access_token=$1 id_payload=$2 client_secret=$3 userinfo introspection core_uuid core_secret
  json_assert "$id_payload" '.sky_authorization == null' 'sky_authorization leaked into the ID token'
  userinfo=$(curl --fail --silent --show-error \
    -H "Authorization: Bearer $access_token" \
    "http://localhost:18080/realms/$V2_REALM/protocol/openid-connect/userinfo")
  json_assert "$userinfo" '.sub == $sub and .sky_authorization == null' \
    'sky_authorization leaked into userinfo' --arg sub "$V2_FIXTURE_USER_UUID"
  core_uuid=$(v2_client_uuid core)
  kcadm create "clients/$core_uuid/client-secret" -r "$V2_REALM" >/dev/null 2>&1
  core_secret=$(kcadm get "clients/$core_uuid/client-secret" -r "$V2_REALM" -c | jq -r .value)
  [[ -n $core_secret && $core_secret != null ]] || fail 'the core fixture client has no secret to introspect with'
  introspection=$(curl --fail --silent --show-error \
    --user "core:$core_secret" \
    --data-urlencode "token=$access_token" \
    "http://localhost:18080/realms/$V2_REALM/protocol/openid-connect/token/introspect")
  json_assert "$introspection" \
    '.active == true and .sky_authorization == {"core": {"roles": ["url:create"]}}' \
    'introspection by the core resource server does not carry sky_authorization'
  introspection=$(curl --fail --silent --show-error \
    --user "account-center:$client_secret" \
    --data-urlencode "token=$access_token" \
    "http://localhost:18080/realms/$V2_REALM/protocol/openid-connect/token/introspect")
  json_assert "$introspection" '.active == false and .sky_authorization == null' \
    'introspection answered a client outside the token audience'
}

# core keeps a person's university, department and faculty in step with the YTÜ login from
# any token that carries the university and department claims (C2). Account Center's own
# access token carries them through the account-center-core-claims scope, from the user
# attributes, as plain strings like the realm's department_ve_university_to_jwt scope: in the
# access token and in core's introspection answer, never in the ID token or userinfo. A person
# without the attributes gets neither claim, so core never reads an empty value as a change.
stage_v2_assert_ytu_claims() {
  CURRENT_STAGE='v2 university and department claims of account-center tokens'
  local client_secret=$1
  local university='Yıldız Teknik Üniversitesi' department='Bilgisayar Mühendisliği'
  local stale_user user_uuid password userinfo core_uuid core_secret introspection
  v2_login_account_center ytu-absent fixture-password-change-me "$client_secret"
  json_assert "$V2_ACCESS_PAYLOAD" '(has("university") or has("department")) | not' \
    'the access token of a person without YTÜ attributes carries university or department'

  while IFS= read -r stale_user; do
    [[ -n $stale_user ]] || continue
    kcadm delete "users/$stale_user" -r "$V2_REALM" >/dev/null
  done < <(kcadm get users -r "$V2_REALM" -c -q username=ytu-claims-fixture -q exact=true | jq -r '.[].id')
  password=$(openssl rand -base64 24 | tr -d '\n')
  user_uuid=$(jq -n \
    --arg password "$password" --arg university "$university" --arg department "$department" \
    '{username: "ytu-claims-fixture", enabled: true, emailVerified: true,
      firstName: "Ytu", lastName: "Fixture", email: "ytu-claims-fixture@example.invalid",
      attributes: {university: [$university], department: [$department]},
      credentials: [{type: "password", value: $password, temporary: false}]}' \
    | kcadm create users -r "$V2_REALM" -i -f -)
  [[ -n $user_uuid ]] || fail 'the YTÜ claims fixture person was not created'
  json_assert "$(kcadm get "users/$user_uuid" -r "$V2_REALM" -c)" \
    '.attributes.university == [$university] and .attributes.department == [$department]' \
    'the YTÜ claims fixture person does not hold the university and department attributes' \
    --arg university "$university" --arg department "$department"

  v2_login_account_center ytu-present "$password" "$client_secret" ytu-claims-fixture
  json_assert "$V2_ACCESS_PAYLOAD" \
    '.university == $university and .department == $department' \
    'the account-center access token does not carry university and department as plain strings' \
    --arg university "$university" --arg department "$department"
  json_assert "$V2_ID_PAYLOAD" '(has("university") or has("department")) | not' \
    'university or department leaked into the account-center ID token'
  userinfo=$(curl --fail --silent --show-error \
    -H "Authorization: Bearer $V2_ACCESS_TOKEN" \
    "http://localhost:18080/realms/$V2_REALM/protocol/openid-connect/userinfo")
  json_assert "$userinfo" '.sub == $sub and ((has("university") or has("department")) | not)' \
    'university or department leaked into userinfo' --arg sub "$user_uuid"
  core_uuid=$(v2_client_uuid core)
  core_secret=$(kcadm get "clients/$core_uuid/client-secret" -r "$V2_REALM" -c | jq -r .value)
  [[ -n $core_secret && $core_secret != null ]] || fail 'the core fixture client has no secret to introspect with'
  introspection=$(curl --fail --silent --show-error \
    --user "core:$core_secret" \
    --data-urlencode "token=$V2_ACCESS_TOKEN" \
    "http://localhost:18080/realms/$V2_REALM/protocol/openid-connect/token/introspect")
  json_assert "$introspection" \
    '.active == true and .university == $university and .department == $department' \
    'introspection by the core resource server does not carry university and department' \
    --arg university "$university" --arg department "$department"
  kcadm delete "users/$user_uuid" -r "$V2_REALM" >/dev/null
}

# One passkey registered through Keycloak's own login page with a Chromium virtual
# authenticator, after the relying party id switched back to the harness value.
v2_register_passkey_after_switch() {
  local client_secret=$1 config_file="$TEST_STATE_DIR/passkey-register.json"
  jq -n \
    --arg baseUrl 'http://localhost:18080' \
    --arg realm "$V2_REALM" \
    --arg callbackUrl 'https://my.yildizskylab.com/api/auth/callback' \
    --arg clientId 'account-center' \
    --arg clientSecret "$client_secret" \
    --arg username 'account-fixture' \
    --arg password 'fixture-password-change-me' \
    '{baseUrl: $baseUrl, realm: $realm, callbackUrl: $callbackUrl, clientId: $clientId, clientSecret: $clientSecret, username: $username, password: $password}' \
    >"$config_file"
  chmod 0600 "$config_file"
  (
    cd "$SCRIPT_DIR/../theme"
    PASSKEY_REGISTER_CONFIG="$config_file" \
      npx --no-install playwright test \
        --config=playwright.integration.config.ts \
        tests/integration/passkey-register.spec.ts
  )
}

# The Chromium stage registered a passkey under the current relying party id. The realm then
# switches its relying party id away and back through the reconciler (each switch is recorded,
# the latest wins), a second passkey is registered after the last switch, and the cleanup must
# delete exactly the passkeys registered before that switch: never with a later cutover, never
# silently when a deletion fails.
# ---------------------------------------------------------------------------
# K5 (ADR-0045): Keycloak's system mails are templated in SkyMail and sent by it,
# with the realm's own SMTP as the fallback. The fixture `skymail` service is both
# the SkyMail single-mail task API and the SMTP sink the fallback delivers to, so
# one stage proves the whole path: the real keycloak-mailer service account obtains
# a real client-credentials token against this Keycloak, the sender posts the mapped
# template key with every variable, and a refused mail still reaches the recipient.
# ---------------------------------------------------------------------------
sky_mail_fixture_records() {
  "${COMPOSE[@]}" logs --no-color --no-log-prefix skymail 2>/dev/null \
    | sed -n 's/^SKYMAIL_FIXTURE //p'
}

# Prints the last fixture record of $1 for recipient $2, waiting for it to arrive.
sky_mail_await_record() {
  local event=$1 recipient=$2 attempt record
  for attempt in $(seq 1 45); do
    record=$(sky_mail_fixture_records \
      | jq -c --arg event "$event" --arg recipient "$recipient" \
        'select(.event == $event and ((.recipient_email // (.recipients // [])[0]) == $recipient))' \
      | tail -n 1)
    if [[ -n $record ]]; then
      printf '%s\n' "$record"
      return 0
    fi
    sleep 1
  done
  return 1
}

sky_mail_send_verify_email() {
  local user_uuid=$1
  kcadm update "users/$user_uuid/send-verify-email" -r "$V2_REALM" -n -b '{}' >/dev/null
}

sky_mail_create_user() {
  local username=$1 address=$2
  kcadm create users -r "$V2_REALM" -i \
    -s "username=$username" -s enabled=true -s emailVerified=false \
    -s firstName=Sky -s lastName=Mail -s "email=$address"
}

stage_k5_system_mail_through_skymail() {
  CURRENT_STAGE='K5 Keycloak system mail through SkyMail'
  local mailer_uuid secret realm_display sent_uuid missing_uuid fallback_uuid
  local task keycloak_log smtp_record posted user_uuid

  mailer_uuid=$(v2_client_uuid keycloak-mailer)
  secret=$(kcadm get "clients/$mailer_uuid/client-secret" -r "$V2_REALM" -c | jq -r .value)
  [[ -n $secret && $secret != null ]] \
    || fail 'keycloak-mailer secret is not readable for the SkyMail sender'
  printf '%s\n' "$secret" >"$sky_mail_dir/client.secret"
  chmod 0644 "$sky_mail_dir/client.secret"

  realm_display=$(kcadm get "realms/$V2_REALM" -c | jq -r '.displayName // ""')
  [[ -n $realm_display ]] || fail 'the fixture realm has no display name to send to SkyMail'
  # The fallback must genuinely deliver, so the realm points at the fixture SMTP sink.
  kcadm update "realms/$V2_REALM" \
    -s smtpServer.host=skymail \
    -s smtpServer.port=1025 \
    -s smtpServer.from=noreply@yildizskylab.com \
    -s 'smtpServer.fromDisplayName=SKY LAB' \
    -s smtpServer.ssl=false \
    -s smtpServer.starttls=false \
    -s smtpServer.auth=false >/dev/null

  # --- the mapped mail leaves through SkyMail -------------------------------------------
  sent_uuid=$(sky_mail_create_user skymail-fixture skymail-fixture@example.invalid)
  sky_mail_send_verify_email "$sent_uuid"
  task=$(sky_mail_await_record mail_task skymail-fixture@example.invalid) \
    || fail 'SkyMail fixture did not receive the verify-email mail task'
  json_assert "$task" '.template_key == "keycloak.verify-email"' \
    'the verify-email mail did not carry the mapped SkyMail template key'
  json_assert "$task" '.recipient_full_name == "Sky Mail"' \
    'the mail task did not name the recipient'
  json_assert "$task" '.missing_variables == []' \
    'SkyMail would render <no value>: a body variable was omitted'
  json_assert "$task" \
    '(.body_variables | keys | sort) == ["code","codeExpirationMinutes","firstName","link","linkExpirationMinutes","realmDisplayName","subjectKey","username"]' \
    'the mail task did not carry exactly the eight agreed body variables'
  json_assert "$task" '.body_variables.code == "" and .body_variables.codeExpirationMinutes == ""' \
    'a link mail must send the code variables empty'
  json_assert "$task" \
    '.body_variables.subjectKey == "emailVerificationSubject" and .body_variables.firstName == "Sky" and .body_variables.username == "skymail-fixture"' \
    'the mail task body variables differ from the Keycloak mail'
  json_assert "$task" '.body_variables.realmDisplayName == $display' \
    'the mail task did not carry the realm display name' --arg display "$realm_display"
  json_assert "$task" \
    '(.body_variables.link | contains("/realms/e-skylab-test/login-actions/action-token")) and (.body_variables.linkExpirationMinutes | test("^[0-9]+$"))' \
    'the mail task did not carry the action link and its expiration'
  json_assert "$task" \
    '.azp == "keycloak-mailer" and (.roles | sort) == ["skymail:access", "skymail:mails:send"]' \
    'the mail task was not authorized by the keycloak-mailer service account'
  posted=$(sky_mail_fixture_records | jq -c 'select(.event == "mail_task")' | wc -l | tr -d ' ')
  [[ $posted == 1 ]] || fail "the verify-email mail reached SkyMail $posted times instead of once"
  [[ -z $(sky_mail_fixture_records | jq -c 'select(.event == "smtp_message")') ]] \
    || fail 'an accepted mail was also delivered over SMTP'

  # --- an archived or unknown template key falls back, it does not vanish ---------------
  missing_uuid=$(sky_mail_create_user skymail-missing-fixture skymail-missing@example.invalid)
  sky_mail_send_verify_email "$missing_uuid"
  sky_mail_await_record smtp_message skymail-missing@example.invalid >/dev/null \
    || fail 'a mail SkyMail answered 404 for never reached the recipient'

  # --- an unavailable SkyMail falls back ------------------------------------------------
  fallback_uuid=$(sky_mail_create_user skymail-fallback-fixture skymail-fallback@example.invalid)
  sky_mail_send_verify_email "$fallback_uuid"
  smtp_record=$(sky_mail_await_record smtp_message skymail-fallback@example.invalid) \
    || fail 'the SMTP fallback did not deliver the mail SkyMail refused'
  json_assert "$smtp_record" '.bytes > 0' 'the fallback delivered an empty message'

  keycloak_log=$("${COMPOSE[@]}" logs --no-color --no-log-prefix keycloak 2>/dev/null \
    | grep -F 'sky_mail_' || true)
  grep -Fq 'sky_mail_fallback reason=template_missing template=keycloak.verify-email' \
    <<<"$keycloak_log" \
    || { printf '%s\n' "$keycloak_log" >&2; fail 'the 404 fallback did not record its own reason'; }
  grep -Fq 'sky_mail_fallback reason=unavailable template=keycloak.verify-email' \
    <<<"$keycloak_log" \
    || { printf '%s\n' "$keycloak_log" >&2; fail 'the 500 fallback did not record its own reason'; }
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    [[ $line != *"@example.invalid"* ]] || fail 'a sky_mail log line carried a recipient address'
    [[ $line != *"login-actions/action-token"* ]] || fail 'a sky_mail log line carried an action link'
    [[ $line != *"$secret"* ]] || fail 'a sky_mail log line carried the client secret'
  done <<<"$keycloak_log"
  [[ $(sky_mail_fixture_records | jq -c 'select(.event == "mail_task")' | wc -l | tr -d ' ') == 3 ]] \
    || fail 'SkyMail did not receive exactly the three triggered mails'

  # Leave the realm and its users exactly as this stage found them.
  for user_uuid in "$sent_uuid" "$missing_uuid" "$fallback_uuid"; do
    kcadm delete "users/$user_uuid" -r "$V2_REALM" >/dev/null
  done
  kcadm update "realms/$V2_REALM" -s 'smtpServer={}' >/dev/null
  unset secret
}

stage_v2_passkey_cleanup() {
  CURRENT_STAGE='v2 legacy passkey cleanup around a relying party id switch'
  local client_secret=$1
  local legacy_ids legacy_count switched_before switched_away switched_back output all_ids survivor_ids
  legacy_ids=$(v2_fixture_passkey_ids)
  legacy_count=$(grep -c . <<<"$legacy_ids" || true)
  [[ $legacy_count -ge 1 ]] || fail 'the Chromium stage left no passwordless credential to clean up'
  switched_before=$(v2_switch_attribute)
  [[ $switched_before =~ $V2_ISO_UTC ]] \
    || fail "realm attribute $V2_SWITCH_ATTRIBUTE is missing or malformed: '$switched_before'"

  # A cutover later than the recorded switch would delete valid passkeys: refused, even dry.
  sleep 2
  if v2_cleanup_legacy_passkeys --cutover "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$TEST_STATE_DIR/cleanup-late-cutover.log"; then
    cat "$TEST_STATE_DIR/cleanup-late-cutover.log" >&2
    fail 'cleanup accepted a --cutover later than the recorded relying party id switch'
  fi
  grep -Fq "is later than the recorded relying party id switch $switched_before (realm attribute $V2_SWITCH_ATTRIBUTE)" \
    "$TEST_STATE_DIR/cleanup-late-cutover.log" \
    || { cat "$TEST_STATE_DIR/cleanup-late-cutover.log" >&2; fail 'cleanup did not explain the refused late cutover'; }

  "${COMPOSE[@]}" run --rm --no-deps \
    -e KEYCLOAK_PASSKEY_RP_ID=switch.invalid \
    -e KEYCLOAK_PASSKEY_EXTRA_ORIGINS=http://switch.invalid \
    keycloak-config >"$TEST_STATE_DIR/reconcile-switch-away.log" 2>&1
  grep -Fq "passkey relying party id switches from 'localhost' to 'switch.invalid'" \
    "$TEST_STATE_DIR/reconcile-switch-away.log" \
    || fail 'reconciler did not report the relying party id switch away from localhost'
  switched_away=$(v2_switch_attribute)
  [[ $switched_away =~ $V2_ISO_UTC && $switched_away > $switched_before ]] \
    || fail "the switch away did not advance $V2_SWITCH_ATTRIBUTE ($switched_before -> $switched_away)"
  sleep 2
  "${COMPOSE[@]}" run --rm --no-deps keycloak-config >"$TEST_STATE_DIR/reconcile-switch-back.log" 2>&1
  grep -Fq "passkey relying party id switches from 'switch.invalid' to 'localhost'" \
    "$TEST_STATE_DIR/reconcile-switch-back.log" \
    || fail 'reconciler did not report the relying party id switch back to localhost'
  switched_back=$(v2_switch_attribute)
  [[ $switched_back =~ $V2_ISO_UTC && $switched_back > $switched_away ]] \
    || fail "the switch back did not advance $V2_SWITCH_ATTRIBUTE ($switched_away -> $switched_back)"
  json_assert "$(kcadm get "realms/$V2_REALM" -c)" \
    '.webAuthnPolicyPasswordlessRpId == "localhost" and .webAuthnPolicyPasswordlessExtraOrigins == ["http://localhost:18080"] and .attributes["harness.keep"] == "kept"' \
    'the switch back did not restore the harness passkey policy or dropped a foreign attribute'

  # Dry run with the recorded cutover: every pre-switch passkey is counted, nothing is deleted.
  output=$(v2_cleanup_legacy_passkeys)
  grep -Fq "cutover=$switched_back cutoverSource=realmAttribute mode=dry-run" <<<"$output" \
    || { printf '%s\n' "$output" >&2; fail 'cleanup dry run did not take the recorded switch as its cutover'; }
  grep -Fq "passkeysBeforeCutover=$legacy_count passkeysDeleted=0 passkeysDeleteFailed=0" <<<"$output" \
    || { printf '%s\n' "$output" >&2; fail 'cleanup dry run did not count the pre-switch passkeys without deleting them'; }
  grep -Fq 'Dry run: nothing was deleted.' <<<"$output" \
    || fail 'cleanup dry run did not announce itself'
  [[ $output != *account-fixture* && $output != *"$V2_FIXTURE_USER_UUID"* ]] \
    || fail 'cleanup output must not print user identifiers'
  [[ $(v2_fixture_passkey_ids) == "$legacy_ids" ]] || fail 'cleanup dry run changed the credentials'

  v2_register_passkey_after_switch "$client_secret"
  all_ids=$(v2_fixture_passkey_ids)
  [[ $(grep -c . <<<"$all_ids") == $((legacy_count + 1)) ]] \
    || fail 'the post-switch registration did not add exactly one passkey'
  survivor_ids=$(comm -13 <(printf '%s\n' "$legacy_ids") <(printf '%s\n' "$all_ids"))
  [[ $(grep -c . <<<"$survivor_ids") == 1 ]] || fail 'the post-switch passkey could not be told apart'

  # Failed deletions are counted, the summary still prints and the exit status is non-zero.
  v2_cleanup_run_options=(
    -e KCADM_BIN=/tmp/kcadm-delete-failure.sh
    -v "$SCRIPT_DIR/kcadm-delete-failure.sh:/tmp/kcadm-delete-failure.sh:ro"
  )
  if v2_cleanup_legacy_passkeys --apply >"$TEST_STATE_DIR/cleanup-delete-failure.log"; then
    v2_cleanup_run_options=()
    cat "$TEST_STATE_DIR/cleanup-delete-failure.log" >&2
    fail 'cleanup exited zero although every deletion failed'
  fi
  v2_cleanup_run_options=()
  output=$(cat "$TEST_STATE_DIR/cleanup-delete-failure.log")
  grep -Fq "passkeysBeforeCutover=$legacy_count passkeysDeleted=0 passkeysDeleteFailed=$legacy_count" <<<"$output" \
    || { printf '%s\n' "$output" >&2; fail 'cleanup did not count the failed deletions in its summary'; }
  grep -Fq "Legacy passkey cleanup is incomplete: $legacy_count deletion(s) failed" <<<"$output" \
    || { printf '%s\n' "$output" >&2; fail 'cleanup did not report the failed deletions'; }
  [[ $output != *account-fixture* && $output != *"$V2_FIXTURE_USER_UUID"* && $output != *"$(head -n 1 <<<"$legacy_ids")"* ]] \
    || fail 'cleanup failure output must not print user or credential identifiers'
  [[ $(v2_fixture_passkey_ids) == "$all_ids" ]] || fail 'a failed apply run changed the credentials'

  output=$(v2_cleanup_legacy_passkeys --apply)
  grep -Fq "cutover=$switched_back cutoverSource=realmAttribute mode=apply" <<<"$output" \
    || { printf '%s\n' "$output" >&2; fail 'cleanup apply did not take the recorded switch as its cutover'; }
  grep -Fq "passkeysBeforeCutover=$legacy_count passkeysDeleted=$legacy_count passkeysDeleteFailed=0" <<<"$output" \
    || { printf '%s\n' "$output" >&2; fail 'cleanup apply did not delete exactly the pre-switch passkeys'; }
  grep -Fq 'Legacy passkey cleanup applied.' <<<"$output" || fail 'cleanup apply did not announce itself'
  [[ $(v2_fixture_passkey_ids) == "$survivor_ids" ]] \
    || fail 'the passkey registered after the switch did not survive the cleanup, or a pre-switch one did'

  # Idempotent; an earlier explicit cutover is accepted; later and future cutovers are refused.
  output=$(v2_cleanup_legacy_passkeys --apply)
  grep -Fq 'passkeysBeforeCutover=0 passkeysDeleted=0 passkeysDeleteFailed=0' <<<"$output" \
    || { printf '%s\n' "$output" >&2; fail 'a second cleanup apply found passkeys to delete'; }
  output=$(v2_cleanup_legacy_passkeys --cutover "$switched_before")
  grep -Fq "cutover=$switched_before cutoverSource=argument mode=dry-run" <<<"$output" \
    || { printf '%s\n' "$output" >&2; fail 'cleanup refused an explicit cutover earlier than the recorded switch'; }
  sleep 2
  if v2_cleanup_legacy_passkeys --cutover "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --apply >/dev/null; then
    fail 'cleanup accepted a --cutover --apply later than the recorded relying party id switch'
  fi
  if v2_cleanup_legacy_passkeys --cutover 2099-01-01T00:00:00Z >/dev/null; then
    fail 'cleanup accepted a cutover in the future'
  fi
  [[ $(v2_fixture_passkey_ids) == "$survivor_ids" ]] || fail 'a refused cleanup run changed the credentials'
}

"${COMPOSE[@]}" up -d postgres rabbitmq keycloak
CURRENT_STAGE='Keycloak readiness'
wait_for_url http://localhost:19000/health/ready

"${KCADM[@]}" config credentials \
  --config "$ADMIN_CONFIG" \
  --server http://localhost:8080 \
  --realm master \
  --user admin \
  --password integration-admin-password >/dev/null

kcadm() {
  local command=$1
  shift
  "${KCADM[@]}" "$command" --config "$ADMIN_CONFIG" "$@"
}

CURRENT_STAGE='scoped reconciler bootstrap'
"${COMPOSE[@]}" run --rm --no-deps keycloak-bootstrap >/dev/null

# Production uses a realm-level custom browser flow. Account Center signs in
# through that active realm flow itself (no client-specific copy since the Web
# handoff replaced the native handoff), and reconciliation must never change it.
# The disabled custom execution keeps this fixture behaviorally inert while making
# the realm graph observably different from Keycloak's built-in `browser` flow.
CURRENT_STAGE='active custom browser flow fixture'
kcadm create authentication/flows/browser/copy \
  -r e-skylab-test \
  -s 'newName=browser plus passkey' >/dev/null
kcadm create 'authentication/flows/browser%20plus%20passkey/executions/execution' \
  -r e-skylab-test \
  -b '{"provider":"passkey-offer-authenticator","priority":60}' >/dev/null
kcadm update realms/e-skylab-test \
  -s 'browserFlow=browser plus passkey' >/dev/null
active_browser_flow=$(kcadm get realms/e-skylab-test -c | jq -r '.browserFlow')
[[ $active_browser_flow == 'browser plus passkey' ]] \
  || fail 'custom browser flow fixture is not active'
active_browser_flow_before=$(kcadm get \
  'authentication/flows/browser%20plus%20passkey/executions' \
  -r e-skylab-test -c | jq -S -c '.')

# Reproduce the production drift that originally caused every Account REST
# request to return 403. Client scope mappings only limit roles which may enter
# a token; they do not grant those roles to a user. Remove the Account REST
# roles from the realm default role before reconciliation so the test proves
# the isolated Account Center scope supplies them without granting realm-wide
# roles to existing or future users.
account_client_uuid=$(kcadm get clients -r e-skylab-test -c \
  | jq -r '.[] | select(.clientId == "account") | .id')
default_role=$(kcadm get roles/default-roles-e-skylab-test \
  -r e-skylab-test -c)
default_role_uuid=$(jq -r '.id' <<<"$default_role")
required_default_account_roles=$(kcadm get \
  "clients/$account_client_uuid/roles" -r e-skylab-test -c \
  | jq -c '[.[] | select(.name == "manage-account" or .name == "view-profile")]')
[[ $(jq 'length' <<<"$required_default_account_roles") == 2 ]] \
  || fail 'built-in Account REST roles are unavailable in the fixture realm'
kcadm delete "roles-by-id/$default_role_uuid/composites" \
  -r e-skylab-test -b "$required_default_account_roles" >/dev/null
default_account_roles_before=$(kcadm get \
  "roles-by-id/$default_role_uuid/composites/clients/$account_client_uuid" \
  -r e-skylab-test -c)
json_assert "$default_account_roles_before" \
  '([.[].name] | map(select(. == "manage-account" or . == "view-profile"))) | length == 0' \
  'Account REST role drift was not injected into the realm default role'

# Capture the immutable built-in scope inventory before reconciliation. This
# catches accidental fallback to an arbitrary scope when exact lookup fails.
built_in_scope_snapshot=$(kcadm get client-scopes -r e-skylab-test -c \
  | jq -c '[.[] | {id, name}] | sort_by(.id)')

stage_login_audiences_hand_made

CURRENT_STAGE='first reconciliation'
"${COMPOSE[@]}" run --rm --no-deps keycloak-config >"$TEST_STATE_DIR/reconcile-first.log" 2>&1

assert_account_center_uses_the_realm_browser_flow() {
  local client_json
  client_json=$(kcadm get clients -r e-skylab-test -q clientId=account-center -c \
    | jq -c '.[] | select(.clientId == "account-center")')
  json_assert "$client_json" '(.authenticationFlowBindingOverrides.browser // "") == ""' \
    'account-center must sign in through the realm browser flow, not a client-specific one'
  json_assert "$(kcadm get authentication/flows -r e-skylab-test -c)" \
    '[.[] | select(.alias == "account-center-browser")] | length == 0' \
    'the retired account-center-browser flow must not exist'
  local subflow_error
  if subflow_error=$(kcadm get authentication/flows/account-center-native-handoff/executions -r e-skylab-test 2>&1 >/dev/null); then
    fail 'the retired account-center-native-handoff subflow must not exist'
  fi
  grep -qi 'not found' <<<"$subflow_error" \
    || fail "reading the retired subflow failed for another reason than its absence: $subflow_error"
}
assert_account_center_uses_the_realm_browser_flow
grep -Fq '[reconcile] authentication flow account-center-browser: unchanged (absent)' \
  "$TEST_STATE_DIR/reconcile-first.log" \
  || fail 'the first reconciliation did not report the absent client-specific flow'
active_browser_flow_after=$(kcadm get \
  'authentication/flows/browser%20plus%20passkey/executions' \
  -r e-skylab-test -c | jq -S -c '.')
[[ $active_browser_flow_after == "$active_browser_flow_before" ]] \
  || fail 'Account Center reconciliation mutated the active realm browser flow'

stage_v2_after_first_reconciliation
stage_login_audiences_after_first_reconciliation

# Inject drift before the second pass. Reconciliation must repair the existing
# realm, flow, scope and allowlists rather than merely treating names as success.
client_uuid=$(kcadm get clients -r e-skylab-test -c \
  | jq -r '.[] | select(.clientId == "account-center") | .id')
drift_scope_uuid=$(kcadm get client-scopes -r e-skylab-test -c \
  | jq -r '.[] | select(.name == "account-center-account-api") | .id')
core_scope_uuid=$(kcadm get client-scopes -r e-skylab-test -c \
  | jq -r '.[] | select(.name == "account-center-core-claims") | .id')
drift_mapper_uuid=$(kcadm get "client-scopes/$drift_scope_uuid/protocol-mappers/models" \
  -r e-skylab-test -c \
  | jq -r '.[] | select(.name == "account-api-audience") | .id')
kcadm update "client-scopes/$drift_scope_uuid" -r e-skylab-test \
  -s 'attributes."include.in.token.scope"=true' >/dev/null
kcadm update "client-scopes/$drift_scope_uuid/protocol-mappers/models/$drift_mapper_uuid" \
  -r e-skylab-test \
  -s 'config."included.client.audience"=wrong-audience' >/dev/null
kcadm create "client-scopes/$drift_scope_uuid/protocol-mappers/models" \
  -r e-skylab-test \
  -b '{"name":"unexpected-account-mapper","protocol":"openid-connect","protocolMapper":"oidc-hardcoded-claim-mapper","config":{"claim.name":"unexpected","claim.value":"true","jsonType.label":"boolean","access.token.claim":"true"}}' >/dev/null
core_auth_time_mapper_uuid=$(kcadm get \
  "client-scopes/$core_scope_uuid/protocol-mappers/models" \
  -r e-skylab-test -c \
  | jq -r '.[] | select(.name == "auth_time") | .id')
kcadm update \
  "client-scopes/$core_scope_uuid/protocol-mappers/models/$core_auth_time_mapper_uuid" \
  -r e-skylab-test \
  -s 'config."claim.name"=wrong_auth_time' \
  -s 'config."id.token.claim"=false' >/dev/null
kcadm create "client-scopes/$core_scope_uuid/protocol-mappers/models" \
  -r e-skylab-test \
  -b '{"name":"email-drift","protocol":"openid-connect","protocolMapper":"oidc-usermodel-property-mapper","config":{"user.attribute":"email","claim.name":"email","id.token.claim":"true","access.token.claim":"true"}}' >/dev/null
# The university and department mappers: one drifts into a multivalued ID token claim, the
# other disappears; the second pass must rewrite the first and recreate the second.
core_department_mapper_uuid=$(kcadm get \
  "client-scopes/$core_scope_uuid/protocol-mappers/models" \
  -r e-skylab-test -c \
  | jq -r '.[] | select(.name == "department") | .id')
[[ -n $core_department_mapper_uuid ]] || fail 'the first reconciliation did not create the department mapper'
kcadm update \
  "client-scopes/$core_scope_uuid/protocol-mappers/models/$core_department_mapper_uuid" \
  -r e-skylab-test \
  -s 'config.multivalued=true' \
  -s 'config."id.token.claim"=true' >/dev/null
core_university_mapper_uuid=$(kcadm get \
  "client-scopes/$core_scope_uuid/protocol-mappers/models" \
  -r e-skylab-test -c \
  | jq -r '.[] | select(.name == "university") | .id')
[[ -n $core_university_mapper_uuid ]] || fail 'the first reconciliation did not create the university mapper'
kcadm delete \
  "client-scopes/$core_scope_uuid/protocol-mappers/models/$core_university_mapper_uuid" \
  -r e-skylab-test >/dev/null
skyapp_client_uuid=$(kcadm get clients -r e-skylab-test -c \
  | jq -r '.[] | select(.clientId == "skyapp") | .id')
skyapp_scope_uuid=$(kcadm get client-scopes -r e-skylab-test -c \
  | jq -r '.[] | select(.name == "skyapp-account-center-audience") | .id')
skyapp_mapper_uuid=$(kcadm get \
  "client-scopes/$skyapp_scope_uuid/protocol-mappers/models" \
  -r e-skylab-test -c \
  | jq -r '.[] | select(.name == "account-center-audience") | .id')
kcadm update \
  "client-scopes/$skyapp_scope_uuid/protocol-mappers/models/$skyapp_mapper_uuid" \
  -r e-skylab-test \
  -s 'config."included.client.audience"=wrong-audience' >/dev/null
kcadm create "client-scopes/$skyapp_scope_uuid/protocol-mappers/models" \
  -r e-skylab-test \
  -b '{"name":"unexpected-skyapp-mapper","protocol":"openid-connect","protocolMapper":"oidc-hardcoded-claim-mapper","config":{"claim.name":"unexpected","claim.value":"true","jsonType.label":"boolean","access.token.claim":"true"}}' >/dev/null
kcadm delete "clients/$skyapp_client_uuid/default-client-scopes/$skyapp_scope_uuid" \
  -r e-skylab-test >/dev/null
profile_scope_uuid=$(kcadm get client-scopes -r e-skylab-test -c \
  | jq -r '.[] | select(.name == "profile") | .id')
kcadm update "clients/$client_uuid/default-client-scopes/$profile_scope_uuid" \
  -r e-skylab-test -n -b '{}' >/dev/null
email_scope_uuid=$(kcadm get client-scopes -r e-skylab-test -c \
  | jq -r '.[] | select(.name == "email") | .id')
kcadm update "clients/$client_uuid/default-client-scopes/$email_scope_uuid" \
  -r e-skylab-test -n -b '{}' >/dev/null
address_scope_uuid=$(kcadm get client-scopes -r e-skylab-test -c \
  | jq -r '.[] | select(.name == "address") | .id')
kcadm update "clients/$client_uuid/optional-client-scopes/$address_scope_uuid" \
  -r e-skylab-test -n -b '{}' >/dev/null

account_client_uuid=$(kcadm get clients -r e-skylab-test -c \
  | jq -r '.[] | select(.clientId == "account") | .id')
extra_account_role=$(kcadm get "clients/$account_client_uuid/roles" -r e-skylab-test -c \
  | jq -c '[.[] | select(.name != "manage-account" and .name != "view-profile")][0] | [{id, name}]')
kcadm create "clients/$client_uuid/scope-mappings/clients/$account_client_uuid" \
  -r e-skylab-test -b "$extra_account_role" >/dev/null

# A failed security-state read must abort reconciliation. Process-substitution
# readers can otherwise mask kcadm failures as an empty allowlist and continue.
CURRENT_STAGE='injected reconciler read failure'
if "${COMPOSE[@]}" run --rm --no-deps \
  -e KCADM_BIN=/tmp/kcadm-read-failure.sh \
  -v "$SCRIPT_DIR/kcadm-read-failure.sh:/tmp/kcadm-read-failure.sh:ro" \
  keycloak-config >/dev/null 2>&1; then
  fail "reconciliation succeeded after an injected protocol-mapper read failure"
fi
unexpected_mapper_count=$(kcadm get \
  "client-scopes/$drift_scope_uuid/protocol-mappers/models" \
  -r e-skylab-test -c \
  | jq '[.[] | select(.name == "unexpected-account-mapper")] | length')
[[ $unexpected_mapper_count == 1 ]] \
  || fail "failed reconciliation mutated mapper state after its read failed"

kcadm update realms/e-skylab-test \
  -s ssoSessionMaxLifespan=123 \
  -s webAuthnPolicyPasswordlessPasskeysEnabled=false \
  -s webAuthnPolicyPasswordlessMediation=none >/dev/null
kcadm update authentication/required-actions/UPDATE_PASSWORD \
  -r e-skylab-test -s enabled=false >/dev/null
stage_v2_inject_drift

# The state production had before the Web handoff: account-center bound to
# account-center-browser, a copy of the realm browser flow with the native handoff
# subflow in front. The next pass must unbind the client and delete the flow with its
# subflow. The sky-native-handoff execution itself cannot be recreated (Admin REST refuses
# an unknown provider); Keycloak's deep delete never resolves providers, so the path is
# the same with or without it.
CURRENT_STAGE='retired native handoff flow fixture'
kcadm create 'authentication/flows/browser%20plus%20passkey/copy' \
  -r e-skylab-test -s 'newName=account-center-browser' >/dev/null
kcadm create authentication/flows/account-center-browser/executions/flow \
  -r e-skylab-test \
  -b '{"alias":"account-center-native-handoff","type":"basic-flow","provider":"basic-flow","priority":5,"description":"Redeems one-time Account Center native handoff codes"}' >/dev/null
legacy_flow_uuid=$(kcadm get authentication/flows -r e-skylab-test -c \
  | jq -r '.[] | select(.alias == "account-center-browser") | .id')
[[ -n $legacy_flow_uuid ]] || fail 'the retired client flow fixture was not created'
kcadm update "clients/$client_uuid" -r e-skylab-test \
  -s "authenticationFlowBindingOverrides.browser=$legacy_flow_uuid" >/dev/null
json_assert "$(kcadm get "clients/$client_uuid" -r e-skylab-test -c)" \
  '.authenticationFlowBindingOverrides.browser == $flow' \
  'the retired client flow binding was not injected' --arg flow "$legacy_flow_uuid"
kcadm get authentication/flows/account-center-native-handoff/executions -r e-skylab-test >/dev/null \
  || fail 'the retired native handoff subflow fixture was not created'

# A second pass proves both idempotence and drift repair.
CURRENT_STAGE='second reconciliation and drift repair'
"${COMPOSE[@]}" run --rm --no-deps keycloak-config >"$TEST_STATE_DIR/reconcile-second.log" 2>&1

[[ -n $client_uuid ]] || fail "account-center client was not created"

client=$(kcadm get "clients/$client_uuid" -r e-skylab-test -c)
json_assert "$client" '.standardFlowEnabled == true' 'authorization code flow is not enabled'
json_assert "$client" '.implicitFlowEnabled == false' 'implicit flow is enabled'
json_assert "$client" '.directAccessGrantsEnabled == false' 'direct grants are enabled'
json_assert "$client" '.serviceAccountsEnabled == false' 'service account is enabled'
json_assert "$client" '.publicClient == false' 'client is not confidential'
json_assert "$client" '.redirectUris == ["https://my.yildizskylab.com/api/auth/callback"]' 'redirect URI is not exact'
json_assert "$client" '.webOrigins == []' 'web origins are not empty/exact'
json_assert "$client" '.attributes["pkce.code.challenge.method"] == "S256"' 'S256 PKCE is not required'
json_assert "$client" '.attributes["require.pushed.authorization.requests"] == "true"' 'PAR is not required'
json_assert "$client" '.attributes["backchannel.logout.url"] == "https://my.yildizskylab.com/api/auth/backchannel-logout"' 'backchannel logout URL differs'
json_assert "$client" '.attributes["backchannel.logout.session.required"] == "true"' 'backchannel session requirement is off'

realm=$(kcadm get realms/e-skylab-test -c)
json_assert "$realm" \
  '.sslRequired == "external" and .registrationAllowed == false and .resetPasswordAllowed == true and .ssoSessionIdleTimeout == 1800 and .ssoSessionMaxLifespan == 28800 and .accessCodeLifespanUserAction == 300 and .internationalizationEnabled == true and .defaultLocale == "tr" and (.supportedLocales | sort) == ["en", "tr"] and .loginTheme == "e-skylab-theme"' \
  'realm security, session or theme desired state differs'
json_assert "$realm" \
  '.webAuthnPolicyPasswordlessRpEntityName == "SKY LAB" and .webAuthnPolicyPasswordlessResidentKey == "required" and .webAuthnPolicyPasswordlessUserVerificationRequirement == "required" and .webAuthnPolicyPasswordlessPasskeysEnabled == true and .webAuthnPolicyPasswordlessMediation == "conditional"' \
  'passwordless WebAuthn desired state differs'

required_actions=$(kcadm get authentication/required-actions -r e-skylab-test -c)
for required_action in UPDATE_PASSWORD CONFIGURE_TOTP webauthn-register-passwordless delete_credential; do
  json_assert "$required_actions" \
    '[.[] | select(.alias == $alias and .enabled == true and .defaultAction == false)] | length == 1' \
    "required action $required_action differs" \
    --arg alias "$required_action"
done

assert_account_center_uses_the_realm_browser_flow
grep -Fq '[reconcile] client account-center browser flow binding: updated (removed; the realm browser flow applies)' \
  "$TEST_STATE_DIR/reconcile-second.log" \
  || fail 'reconciliation did not report removing the retired client flow binding'
grep -Fq '[reconcile] authentication flow account-center-browser: deleted (with its retired native handoff subflow)' \
  "$TEST_STATE_DIR/reconcile-second.log" \
  || fail 'reconciliation did not report deleting the retired client flow'
active_browser_flow_after_repair=$(kcadm get \
  'authentication/flows/browser%20plus%20passkey/executions' \
  -r e-skylab-test -c | jq -S -c '.')
[[ $active_browser_flow_after_repair == "$active_browser_flow_before" ]] \
  || fail 'retiring the client flow mutated the active realm browser flow'
json_assert "$(kcadm get realms/e-skylab-test -c)" '.browserFlow == "browser plus passkey"' \
  'retiring the client flow changed the realm browser flow binding'

scope_count=$(kcadm get client-scopes -r e-skylab-test -c \
  | jq '[.[] | select(.name == "account-center-account-api")] | length')
[[ $scope_count == 1 ]] || fail "Account API client scope is missing or duplicated"
core_scope_count=$(kcadm get client-scopes -r e-skylab-test -c \
  | jq '[.[] | select(.name == "account-center-core-claims")] | length')
[[ $core_scope_count == 1 ]] || fail "Account Center core-claims scope is missing or duplicated"
skyapp_scope_count=$(kcadm get client-scopes -r e-skylab-test -c \
  | jq '[.[] | select(.name == "skyapp-account-center-audience")] | length')
[[ $skyapp_scope_count == 1 ]] || fail "skyapp audience scope is missing or duplicated"

built_in_scope_after=$(kcadm get client-scopes -r e-skylab-test -c \
  | jq -c '[.[] | select(.name != "account-center-account-api" and .name != "account-center-core-claims" and .name != "skyapp-account-center-audience" and .name != "skyforms-forms-audience" and .name != "frontend-main-core-audience") | {id, name}] | sort_by(.id)')
[[ $built_in_scope_after == "$built_in_scope_snapshot" ]] \
  || fail "a built-in client scope id or name was mutated"

while IFS= read -r built_in_scope_uuid; do
  built_in_mappers=$(kcadm get \
    "client-scopes/$built_in_scope_uuid/protocol-mappers/models" \
    -r e-skylab-test -c)
  json_assert "$built_in_mappers" \
    '[.[] | select(.name == "account-api-audience" or .name == "account-api-core-audience" or .name == "account-api-manage-account" or .name == "account-api-view-profile" or .name == "account-api-manage-account-links" or .name == "account-api-roles" or .name == "account-api-sky-authorization" or .name == "account-center-audience" or .name == "sky_session_lifetime" or .name == "sky_embed")] | length == 0' \
    "an Account Center mapper was injected into built-in scope $built_in_scope_uuid"
done < <(jq -r '.[].id' <<<"$built_in_scope_snapshot")

scope_uuid=$(kcadm get client-scopes -r e-skylab-test -c \
  | jq -r '.[] | select(.name == "account-center-account-api") | .id')
scope=$(kcadm get "client-scopes/$scope_uuid" -r e-skylab-test -c)
json_assert "$scope" '.protocol == "openid-connect" and .attributes["include.in.token.scope"] == "false"' 'Account API scope drift was not repaired'
mappers=$(kcadm get "client-scopes/$scope_uuid/protocol-mappers/models" -r e-skylab-test -c)
json_assert "$mappers" 'length == 7' 'unexpected or duplicate Account API mappers remain'
json_assert "$mappers" '[.[] | select(.name == "account-api-audience" and .config["included.client.audience"] == "account")] | length == 1' 'Account API audience mapper differs'
json_assert "$mappers" '[.[] | select(.name == "account-api-manage-account" and .protocolMapper == "oidc-hardcoded-role-mapper" and .config.role == "account.manage-account")] | length == 1' 'Account API manage-account role mapper differs'
json_assert "$mappers" '[.[] | select(.name == "account-api-view-profile" and .protocolMapper == "oidc-hardcoded-role-mapper" and .config.role == "account.view-profile")] | length == 1' 'Account API view-profile role mapper differs'
json_assert "$mappers" '[.[] | select(.name == "account-api-roles" and .config["usermodel.clientRoleMapping.clientId"] == "account")] | length == 1' 'Account API role mapper differs'

core_scope_uuid=$(kcadm get client-scopes -r e-skylab-test -c \
  | jq -r '.[] | select(.name == "account-center-core-claims") | .id')
core_scope=$(kcadm get "client-scopes/$core_scope_uuid" -r e-skylab-test -c)
json_assert "$core_scope" \
  '.protocol == "openid-connect" and .attributes["include.in.token.scope"] == "false"' \
  'Account Center core-claims scope drift was not repaired'
core_mappers=$(kcadm get \
  "client-scopes/$core_scope_uuid/protocol-mappers/models" \
  -r e-skylab-test -c)
json_assert "$core_mappers" \
  'length == 6 and ([.[].name] | sort) == ["auth_time", "department", "sky_embed", "sky_session_lifetime", "sub", "university"]' \
  'unexpected, profile or email mappers remain in the core-claims scope'
# The same claim shape as the realm's department_ve_university_to_jwt scope (String, single
# value), but only in the access token and introspection: core reads them there.
json_assert "$core_mappers" \
  '[.[] | select((.name == "university" or .name == "department") and .protocolMapper == "oidc-usermodel-attribute-mapper" and .config["user.attribute"] == .name and .config["claim.name"] == .name and .config["jsonType.label"] == "String" and .config.multivalued == "false" and .config["access.token.claim"] == "true" and .config["introspection.token.claim"] == "true" and .config["id.token.claim"] == "false" and .config["userinfo.token.claim"] == "false")] | length == 2' \
  'source-controlled university and department mapper contract differs'
grep -Eq '^\[reconcile\] protocol mappers of scope [^ ]+: updated \(.*\+university' \
  "$TEST_STATE_DIR/reconcile-second.log" \
  || fail 'the second reconciliation did not recreate the deleted university mapper'
grep -Eq '^\[reconcile\] protocol mappers of scope [^ ]+: updated \(.*~department' \
  "$TEST_STATE_DIR/reconcile-second.log" \
  || fail 'the second reconciliation did not repair the drifted department mapper'
json_assert "$core_mappers" \
  '[.[] | select(.name == "sky_session_lifetime" and .protocolMapper == "sky-session-lifetime-mapper" and .config["id.token.claim"] == "true" and .config["access.token.claim"] == "true" and .config["introspection.token.claim"] == "true")] | length == 1' \
  'source-controlled sky_session_lifetime mapper contract differs'
json_assert "$core_mappers" \
  '[.[] | select(.name == "sky_embed" and .protocolMapper == "oidc-usersessionmodel-note-mapper" and .config["user.session.note"] == "sky.embed" and .config["claim.name"] == "sky_embed" and .config["jsonType.label"] == "String" and .config["id.token.claim"] == "true" and .config["access.token.claim"] == "true" and .config["userinfo.token.claim"] == "false")] | length == 1' \
  'source-controlled sky_embed mapper contract differs'
json_assert "$core_mappers" \
  '[.[] | select(.name == "sub" and .protocolMapper == "oidc-sub-mapper" and .config["access.token.claim"] == "true" and .config["introspection.token.claim"] == "true")] | length == 1' \
  'source-controlled sub mapper contract differs'
json_assert "$core_mappers" \
  '[.[] | select(.name == "auth_time" and .protocolMapper == "oidc-usersessionmodel-note-mapper" and .config["user.session.note"] == "AUTH_TIME" and .config["claim.name"] == "auth_time" and .config["jsonType.label"] == "long" and .config["id.token.claim"] == "true" and .config["access.token.claim"] == "true" and .config["introspection.token.claim"] == "true")] | length == 1' \
  'source-controlled auth_time mapper contract differs'

skyapp_scope_uuid=$(kcadm get client-scopes -r e-skylab-test -c \
  | jq -r '.[] | select(.name == "skyapp-account-center-audience") | .id')
skyapp_scope=$(kcadm get "client-scopes/$skyapp_scope_uuid" -r e-skylab-test -c)
json_assert "$skyapp_scope" \
  '.protocol == "openid-connect" and .attributes["include.in.token.scope"] == "false"' \
  'skyapp audience scope drift was not repaired'
skyapp_mappers=$(kcadm get \
  "client-scopes/$skyapp_scope_uuid/protocol-mappers/models" \
  -r e-skylab-test -c)
json_assert "$skyapp_mappers" \
  'length == 1 and .[0].name == "account-center-audience" and .[0].protocolMapper == "oidc-audience-mapper" and .[0].config["included.client.audience"] == "account-center" and .[0].config["access.token.claim"] == "true"' \
  'skyapp account-center audience mapper drift was not repaired'
skyapp_default_scopes=$(kcadm get \
  "clients/$skyapp_client_uuid/default-client-scopes" \
  -r e-skylab-test -c)
json_assert "$skyapp_default_scopes" \
  '[.[] | select(.id == $scope and .name == "skyapp-account-center-audience")] | length == 1' \
  'skyapp audience scope is not attached as a default scope' \
  --arg scope "$skyapp_scope_uuid"
stage_login_audiences_after_second_reconciliation

default_scopes=$(kcadm get "clients/$client_uuid/default-client-scopes" -r e-skylab-test -c)
json_assert "$default_scopes" \
  '([.[].name] | sort) == ["account-center-account-api", "account-center-core-claims"]' \
  'unexpected Account Center default client scopes remain'
optional_scopes=$(kcadm get "clients/$client_uuid/optional-client-scopes" -r e-skylab-test -c)
json_assert "$optional_scopes" \
  'length == 0' \
  'unexpected Account Center optional client scopes remain'

account_roles=$(kcadm get \
  "clients/$client_uuid/scope-mappings/clients/$account_client_uuid" \
  -r e-skylab-test -c)
json_assert "$account_roles" \
  '([.[].name] | sort) == ["manage-account", "manage-account-links", "view-profile"]' \
  'unexpected Account API role mappings remain'
default_account_roles=$(kcadm get \
  "roles-by-id/$default_role_uuid/composites/clients/$account_client_uuid" \
  -r e-skylab-test -c)
json_assert "$default_account_roles" \
  '([.[].name] | map(select(. == "manage-account" or . == "view-profile"))) | length == 0' \
  'Account Center reconciliation granted Account REST roles realm-wide'

config_client_uuid=$(kcadm get clients -r e-skylab-test -c \
  | jq -r '.[] | select(.clientId == "account-center-config") | .id')
config_client=$(kcadm get "clients/$config_client_uuid" -r e-skylab-test -c)
json_assert "$config_client" \
  '.serviceAccountsEnabled == true and .standardFlowEnabled == false and .directAccessGrantsEnabled == false and .fullScopeAllowed == false' \
  'configuration client is not service-account-only'
config_service_user=$(kcadm get "clients/$config_client_uuid/service-account-user" \
  -r e-skylab-test -c | jq -r .id)
realm_management_uuid=$(kcadm get clients -r e-skylab-test -c \
  | jq -r '.[] | select(.clientId == "realm-management") | .id')
config_roles=$(kcadm get \
  "users/$config_service_user/role-mappings/clients/$realm_management_uuid" \
  -r e-skylab-test -c)
json_assert "$config_roles" \
  '([.[].name] | sort) == ["manage-clients", "manage-realm", "view-clients", "view-realm"]' \
  'configuration client realm-management roles exceed the allowlist'

stage_v2_assert_realm_identity
stage_v2_assert_user_profile
stage_v2_assert_account_api_scope
stage_v2_assert_mailer_client
stage_v2_mailer_drift_is_reported

# Account erasure (ADR-0051, ticket 03): the operator script builds the core-erasure client, its
# erase scopes and roles; the reconciler verifies them. It runs before the no-op reconciliation so
# that run proves the verification writes nothing.
CURRENT_STAGE='core-erasure client operator script and reconciler verification'
ERASURE_COMPOSE_FILE="$COMPOSE_FILE" \
  ERASURE_ADMIN_CONFIG="$ADMIN_CONFIG" \
  ERASURE_REALM="$V2_REALM" \
  "$SCRIPT_DIR/core-erasure-client.sh"

stage_v2_reconcile_noop
stage_v2_identity_guardrails

# A1c: the operator adoption of verified legacy primaries as the Personal e-mail, in a throwaway
# realm that takes the reconciled User Profile: dry run, apply, then a run that writes nothing.
CURRENT_STAGE='legacy personal e-mail adoption operator script'
LEGACY_EMAIL_COMPOSE_FILE="$COMPOSE_FILE" \
  LEGACY_EMAIL_ADMIN_CONFIG="$ADMIN_CONFIG" \
  LEGACY_EMAIL_SOURCE_REALM="$V2_REALM" \
  "$SCRIPT_DIR/legacy-personal-email-adoption.sh"

# Account erasure ticket 09: which personal data Keycloak's admin and user events keep once core's
# saga has deleted a person, and what each remedy does, in a throwaway realm with production's
# event settings that takes the reconciled User Profile.
CURRENT_STAGE='erasure event PII evidence'
EVENT_PII_COMPOSE_FILE="$COMPOSE_FILE" \
  EVENT_PII_ADMIN_CONFIG="$ADMIN_CONFIG" \
  EVENT_PII_SOURCE_REALM="$V2_REALM" \
  "$SCRIPT_DIR/erasure-event-pii.sh"

CURRENT_STAGE='minimal openid PAR contract'
discovery=$(curl --fail --silent --show-error \
  http://localhost:18080/realms/e-skylab-test/.well-known/openid-configuration)
json_assert "$discovery" '.pushed_authorization_request_endpoint == "http://localhost:18080/realms/e-skylab-test/protocol/openid-connect/ext/par/request"' 'PAR endpoint is not advertised'

client_secret=$(kcadm get "clients/$client_uuid/client-secret" -r e-skylab-test -c | jq -r .value)
[[ -n $client_secret && $client_secret != null ]] || fail "client secret was not generated"

CURRENT_STAGE='skyapp account-center audience token contract'
skyapp_token_response=$(curl --fail --silent --show-error \
  --data-urlencode grant_type=password \
  --data-urlencode client_id=skyapp \
  --data-urlencode username=account-fixture \
  --data-urlencode password=fixture-password-change-me \
  --data-urlencode scope=openid \
  http://localhost:18080/realms/e-skylab-test/protocol/openid-connect/token)
skyapp_access_token=$(jq -r .access_token <<<"$skyapp_token_response")
[[ -n $skyapp_access_token && $skyapp_access_token != null ]] \
  || fail 'skyapp direct grant did not return an access token'
skyapp_payload_segment=$(cut -d. -f2 <<<"$skyapp_access_token")
case $((${#skyapp_payload_segment} % 4)) in
  2) skyapp_payload_segment="${skyapp_payload_segment}==" ;;
  3) skyapp_payload_segment="${skyapp_payload_segment}=" ;;
esac
skyapp_payload=$(tr '_-' '/+' <<<"$skyapp_payload_segment" | base64 --decode)
json_assert "$skyapp_payload" \
  '.azp == "skyapp" and ((.aud == "account-center") or ((.aud | type) == "array" and (.aud | index("account-center") != null)))' \
  'skyapp access token is missing the account-center audience or changed azp'

par_response=$(curl --fail --silent --show-error \
  --user "account-center:$client_secret" \
  --data-urlencode client_id=account-center \
  --data-urlencode response_type=code \
  --data-urlencode scope=openid \
  --data-urlencode redirect_uri=https://my.yildizskylab.com/api/auth/callback \
  --data-urlencode code_challenge=QWxhZGRpbjpPcGVuU2VzYW1lMTIzNDU2Nzg5MDEyMzQ1Njc \
  --data-urlencode code_challenge_method=S256 \
  http://localhost:18080/realms/e-skylab-test/protocol/openid-connect/ext/par/request)
json_assert "$par_response" '.request_uri | startswith("urn:ietf:params:oauth:request_uri:")' 'PAR request was not accepted'

wrong_redirect_status=$(curl --silent --show-error \
  --output "$TEST_STATE_DIR/wrong-redirect.json" \
  --write-out '%{http_code}' \
  --user "account-center:$client_secret" \
  --data-urlencode client_id=account-center \
  --data-urlencode response_type=code \
  --data-urlencode scope=openid \
  --data-urlencode redirect_uri=https://attacker.invalid/callback \
  --data-urlencode code_challenge=QWxhZGRpbjpPcGVuU2VzYW1lMTIzNDU2Nzg5MDEyMzQ1Njc \
  --data-urlencode code_challenge_method=S256 \
  http://localhost:18080/realms/e-skylab-test/protocol/openid-connect/ext/par/request)
[[ $wrong_redirect_status == 400 ]] || fail "PAR accepted a non-allowlisted redirect URI"

plain_pkce_status=$(curl --silent --show-error \
  --output "$TEST_STATE_DIR/plain-pkce.json" \
  --write-out '%{http_code}' \
  --user "account-center:$client_secret" \
  --data-urlencode client_id=account-center \
  --data-urlencode response_type=code \
  --data-urlencode scope=openid \
  --data-urlencode redirect_uri=https://my.yildizskylab.com/api/auth/callback \
  --data-urlencode code_challenge=plain-code-challenge-that-is-long-enough-for-pkce \
  --data-urlencode code_challenge_method=plain \
  http://localhost:18080/realms/e-skylab-test/protocol/openid-connect/ext/par/request)
[[ $plain_pkce_status == 400 ]] || fail "PAR accepted plain PKCE"

request_uri=$(jq -r .request_uri <<<"$par_response")
request_uri_query=$(jq -rn --arg value "$request_uri" '$value | @uri')
CURRENT_STAGE='login theme render smoke test'
login_page=$(curl --fail --silent --show-error --location \
  --cookie-jar "$TEST_STATE_DIR/login.cookies" \
  --cookie "$TEST_STATE_DIR/login.cookies" \
  "http://localhost:18080/realms/e-skylab-test/protocol/openid-connect/auth?client_id=account-center&request_uri=$request_uri_query")
[[ $login_page == *e-skylab-theme* ]] \
  || fail "the configured SKY LAB login theme did not render"

CURRENT_STAGE='AIA PAR acceptance'
aia_par_response=$(curl --fail --silent --show-error \
  --user "account-center:$client_secret" \
  --data-urlencode client_id=account-center \
  --data-urlencode response_type=code \
  --data-urlencode scope=openid \
  --data-urlencode redirect_uri=https://my.yildizskylab.com/api/auth/callback \
  --data-urlencode code_challenge=QWxhZGRpbjpPcGVuU2VzYW1lMTIzNDU2Nzg5MDEyMzQ1Njc \
  --data-urlencode code_challenge_method=S256 \
  --data-urlencode kc_action=UPDATE_PASSWORD \
  http://localhost:18080/realms/e-skylab-test/protocol/openid-connect/ext/par/request)
json_assert "$aia_par_response" \
  '.request_uri | startswith("urn:ietf:params:oauth:request_uri:")' \
  'allowlisted UPDATE_PASSWORD AIA PAR request was not accepted'

fixture_user_uuid=$(kcadm get users -r e-skylab-test -q username=account-fixture -c \
  | jq -r '.[] | select(.username == "account-fixture") | .id')

# The Web handoff (sky-handoff provider, ADR-0048), which replaced the retired native handoff:
# SkyApp mints a code, the WebView opens it with its proof and account-center signs in
# silently from the browser session. Its stages are named 'web handoff ...'.
CURRENT_STAGE='web handoff contract'
SKY_HANDOFF_COMPOSE_FILE="$COMPOSE_FILE" \
  SKY_HANDOFF_ADMIN_CONFIG="$ADMIN_CONFIG" \
  SKY_HANDOFF_CLIENT_SECRET="$client_secret" \
  "$SCRIPT_DIR/sky-handoff-contract.sh"

CURRENT_STAGE='real browser authorization-code login'
code_verifier=account-center-integration-code-verifier-0123456789abcdefghijklmnop
code_challenge=$(printf '%s' "$code_verifier" \
  | openssl dgst -binary -sha256 \
  | openssl base64 -A \
  | tr '+/' '-_' \
  | tr -d '=')
browser_par_response=$(curl --fail --silent --show-error \
  --user "account-center:$client_secret" \
  --data-urlencode client_id=account-center \
  --data-urlencode response_type=code \
  --data-urlencode scope=openid \
  --data-urlencode redirect_uri=https://my.yildizskylab.com/api/auth/callback \
  --data-urlencode "code_challenge=$code_challenge" \
  --data-urlencode code_challenge_method=S256 \
  --data-urlencode state=integration-state \
  --data-urlencode nonce=integration-nonce \
  http://localhost:18080/realms/e-skylab-test/protocol/openid-connect/ext/par/request)
browser_request_uri=$(jq -r .request_uri <<<"$browser_par_response")
browser_request_uri_query=$(jq -rn --arg value "$browser_request_uri" '$value | @uri')
browser_login_page=$(curl --fail --silent --show-error --location \
  --cookie-jar "$TEST_STATE_DIR/browser-login.cookies" \
  --cookie "$TEST_STATE_DIR/browser-login.cookies" \
  "http://localhost:18080/realms/e-skylab-test/protocol/openid-connect/auth?client_id=account-center&request_uri=$browser_request_uri_query")
login_action_literals=$(grep -Eo '"loginAction"[[:space:]]*:[[:space:]]*"[^"]*"' \
  <<<"$browser_login_page" || true)
[[ $(grep -c . <<<"$login_action_literals") == 1 ]] \
  || fail "login theme did not expose one exact login action"
login_action_literal=$(sed -E \
  's/^"loginAction"[[:space:]]*:[[:space:]]*//' \
  <<<"$login_action_literals")
login_action=$(jq -r . <<<"$login_action_literal")
login_submit_status=$(curl --silent --show-error \
  --output "$TEST_STATE_DIR/login-submit.body" \
  --dump-header "$TEST_STATE_DIR/login-submit.headers" \
  --write-out '%{http_code}' \
  --cookie-jar "$TEST_STATE_DIR/browser-login.cookies" \
  --cookie "$TEST_STATE_DIR/browser-login.cookies" \
  --data-urlencode username=account-fixture \
  --data-urlencode password=fixture-password-change-me \
  --data-urlencode credentialId= \
  "$login_action")
[[ $login_submit_status == 302 ]] || fail "browser credential submission did not redirect"
authorization_redirects=$(awk '
  tolower($1) == "location:" {
    sub(/^[^:]*:[[:space:]]*/, "")
    sub(/\r$/, "")
    print
  }
' "$TEST_STATE_DIR/login-submit.headers")
[[ $(grep -c . <<<"$authorization_redirects") == 1 ]] \
  || fail "browser login did not return one exact authorization redirect"
authorization_redirect=$authorization_redirects
[[ $authorization_redirect == https://my.yildizskylab.com/api/auth/callback?* ]] \
  || fail "browser login redirected outside the exact callback"
[[ $authorization_redirect == *"state=integration-state"* ]] \
  || fail "browser authorization redirect lost state"
authorization_code=$(sed -n 's/.*[?&]code=\([^&]*\).*/\1/p' <<<"$authorization_redirect")
[[ -n $authorization_code ]] || fail "browser authorization redirect lacks a code"

CURRENT_STAGE='minimal openid ID and access token contract'
token_response=$(curl --fail --silent --show-error \
  --user "account-center:$client_secret" \
  --data-urlencode grant_type=authorization_code \
  --data-urlencode client_id=account-center \
  --data-urlencode "code=$authorization_code" \
  --data-urlencode redirect_uri=https://my.yildizskylab.com/api/auth/callback \
  --data-urlencode "code_verifier=$code_verifier" \
  http://localhost:18080/realms/e-skylab-test/protocol/openid-connect/token)
access_token=$(jq -r .access_token <<<"$token_response")
[[ -n $access_token && $access_token != null ]] || fail "browser code exchange did not receive an access token"
token_header_segment=$(cut -d. -f1 <<<"$access_token")
case $((${#token_header_segment} % 4)) in
  2) token_header_segment="${token_header_segment}==" ;;
  3) token_header_segment="${token_header_segment}=" ;;
esac
token_header=$(tr '_-' '/+' <<<"$token_header_segment" | base64 --decode)
json_assert "$token_header" \
  '.alg == "RS256" and .typ == "JWT"' \
  'access token JOSE header differs from the pinned RS256/JWT contract'
token_payload_segment=$(cut -d. -f2 <<<"$access_token")
case $((${#token_payload_segment} % 4)) in
  2) token_payload_segment="${token_payload_segment}==" ;;
  3) token_payload_segment="${token_payload_segment}=" ;;
esac
token_payload=$(tr '_-' '/+' <<<"$token_payload_segment" | base64 --decode)
json_assert "$token_payload" \
  '((.aud | if type == "array" then . else [.] end) | sort) == ["account", "core"] and .azp == "account-center" and .scope == "openid" and ((.resource_access.account.roles | index("manage-account")) != null) and ((.resource_access.account.roles | index("view-profile")) != null)' \
  'issued token differs from the exact audience, authorized-party, scope or required-role contract'
stage_v2_assert_token_contract "$token_payload"

id_token=$(jq -r .id_token <<<"$token_response")
[[ -n $id_token && $id_token != null ]] || fail "minimal openid request did not receive an ID token"
id_token_payload_segment=$(cut -d. -f2 <<<"$id_token")
case $((${#id_token_payload_segment} % 4)) in
  2) id_token_payload_segment="${id_token_payload_segment}==" ;;
  3) id_token_payload_segment="${id_token_payload_segment}=" ;;
esac
id_token_payload=$(tr '_-' '/+' <<<"$id_token_payload_segment" | base64 --decode)
now_epoch=$(date +%s)
json_assert "$id_token_payload" \
  '(.sub | type) == "string" and (.sub | length) > 0 and (.sid | type) == "string" and (.sid | length) > 0 and (.auth_time | type) == "number" and .auth_time == (.auth_time | floor) and .auth_time > 0 and .auth_time <= $now' \
  'ID token lacks a non-future integer auth_time, sub or sid' \
  --argjson now "$now_epoch"

CURRENT_STAGE='Account REST profile contract'
account_profile=$(curl --fail --silent --show-error \
  -H "Authorization: Bearer $access_token" \
  -H 'Accept: application/json' \
  http://localhost:18080/realms/e-skylab-test/account/)
json_assert "$account_profile" \
  '.username == "account-fixture" and .email == "account-fixture@example.invalid"' \
  'live Account REST profile contract failed'

stage_v2_assert_claim_surfaces "$access_token" "$id_token_payload" "$client_secret"
stage_v2_admin_rest_is_not_reachable_with_account_center_tokens "$client_secret"
stage_v2_assert_ytu_claims "$client_secret"

CURRENT_STAGE='real Chromium login and AIA contracts'
real_browser_config="$TEST_STATE_DIR/real-keycloak-browser.json"
jq -n \
  --arg baseUrl 'http://localhost:18080' \
  --arg callbackUrl 'https://my.yildizskylab.com/api/auth/callback' \
  --arg clientId 'account-center' \
  --arg clientSecret "$client_secret" \
  --arg username 'account-fixture' \
  --arg password 'fixture-password-change-me' \
  --arg changedPassword 'fixture-password-changed-by-browser' \
  '{
    baseUrl: $baseUrl,
    callbackUrl: $callbackUrl,
    clientId: $clientId,
    clientSecret: $clientSecret,
    username: $username,
    password: $password,
    changedPassword: $changedPassword
  }' \
  >"$real_browser_config"
chmod 0600 "$real_browser_config"
(
  cd "$SCRIPT_DIR/../theme"
  REAL_KEYCLOAK_BROWSER_CONFIG="$real_browser_config" \
    npx --no-install playwright test \
      --config=playwright.integration.config.ts \
      tests/integration/real-keycloak.spec.ts
)
# The Chromium stage changed the password and left a TOTP credential behind; the passkey
# cleanup stage logs the fixture person in again, so restore a password-only account first.
kcadm set-password \
  -r e-skylab-test \
  --userid "$fixture_user_uuid" \
  --new-password fixture-password-change-me \
  --temporary=false >/dev/null
while IFS= read -r otp_credential_id; do
  [[ -n $otp_credential_id ]] || continue
  kcadm delete "users/$fixture_user_uuid/credentials/$otp_credential_id" -r e-skylab-test >/dev/null
done < <(kcadm get "users/$fixture_user_uuid/credentials" -r e-skylab-test -c \
  | jq -r '.[] | select(.type == "otp") | .id')
stage_v2_passkey_cleanup "$client_secret"

# K5 runs before the sky-account contract on purpose: it writes the real keycloak-mailer
# secret into the sender's mount. Afterwards the contract's personal e-mail code travels the
# production path (a SkyMail task under keycloak.personal-email-confirm) and the contract reads
# it there; run later, the sender still holds the placeholder, falls back to SMTP, and the
# contract would only prove the fallback.
stage_k5_system_mail_through_skymail

# The sky-account SPI contract runs against the same realm: bearer guard, Verified
# YTÜ lock, brute force, sudo binding, password/TOTP/username flows and events.
CURRENT_STAGE='sky-account SPI contract'
SKY_ACCOUNT_COMPOSE_FILE="$COMPOSE_FILE" \
  SKY_ACCOUNT_ADMIN_CONFIG="$ADMIN_CONFIG" \
  SKY_ACCOUNT_CLIENT_SECRET="$client_secret" \
  "$SCRIPT_DIR/sky-account-contract.sh"

# The passkey ceremony runs a Chromium virtual authenticator against the SPI: register a
# passkey from an allowed my.-like origin, see it in GET identity, log in on Keycloak's own
# login page with it (RP-ID compatibility), sudo by passkey, and prove the refusals. The
# fixture passwordless policy is set to rpId=localhost and the served page origin as an extra
# origin so the ceremony's clientData origin is allowed; the disallowed origin proves rejection.
CURRENT_STAGE='sky-account passkey ceremony'
webauthn_realm_before=$(kcadm get "realms/e-skylab-test" -c \
  | jq -c '{webAuthnPolicyPasswordlessRpId, webAuthnPolicyPasswordlessExtraOrigins}')
kcadm update realms/e-skylab-test \
  -s 'webAuthnPolicyPasswordlessRpId=localhost' \
  -s 'webAuthnPolicyPasswordlessExtraOrigins=["http://localhost:18081"]' >/dev/null
# The ceremony gets its own person: sky-account rate limits are per user and per fixed
# 15-minute window, and the contract stage above deliberately exhausts the fixture user's
# sudo budget. A throwaway user keeps the ceremony independent of that and of leftover
# credentials; it is removed (with its passkey) at the end of the stage.
while IFS= read -r stale_passkey_user; do
  [[ -n $stale_passkey_user ]] || continue
  kcadm delete "users/$stale_passkey_user" -r e-skylab-test >/dev/null
done < <(kcadm get users -r e-skylab-test -c -q username=passkey-fixture -q exact=true | jq -r '.[].id')
passkey_user_password=$(openssl rand -base64 24 | tr -d '\n')
passkey_user_uuid=$(kcadm create users -r e-skylab-test -i \
  -s username=passkey-fixture -s enabled=true -s emailVerified=true \
  -s firstName=Passkey -s lastName=Fixture -s email=passkey-fixture@example.invalid)
kcadm set-password -r e-skylab-test --userid "$passkey_user_uuid" \
  --new-password "$passkey_user_password" --temporary=false >/dev/null
webauthn_page_log="$TEST_STATE_DIR/webauthn-page.log"
WEBAUTHN_PAGE_PORT=18081 WEBAUTHN_PAGE_DISALLOWED_PORT=18082 \
  node "$SCRIPT_DIR/webauthn-page.mjs" >"$webauthn_page_log" 2>&1 &
webauthn_page_pid=$!
# The page server is a plain background process; stop it explicitly on both paths rather than
# installing an EXIT trap that would clobber the compose teardown registered at startup.
webauthn_stop_page() {
  if [[ -n ${webauthn_page_pid:-} ]]; then
    kill "$webauthn_page_pid" >/dev/null 2>&1 || true
    wait "$webauthn_page_pid" 2>/dev/null || true
    webauthn_page_pid=''
  fi
}
for _ in $(seq 1 30); do
  if curl --fail --silent --show-error http://localhost:18081/ >/dev/null 2>&1 \
    && curl --fail --silent --show-error http://localhost:18082/ >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done
if ! curl --fail --silent --show-error http://localhost:18081/ >/dev/null 2>&1; then
  webauthn_stop_page
  fail 'the WebAuthn ceremony page did not become ready on http://localhost:18081'
fi
webauthn_config="$TEST_STATE_DIR/webauthn-integration.json"
jq -n \
  --arg baseUrl 'http://localhost:18080' \
  --arg realm 'e-skylab-test' \
  --arg callbackUrl 'https://my.yildizskylab.com/api/auth/callback' \
  --arg clientId 'account-center' \
  --arg clientSecret "$client_secret" \
  --arg username 'passkey-fixture' \
  --arg password "$passkey_user_password" \
  --arg pageOrigin 'http://localhost:18081' \
  --arg disallowedOrigin 'http://localhost:18082' \
  --arg rpId 'localhost' \
  --arg userId "$passkey_user_uuid" \
  '{baseUrl:$baseUrl, realm:$realm, callbackUrl:$callbackUrl, clientId:$clientId, clientSecret:$clientSecret, username:$username, password:$password, pageOrigin:$pageOrigin, disallowedOrigin:$disallowedOrigin, rpId:$rpId, userId:$userId}' \
  >"$webauthn_config"
chmod 0600 "$webauthn_config"
if ! (
  cd "$SCRIPT_DIR/../theme"
  WEBAUTHN_INTEGRATION_CONFIG="$webauthn_config" \
    npx --no-install playwright test \
      --config=playwright.integration.config.ts \
      tests/integration/webauthn-passkey.spec.ts
); then
  webauthn_stop_page
  fail 'the passkey ceremony Playwright test failed'
fi
webauthn_stop_page
# The ceremony must have left exactly one passkey on the throwaway user (the disallowed-origin
# registration was refused); then remove the user and restore the passwordless policy.
passkey_credentials=$(kcadm get "users/$passkey_user_uuid/credentials" -r e-skylab-test -c)
json_assert "$passkey_credentials" \
  '[.[] | select(.type == "webauthn-passwordless")] | length == 1' \
  'the passkey ceremony must leave exactly one passwordless credential on the throwaway user'
kcadm delete "users/$passkey_user_uuid" -r e-skylab-test >/dev/null
unset passkey_user_password
kcadm update realms/e-skylab-test \
  -s "webAuthnPolicyPasswordlessRpId=$(jq -r '.webAuthnPolicyPasswordlessRpId // ""' <<<"$webauthn_realm_before")" \
  -s "webAuthnPolicyPasswordlessExtraOrigins=$(jq -c '.webAuthnPolicyPasswordlessExtraOrigins // []' <<<"$webauthn_realm_before")" >/dev/null

# Provision the RabbitMQ topology expected by the provider, then use an admin
# event to prove the rebuilt provider can publish on Keycloak 26.7.4.
CURRENT_STAGE='RabbitMQ provider contract'
curl --fail --silent --show-error --user keycloak:integration-rabbit-password \
  -X PUT -H 'content-type: application/json' \
  -d '{"type":"topic","durable":true,"auto_delete":false,"internal":false,"arguments":{}}' \
  http://localhost:15673/api/exchanges/%2F/keycloak.events >/dev/null
curl --fail --silent --show-error --user keycloak:integration-rabbit-password \
  -X PUT -H 'content-type: application/json' \
  -d '{"durable":false,"auto_delete":true,"arguments":{}}' \
  http://localhost:15673/api/queues/%2F/keycloak-foundation-test >/dev/null
curl --fail --silent --show-error --user keycloak:integration-rabbit-password \
  -X POST -H 'content-type: application/json' \
  -d '{"routing_key":"KK.EVENT.#","arguments":{}}' \
  http://localhost:15673/api/bindings/%2F/e/keycloak.events/q/keycloak-foundation-test >/dev/null

kcadm update realms/e-skylab-test -s displayName='SKY LAB integration event' >/dev/null
for attempt in $(seq 1 30); do
  message_count=$(curl --fail --silent --show-error --user keycloak:integration-rabbit-password \
    http://localhost:15673/api/queues/%2F/keycloak-foundation-test | jq -r '.messages // 0')
  if [[ ${message_count:-0} -gt 0 ]]; then
    break
  fi
  sleep 1
done
[[ ${message_count:-0} -gt 0 ]] || fail "RabbitMQ provider did not publish the Keycloak admin event"

provider_names=$("${COMPOSE[@]}" exec -T keycloak sh -c \
  "find /opt/keycloak/providers -maxdepth 1 -type f -name '*.jar' -printf '%f\\n' | sort")
[[ $(grep -c '^e-skylab-spi-' <<<"$provider_names") == 1 ]] || fail "runtime does not contain exactly one SKY LAB SPI"
[[ $(grep -c '^e-skylab-theme-' <<<"$provider_names") == 1 ]] || fail "runtime does not contain exactly one SKY LAB theme"
[[ $(grep -c '^keycloak-to-rabbit-' <<<"$provider_names") == 1 ]] || fail "runtime does not contain exactly one RabbitMQ provider"

printf 'Keycloak 26.7.4 Account Center integration contract passed.\n'
