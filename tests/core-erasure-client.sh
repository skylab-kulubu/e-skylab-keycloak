#!/usr/bin/env bash
# Real-Keycloak contract for config/create-erasure-client.sh (account erasure, ADR-0051, ticket 03)
# and the reconciler's read-only verification of the core-erasure client. Invoked by
# run-integration.sh once the reconciled test realm exists and before the no-op reconciliation,
# so that run proves the verification writes nothing.
#
# What it proves:
#   - the script refuses an environment password outside the harness and stops, writing
#     nothing, while a resource client (skycms, forms) is missing;
#   - dry run prints the plan and writes nothing; apply builds exactly the contract; a second
#     dry run plans nothing and a second apply writes nothing (no admin event);
#   - a token requested with one erase scope carries azp=core-erasure, that service's audience
#     and exactly its erase role, nothing of the other services; a token without an erase scope
#     carries no erase role;
#   - core's own tokens are unchanged: its SkyMail send token carries no erase role, it cannot
#     request an erase scope, and Admin REST still accepts it;
#   - the reconciler verifies the client, fails on security drift and names the command, and the
#     script repairs that drift;
#   - the client secret appears in no output.
# Inputs: ERASURE_COMPOSE_FILE, ERASURE_ADMIN_CONFIG, TEST_STATE_DIR, ERASURE_REALM.
set -Eeuo pipefail

COMPOSE_FILE=${ERASURE_COMPOSE_FILE:?set ERASURE_COMPOSE_FILE}
ADMIN_CONFIG=${ERASURE_ADMIN_CONFIG:?set ERASURE_ADMIN_CONFIG}
STATE_DIR=${TEST_STATE_DIR:?set TEST_STATE_DIR}
REALM=${ERASURE_REALM:-e-skylab-test}
BASE_URL=http://localhost:18080
COMPOSE=(docker compose -f "$COMPOSE_FILE")
SCOPES=(account-erase-skymail account-erase-cms account-erase-forms)
RESOURCES=(skymail skycms forms)
ROLES=(skymail:account:erase cms:account:erase skyforms:account:erase)
ALL_ERASE_ROLES='["cms:account:erase","skyforms:account:erase","skymail:account:erase"]'
CURRENT_STAGE='core-erasure client fixture'

fail() {
  printf 'core-erasure client failure during %s: %s\n' "$CURRENT_STAGE" "$1" >&2
  exit 1
}
trap 'status=$?; printf "core-erasure client command failed during %s (line %s)\n" "$CURRENT_STAGE" "$LINENO" >&2; exit "$status"' ERR

kcadm() {
  local command=$1
  shift
  "${COMPOSE[@]}" exec -T keycloak /opt/keycloak/bin/kcadm.sh "$command" --config "$ADMIN_CONFIG" "$@"
}

create_erasure_client() {
  "${COMPOSE[@]}" run --rm --no-deps \
    -e KEYCLOAK_ADMIN_REALM=master \
    -e KEYCLOAK_REALM="$REALM" \
    -e KEYCLOAK_ERASURE_ADMIN_USERNAME=admin \
    -e KEYCLOAK_ERASURE_ADMIN_PASSWORD=integration-admin-password \
    -e SKY_HARNESS=1 \
    --entrypoint /opt/keycloak/config/create-erasure-client.sh \
    keycloak-config "$@" 2>&1
}

reconcile() {
  "${COMPOSE[@]}" run --rm --no-deps -e KEYCLOAK_REALM="$REALM" keycloak-config >"$1" 2>&1
}

expect_line() {
  local output=$1 expected=$2 message=$3
  grep -Fq -- "$expected" <<<"$output" || { printf '%s\n' "$output" >&2; fail "$message: $expected"; }
}

client_uuid() {
  kcadm get clients -r "$REALM" -q "clientId=$1" -c | jq -r --arg id "$1" '.[] | select(.clientId == $id) | .id'
}

scope_uuid() {
  kcadm get client-scopes -r "$REALM" -c | jq -r --arg name "$1" '.[] | select(.name == $name) | .id'
}

role_body() {
  kcadm get "clients/$1/roles" -r "$REALM" -c | jq -c --arg name "$2" '[.[] | select(.name == $name) | {id, name}]'
}

newest_admin_event() {
  kcadm get admin-events -r "$REALM" -q max=1 -c | jq -r '.[0].time // 0'
}

