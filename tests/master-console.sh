#!/usr/bin/env bash
# Real-Keycloak contract of config/master-console.sh (rol-temizligi ticket 03): the console groups of
# master, its hardening and the passkey sign-in of the console. Stand-alone: starts the stock Keycloak
# image this repository builds on (the Dockerfile's KEYCLOAK_IMAGE) in dev mode with docker run --rm and
# no volume, copies config/ into the container and runs the script there the way an operator does.
#
# Fixtures: realms e-skylab and e-skylab-sandbox (so master holds the clients e-skylab-realm and
# e-skylab-sandbox-realm); master's bootstrap administrator admin; later the people of master: two
# writers (in /KONSOL/E-SKYLAB-YAZICILAR and /KONSOL/SANDBOX-YAZICILAR), a reader in a group of their
# own with view-* roles of e-skylab-realm (outside /KONSOL), three more admin holders, a person with an
# e-skylab-realm role directly and a service account with one.
#
# What it proves:
#   - a bad threshold and a file that lists an excluded role are refused before a login (exit 2);
#   - --check on a fresh master names every change and writes nothing;
#   - --apply creates the flow konsol-passkey (auth-username-password-form, webauthn-authenticator,
#     both REQUIRED, nothing else), binds it to security-admin-console, account-console and account,
#     sets brute force to e-skylab's values, the passkey policy, events (30 days, details on) and
#     enables webauthn-register, creates /KONSOL and its two leaves with the 17 roles each (no
#     impersonation); --check then has 0 changes, and a second --apply writes nothing (no admin event);
#   - drift is put back: a Cookie step and a DISABLED passkey step in the flow, a missing override, a
#     disabled webauthn-register, a missing password step (rebuilt in order); extra roles on a leaf
#     (impersonation), a role on /KONSOL, a subgroup and an unlisted group are WARNINGs, never taken
#     away; a default group under /KONSOL is a PROBLEM (exit 1, nothing written);
#   - the counts never name a person: admin holders against KEYCLOAK_MASTER_ADMIN_MAX, leaf members
#     against KEYCLOAK_CONSOLE_WRITERS_MAX, people with a <realm>-realm role outside /KONSOL (a service
#     account is not counted), console people without a passkey;
#   - Admin REST with the people's own tokens: a writer reads and writes e-skylab, cannot impersonate
#     and cannot read master; the view-* reader reads e-skylab and cannot write;
#   - in Chromium with a virtual authenticator (tests/master-console-browser.mjs): a console account
#     without a passkey is sent to register one right after its password and reaches the console; with
#     the SSO session open the console asks for the password and the passkey again (prompt=none gets
#     login_required); a sign-in without the registered passkey is refused; the view-* reader opens the
#     console;
#   - --remove-override takes the three overrides away (dry run first) and --apply puts them back.
# Requirements on the host: docker, curl, jq, node with theme/node_modules (npm ci) and Playwright's
# Chromium. MASTER_CONSOLE_TEST_PORT (default 18098), MASTER_CONSOLE_TEST_CONTAINER (default
# master-console-test-<pid>), MASTER_CONSOLE_TEST_IMAGE (default: the Dockerfile's KEYCLOAK_IMAGE),
# MASTER_CONSOLE_TEST_BROWSER=0 skips the browser stage (local runs without Chromium only).
# shellcheck disable=SC2016  # jq programs name jq variables
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=kcadm-jvm.sh
source "$SCRIPT_DIR/kcadm-jvm.sh"
# shellcheck source=kcadm-rest.sh
source "$SCRIPT_DIR/kcadm-rest.sh"
REPOSITORY_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
IMAGE=${MASTER_CONSOLE_TEST_IMAGE:-$(sed -n 's/^ARG KEYCLOAK_IMAGE=//p' "$REPOSITORY_ROOT/Dockerfile")}
PORT=${MASTER_CONSOLE_TEST_PORT:-18098}
BASE_URL="http://127.0.0.1:$PORT"
CONTAINER=${MASTER_CONSOLE_TEST_CONTAINER:-master-console-test-$$}
ADMIN_PASSWORD=harness-admin-password
PEOPLE_PASSWORD=harness-people-password-1
KCADM_CONFIG=/tmp/harness-kcadm.config
IN_CONTAINER_CONFIG=/tmp/config
MASTER=master
WRITERS=/KONSOL/E-SKYLAB-YAZICILAR
SANDBOX_WRITERS=/KONSOL/SANDBOX-YAZICILAR
WRITER_ROLES='["create-client","manage-authorization","manage-clients","manage-events","manage-identity-providers","manage-realm","manage-users","query-clients","query-groups","query-realms","query-users","view-authorization","view-clients","view-events","view-identity-providers","view-realm","view-users"]'
CURRENT_STAGE=startup
STATE_DIR=$(mktemp -d)

