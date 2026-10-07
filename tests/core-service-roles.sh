# shellcheck shell=bash
# Sourced by run-integration.sh; uses its kcadm, fail, json_assert, v2_jwt_payload, V2_REALM,
# TEST_STATE_DIR, SCRIPT_DIR, COMPOSE and ADMIN_CONFIG, lca_client_uuid / LCA_USER from
# login-client-audiences.sh and cr_group_id from core-roles.sh.
#
# core's service roles (runbook §20): media:attach (media redesign ticket 03, ADR-0052),
# ticket:forms (core's form response Tickets, docs/form-response-tickets.md), url:forms and users:read. The reconciler
# creates them on core; the forms service account holds them. The reconciler identity has no user
# permissions, so it reports and an operator grants with the step alone
# (KEYCLOAK_RECONCILE_ONLY=service-roles; media-attach is the old name of the step), first as a dry
# run (KEYCLOAK_RECONCILE_CHECK=true). Proven with a real client-credentials token of forms: azp and
# client_id forms, aud core, resource_access.core.roles holding all four. The fixture realm gets
# forms (confidential, service account, full scope, the realm's default scopes) from
# core-erasure-client.sh.

CSR_ROLES=(media:attach ticket:forms url:forms users:read)
CSR_NEW_ROLE=ticket:forms
# Held by hand before the operator step (as production's forms service account held it).
CSR_HAND_ROLE=users:read
CSR_SORTED='["media:attach","ticket:forms","url:forms","users:read"]'
CSR_ATTRIBUTE=skylab.granted-service-accounts
CSR_CLIENT=forms
CSR_ACCOUNT=service-account-forms
declare -A CSR_DESCRIPTION=(
  [media:attach]="Service attach API (media redesign ticket 03, ADR-0052): a product's service account links Media to its own records. Service accounts only; never a person or a group."
  [ticket:forms]="Forms reports its answers (POST /v1/forms/{formId}/responses, core docs/form-response-tickets.md); core writes the Tickets an accepted answer to an Event's form earns. Service accounts only; never a person or a group."
  [url:forms]="Forms service account: form-bound short links (/v1/urls/forms/{formId}) and GET /v1/urls/availability only. Grants nothing on the generic /v1/urls endpoints."
  [users:read]="Reads a person's profile (GET /v1/users/{id}); held by the Forms service account."
)
CSR_PAYLOAD=''

# The step alone with the harness administrator's kcadm session (the operator path). Arguments are
# extra `exec` options (environment).
csr_operator() {
  "${COMPOSE[@]}" exec -T \
    -e "KEYCLOAK_REALM=$V2_REALM" \
    -e "KEYCLOAK_RECONCILE_KCADM_CONFIG=$ADMIN_CONFIG" \
    -e KEYCLOAK_RECONCILE_ONLY=service-roles \
    "$@" \
    keycloak /opt/keycloak/config/reconcile-account-center.sh 2>&1
}

# The step alone as the reconciler identity (account-center-config: manage-clients, no user
# permissions), the way the full reconciliation runs it. $1: the step name (default service-roles).
csr_reconciler() {
  "${COMPOSE[@]}" run --rm --no-deps -e "KEYCLOAK_RECONCILE_ONLY=${1:-service-roles}" "${@:2}" keycloak-config 2>&1
}

csr_newest_event() {
  kcadm get admin-events -r "$V2_REALM" -q max=1 -c | jq -r '.[0].time // 0'
}

csr_events_since() {
  kcadm get admin-events -r "$V2_REALM" -q max=200 -c | jq --argjson since "$1" '[.[] | select(.time > $since)] | length'
}

csr_role_body() {
  kcadm get "clients/$(lca_client_uuid core)/roles/$1" -r "$V2_REALM" -c | jq -c '[{id, name}]'
}

# The core roles service-account-forms holds directly, sorted JSON array.
csr_account_roles() {
  local account_id
  account_id=$(kcadm get "clients/$(lca_client_uuid "$CSR_CLIENT")/service-account-user" -r "$V2_REALM" -c | jq -r .id)
  kcadm get "users/$account_id/role-mappings/clients/$(lca_client_uuid core)" -r "$V2_REALM" -c | jq -c '[.[].name] | sort'
}

