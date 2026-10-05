#!/usr/bin/env bash
# Real-Keycloak contract for config/forms-skymail-grants.sh (SkyMail's send permission for Forms'
# service account). Stand-alone: starts the stock Keycloak image this repository builds on (the
# Dockerfile's KEYCLOAK_IMAGE) in dev mode with docker run --rm and no volume, runs the script
# inside that container the way the wizard does and reads real client-credentials tokens the way
# forms-backend asks for them (scope openid), then asks userinfo the way SkyMail authenticates.
#
# Fixtures: realm e-skylab with a client skymail (roles skymail:access, skymail:mails:send,
# skymail:mails:write, skymail:templates:read) and a confidential client forms with a service
# account and no SkyMail role, the sandbox realm's state on 2026-10-05; realm e-skylab-sandbox with
# the same clients, where forms is fullScopeAllowed=false and its service account already holds
# skymail:mails:write.
#
# What it proves:
#   - every realm but e-skylab and e-skylab-sandbox is refused before a login (exit 2); a missing
#     allowed realm is exit 1 and writes nothing;
#   - --check writes nothing and plans skymail:access and skymail:mails:send; --apply grants exactly
#     those; the forms token then carries resource_access.skymail.roles [skymail:access,
#     skymail:mails:send] and userinfo answers 200 (SkyMail's check); a second --check plans nothing
#     and a second --apply writes nothing;
#   - with skymail:mails:write held and fullScopeAllowed=false, only skymail:access is granted,
#     skymail:mails:write is a NOTE and stays, and both roles enter the scope mappings so the token
#     carries them; nothing is ever removed;
#   - a client skymail without skymail:access is a PROBLEM (exit 1) and nothing is written.
# Requirements on the host: docker, curl, jq. FORMS_GRANTS_TEST_PORT (default 18094),
# FORMS_GRANTS_TEST_CONTAINER (default forms-skymail-grants-test-<pid>).
# shellcheck disable=SC2016  # jq programs name jq variables
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPOSITORY_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
OPERATOR_SCRIPT="$REPOSITORY_ROOT/config/forms-skymail-grants.sh"
IMAGE=$(sed -n 's/^ARG KEYCLOAK_IMAGE=//p' "$REPOSITORY_ROOT/Dockerfile")
PORT=${FORMS_GRANTS_TEST_PORT:-18094}
BASE_URL="http://127.0.0.1:$PORT"
CONTAINER=${FORMS_GRANTS_TEST_CONTAINER:-forms-skymail-grants-test-$$}
ADMIN_PASSWORD=harness-admin-password
KCADM_CONFIG=/tmp/harness-kcadm.config
IN_CONTAINER_SCRIPT=/tmp/forms-skymail-grants.sh
CURRENT_STAGE=startup

fail() {
  printf 'forms-skymail-grants failure during %s: %s\n' "$CURRENT_STAGE" "$1" >&2
  exit 1
}
cleanup() {
  docker rm -fv "$CONTAINER" >/dev/null 2>&1 || true
}
trap 'status=$?; trap - EXIT; cleanup; exit "$status"' EXIT
on_error() {
  local status=$?
  printf 'forms-skymail-grants command failed during %s (line %s)\n' "$CURRENT_STAGE" "$1" >&2
  exit "$status"
}
trap 'on_error "$LINENO"' ERR

kcadm() {
  local command=$1
  shift
  docker exec -i "$CONTAINER" /opt/keycloak/bin/kcadm.sh "$command" --config "$KCADM_CONFIG" "$@" \
    2> >(grep -v -e '^Created new ' -e '^$' >&2 || true)
}

# run_script REALM ARGS...: the operator script inside the container with the harness's kcadm session.
run_script() {
  local realm=$1
  shift
  docker exec -e KEYCLOAK_ADMIN_URL=http://localhost:8080 -e KEYCLOAK_REALM="$realm" "$CONTAINER" \
    bash "$IN_CONTAINER_SCRIPT" --kcadm-config "$KCADM_CONFIG" "$@" 2>&1
}

# run_expecting STATUS REALM ARGS...: run_script for a run that must exit STATUS; prints the output.
run_expecting() {
  local wanted=$1 output status=0
  shift
  trap - ERR
  output=$(run_script "$@") || status=$?
  trap 'on_error "$LINENO"' ERR
  [[ $status == "$wanted" ]] || { printf '%s\n' "$output" >&2; fail "the run did not exit $wanted (exit $status)"; }
  printf '%s\n' "$output"
}

expect_line() {
  grep -Fq -- "$2" <<<"$1" || { printf '%s\n' "$1" >&2; fail "$3: $2"; }
}

