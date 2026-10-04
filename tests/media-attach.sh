# shellcheck shell=bash
# Sourced by run-integration.sh; uses its kcadm, fail, json_assert, v2_jwt_payload, V2_REALM,
# TEST_STATE_DIR, SCRIPT_DIR, COMPOSE and ADMIN_CONFIG, lca_client_uuid / LCA_USER from
# login-client-audiences.sh and cr_group_id from core-roles.sh.
#
# core's service attach role media:attach (media redesign ticket 03, ADR-0052; runbook §20). The
# reconciler creates it on core; only the forms service account may hold it. The reconciler
# identity has no user permissions, so it reports and an operator grants with the step alone
# (KEYCLOAK_RECONCILE_ONLY=media-attach). Proven with a real client-credentials token of forms:
# azp and client_id forms, aud core, resource_access.core.roles media:attach. The fixture realm
# gets forms (confidential, service account, full scope, the realm's default scopes) from
# core-erasure-client.sh.

MA_ROLE=media:attach
MA_ATTRIBUTE=skylab.granted-service-accounts
MA_CLIENT=forms
MA_ACCOUNT=service-account-forms
MA_DESCRIPTION="Service attach API (media redesign ticket 03, ADR-0052): a product's service account links Media to its own records. Service accounts only; never a person or a group."
MA_PAYLOAD=''

# The step alone with the harness administrator's kcadm session (the operator path). Arguments are
# extra `exec` options (environment).
ma_operator() {
  "${COMPOSE[@]}" exec -T \
    -e "KEYCLOAK_REALM=$V2_REALM" \
    -e "KEYCLOAK_RECONCILE_KCADM_CONFIG=$ADMIN_CONFIG" \
    -e KEYCLOAK_RECONCILE_ONLY=media-attach \
    "$@" \
    keycloak /opt/keycloak/config/reconcile-account-center.sh 2>&1
}

# The step alone as the reconciler identity (account-center-config: manage-clients, no user
# permissions), the way the full reconciliation runs it.
ma_reconciler() {
  "${COMPOSE[@]}" run --rm --no-deps -e KEYCLOAK_RECONCILE_ONLY=media-attach keycloak-config 2>&1
}

ma_newest_event() {
  kcadm get admin-events -r "$V2_REALM" -q max=1 -c | jq -r '.[0].time // 0'
}

ma_events_since() {
  kcadm get admin-events -r "$V2_REALM" -q max=200 -c | jq --argjson since "$1" '[.[] | select(.time > $since)] | length'
}

ma_role_body() {
  kcadm get "clients/$(lca_client_uuid core)/roles/$MA_ROLE" -r "$V2_REALM" -c | jq -c '[{id, name}]'
}

# The core roles service-account-forms holds directly, sorted JSON array.
ma_account_roles() {
  local account_id
  account_id=$(kcadm get "clients/$(lca_client_uuid "$MA_CLIENT")/service-account-user" -r "$V2_REALM" -c | jq -r .id)
  kcadm get "users/$account_id/role-mappings/clients/$(lca_client_uuid core)" -r "$V2_REALM" -c | jq -c '[.[].name] | sort'
}

ma_marker() {
  kcadm get "clients/$(lca_client_uuid core)/roles/$MA_ROLE" -r "$V2_REALM" -c \
    | jq -r --arg a "$MA_ATTRIBUTE" '(.attributes // {})[$a][0] // ""'
}

# A real client-credentials grant of CLIENT (default forms); leaves the decoded access token in
# MA_PAYLOAD.
ma_service_token() {
  local client=${1:-$MA_CLIENT} secret token
  secret=$(kcadm get "clients/$(lca_client_uuid "$client")/client-secret" -r "$V2_REALM" -c | jq -r '.value // empty')
  [[ -n $secret ]] || fail "client $client has no secret"
  token=$(curl --fail --silent --show-error --user "$client:$secret" \
    --data-urlencode grant_type=client_credentials \
    "http://localhost:18080/realms/$V2_REALM/protocol/openid-connect/token" | jq -r '.access_token // empty')
  [[ -n $token ]] || fail "client $client got no client-credentials access token"
  MA_PAYLOAD=$(v2_jwt_payload "$token")
}