csr_account_id() {
  kcadm get "clients/$(lca_client_uuid "$CSR_CLIENT")/service-account-user" -r "$V2_REALM" -c | jq -r .id
}

# The grant records of the four roles, one "role=record" per line.
csr_markers() {
  local role
  for role in "${CSR_ROLES[@]}"; do
    printf '%s=%s\n' "$role" "$(kcadm get "clients/$(lca_client_uuid core)/roles/$role" -r "$V2_REALM" -c \
      | jq -r --arg a "$CSR_ATTRIBUTE" '(.attributes // {})[$a][0] // ""')"
  done
}

# A real client-credentials grant of CLIENT (default forms); leaves the decoded access token in
# CSR_PAYLOAD.
csr_service_token() {
  local client=${1:-$CSR_CLIENT} secret token
  secret=$(kcadm get "clients/$(lca_client_uuid "$client")/client-secret" -r "$V2_REALM" -c | jq -r '.value // empty')
  [[ -n $secret ]] || fail "client $client has no secret"
  token=$(curl --fail --silent --show-error --user "$client:$secret" \
    --data-urlencode grant_type=client_credentials \
    "http://localhost:18080/realms/$V2_REALM/protocol/openid-connect/token" | jq -r '.access_token // empty')
  [[ -n $token ]] || fail "client $client got no client-credentials access token"
  CSR_PAYLOAD=$(v2_jwt_payload "$token")
}

# The core roles of the token in CSR_PAYLOAD that are service roles, sorted JSON array.
csr_token_service_roles() {
  jq -c --argjson want "$CSR_SORTED" '[(.resource_access.core.roles // [])[] | select(. as $r | $want | index($r) != null)] | sort' <<<"$CSR_PAYLOAD"
}

csr_token_has_core_audience() {
  jq -e '(.aud // []) | (if type == "array" then . else [.] end) | index("core") != null' <<<"$CSR_PAYLOAD" >/dev/null
}

# expect_lines OUTPUT WHO LINE...: every LINE is in OUTPUT.
csr_expect_lines() {
  local output=$1 who=$2 expected
  shift 2
  for expected in "$@"; do
    grep -Fq -- "$expected" <<<"$output" || { printf '%s\n' "$output" >&2; fail "$who did not print: $expected"; }
  done
}

# The operator step with one kcadm read failing for another reason than "not found" (KCADM_BIN
# injection): it must stop and write nothing. $1: the failing read, $2: the expected message.
csr_injected_failure_refuses() {
  local log="$TEST_STATE_DIR/service-roles-injected-failure.log" before
  before=$(csr_newest_event)
  if csr_operator -e KCADM_BIN=/tmp/kcadm-core-roles-failure.sh -e "KCADM_INJECT_FAIL=$1" >"$log"; then
    cat "$log" >&2
    fail "the service-roles step succeeded although reading $1 failed"
  fi
  grep -Fq "$2" "$log" || { cat "$log" >&2; fail "the service-roles step did not say why it stopped when reading $1 failed"; }
  [[ $(csr_events_since "$before") == 0 ]] || fail "the service-roles step wrote something after reading $1 failed"
  [[ $(csr_account_roles) == '[]' ]] || fail "the service-roles step granted a role after reading $1 failed"
}