fail() {
  printf 'master-console failure during %s: %s\n' "$CURRENT_STAGE" "$1" >&2
  exit 1
}
cleanup() {
  kcadm_rest_cleanup
  docker rm -fv "$CONTAINER" >/dev/null 2>&1 || true
  rm -rf "$STATE_DIR"
}
trap 'status=$?; trap - EXIT; cleanup; exit "$status"' EXIT
on_error() {
  local status=$?
  printf 'master-console command failed during %s (line %s)\n' "$CURRENT_STAGE" "$1" >&2
  exit "$status"
}
trap 'on_error "$LINENO"' ERR

# kcadm "get" reads go to Admin REST from the host (tests/kcadm-rest.sh); writes stay on kcadm.
kcadm_rest_setup "$BASE_URL" "$ADMIN_PASSWORD"

kcadm() {
  local command=$1
  shift
  if kcadm_rest_handles "$command" "$@"; then
    kcadm_rest_get "$@"
    return
  fi
  docker exec -i "$CONTAINER" /opt/keycloak/bin/kcadm.sh "$command" --config "$KCADM_CONFIG" "$@" \
    2> >(grep -v -e '^Created new ' -e '^$' >&2 || true)
}

# run_expecting STATUS ARGS...: config/master-console.sh with the harness's kcadm session, for a run
# that must exit STATUS; prints the output. RUN_ENV holds extra docker exec -e options.
RUN_ENV=()
run_expecting() {
  local wanted=$1 output status=0
  shift
  trap - ERR
  output=$(docker exec -e KEYCLOAK_ADMIN_URL=http://localhost:8080 ${RUN_ENV[@]+"${RUN_ENV[@]}"} "$CONTAINER" \
    bash "$IN_CONTAINER_CONFIG/master-console.sh" --kcadm-config "$KCADM_CONFIG" "$@" 2>&1) || status=$?
  trap 'on_error "$LINENO"' ERR
  [[ $status == "$wanted" ]] || { printf '%s\n' "$output" >&2; fail "master-console.sh $* did not exit $wanted (exit $status)"; }
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

group_id() { # group_id PATH (in master)
  kcadm get "group-by-path$1" -r "$MASTER" | jq -r .id
}

events() { # events: the number of master's admin events so far
  kcadm get admin-events -r "$MASTER" -q max=100000 | jq length
}

# flow_shape: master's konsol-passkey as "level:provider:requirement" lines.
flow_shape() {
  kcadm get authentication/flows/konsol-passkey/executions -r "$MASTER" \
    | jq -r '.[] | "\(.level):\(.providerId // "subflow"):\(.requirement)"'
}

override_of() { # override_of CLIENT_ID: the browser override's flow id ("" when none)
  kcadm get "clients/$(client_uuid "$MASTER" "$1")" -r "$MASTER" | jq -r '.authenticationFlowBindingOverrides.browser // ""'
}

flow_id() {
  kcadm get authentication/flows -r "$MASTER" | jq -r '.[] | select(.alias == "konsol-passkey") | .id'
}

leaf_roles() { # leaf_roles PATH CLIENT: the client roles the group holds, sorted JSON
  kcadm get "groups/$(group_id "$1")/role-mappings" -r "$MASTER" \
    | jq -c --arg c "$2" '[(.clientMappings // {})[$c].mappings // [] | .[].name] | sort'
}

realm_client_role_body() { # realm_client_role_body CLIENT ROLE...: [{id,name}] of master's client roles
  local client=$1
  shift
  kcadm get "clients/$(client_uuid "$MASTER" "$client")/roles" -r "$MASTER" \
    | jq -c --args '[.[] | select(.name as $n | $ARGS.positional | index($n)) | {id, name}]' "$@"
}

make_person() { # make_person USERNAME [GROUP_PATH...]: a master account with the people's password
  local username=$1 user_id path
  shift
  kcadm create users -r "$MASTER" -s "username=$username" -s enabled=true -s "email=$username@example.test" \
    -s emailVerified=true -s firstName=Harness -s lastName=Person >/dev/null
  kcadm set-password -r "$MASTER" --username "$username" --new-password "$PEOPLE_PASSWORD" >/dev/null
  user_id=$(kcadm get users -r "$MASTER" -q "username=$username" -q exact=true | jq -r '.[0].id')
  for path in "$@"; do
    kcadm update "users/$user_id/groups/$(group_id "$path")" -r "$MASTER" -n -b '{}' >/dev/null
  done
}

user_id() {
  kcadm get users -r "$1" -q "username=$2" -q exact=true | jq -r '.[0].id'
}

# token USERNAME: a master access token of the person, password grant through admin-cli (the direct
# grant flow; the browser flow and its passkey do not apply, see the runbook).
token() {
  curl -fsS "$BASE_URL/realms/$MASTER/protocol/openid-connect/token" \
    --data-urlencode grant_type=password --data-urlencode client_id=admin-cli \
    --data-urlencode "username=$1" --data-urlencode "password=$PEOPLE_PASSWORD" | jq -r .access_token
}

# status_of METHOD PATH TOKEN [BODY]: the HTTP status of an Admin REST call.
status_of() {
  local args=(-s -o /dev/null -w '%{http_code}' -X "$1" -H "authorization: Bearer $3")
  [[ -z ${4:-} ]] || args+=(-H 'content-type: application/json' --data "$4")
  curl "${args[@]}" "$BASE_URL/admin/realms/$2"
}

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='Keycloak start'
[[ -n $IMAGE ]] || fail 'Dockerfile has no ARG KEYCLOAK_IMAGE'
for tool in jq curl; do command -v "$tool" >/dev/null || fail "$tool is required"; done
docker run --rm -d --name "$CONTAINER" -p "127.0.0.1:$PORT:8080" \
  -e KC_OPTS="$KCADM_JVM_OPTS" \
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
docker cp "$REPOSITORY_ROOT/config/." "$CONTAINER:$IN_CONTAINER_CONFIG/" >/dev/null

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='refused inputs'
RUN_ENV=(-e KEYCLOAK_MASTER_ADMIN_MAX=three)
refused=$(run_expecting 2 --check)
expect_line "$refused" 'must be whole numbers' 'a bad threshold was not refused'
RUN_ENV=()
docker exec "$CONTAINER" sh -c "sed 's/\"create-client\",/\"create-client\", \"impersonation\",/' $IN_CONTAINER_CONFIG/master-console.json > /tmp/bad-console.json"
RUN_ENV=(-e KEYCLOAK_MASTER_CONSOLE_FILE=/tmp/bad-console.json)
refused=$(run_expecting 2 --apply)
expect_line "$refused" 'lists the excluded role impersonation' 'a leaf with impersonation was not refused'
reject_line "$refused" 'realm=master' 'the script went on with a bad file'
RUN_ENV=()
printf '    a bad threshold and a file listing impersonation refused before a login (exit 2)\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='fixtures (master as Keycloak makes it)'
kcadm create realms -s realm=e-skylab -s enabled=true >/dev/null
kcadm create realms -s realm=e-skylab-sandbox -s enabled=true >/dev/null
kcadm create users -r e-skylab -s username=member -s enabled=true >/dev/null
[[ -n $(client_uuid "$MASTER" e-skylab-realm) ]] || fail 'master has no client e-skylab-realm'
all_roles=$(kcadm get "clients/$(client_uuid "$MASTER" e-skylab-realm)/roles" -r "$MASTER" | jq -c '[.[].name] | sort')
[[ $(jq -c '. - ["impersonation"]' <<<"$all_roles") == "$WRITER_ROLES" ]] \
  || fail "e-skylab-realm's roles are not the 17 of the file plus impersonation: $all_roles"
printf '    e-skylab-realm in master: the 17 roles of config/master-console.json and impersonation\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='--check on a fresh master'
before=$(kcadm get "realms/$MASTER" | jq -c '{bruteForceProtected, adminEventsEnabled, eventsEnabled}')
checked=$(run_expecting 0 --check)
for line in 'would set brute force detection (the values of e-skylab)' 'would set WebAuthn policy' \
  'would set user and admin events (kept 2592000 s, admin event details on)' \
  'would create the flow konsol-passkey (auth-username-password-form webauthn-authenticator, each REQUIRED; no Cookie step)' \
  'would bind the browser sign-in of security-admin-console to konsol-passkey' \
  'would bind the browser sign-in of account-console to konsol-passkey' \
  'would bind the browser sign-in of account to konsol-passkey' \
  'would create the group /KONSOL (no role, no member)' \
  'would create the console group /KONSOL/E-SKYLAB-YAZICILAR (e-skylab-realm: every role but impersonation; no member)' \
  'would create the console group /KONSOL/SANDBOX-YAZICILAR' \
  'would map 17 role(s) of e-skylab-realm to /KONSOL/E-SKYLAB-YAZICILAR' \
  'count: 1 person(s) hold master'"'"'s realm role admin (at most 3' \
  'count: 1 console person(s) (admin or a console group), 1 of them without a passkey'; do
  expect_line "$checked" "$line" 'the dry run did not name it'
done
reject_line "$checked" 'would enable the required action' 'webauthn-register is enabled in a fresh master'
[[ -z $(flow_id) ]] || fail 'the dry run created the flow'
[[ $(kcadm get "realms/$MASTER" | jq -c '{bruteForceProtected, adminEventsEnabled, eventsEnabled}') == "$before" ]] \
  || fail 'the dry run changed the realm'
[[ -z $(override_of security-admin-console) ]] || fail 'the dry run bound the console'
printf '    --check names every change and writes nothing\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='--apply'
applied=$(run_expecting 0 --apply)
expect_line "$applied" 'create the flow konsol-passkey' 'the flow was not created'
expect_line "$applied" 'map 17 role(s) of e-skylab-sandbox-realm to /KONSOL/SANDBOX-YAZICILAR' 'the sandbox leaf was not mapped'
[[ $(flow_shape | paste -sd' ' -) == '0:auth-username-password-form:REQUIRED 0:webauthn-authenticator:REQUIRED' ]] \
  || fail "the flow is not password then passkey: $(flow_shape | paste -sd' ' -)"
flow=$(flow_id)
for client in security-admin-console account-console account; do
  [[ $(override_of "$client") == "$flow" ]] || fail "$client is not bound to konsol-passkey"
done
security=$(jq -c '{bruteForceProtected, permanentLockout, failureFactor, waitIncrementSeconds, maxFailureWaitSeconds, maxDeltaTimeSeconds, quickLoginCheckMilliSeconds, minimumQuickLoginWaitSeconds}' \
  "$REPOSITORY_ROOT/config/account-center-realm-security.json")
realm=$(kcadm get "realms/$MASTER")
[[ $(jq -c '{bruteForceProtected, permanentLockout, failureFactor, waitIncrementSeconds, maxFailureWaitSeconds, maxDeltaTimeSeconds, quickLoginCheckMilliSeconds, minimumQuickLoginWaitSeconds}' <<<"$realm") == "$security" ]] \
  || fail 'master brute force is not e-skylab'"'"'s'
jq -e '.eventsEnabled and .adminEventsEnabled and .adminEventsDetailsEnabled and .eventsExpiration == 2592000
  and .attributes.adminEventsExpiration == "2592000"
  and .webAuthnPolicyUserVerificationRequirement == "required" and .webAuthnPolicyResidentKey == "required"
  and .webAuthnPolicyRpEntityName == "keycloak"' <<<"$realm" >/dev/null \
  || fail "master events or passkey policy: $(jq -c '{eventsEnabled, adminEventsEnabled, adminEventsDetailsEnabled, eventsExpiration, webAuthnPolicyUserVerificationRequirement, webAuthnPolicyResidentKey, webAuthnPolicyRpEntityName}' <<<"$realm")"
[[ $(jq -c '(.passwordPolicy // "")' <<<"$realm") == '""' ]] || fail 'the script set a password policy on master'
for leaf in "$WRITERS:e-skylab-realm" "$SANDBOX_WRITERS:e-skylab-sandbox-realm"; do
  [[ $(leaf_roles "${leaf%%:*}" "${leaf#*:}") == "$WRITER_ROLES" ]] || fail "${leaf%%:*} does not hold the 17 roles"
done
[[ $(kcadm get "groups/$(group_id /KONSOL)/role-mappings" -r "$MASTER" | jq -c '[.realmMappings // [], (.clientMappings // {} | to_entries)] | flatten | length') == 0 ]] \
  || fail '/KONSOL holds a role'
rechecked=$(run_expecting 0 --check)
expect_line "$rechecked" 'check: 0 change(s) pending, 1 warning(s), 0 problem(s)' '--check after --apply is not clean'
expect_line "$rechecked" 'WARNING: 1 console person(s) have no passkey yet' 'the bootstrap admin without a passkey is not counted'
events_before=$(events)
again=$(run_expecting 0 --apply)
expect_line "$again" 'applied 0 change(s)' 'a second --apply changed something'
[[ $(events) == "$events_before" ]] || fail "a second --apply left $(($(events) - events_before)) admin event(s)"
printf '    --apply: flow, overrides, brute force, events, passkey policy and the two leaves; --check 0 changes; a second --apply leaves no admin event\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='drift'
flows_path=authentication/flows/konsol-passkey/executions
cookie=$(kcadm create "$flows_path/execution" -r "$MASTER" -i -b '{"provider":"auth-cookie"}')
kcadm update "$flows_path" -r "$MASTER" -n -b "{\"id\":\"$cookie\",\"requirement\":\"ALTERNATIVE\"}" >/dev/null
passkey_step=$(kcadm get "$flows_path" -r "$MASTER" | jq -r '.[] | select(.providerId == "webauthn-authenticator") | .id')
kcadm update "$flows_path" -r "$MASTER" -n -b "{\"id\":\"$passkey_step\",\"requirement\":\"DISABLED\"}" >/dev/null
kcadm update "clients/$(client_uuid "$MASTER" account-console)" -r "$MASTER" -s 'authenticationFlowBindingOverrides.browser=' >/dev/null
kcadm update authentication/required-actions/webauthn-register -r "$MASTER" -s enabled=false >/dev/null
kcadm create "groups/$(group_id "$WRITERS")/role-mappings/clients/$(client_uuid "$MASTER" e-skylab-realm)" -r "$MASTER" \
  -b "$(realm_client_role_body e-skylab-realm impersonation)" >/dev/null
kcadm create "groups/$(group_id /KONSOL)/role-mappings/clients/$(client_uuid "$MASTER" e-skylab-sandbox-realm)" -r "$MASTER" \
  -b "$(realm_client_role_body e-skylab-sandbox-realm view-users)" >/dev/null
kcadm create "groups/$(group_id "$WRITERS")/children" -r "$MASTER" -s name=ALT >/dev/null
kcadm create "groups/$(group_id /KONSOL)/children" -r "$MASTER" -s name=BASKA >/dev/null
drift=$(run_expecting 0 --check)
for line in 'would remove auth-cookie (level 0, ALTERNATIVE) from the flow konsol-passkey' \
  'would set webauthn-authenticator of the flow konsol-passkey to REQUIRED (was DISABLED)' \
  'would bind the browser sign-in of account-console to konsol-passkey' \
  'would enable the required action webauthn-register' \
  'WARNING: /KONSOL/E-SKYLAB-YAZICILAR also holds e-skylab-realm/impersonation' \
  'WARNING: /KONSOL itself holds roles (e-skylab-sandbox-realm/view-users)' \
  'WARNING: /KONSOL/E-SKYLAB-YAZICILAR has 1 subgroup(s)' \
  'WARNING: /KONSOL/BASKA is not in master-console.json' \
  'check: 4 change(s) pending, 5 warning(s), 0 problem(s)'; do
  expect_line "$drift" "$line" 'the drift was not named'
done
repaired=$(run_expecting 0 --apply)
expect_line "$repaired" 'applied 4 change(s), 5 warning(s)' 'the drift was not repaired'
[[ $(flow_shape | paste -sd' ' -) == '0:auth-username-password-form:REQUIRED 0:webauthn-authenticator:REQUIRED' ]] \
  || fail "the repaired flow: $(flow_shape | paste -sd' ' -)"
[[ $(override_of account-console) == "$flow" ]] || fail 'account-console was not bound again'
jq -e '.[] | select(.alias == "webauthn-register") | .enabled' <<<"$(kcadm get authentication/required-actions -r "$MASTER")" >/dev/null \
  || fail 'webauthn-register was not enabled'
[[ $(leaf_roles "$WRITERS" e-skylab-realm | jq 'index("impersonation") != null') == true ]] || fail 'impersonation was taken away'
# The extras go by hand, as an operator would.
kcadm delete "groups/$(group_id "$WRITERS")/role-mappings/clients/$(client_uuid "$MASTER" e-skylab-realm)" -r "$MASTER" \
  -b "$(realm_client_role_body e-skylab-realm impersonation)" >/dev/null
kcadm delete "groups/$(group_id /KONSOL)/role-mappings/clients/$(client_uuid "$MASTER" e-skylab-sandbox-realm)" -r "$MASTER" \
  -b "$(realm_client_role_body e-skylab-sandbox-realm view-users)" >/dev/null
kcadm delete "groups/$(group_id "$WRITERS/ALT")" -r "$MASTER" >/dev/null
kcadm delete "groups/$(group_id /KONSOL/BASKA)" -r "$MASTER" >/dev/null
# A missing password step: the steps are rebuilt in order.
password_step=$(kcadm get "$flows_path" -r "$MASTER" | jq -r '.[] | select(.providerId == "auth-username-password-form") | .id')
kcadm delete "authentication/executions/$password_step" -r "$MASTER" >/dev/null
rebuilt=$(run_expecting 0 --apply)
expect_line "$rebuilt" 'rebuild the steps of the flow konsol-passkey as auth-username-password-form webauthn-authenticator, each REQUIRED (found: webauthn-authenticator)' \
  'the missing password step was not rebuilt'
[[ $(flow_shape | paste -sd' ' -) == '0:auth-username-password-form:REQUIRED 0:webauthn-authenticator:REQUIRED' ]] \
  || fail "the rebuilt flow: $(flow_shape | paste -sd' ' -)"
[[ $(flow_id) == "$flow" ]] || fail 'the flow itself was replaced'
# A default group under /KONSOL: a PROBLEM, nothing written.
kcadm update "default-groups/$(group_id "$WRITERS")" -r "$MASTER" -n -b '{}' >/dev/null
kcadm update authentication/required-actions/webauthn-register -r "$MASTER" -s enabled=false >/dev/null
events_before=$(events)
refused=$(run_expecting 1 --apply)
expect_line "$refused" 'PROBLEM: the default group /KONSOL/E-SKYLAB-YAZICILAR is at or under /KONSOL' 'a default group under /KONSOL was not refused'
[[ $(events) == "$events_before" ]] || fail 'the refused run wrote something'
kcadm delete "default-groups/$(group_id "$WRITERS")" -r "$MASTER" >/dev/null
clean=$(run_expecting 0 --apply)
expect_line "$clean" 'applied 1 change(s), 1 warning(s), 0 problem(s)' 'the realm is not back to one change'
printf '    drift put back (Cookie step, DISABLED passkey, missing override, disabled registration, missing password step); extras only warned; a default group under /KONSOL refused\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='people and counts'
kcadm create groups -r "$MASTER" -s name=TEST-OKUYUCU >/dev/null
kcadm create "groups/$(group_id /TEST-OKUYUCU)/role-mappings/clients/$(client_uuid "$MASTER" e-skylab-realm)" -r "$MASTER" \
  -b "$(realm_client_role_body e-skylab-realm view-users view-realm view-clients view-events view-identity-providers view-authorization query-users query-groups query-clients query-realms)" >/dev/null
make_person yazici-bir "$WRITERS" "$SANDBOX_WRITERS"
make_person yazici-iki "$WRITERS" "$SANDBOX_WRITERS"
make_person okuyucu /TEST-OKUYUCU
for person in yonetici-bir yonetici-iki yonetici-uc; do
  make_person "$person"
  kcadm add-roles -r "$MASTER" --uusername "$person" --rolename admin >/dev/null
done
make_person dogrudan
kcadm add-roles -r "$MASTER" --uusername dogrudan --cclientid e-skylab-realm --rolename view-users >/dev/null
kcadm create clients -r "$MASTER" -s clientId=harness-service -s publicClient=false -s serviceAccountsEnabled=true \
  -s standardFlowEnabled=false >/dev/null
kcadm add-roles -r "$MASTER" --uusername service-account-harness-service --cclientid e-skylab-realm --rolename manage-users >/dev/null
RUN_ENV=(-e KEYCLOAK_CONSOLE_WRITERS_MAX=1)
counted=$(run_expecting 0 --check)
RUN_ENV=()
for line in 'count: 4 person(s) hold master'"'"'s realm role admin (at most 3' \
  'WARNING: 4 person(s) hold master'"'"'s admin, more than 3 (KEYCLOAK_MASTER_ADMIN_MAX)' \
  'count: /KONSOL/E-SKYLAB-YAZICILAR has 2 member(s) (at most 1)' \
  'WARNING: /KONSOL/SANDBOX-YAZICILAR has 2 member(s), more than 1 (KEYCLOAK_CONSOLE_WRITERS_MAX)' \
  'count: 2 person(s) hold a <realm>-realm role directly or through a group outside /KONSOL/*' \
  'count: 6 console person(s) (admin or a console group), 6 of them without a passkey' \
  'check: 0 change(s) pending, 5 warning(s), 0 problem(s)'; do
  expect_line "$counted" "$line" 'a count is wrong'
done
for person in yazici-bir yazici-iki okuyucu yonetici-bir dogrudan harness-service; do
  reject_line "$counted" "$person" 'the counts named a person'
done
kcadm remove-roles -r "$MASTER" --uusername yonetici-uc --rolename admin >/dev/null
counted=$(run_expecting 0 --check)
expect_line "$counted" 'count: 3 person(s) hold master'"'"'s realm role admin (at most 3' 'the admin count did not drop'
reject_line "$counted" "more than 3 (KEYCLOAK_MASTER_ADMIN_MAX)" 'three admin holders were warned'
printf '    counts: admin holders, leaf members, <realm>-realm roles outside /KONSOL (service account left out), console people without a passkey; no name printed\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='Admin REST with the people'"'"'s own tokens'
writer=$(token yazici-bir)
reader=$(token okuyucu)
member=$(user_id e-skylab member)
[[ $(status_of GET e-skylab/users "$writer") == 200 ]] || fail 'a writer cannot read e-skylab'
[[ $(status_of POST e-skylab/groups "$writer" '{"name":"YAZICI-DENEME"}') == 201 ]] || fail 'a writer cannot write e-skylab'
[[ $(status_of POST "e-skylab/users/$member/impersonation" "$writer") == 403 ]] || fail 'a writer can impersonate'
[[ $(status_of GET master/users "$writer") == 403 ]] || fail 'a writer can read master'
[[ $(status_of GET e-skylab-sandbox/users "$writer") == 200 ]] || fail 'a writer cannot read the sandbox'
[[ $(status_of GET e-skylab/users "$reader") == 200 ]] || fail 'the view-* reader cannot read e-skylab'
[[ $(status_of POST e-skylab/groups "$reader" '{"name":"OKUYUCU-DENEME"}') == 403 ]] || fail 'the view-* reader can write e-skylab'
[[ $(status_of PUT "e-skylab/users/$member" "$reader" '{"firstName":"Deneme"}') == 403 ]] || fail 'the view-* reader can change a person'
printf '    a writer reads and writes e-skylab, cannot impersonate or read master; a view-* reader reads and cannot write\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='the console sign-in in Chromium (virtual authenticator)'
if [[ ${MASTER_CONSOLE_TEST_BROWSER:-1} != 0 ]]; then
  command -v node >/dev/null || fail 'node is required for the browser stage (MASTER_CONSOLE_TEST_BROWSER=0 skips it)'
  user_events_before=$(kcadm get events -r "$MASTER" -q max=100000 | jq length)
  MASTER_CONSOLE_BASE_URL=$BASE_URL MASTER_CONSOLE_PASSWORD=$PEOPLE_PASSWORD \
    node "$SCRIPT_DIR/master-console-browser.mjs" | tee "$STATE_DIR/browser.log"
  expect_line "$(cat "$STATE_DIR/browser.log")" 'browser: all cases passed' 'the browser stage did not finish'
  events_json=$(kcadm get events -r "$MASTER" -q max=100000)
  [[ $(jq length <<<"$events_json") -gt $user_events_before ]] || fail 'master stored no user event of the sign-ins'
  jq -e '[.[] | select(.type == "LOGIN" and .clientId == "security-admin-console")] | length >= 3' <<<"$events_json" >/dev/null \
    || fail 'master has no LOGIN events of security-admin-console (ticket 18 reads them)'
  jq -e '[.[] | select(.type == "LOGIN_ERROR" and .clientId == "security-admin-console")] | length >= 1' <<<"$events_json" >/dev/null \
    || fail 'the refused sign-in left no LOGIN_ERROR'
  counted=$(run_expecting 0 --check)
  expect_line "$counted" 'count: 5 console person(s) (admin or a console group), 4 of them without a passkey' \
    'the passkeys registered in the browser are not counted'
  printf '    Chromium: registration on first sign-in, passkey again with an open SSO session, refusal without the passkey, view-* console; LOGIN and LOGIN_ERROR events stored\n'
else
  printf '    SKIPPED: the browser stage (MASTER_CONSOLE_TEST_BROWSER=0)\n'
fi

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='--remove-override'
dry=$(run_expecting 0 --remove-override)
for client in security-admin-console account-console account; do
  expect_line "$dry" "would remove the browser flow override of $client" 'the rollback dry run did not name it'
done
[[ $(override_of security-admin-console) == "$flow" ]] || fail 'the rollback dry run removed the override'
removed=$(run_expecting 0 --remove-override --apply)
expect_line "$removed" 'applied 3 change(s)' 'the rollback did not remove the three overrides'
for client in security-admin-console account-console account; do
  [[ -z $(override_of "$client") ]] || fail "$client is still bound after the rollback"
done
[[ $(flow_id) == "$flow" ]] || fail 'the rollback deleted the flow'
again=$(run_expecting 0 --remove-override --apply)
expect_line "$again" 'applied 0 change(s)' 'a second rollback changed something'
back=$(run_expecting 0 --apply)
expect_line "$back" 'applied 3 change(s)' '--apply did not bind the three clients again'
[[ $(override_of security-admin-console) == "$flow" ]] || fail 'the console is not bound again'
printf '    --remove-override: dry run, removes the three overrides, keeps the flow; --apply binds them again\n'

printf 'master-console contract passed\n'