ma_token_carries_role() {
  jq -e --arg r "$MA_ROLE" '((.resource_access.core.roles // []) | index($r)) != null' <<<"$MA_PAYLOAD" >/dev/null
}

# The operator step with one kcadm read failing for another reason than "not found" (KCADM_BIN
# injection): it must stop and write nothing. $1: the failing read, $2: the expected message.
ma_injected_failure_refuses() {
  local log="$TEST_STATE_DIR/media-attach-injected-failure.log" before
  before=$(ma_newest_event)
  if ma_operator -e KCADM_BIN=/tmp/kcadm-core-roles-failure.sh -e "KCADM_INJECT_FAIL=$1" >"$log"; then
    cat "$log" >&2
    fail "the media-attach step succeeded although reading $1 failed"
  fi
  grep -Fq "$2" "$log" || { cat "$log" >&2; fail "the media-attach step did not say why it stopped when reading $1 failed"; }
  [[ $(ma_events_since "$before") == 0 ]] || fail "the media-attach step wrote something after reading $1 failed"
  [[ $(ma_account_roles) == '[]' ]] || fail "the media-attach step granted the role after reading $1 failed"
}

# First reconciliation (the reconciler identity): the role exists with its description, forms does
# not exist yet, nobody holds the role.
stage_media_attach_after_first_reconciliation() {
  CURRENT_STAGE='media:attach: created by the first reconciliation, held by nobody'
  local log="$TEST_STATE_DIR/reconcile-first.log" core_uuid
  grep -Fq "[reconcile] client role $MA_ROLE of core: created" "$log" \
    || fail 'the first reconciliation did not create media:attach'
  grep -Fq "[reconcile] WARNING: client $MA_CLIENT does not exist in realm $V2_REALM; $MA_ROLE is not granted to its service account" "$log" \
    || fail 'the first reconciliation did not report the missing forms client'
  core_uuid=$(lca_client_uuid core)
  json_assert "$(kcadm get "clients/$core_uuid/roles/$MA_ROLE" -r "$V2_REALM" -c)" '.description == $d and .composite == false' \
    'media:attach was created without its description or as a composite' --arg d "$MA_DESCRIPTION"
  json_assert "$(kcadm get "clients/$core_uuid/roles/$MA_ROLE/users" -r "$V2_REALM" -c)" 'length == 0' \
    'a user holds media:attach after the first reconciliation'
  json_assert "$(kcadm get "clients/$core_uuid/roles/$MA_ROLE/groups" -r "$V2_REALM" -c)" 'length == 0' \
    'a group holds media:attach after the first reconciliation'
}