reject_line() {
  if grep -Fq -- "$2" <<<"$1"; then
    printf '%s\n' "$1" >&2
    fail "$3: $2"
  fi
}

client_uuid() { # client_uuid REALM CLIENT_ID
  kcadm get clients -r "$1" -q "clientId=$2" | jq -r --arg id "$2" '.[] | select(.clientId == $id) | .id'
}

# skymail_roles_of REALM: the skymail roles service-account-forms holds (sorted, comma-joined).
skymail_roles_of() {
  local forms skymail user
  forms=$(client_uuid "$1" forms)
  skymail=$(client_uuid "$1" skymail)
  user=$(kcadm get "clients/$forms/service-account-user" -r "$1" | jq -r .id)
  kcadm get "users/$user/role-mappings/clients/$skymail/composite" -r "$1" | jq -r '[.[].name] | sort | join(",")'
}

# token REALM: forms' client-credentials access token, asked for the way forms-backend does (scope openid).
token() {
  local secret
  secret=$(kcadm get "clients/$(client_uuid "$1" forms)/client-secret" -r "$1" | jq -j .value)
  printf '%s' "$secret" | curl -fsS "$BASE_URL/realms/$1/protocol/openid-connect/token" \
    --data-urlencode grant_type=client_credentials --data-urlencode client_id=forms \
    --data-urlencode client_secret@- --data-urlencode scope=openid | jq -r .access_token
}