# First reconciliation (the reconciler identity): the four roles exist with their descriptions,
# forms does not exist yet, nobody holds them.
stage_core_service_roles_after_first_reconciliation() {
  CURRENT_STAGE='core service roles: created by the first reconciliation, held by nobody'
  local log="$TEST_STATE_DIR/reconcile-first.log" core_uuid role
  core_uuid=$(lca_client_uuid core)
  for role in "${CSR_ROLES[@]}"; do
    grep -Fq "[reconcile] client role $role of core: created" "$log" \
      || fail "the first reconciliation did not create $role"
    json_assert "$(kcadm get "clients/$core_uuid/roles/$role" -r "$V2_REALM" -c)" '.description == $d and .composite == false' \
      "$role was created without its description or as a composite" --arg d "${CSR_DESCRIPTION[$role]}"
    json_assert "$(kcadm get "clients/$core_uuid/roles/$role/users" -r "$V2_REALM" -c)" 'length == 0' \
      "a user holds $role after the first reconciliation"
    json_assert "$(kcadm get "clients/$core_uuid/roles/$role/groups" -r "$V2_REALM" -c)" 'length == 0' \
      "a group holds $role after the first reconciliation"
  done
  grep -Fq "[reconcile] WARNING: client $CSR_CLIENT does not exist in realm $V2_REALM; its core service roles are not granted to its service account" "$log" \
    || fail 'the first reconciliation did not report the missing forms client'
}