# After core-erasure-client.sh made forms and core-roles seeded the groups, before the no-op
# reconciliation (which then proves the steady state writes nothing).
stage_media_attach_granted_by_operator() {
  CURRENT_STAGE='media:attach: the reconciler identity reports, it does not grant'
  local output core_uuid forms_uuid user_id admin_id role_body before marker
  core_uuid=$(lca_client_uuid core)
  forms_uuid=$(lca_client_uuid "$MA_CLIENT")
  [[ -n $forms_uuid ]] || fail 'core-erasure-client.sh did not leave the forms client'
  json_assert "$(kcadm get "clients/$forms_uuid" -r "$V2_REALM" -c)" '.serviceAccountsEnabled == true and .fullScopeAllowed == true' \
    'the forms fixture is not a full-scope service-account client (production shape)'
  ma_service_token
  ! ma_token_carries_role || fail 'the forms service token carries media:attach before any grant'

  output=$(ma_reconciler) || { printf '%s\n' "$output" >&2; fail 'the reconciler identity failed on the media-attach step'; }
  for expected in 'Media attach role is reconciled.' \
    "[reconcile] client role $MA_ROLE of core: unchanged" \
    "[reconcile] default client scope roles of $MA_CLIENT: verified" \
    "[reconcile] role scope of $MA_CLIENT: unchanged (full scope" \
    "[reconcile] WARNING: $MA_ROLE is not yet granted to service account $MA_ACCOUNT by the operator step" \
    'KEYCLOAK_RECONCILE_ONLY=media-attach'; do
    grep -Fq -- "$expected" <<<"$output" || { printf '%s\n' "$output" >&2; fail "the reconciler identity did not print: $expected"; }
  done
  [[ $(ma_account_roles) == '[]' ]] || fail 'the reconciler identity granted media:attach'
  [[ -z $(ma_marker) ]] || fail 'the reconciler identity recorded a grant'

  CURRENT_STAGE='media:attach: the operator step fails closed'
  "${COMPOSE[@]}" exec -T keycloak bash -c \
    'cat >/tmp/kcadm-core-roles-failure.sh && chmod 755 /tmp/kcadm-core-roles-failure.sh' \
    <"$SCRIPT_DIR/kcadm-core-roles-failure.sh"
  ma_injected_failure_refuses "clients/$forms_uuid/default-client-scopes" \
    "The default client scopes of $MA_CLIENT could not be read in realm $V2_REALM; nothing was granted"
  ma_injected_failure_refuses /role-mappings/clients/ \
    "The core roles of $MA_ACCOUNT could not be read in realm $V2_REALM; nothing was granted"
  ma_injected_failure_refuses "roles/$MA_ROLE/users" \
    "The users holding $MA_ROLE could not be read in realm $V2_REALM; nothing was granted"
  ma_injected_failure_refuses composites/clients/ \
    "The default role default-roles-$V2_REALM could not be read in realm $V2_REALM; nothing was granted"

  CURRENT_STAGE='media:attach: granted by the operator step, other holders reported and kept'
  # A person and a group got the role by hand: reported, never removed.
  role_body=$(ma_role_body)
  user_id=$(kcadm get users -r "$V2_REALM" -q "username=$LCA_USER" -q exact=true -c | jq -r '.[0].id')
  admin_id=$(cr_group_id /ADMIN)
  kcadm create "users/$user_id/role-mappings/clients/$core_uuid" -r "$V2_REALM" -b "$role_body" >/dev/null
  kcadm create "groups/$admin_id/role-mappings/clients/$core_uuid" -r "$V2_REALM" -b "$role_body" >/dev/null
  output=$(ma_operator) || { printf '%s\n' "$output" >&2; fail 'the media-attach operator step failed'; }
  for expected in 'Media attach role is reconciled.' \
    "[reconcile] service account $MA_ACCOUNT: $MA_ROLE granted" \
    "[reconcile] client role $MA_ROLE of core: grant recorded ($MA_ATTRIBUTE=" \
    "[reconcile] WARNING: $MA_ROLE is also held by the users $LCA_USER (nothing was removed" \
    "[reconcile] WARNING: $MA_ROLE is held by the groups /ADMIN (nothing was removed"; do
    grep -Fq -- "$expected" <<<"$output" || { printf '%s\n' "$output" >&2; fail "the operator step did not print: $expected"; }
  done
  [[ $(ma_account_roles) == "[\"$MA_ROLE\"]" ]] || fail "$MA_ACCOUNT does not hold exactly media:attach of core"
  marker=$(ma_marker)
  [[ $marker =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\ $MA_ACCOUNT$ ]] \
    || fail "the grant record of media:attach is not '<UTC time> $MA_ACCOUNT': $marker"
  json_assert "$(kcadm get "users/$user_id/role-mappings/clients/$core_uuid" -r "$V2_REALM" -c)" \
    '[.[].name] | index($r) != null' 'the operator step removed media:attach from a person' --arg r "$MA_ROLE"
  json_assert "$(kcadm get "groups/$admin_id/role-mappings/clients/$core_uuid" -r "$V2_REALM" -c)" \
    '[.[].name] | index($r) != null' 'the operator step removed media:attach from a group' --arg r "$MA_ROLE"
  kcadm delete "users/$user_id/role-mappings/clients/$core_uuid" -r "$V2_REALM" -b "$role_body" >/dev/null
  kcadm delete "groups/$admin_id/role-mappings/clients/$core_uuid" -r "$V2_REALM" -b "$role_body" >/dev/null

  CURRENT_STAGE='media:attach: in the forms client-credentials token'
  ma_service_token
  json_assert "$MA_PAYLOAD" '.azp == "forms" and .client_id == "forms"' \
    'the forms service token does not name forms in azp and client_id'
  json_assert "$MA_PAYLOAD" '(.aud // []) | (if type == "array" then . else [.] end) | index("core") != null' \
    'the forms service token does not carry aud core'
  ma_token_carries_role || fail 'the forms service token lacks resource_access.core.roles media:attach'
  # Another service account does not get it.
  ma_service_token core-erasure
  ! ma_token_carries_role || fail 'the core-erasure service token carries media:attach'

  CURRENT_STAGE='media:attach: a second operator step writes nothing'
  before=$(ma_newest_event)
  output=$(ma_operator) || { printf '%s\n' "$output" >&2; fail 'the second media-attach operator step failed'; }
  grep -Fq "[reconcile] service account $MA_ACCOUNT: $MA_ROLE unchanged (held)" <<<"$output" \
    || { printf '%s\n' "$output" >&2; fail 'the second operator step did not find the grant'; }
  ! grep -Eq 'grant recorded|WARNING' <<<"$output" || { printf '%s\n' "$output" >&2; fail 'the second operator step changed or reported something'; }
  [[ $(ma_events_since "$before") == 0 ]] || fail 'the second operator step wrote something'
  [[ $(ma_marker) == "$marker" ]] || fail 'the second operator step rewrote the grant record'

  CURRENT_STAGE='media:attach: without full scope the role is mapped into the forms token'
  kcadm update "clients/$forms_uuid" -r "$V2_REALM" -s fullScopeAllowed=false >/dev/null
  ma_service_token
  ! ma_token_carries_role || fail 'positive control: without full scope and a mapping the role still reached the token'
  output=$(ma_reconciler) || { printf '%s\n' "$output" >&2; fail 'the reconciler identity failed on a forms client without full scope'; }
  for expected in "[reconcile] role scope of $MA_CLIENT: updated (+core/$MA_ROLE; fullScopeAllowed is false)" \
    "[reconcile] service account $MA_ACCOUNT: $MA_ROLE unchanged (granted by the operator step at ${marker%% *};"; do
    grep -Fq -- "$expected" <<<"$output" || { printf '%s\n' "$output" >&2; fail "the reconciler identity did not print: $expected"; }
  done
  ! grep -Fq WARNING <<<"$output" || { printf '%s\n' "$output" >&2; fail 'the reconciler identity warned after the grant'; }
  ma_service_token
  ma_token_carries_role || fail 'the mapped role did not reach the forms token without full scope'
  json_assert "$MA_PAYLOAD" '(.aud // []) | (if type == "array" then . else [.] end) | index("core") != null' \
    'the forms service token without full scope does not carry aud core'
  # Back to production's shape; the mapping stays (harmless with full scope).
  kcadm update "clients/$forms_uuid" -r "$V2_REALM" -s fullScopeAllowed=true >/dev/null
}

# Part of v2_state_snapshot: the forms client's flags, role scope and service-account roles of core.
ma_state_snapshot() {
  local forms_uuid
  forms_uuid=$(lca_client_uuid "$MA_CLIENT")
  kcadm get "clients/$forms_uuid" -r "$V2_REALM" -c | jq -c '{fullScopeAllowed, serviceAccountsEnabled}'
  kcadm get "clients/$forms_uuid/scope-mappings/clients/$(lca_client_uuid core)" -r "$V2_REALM" -c | jq -c '[.[].name] | sort'
  ma_account_roles
}