jwt_payload() {
  local segment
  segment=$(cut -d. -f2 <<<"$1" | tr '_-' '/+')
  case $(( ${#segment} % 4 )) in 2) segment+='==' ;; 3) segment+='=' ;; esac
  base64 -d <<<"$segment"
}

userinfo_code() { # userinfo_code REALM TOKEN
  curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $2" "$BASE_URL/realms/$1/protocol/openid-connect/userinfo"
}

# make_fixture REALM: clients skymail (four roles) and forms (confidential, service account only).
make_fixture() {
  local realm=$1 skymail role
  kcadm create realms -s realm="$realm" -s enabled=true >/dev/null
  kcadm create clients -r "$realm" -s clientId=skymail -s publicClient=false -s standardFlowEnabled=true >/dev/null
  skymail=$(client_uuid "$realm" skymail)
  for role in skymail:access skymail:mails:send skymail:mails:write skymail:templates:read; do
    kcadm create "clients/$skymail/roles" -r "$realm" -s "name=$role" >/dev/null
  done
  kcadm create clients -r "$realm" -s clientId=forms -s publicClient=false -s standardFlowEnabled=false \
    -s directAccessGrantsEnabled=false -s serviceAccountsEnabled=true >/dev/null
}

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='Keycloak start'
[[ -n $IMAGE ]] || fail 'Dockerfile has no ARG KEYCLOAK_IMAGE'
for tool in jq curl; do command -v "$tool" >/dev/null || fail "$tool is required"; done
docker run --rm -d --name "$CONTAINER" -p "127.0.0.1:$PORT:8080" \
  -e KC_BOOTSTRAP_ADMIN_USERNAME=admin -e KC_BOOTSTRAP_ADMIN_PASSWORD="$ADMIN_PASSWORD" \
  "$IMAGE" start-dev >/dev/null
for _ in $(seq 1 90); do
  curl -fsS "$BASE_URL/realms/master" >/dev/null 2>&1 && break
  sleep 2
done
curl -fsS "$BASE_URL/realms/master" >/dev/null || fail "Keycloak did not start ($IMAGE)"
docker exec "$CONTAINER" /opt/keycloak/bin/kcadm.sh config credentials --config "$KCADM_CONFIG" \
  --server http://localhost:8080 --realm master --user admin --password "$ADMIN_PASSWORD" >/dev/null 2>&1 \
  || fail 'kcadm login failed'
docker exec -i "$CONTAINER" sh -c "cat > $IN_CONTAINER_SCRIPT" <"$OPERATOR_SCRIPT"

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='refused and missing realms'
for realm in master other-realm; do
  refused=$(run_expecting 2 "$realm" --apply)
  expect_line "$refused" "refusing realm $realm" 'realm not refused'
  reject_line "$refused" 'realm=' 'the refused run went on'
done
missing=$(run_expecting 1 e-skylab --apply)
expect_line "$missing" 'realm e-skylab does not exist or cannot be read; nothing was changed' 'missing realm not reported'
printf '    master and other-realm refused (exit 2); a missing realm is exit 1\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='e-skylab: no SkyMail role yet'
make_fixture e-skylab
[[ -z $(skymail_roles_of e-skylab) ]] || fail 'the fixture forms account already holds a skymail role'
before=$(token e-skylab)
[[ $(userinfo_code e-skylab "$before") == 200 ]] || fail 'userinfo refused the fixture token'
jq -e '(.resource_access.skymail // null) == null' <<<"$(jwt_payload "$before")" >/dev/null \
  || fail 'the fixture token already carries skymail roles'

checked=$(run_expecting 0 e-skylab)
expect_line "$checked" 'would assign skymail role skymail:access to service-account-forms' 'access not planned'
expect_line "$checked" 'would assign skymail role skymail:mails:send to service-account-forms' 'send not planned'
reject_line "$checked" 'skymail:mails:write to' 'write planned'
expect_line "$checked" 'check: 2 change(s) pending, 0 warning(s), 0 problem(s)' 'check summary'
[[ -z $(skymail_roles_of e-skylab) ]] || fail '--check wrote a role'

applied=$(run_expecting 0 e-skylab --apply)
expect_line "$applied" 'applied 2 change(s), 0 warning(s), 0 problem(s)' 'apply summary'
[[ $(skymail_roles_of e-skylab) == 'skymail:access,skymail:mails:send' ]] || fail "granted $(skymail_roles_of e-skylab)"
after=$(token e-skylab)
jq -e '(.resource_access.skymail.roles | sort) == ["skymail:access", "skymail:mails:send"]' <<<"$(jwt_payload "$after")" >/dev/null \
  || fail 'the forms token does not carry the two skymail roles'
[[ $(userinfo_code e-skylab "$after") == 200 ]] || fail 'userinfo refused the forms token after the grant'

again=$(run_expecting 0 e-skylab)
expect_line "$again" 'check: 0 change(s) pending' 'second check planned something'
again=$(run_expecting 0 e-skylab --apply)
expect_line "$again" 'applied 0 change(s)' 'second apply wrote something'
printf '    e-skylab: skymail:access + skymail:mails:send granted, in the token, userinfo 200; idempotent\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='e-skylab-sandbox: write held, full scope off'
make_fixture e-skylab-sandbox
forms=$(client_uuid e-skylab-sandbox forms)
skymail=$(client_uuid e-skylab-sandbox skymail)
kcadm update "clients/$forms" -r e-skylab-sandbox -s fullScopeAllowed=false >/dev/null
kcadm add-roles -r e-skylab-sandbox --uusername service-account-forms --cclientid skymail --rolename skymail:mails:write >/dev/null

checked=$(run_expecting 0 e-skylab-sandbox)
expect_line "$checked" 'NOTE: service-account-forms holds skymail:mails:write' 'write not noted'
expect_line "$checked" 'would assign skymail role skymail:access to service-account-forms' 'access not planned'
reject_line "$checked" 'would assign skymail role skymail:mails:send' 'send planned although write is held'
expect_line "$checked" 'would add scope mapping skymail/skymail:access to forms' 'access scope mapping not planned'
expect_line "$checked" 'would add scope mapping skymail/skymail:mails:write to forms' 'write scope mapping not planned'
expect_line "$checked" 'check: 3 change(s) pending' 'sandbox check summary'

applied=$(run_expecting 0 e-skylab-sandbox --apply)
expect_line "$applied" 'applied 3 change(s), 0 warning(s), 0 problem(s)' 'sandbox apply summary'
[[ $(skymail_roles_of e-skylab-sandbox) == 'skymail:access,skymail:mails:write' ]] || fail "sandbox holds $(skymail_roles_of e-skylab-sandbox)"
scope=$(kcadm get "clients/$forms/scope-mappings/clients/$skymail" -r e-skylab-sandbox | jq -r '[.[].name] | sort | join(",")')
[[ $scope == 'skymail:access,skymail:mails:write' ]] || fail "sandbox scope mappings: $scope"
jq -e '(.resource_access.skymail.roles | sort) == ["skymail:access", "skymail:mails:write"]' <<<"$(jwt_payload "$(token e-skylab-sandbox)")" >/dev/null \
  || fail 'the sandbox forms token does not carry the two skymail roles'
again=$(run_expecting 0 e-skylab-sandbox --apply)
expect_line "$again" 'applied 0 change(s)' 'second sandbox apply wrote something'
printf '    e-skylab-sandbox: write kept (NOTE), access granted, both in the scope mappings and the token\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='skymail without skymail:access'
kcadm delete "clients/$skymail/roles/skymail:access" -r e-skylab-sandbox >/dev/null
broken=$(run_expecting 1 e-skylab-sandbox --apply)
expect_line "$broken" 'PROBLEM: client skymail has no role skymail:access' 'missing role not a PROBLEM'
expect_line "$broken" 'applied 0 change(s)' 'a PROBLEM run wrote something'
printf '    a client skymail without skymail:access is a PROBLEM (exit 1), nothing written\n'

printf 'forms-skymail-grants: all checks passed\n'