# After core-erasure-client.sh made forms and core-roles seeded the groups, before the no-op
# reconciliation (which then proves the steady state writes nothing).
stage_core_service_roles_granted_by_operator() {
  CURRENT_STAGE='core service roles: the reconciler identity reports, it does not grant'
  local output core_uuid forms_uuid account_id user_id admin_id new_body hand_body extra_body before markers role
  local reconciler_lines=() operator_lines=()
  core_uuid=$(lca_client_uuid core)
  forms_uuid=$(lca_client_uuid "$CSR_CLIENT")
  [[ -n $forms_uuid ]] || fail 'core-erasure-client.sh did not leave the forms client'
  json_assert "$(kcadm get "clients/$forms_uuid" -r "$V2_REALM" -c)" '.serviceAccountsEnabled == true and .fullScopeAllowed == true' \
    'the forms fixture is not a full-scope service-account client (production shape)'
  # core reads the product from client_id == azp: forms signs in no person (no browser login, no
  # password grant), so a forms token is always its service account's.
  json_assert "$(kcadm get "clients/$forms_uuid" -r "$V2_REALM" -c)" '.standardFlowEnabled == false and .directAccessGrantsEnabled == false' \
    'the forms fixture allows a person to sign in (standard flow or direct access grants)'
  csr_service_token
  [[ $(csr_token_service_roles) == '[]' ]] || fail 'the forms service token carries a core service role before any grant'

  # The step's old name still runs it.
  output=$(csr_reconciler media-attach) || { printf '%s\n' "$output" >&2; fail 'the reconciler identity failed on the service-roles step'; }
  reconciler_lines=('Core service roles are reconciled.'
    "[reconcile] default client scope roles of $CSR_CLIENT: verified"
    "[reconcile] role scope of $CSR_CLIENT: unchanged (full scope"
    'KEYCLOAK_RECONCILE_ONLY=service-roles')
  for role in "${CSR_ROLES[@]}"; do
    reconciler_lines+=("[reconcile] client role $role of core: unchanged"
      "[reconcile] WARNING: $role is not yet granted to service account $CSR_ACCOUNT by the operator step")
  done
  csr_expect_lines "$output" 'the reconciler identity' "${reconciler_lines[@]}"
  [[ $(csr_account_roles) == '[]' ]] || fail 'the reconciler identity granted a core service role'
  ! csr_markers | grep -q '=.' || fail 'the reconciler identity recorded a grant'
  # The dry run is the operator's only.
  if output=$(csr_reconciler service-roles -e KEYCLOAK_RECONCILE_CHECK=true); then
    printf '%s\n' "$output" >&2
    fail 'the reconciler identity accepted KEYCLOAK_RECONCILE_CHECK=true'
  fi
  grep -Fq 'KEYCLOAK_RECONCILE_CHECK=true is a dry run of the operator step' <<<"$output" \
    || { printf '%s\n' "$output" >&2; fail 'the refused dry run did not say why'; }

  CURRENT_STAGE='core service roles: the operator step fails closed'
  "${COMPOSE[@]}" exec -T keycloak bash -c \
    'cat >/tmp/kcadm-core-roles-failure.sh && chmod 755 /tmp/kcadm-core-roles-failure.sh' \
    <"$SCRIPT_DIR/kcadm-core-roles-failure.sh"
  csr_injected_failure_refuses "clients/$forms_uuid/default-client-scopes" \
    "The default client scopes of $CSR_CLIENT could not be read in realm $V2_REALM; nothing was granted"
  csr_injected_failure_refuses /role-mappings/clients/ \
    "The core roles of $CSR_ACCOUNT could not be read in realm $V2_REALM; nothing was granted"
  csr_injected_failure_refuses "roles/$CSR_NEW_ROLE/users" \
    "The users holding $CSR_NEW_ROLE could not be read in realm $V2_REALM; nothing was granted"
  csr_injected_failure_refuses composites/clients/ \
    "The default role default-roles-$V2_REALM could not be read in realm $V2_REALM; nothing was granted"

  CURRENT_STAGE='core service roles: the dry run plans only what is missing and writes nothing'
  # Production's shape before the step: users:read granted to forms by hand. A person and a group
  # got the new role by hand, the person also users:read (people may hold it), and forms holds a
  # core role the step does not manage.
  account_id=$(csr_account_id)
  user_id=$(kcadm get users -r "$V2_REALM" -q "username=$LCA_USER" -q exact=true -c | jq -r '.[0].id')
  admin_id=$(cr_group_id /ADMIN)
  new_body=$(csr_role_body "$CSR_NEW_ROLE")
  hand_body=$(csr_role_body "$CSR_HAND_ROLE")
  extra_body=$(csr_role_body url:create)
  kcadm create "users/$account_id/role-mappings/clients/$core_uuid" -r "$V2_REALM" -b "$hand_body" >/dev/null
  kcadm create "users/$account_id/role-mappings/clients/$core_uuid" -r "$V2_REALM" -b "$extra_body" >/dev/null
  kcadm create "users/$user_id/role-mappings/clients/$core_uuid" -r "$V2_REALM" -b "$new_body" >/dev/null
  kcadm create "users/$user_id/role-mappings/clients/$core_uuid" -r "$V2_REALM" -b "$hand_body" >/dev/null
  kcadm create "groups/$admin_id/role-mappings/clients/$core_uuid" -r "$V2_REALM" -b "$new_body" >/dev/null
  before=$(csr_newest_event)
  output=$(csr_operator -e KEYCLOAK_RECONCILE_CHECK=true) || { printf '%s\n' "$output" >&2; fail 'the dry run failed'; }
  operator_lines=('Core service roles are checked; nothing was written.'
    '[reconcile] check: 7 change(s) pending; nothing was written'
    "[reconcile] service account $CSR_ACCOUNT: $CSR_HAND_ROLE unchanged (held)"
    "[reconcile] WARNING: $CSR_NEW_ROLE is also held by the users $LCA_USER (nothing was removed"
    "[reconcile] WARNING: $CSR_NEW_ROLE is held by the groups /ADMIN (nothing was removed"
    "[reconcile] NOTE: service account $CSR_ACCOUNT also holds the core roles url:create, which this step does not manage (nothing was removed)")
  for role in "${CSR_ROLES[@]}"; do
    operator_lines+=("[reconcile] would record the grant of $role ($CSR_ATTRIBUTE=<now> $CSR_ACCOUNT)")
    [[ $role == "$CSR_HAND_ROLE" ]] || operator_lines+=("[reconcile] would grant $role to service account $CSR_ACCOUNT")
  done
  csr_expect_lines "$output" 'the dry run' "${operator_lines[@]}"
  ! grep -Fq "would grant $CSR_HAND_ROLE" <<<"$output" || { printf '%s\n' "$output" >&2; fail 'the dry run planned a grant forms already holds'; }
  ! grep -Fq "$CSR_HAND_ROLE is also held" <<<"$output" || { printf '%s\n' "$output" >&2; fail 'the dry run reported a person holding users:read (people may)'; }
  ! grep -Eq '\] (service account .* granted|client role .* grant recorded)' <<<"$output" \
    || { printf '%s\n' "$output" >&2; fail 'the dry run said it wrote something'; }
  [[ $(csr_events_since "$before") == 0 ]] || fail 'the dry run wrote something'
  [[ $(csr_account_roles) == "[\"url:create\",\"$CSR_HAND_ROLE\"]" ]] || fail "the dry run changed the roles of $CSR_ACCOUNT: $(csr_account_roles)"

  CURRENT_STAGE='core service roles: granted by the operator step, other holders reported and kept'
  output=$(csr_operator) || { printf '%s\n' "$output" >&2; fail 'the service-roles operator step failed'; }
  operator_lines=('Core service roles are reconciled.'
    '[reconcile] applied 7 change(s)'
    "[reconcile] service account $CSR_ACCOUNT: $CSR_HAND_ROLE unchanged (held)"
    "[reconcile] WARNING: $CSR_NEW_ROLE is also held by the users $LCA_USER (nothing was removed"
    "[reconcile] WARNING: $CSR_NEW_ROLE is held by the groups /ADMIN (nothing was removed"
    "[reconcile] NOTE: service account $CSR_ACCOUNT also holds the core roles url:create")
  for role in "${CSR_ROLES[@]}"; do
    operator_lines+=("[reconcile] client role $role of core: grant recorded ($CSR_ATTRIBUTE=")
    [[ $role == "$CSR_HAND_ROLE" ]] || operator_lines+=("[reconcile] service account $CSR_ACCOUNT: $role granted")
  done
  csr_expect_lines "$output" 'the operator step' "${operator_lines[@]}"
  [[ $(csr_account_roles) == '["media:attach","ticket:forms","url:create","url:forms","users:read"]' ]] \
    || fail "$CSR_ACCOUNT does not hold exactly the four core service roles and the hand-made url:create: $(csr_account_roles)"
  markers=$(csr_markers)
  for role in "${CSR_ROLES[@]}"; do
    grep -Eq "^$role=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z $CSR_ACCOUNT\$" <<<"$markers" \
      || fail "the grant record of $role is not '<UTC time> $CSR_ACCOUNT': $markers"
  done
  json_assert "$(kcadm get "users/$user_id/role-mappings/clients/$core_uuid" -r "$V2_REALM" -c)" \
    '[.[].name] | index($r) != null' "the operator step removed $CSR_NEW_ROLE from a person" --arg r "$CSR_NEW_ROLE"
  json_assert "$(kcadm get "groups/$admin_id/role-mappings/clients/$core_uuid" -r "$V2_REALM" -c)" \
    '[.[].name] | index($r) != null' "the operator step removed $CSR_NEW_ROLE from a group" --arg r "$CSR_NEW_ROLE"
  kcadm delete "users/$user_id/role-mappings/clients/$core_uuid" -r "$V2_REALM" -b "$new_body" >/dev/null
  kcadm delete "users/$user_id/role-mappings/clients/$core_uuid" -r "$V2_REALM" -b "$hand_body" >/dev/null
  kcadm delete "groups/$admin_id/role-mappings/clients/$core_uuid" -r "$V2_REALM" -b "$new_body" >/dev/null
  kcadm delete "users/$account_id/role-mappings/clients/$core_uuid" -r "$V2_REALM" -b "$extra_body" >/dev/null
  [[ $(csr_account_roles) == "$CSR_SORTED" ]] || fail "$CSR_ACCOUNT does not hold exactly the four core service roles"

  CURRENT_STAGE='core service roles: in the forms client-credentials token, and nowhere else'
  csr_service_token
  json_assert "$CSR_PAYLOAD" '.azp == "forms" and .client_id == "forms"' \
    'the forms service token does not name forms in azp and client_id'
  csr_token_has_core_audience || fail 'the forms service token does not carry aud core'
  [[ $(csr_token_service_roles) == "$CSR_SORTED" ]] \
    || fail "the forms service token lacks a core service role: $(csr_token_service_roles)"
  # No other service account gets the new role: the only user holding it is forms' service
  # account, no group holds it, and core-erasure's real token lacks it.
  json_assert "$(kcadm get "clients/$core_uuid/roles/$CSR_NEW_ROLE/users" -r "$V2_REALM" -c)" \
    '[.[].username] == [$a]' "a user other than $CSR_ACCOUNT holds $CSR_NEW_ROLE" --arg a "$CSR_ACCOUNT"
  json_assert "$(kcadm get "clients/$core_uuid/roles/$CSR_NEW_ROLE/groups" -r "$V2_REALM" -c)" 'length == 0' \
    "a group holds $CSR_NEW_ROLE"
  csr_service_token core-erasure
  [[ $(csr_token_service_roles) == '[]' ]] || fail "the core-erasure service token carries a core service role: $(csr_token_service_roles)"

  CURRENT_STAGE='core service roles: a second operator step writes nothing'
  before=$(csr_newest_event)
  output=$(csr_operator) || { printf '%s\n' "$output" >&2; fail 'the second service-roles operator step failed'; }
  operator_lines=('[reconcile] applied 0 change(s)')
  for role in "${CSR_ROLES[@]}"; do
    operator_lines+=("[reconcile] service account $CSR_ACCOUNT: $role unchanged (held)")
  done
  csr_expect_lines "$output" 'the second operator step' "${operator_lines[@]}"
  ! grep -Eq 'granted$|grant recorded|WARNING|NOTE' <<<"$output" || { printf '%s\n' "$output" >&2; fail 'the second operator step changed or reported something'; }
  [[ $(csr_events_since "$before") == 0 ]] || fail 'the second operator step wrote something'
  [[ $(csr_markers) == "$markers" ]] || fail 'the second operator step rewrote a grant record'
  output=$(csr_operator -e KEYCLOAK_RECONCILE_CHECK=true) || { printf '%s\n' "$output" >&2; fail 'the dry run after the grant failed'; }
  csr_expect_lines "$output" 'the dry run after the grant' '[reconcile] check: 0 change(s) pending; nothing was written'
  ! grep -Fq '] would ' <<<"$output" || { printf '%s\n' "$output" >&2; fail 'the dry run after the grant planned a change'; }

  CURRENT_STAGE='core service roles: without full scope the roles are mapped into the forms token'
  kcadm update "clients/$forms_uuid" -r "$V2_REALM" -s fullScopeAllowed=false >/dev/null
  csr_service_token
  [[ $(csr_token_service_roles) == '[]' ]] || fail 'positive control: without full scope and a mapping a role still reached the token'
  output=$(csr_reconciler) || { printf '%s\n' "$output" >&2; fail 'the reconciler identity failed on a forms client without full scope'; }
  reconciler_lines=()
  for role in "${CSR_ROLES[@]}"; do
    reconciler_lines+=("[reconcile] role scope of $CSR_CLIENT: updated (+core/$role; fullScopeAllowed is false)"
      "[reconcile] service account $CSR_ACCOUNT: $role unchanged (granted by the operator step at ")
  done
  csr_expect_lines "$output" 'the reconciler identity' "${reconciler_lines[@]}"
  ! grep -Fq WARNING <<<"$output" || { printf '%s\n' "$output" >&2; fail 'the reconciler identity warned after the grant'; }
  csr_service_token
  [[ $(csr_token_service_roles) == "$CSR_SORTED" ]] \
    || fail "the mapped roles did not reach the forms token without full scope: $(csr_token_service_roles)"
  csr_token_has_core_audience || fail 'the forms service token without full scope does not carry aud core'
  # Back to production's shape; the mappings stay (harmless with full scope).
  kcadm update "clients/$forms_uuid" -r "$V2_REALM" -s fullScopeAllowed=true >/dev/null
}

# Part of v2_state_snapshot: the forms client's flags, role scope and service-account roles of core.
csr_state_snapshot() {
  local forms_uuid
  forms_uuid=$(lca_client_uuid "$CSR_CLIENT")
  kcadm get "clients/$forms_uuid" -r "$V2_REALM" -c | jq -c '{fullScopeAllowed, serviceAccountsEnabled}'
  kcadm get "clients/$forms_uuid/scope-mappings/clients/$(lca_client_uuid core)" -r "$V2_REALM" -c | jq -c '[.[].name] | sort'
  csr_account_roles
  csr_markers | jq -R -c .
}