admin_events_since() {
  kcadm get admin-events -r "$REALM" -q max=500 -c | jq --argjson since "$1" '[.[] | select(.time > $since)] | length'
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

# token_response CLIENT SECRET SCOPE: the raw token endpoint response, the HTTP code on the last
# line. An empty SCOPE sends no scope parameter (the client's default scopes only).
token_response() {
  local scope_arguments=()
  [[ -z $3 ]] || scope_arguments=(--data-urlencode "scope=$3")
  curl --silent --show-error --write-out '\n%{http_code}' \
    --user "$1:$2" \
    --data-urlencode grant_type=client_credentials \
    ${scope_arguments[@]+"${scope_arguments[@]}"} \
    "$BASE_URL/realms/$REALM/protocol/openid-connect/token"
}

# access_payload CLIENT SECRET SCOPE: the decoded access token of a successful request.
access_payload() {
  local response code token
  response=$(token_response "$@")
  code=${response##*$'\n'}
  [[ $code == 200 ]] || fail "client credentials for $1 with scope '$3' returned HTTP $code"
  token=$(jq -r .access_token <<<"${response%$'\n'*}")
  [[ -n $token && $token != null ]] || fail "no access token for $1 with scope '$3'"
  jwt_payload "$token"
}

# Everything core-erasure is: the client, its scopes and mappings, the scopes' mappers and
# mappings, its service account's roles and the resource roles. Arrays are sorted: Keycloak does
# not keep the order of scope lists across detach and attach.
state_snapshot() {
  local client sa scope resource
  client=$(client_uuid core-erasure)
  sa=$(kcadm get "clients/$client/service-account-user" -r "$REALM" -c | jq -r .id)
  {
    kcadm get "clients/$client" -r "$REALM" -c | jq 'del(.secret)'
    kcadm get "clients/$client/default-client-scopes" -r "$REALM" -c
    kcadm get "clients/$client/optional-client-scopes" -r "$REALM" -c
    kcadm get "clients/$client/scope-mappings" -r "$REALM" -c
    for scope in "${SCOPES[@]}"; do
      scope=$(scope_uuid "$scope")
      kcadm get "client-scopes/$scope" -r "$REALM" -c
      kcadm get "client-scopes/$scope/scope-mappings" -r "$REALM" -c
    done
    for resource in "${RESOURCES[@]}"; do
      resource=$(client_uuid "$resource")
      kcadm get "users/$sa/role-mappings/clients/$resource" -r "$REALM" -c
      kcadm get "clients/$resource/roles" -r "$REALM" -c
    done
  } | jq -S -c 'walk(if type == "array" then sort_by(tojson) else . end)'
}

# The claims of core's own tokens that must not change with this ticket.
core_claims() {
  jq -S -c '{azp, aud, scope, resource_access, realm_access}' <<<"$(access_payload core "$core_secret" "$1")"
}

skymail_uuid=$(client_uuid skymail)
core_uuid=$(client_uuid core)
[[ -n $skymail_uuid && -n $core_uuid ]] || fail 'the fixture realm lacks the skymail or core client'
for resource in skycms forms; do
  stale=$(client_uuid "$resource")
  [[ -z $stale ]] || kcadm delete "clients/$stale" -r "$REALM" >/dev/null
done
[[ -z $(client_uuid core-erasure) ]] || fail 'core-erasure exists before the operator script ran'

# core sends through SkyMail with its own client (production: skymail:access and
# skymail:mails:send on service-account-core); its tokens are captured before the script runs.
core_sa=$(kcadm get "clients/$core_uuid/service-account-user" -r "$REALM" -c | jq -r .id)
for role in skymail:access skymail:mails:send; do
  kcadm create "users/$core_sa/role-mappings/clients/$skymail_uuid" -r "$REALM" \
    -b "$(role_body "$skymail_uuid" "$role")" >/dev/null
done
kcadm create "clients/$core_uuid/client-secret" -r "$REALM" >/dev/null 2>&1
core_secret=$(kcadm get "clients/$core_uuid/client-secret" -r "$REALM" -c | jq -r .value)
core_send_before=$(core_claims openid)
core_default_before=$(core_claims '')
jq -e '(.resource_access.skymail.roles | sort) == ["skymail:access", "skymail:mails:send"]' <<<"$core_send_before" >/dev/null \
  || fail "core's SkyMail send token does not carry the SkyMail send roles: $core_send_before"

CURRENT_STAGE='core-erasure script refuses an environment password outside the harness'
if "${COMPOSE[@]}" run --rm --no-deps \
  -e KEYCLOAK_ADMIN_REALM=master \
  -e KEYCLOAK_REALM="$REALM" \
  -e KEYCLOAK_ERASURE_ADMIN_USERNAME=admin \
  -e KEYCLOAK_ERASURE_ADMIN_PASSWORD=integration-admin-password \
  --entrypoint /opt/keycloak/config/create-erasure-client.sh \
  keycloak-config >"$STATE_DIR/create-erasure-refused.log" 2>&1; then
  cat "$STATE_DIR/create-erasure-refused.log" >&2
  fail 'create-erasure-client.sh accepted an environment password without SKY_HARNESS=1'
fi
grep -Fq 'KEYCLOAK_ERASURE_ADMIN_PASSWORD is accepted only by the test harness (SKY_HARNESS=1)' \
  "$STATE_DIR/create-erasure-refused.log" \
  || { cat "$STATE_DIR/create-erasure-refused.log" >&2; fail 'the refusal of the environment password is not explained'; }

CURRENT_STAGE='core-erasure script stops while a resource client is missing'
events_before=$(newest_admin_event)
for mode in '' --apply; do
  log_file="$STATE_DIR/create-erasure-missing${mode:+-apply}.log"
  # The expected failure is the if condition itself, not a command substitution: bash 3.2 runs
  # the ERR trap inside a failing $(...) even under if, which printed a misleading failure line.
  if create_erasure_client ${mode:+"$mode"} >"$log_file"; then
    cat "$log_file" >&2
    fail "the script ${mode:-dry run} succeeded although skycms and forms do not exist"
  fi
  output=$(cat "$log_file")
  expect_line "$output" 'resource client(s) skycms forms do not exist in realm e-skylab-test; nothing was changed' \
    'the script did not name the missing resource clients'
done
[[ -z $(client_uuid core-erasure) ]] || fail 'the stopped script created core-erasure'
[[ $(admin_events_since "$events_before") == 0 ]] || fail 'the stopped script wrote something'
[[ $(kcadm get "clients/$skymail_uuid/roles" -r "$REALM" -c | jq '[.[] | select(.name == "skymail:account:erase")] | length') == 0 ]] \
  || fail 'the stopped script created the SkyMail erase role'

# The resource clients as the services register them: CMS validates the skycms audience,
# Forms is a confidential client with a service account of its own.
kcadm create clients -r "$REALM" -s clientId=skycms -s 'name=SkyCMS (fixture)' -s protocol=openid-connect \
  -s publicClient=false -s bearerOnly=true -s standardFlowEnabled=false >/dev/null
kcadm create clients -r "$REALM" -s clientId=forms -s 'name=Forms backend (fixture)' -s protocol=openid-connect \
  -s publicClient=false -s serviceAccountsEnabled=true -s standardFlowEnabled=false >/dev/null

CURRENT_STAGE='core-erasure dry run'
events_before=$(newest_admin_event)
output=$(create_erasure_client)
printf '%s\n' "$output" >"$STATE_DIR/create-erasure-dry-run.log"
expect_line "$output" "[erasure-client] realm=$REALM client=core-erasure mode=dry-run" 'the dry run did not name its realm and mode'
expect_line "$output" 'would create confidential service-account client core-erasure (secret generated by Keycloak; default scopes basic roles; optional scopes account-erase-skymail account-erase-cms account-erase-forms)' \
  'the dry run did not plan the client'
for i in 0 1 2; do
  expect_line "$output" "would create client role ${ROLES[$i]} on ${RESOURCES[$i]}" 'the dry run did not plan a role'
  expect_line "$output" "would create optional client scope ${SCOPES[$i]}" 'the dry run did not plan a scope'
  expect_line "$output" "would add audience mapper ${SCOPES[$i]}-audience (aud ${RESOURCES[$i]}) to scope ${SCOPES[$i]}" 'the dry run did not plan an audience mapper'
  expect_line "$output" "would map role ${RESOURCES[$i]}/${ROLES[$i]} in scope ${SCOPES[$i]}" 'the dry run did not plan a scope mapping'
  expect_line "$output" "would assign role ${RESOURCES[$i]}/${ROLES[$i]} to service-account-core-erasure" 'the dry run did not plan a role assignment'
done
expect_line "$output" 'dry run: 16 change(s) pending; rerun with --apply to execute them' 'the dry run did not count every step'
[[ -z $(client_uuid core-erasure) ]] || fail 'the dry run created core-erasure'
[[ -z $(scope_uuid account-erase-cms) ]] || fail 'the dry run created a scope'
[[ $(admin_events_since "$events_before") == 0 ]] || fail 'the dry run wrote something'

CURRENT_STAGE='core-erasure apply'
output=$(create_erasure_client --apply)
printf '%s\n' "$output" >"$STATE_DIR/create-erasure-apply-1.log"
expect_line "$output" 'client core-erasure: created' 'the script did not create the client'
expect_line "$output" 'applied 16 change(s)' 'the apply did not perform the planned steps'
if grep -Eq 'would |WARNING' <<<"$output"; then
  printf '%s\n' "$output" >&2
  fail 'the apply left a planned step or a warning behind'
fi

client=$(client_uuid core-erasure)
[[ -n $client ]] || fail 'core-erasure was not created'
json=$(kcadm get "clients/$client" -r "$REALM" -c)
jq -e '.publicClient == false and .bearerOnly == false and .serviceAccountsEnabled == true and .standardFlowEnabled == false and .implicitFlowEnabled == false and .directAccessGrantsEnabled == false and .fullScopeAllowed == false and .clientAuthenticatorType == "client-secret" and .enabled == true and .redirectUris == [] and .webOrigins == []' \
  <<<"$json" >/dev/null || fail 'core-erasure is not a confidential service-account-only client without full scope'
# service_account is Keycloak's own: attached to every service-account client and again on every
# client update. basic must stay: it emits sub, which the services' account-access gate reads.
[[ $(kcadm get "clients/$client/default-client-scopes" -r "$REALM" -c | jq -c '[.[].name | select(. != "service_account")] | sort') == '["basic","roles"]' ]] \
  || fail 'core-erasure default scopes are not exactly basic and roles (besides service_account)'
[[ $(kcadm get "clients/$client/optional-client-scopes" -r "$REALM" -c | jq -c '[.[].name] | sort') == '["account-erase-cms","account-erase-forms","account-erase-skymail"]' ]] \
  || fail 'core-erasure optional scopes are not exactly the three erase scopes'
jq -e '(.realmMappings // []) == [] and (.clientMappings // {}) == {}' <<<"$(kcadm get "clients/$client/scope-mappings" -r "$REALM" -c)" >/dev/null \
  || fail 'core-erasure has direct scope mappings: every token would carry those roles'
sa=$(kcadm get "clients/$client/service-account-user" -r "$REALM" -c | jq -r .id)
for i in 0 1 2; do
  resource=$(client_uuid "${RESOURCES[$i]}")
  scope=$(scope_uuid "${SCOPES[$i]}")
  [[ -n $scope ]] || fail "scope ${SCOPES[$i]} was not created"
  jq -e '.protocol == "openid-connect" and .attributes["include.in.token.scope"] == "true" and .attributes["display.on.consent.screen"] == "false"' \
    <<<"$(kcadm get "client-scopes/$scope" -r "$REALM" -c)" >/dev/null || fail "scope ${SCOPES[$i]} attributes differ"
  jq -e --arg name "${SCOPES[$i]}-audience" --arg aud "${RESOURCES[$i]}" \
    'length == 1 and .[0].name == $name and .[0].protocolMapper == "oidc-audience-mapper" and .[0].config["included.client.audience"] == $aud and (.[0].config["included.custom.audience"] // "") == "" and .[0].config["access.token.claim"] == "true" and .[0].config["introspection.token.claim"] == "true" and .[0].config["id.token.claim"] == "false"' \
    <<<"$(kcadm get "client-scopes/$scope/protocol-mappers/models" -r "$REALM" -c)" >/dev/null \
    || fail "scope ${SCOPES[$i]} does not hold exactly its audience mapper"
  jq -e --arg rc "${RESOURCES[$i]}" --arg role "${ROLES[$i]}" \
    '(.realmMappings // []) == [] and (.clientMappings | keys) == [$rc] and ([.clientMappings[$rc].mappings[].name] == [$role])' \
    <<<"$(kcadm get "client-scopes/$scope/scope-mappings" -r "$REALM" -c)" >/dev/null \
    || fail "scope ${SCOPES[$i]} does not map exactly ${RESOURCES[$i]}/${ROLES[$i]}"
  [[ $(kcadm get "users/$sa/role-mappings/clients/$resource" -r "$REALM" -c | jq -c '[.[].name]') == "[\"${ROLES[$i]}\"]" ]] \
    || fail "the service account does not hold exactly ${RESOURCES[$i]}/${ROLES[$i]}"
  [[ $(kcadm get "clients/$resource/roles/${ROLES[$i]}/users" -r "$REALM" -c | jq -c '[.[].username]') == '["service-account-core-erasure"]' ]] \
    || fail "${ROLES[$i]} is held by someone other than the service account"
done
[[ $(kcadm get "clients/$skymail_uuid/roles/skymail:access/users" -r "$REALM" -c | jq '[.[] | select(.username == "service-account-core-erasure")] | length') == 0 ]] \
  || fail 'core-erasure holds a SkyMail role other than the erase role'

CURRENT_STAGE='core-erasure is idempotent'
events_before=$(newest_admin_event)
snapshot_before=$(state_snapshot)
output=$(create_erasure_client)
expect_line "$output" 'dry run: 0 change(s) pending' 'a dry run after apply planned a change'
output=$(create_erasure_client --apply)
printf '%s\n' "$output" >"$STATE_DIR/create-erasure-noop.log"
expect_line "$output" 'applied 0 change(s)' 'a second apply changed something'
[[ $(admin_events_since "$events_before") == 0 ]] || fail 'a no-op run produced admin events'
[[ $(state_snapshot) == "$snapshot_before" ]] || fail 'a no-op run changed the client'

CURRENT_STAGE='core-erasure token contract'
secret=$(kcadm get "clients/$client/client-secret" -r "$REALM" -c | jq -r .value)
[[ -n $secret && $secret != null ]] || fail 'Keycloak did not generate a secret for core-erasure'
for i in 0 1 2; do
  payload=$(access_payload core-erasure "$secret" "openid ${SCOPES[$i]}")
  jq -e --arg rc "${RESOURCES[$i]}" --arg role "${ROLES[$i]}" --argjson all "$ALL_ERASE_ROLES" '
    .azp == "core-erasure"
    and ((.aud | if type == "array" then . else [.] end) == [$rc])
    and .resource_access == {($rc): {roles: [$role]}}
    and (.realm_access == null)
    and ([.. | strings | select(. as $s | $all | index($s))] == [$role])' <<<"$payload" >/dev/null \
    || fail "the ${SCOPES[$i]} token is not limited to ${RESOURCES[$i]}/${ROLES[$i]}: $(jq -c '{azp, aud, resource_access, realm_access, scope}' <<<"$payload")"
  jq -e '.sub | test("^[0-9a-f-]{36}$")' <<<"$payload" >/dev/null || fail "the ${SCOPES[$i]} token carries no sub"
done
for scope in openid ''; do
  payload=$(access_payload core-erasure "$secret" "$scope")
  jq -e --argjson all "$ALL_ERASE_ROLES" '.azp == "core-erasure" and ([.. | strings | select(. as $s | $all | index($s))] == []) and (.aud == null)' \
    <<<"$payload" >/dev/null \
    || fail "a core-erasure token without an erase scope ('$scope') carries an erase role or audience: $(jq -c '{aud, resource_access, scope}' <<<"$payload")"
done
response=$(token_response core-erasure "$secret" 'openid profile email')
[[ ${response##*$'\n'} == 400 ]] || fail 'core-erasure may request scopes outside its contract'

CURRENT_STAGE="core's own tokens are unchanged"
[[ $(core_claims openid) == "$core_send_before" ]] || fail "core's SkyMail send token changed: $(core_claims openid)"
[[ $(core_claims '') == "$core_default_before" ]] || fail "core's default token changed"
jq -e --argjson all "$ALL_ERASE_ROLES" '[.. | strings | select(. as $s | $all | index($s))] == []' <<<"$core_send_before" >/dev/null \
  || fail "core's SkyMail send token carries an erase role"
response=$(token_response core "$core_secret" 'openid account-erase-cms')
[[ ${response##*$'\n'} == 400 && $(jq -r .error <<<"${response%$'\n'*}") == invalid_scope ]] \
  || fail "core may request an erase scope (HTTP ${response##*$'\n'})"
core_token=$(curl --fail --silent --show-error --user "core:$core_secret" -d grant_type=client_credentials \
  "$BASE_URL/realms/$REALM/protocol/openid-connect/token" | jq -r .access_token)
status=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  -H "Authorization: Bearer $core_token" "$BASE_URL/admin/realms/$REALM/clients?clientId=core")
[[ $status == 200 ]] || fail "Admin REST no longer accepts core's token (HTTP $status)"

CURRENT_STAGE='reconciler verifies core-erasure'
reconcile "$STATE_DIR/reconcile-erasure.log" || { cat "$STATE_DIR/reconcile-erasure.log" >&2; fail 'the reconciler failed on the provisioned core-erasure client'; }
output=$(cat "$STATE_DIR/reconcile-erasure.log")
expect_line "$output" '[reconcile] client core-erasure: verified (confidential service account' 'the reconciler did not verify core-erasure'
for i in 0 1 2; do
  expect_line "$output" "[reconcile] erase scope ${SCOPES[$i]}: verified (aud ${RESOURCES[$i]}, role ${RESOURCES[$i]}/${ROLES[$i]})" \
    'the reconciler did not verify an erase scope'
done
expect_line "$output" '[reconcile] WARNING: service-account roles of core-erasure are not readable with the reconciler identity' \
  'the reconciler identity unexpectedly reads user role mappings'

CURRENT_STAGE='reconciler fails on core-erasure drift; the script repairs it'
cms_resource=$(client_uuid skycms)
cms_scope=$(scope_uuid account-erase-cms)
kcadm update "clients/$client" -r "$REALM" -s fullScopeAllowed=true >/dev/null
if reconcile "$STATE_DIR/reconcile-erasure-drift-1.log"; then
  fail 'the reconciler accepted core-erasure with full scope'
fi
output=$(cat "$STATE_DIR/reconcile-erasure-drift-1.log")
expect_line "$output" 'Client core-erasure drifted' 'the reconciler did not name the drifted client'
expect_line "$output" 'create-erasure-client.sh keycloak-config --admin-user <admin> --apply' 'the reconciler did not name the operator command'
# Three more drifts, each of which would leak an erase role into other tokens.
kcadm update "clients/$client" -r "$REALM" -s fullScopeAllowed=false >/dev/null
kcadm delete "clients/$client/optional-client-scopes/$cms_scope" -r "$REALM" >/dev/null
kcadm update "clients/$client/default-client-scopes/$cms_scope" -r "$REALM" -n -b '{}' >/dev/null
kcadm create "clients/$client/scope-mappings/clients/$skymail_uuid" -r "$REALM" \
  -b "$(role_body "$skymail_uuid" skymail:account:erase)" >/dev/null
kcadm create "client-scopes/$cms_scope/scope-mappings/clients/$(client_uuid forms)" -r "$REALM" \
  -b "$(role_body "$(client_uuid forms)" skyforms:account:erase)" >/dev/null
if reconcile "$STATE_DIR/reconcile-erasure-drift-2.log"; then
  fail 'the reconciler accepted an erase scope attached as default, a direct scope mapping and a foreign role in a scope'
fi
output=$(cat "$STATE_DIR/reconcile-erasure-drift-2.log")
expect_line "$output" 'Client core-erasure drifted' 'the reconciler did not name the drifted client'
kcadm update "clients/$client" -r "$REALM" -s fullScopeAllowed=true >/dev/null
output=$(create_erasure_client --apply)
printf '%s\n' "$output" >"$STATE_DIR/create-erasure-repair.log"
for expected in \
  'update client core-erasure flags' \
  'detach default scope account-erase-cms from core-erasure' \
  'attach optional scope account-erase-cms to core-erasure' \
  'remove direct scope mapping skymail/skymail:account:erase from core-erasure' \
  'remove role forms/skyforms:account:erase from scope account-erase-cms' \
  'applied 5 change(s)'; do
  expect_line "$output" "$expected" 'the script did not repair the drift'
done
reconcile "$STATE_DIR/reconcile-erasure-repaired.log" \
  || { cat "$STATE_DIR/reconcile-erasure-repaired.log" >&2; fail 'the reconciler still fails after the repair'; }
[[ $(state_snapshot) == "$snapshot_before" ]] || fail 'the repair did not restore exactly the contract'
payload=$(access_payload core-erasure "$secret" 'openid account-erase-cms')
jq -e '.resource_access == {"skycms": {"roles": ["cms:account:erase"]}}' <<<"$payload" >/dev/null \
  || fail "the repaired cms token is not limited to cms:account:erase: $(jq -c .resource_access <<<"$payload")"
[[ -n $cms_resource ]] || fail 'skycms disappeared'

CURRENT_STAGE='core-erasure secret stays out of every output'
for log_file in "$STATE_DIR"/create-erasure-*.log "$STATE_DIR"/reconcile-erasure*.log; do
  [[ $(cat "$log_file") != *"$secret"* ]] || fail "the core-erasure secret leaked into $(basename "$log_file")"
done
secret=''
printf 'core-erasure client contract passed.\n'
