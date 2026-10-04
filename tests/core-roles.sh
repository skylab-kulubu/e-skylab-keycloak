# shellcheck shell=bash
# Sourced by run-integration.sh; uses its kcadm, fail, json_assert, v2_role_body, V2_REALM,
# TEST_STATE_DIR, SCRIPT_DIR, COMPOSE and ADMIN_CONFIG, lca_login / lca_client_uuid and LCA_USER from
# login-client-audiences.sh, and the AP_* admin panel client of admin-panel-client.sh.
#
# core's per-resource client roles (ADR-0059, admin-token-authz ticket 03). The reconciler creates
# them on every run; granting them to the Privileged groups needs user permissions the reconciler
# identity lacks, so its runs only warn about unseeded roles, and an operator seeds them once with
# the step alone (KEYCLOAK_RECONCILE_ONLY=core-roles). After seeding, a Privileged person's token
# carries them (inherited by subgroup members too), nobody else's does, and later runs never undo
# what the admin panel changed. The fixture realm has /ADMIN and /UYELER/YK, no DK.

CR_ATTRIBUTE=skylab.seeded-group-mappings
# The contract table of sky_lab_genel .scratch/admin-token-authz/spec.md.
CR_ROLES=(event:manage season:manage ticket:manage ticket:validate competitor:manage media:manage
  media:private:read certificate:manage users:manage groups:manage github:activity:read url:moderator
  url:access)
CR_PRIVILEGED=(/ADMIN /UYELER/YK)
CR_SUBGROUP=core-roles-subgroup-fixture

cr_roles_json() {
  printf '%s\n' "${CR_ROLES[@]}" | jq -R . | jq -s -c 'sort'
}

cr_group_id() {
  kcadm get "group-by-path$1" -r "$V2_REALM" -c | jq -r .id
}

# The core roles a group holds directly, sorted JSON array.
cr_group_roles() {
  kcadm get "groups/$(cr_group_id "$1")/role-mappings/clients/$(lca_client_uuid core)" -r "$V2_REALM" -c \
    | jq -c '[.[].name] | sort'
}

# role name -> value of the seed attribute ("" when absent), as one JSON object.
cr_seed_marks() {
  kcadm get "clients/$(lca_client_uuid core)/roles" -r "$V2_REALM" -q briefRepresentation=false -c \
    | jq -c 'map({key: .name, value: ((.attributes // {})[$a][0] // "")}) | from_entries' --arg a "$CR_ATTRIBUTE"
}

# The step alone with the harness administrator's kcadm session (the operator path). Arguments are
# extra `exec` options (environment).
cr_operator_reconcile() {
  "${COMPOSE[@]}" exec -T \
    -e "KEYCLOAK_REALM=$V2_REALM" \
    -e "KEYCLOAK_RECONCILE_KCADM_CONFIG=$ADMIN_CONFIG" \
    -e KEYCLOAK_RECONCILE_ONLY=core-roles \
    "$@" \
    keycloak /opt/keycloak/config/reconcile-account-center.sh 2>&1
}

# The step with one kcadm read failing for another reason than "not found" (KCADM_BIN injection):
# it must stop before granting or marking anything. $1: the failing read, $2: the expected message.
cr_injected_failure_refuses() {
  local log="$TEST_STATE_DIR/core-roles-injected-failure.log"
  if cr_operator_reconcile -e KCADM_BIN=/tmp/kcadm-core-roles-failure.sh -e "KCADM_INJECT_FAIL=$1" >"$log"; then
    cat "$log" >&2
    fail "the step seeded although reading $1 failed"
  fi
  grep -Fq "$2" "$log" || { cat "$log" >&2; fail "the step did not say why it stopped when reading $1 failed"; }
  ! grep -Eq '^\[reconcile\] core role .*: seeded once' "$log" || fail "the step seeded after reading $1 failed"
  json_assert "$(cr_seed_marks)" '[.[]] | all(. == "")' "the step marked a role after reading $1 failed"
  json_assert "$(cr_group_roles /ADMIN)" '. == []' "the step granted a role after reading $1 failed"
}

# A real login through the admin panel's client; leaves the sorted core roles of its access token
# in CR_SEEN.
CR_SEEN=''
cr_panel_login() {
  lca_login "$AP_CLIENT" "$AP_REDIRECT" "$AP_SECRET" "$1" "$2" "$AP_PANEL_SCOPE"
  CR_SEEN=$(jq -c '(.resource_access.core.roles // []) | sort' <<<"$LCA_ACCESS_PAYLOAD")
}

# First reconciliation (the reconciler identity): every role created with its description, none
# granted, the warning names the operator step; the admin panel step that runs after it has them in
# the panel's scope (ap_assert_contract compares with every core role).
stage_core_roles_after_first_reconciliation() {
  CURRENT_STAGE='core resource roles: created by the first reconciliation, not granted'
  local log="$TEST_STATE_DIR/reconcile-first.log" roles marks path
  grep -E '^\[reconcile\] client roles of core \(13 resource roles\): created \(' "$log" \
    | grep -Fq 'event:manage' \
    || fail 'the first reconciliation did not create the core resource roles'
  grep -Fq '[reconcile] WARNING: core roles not yet granted to the Privileged groups: event:manage season:manage' "$log" \
    || fail 'the first reconciliation did not report the unseeded core roles'
  grep -Fq 'KEYCLOAK_RECONCILE_ONLY=core-roles' "$log" \
    || fail 'the warning does not name the operator step'
  roles=$(kcadm get "clients/$(lca_client_uuid core)/roles" -r "$V2_REALM" -c)
  json_assert "$roles" '($want - [.[].name]) == []' 'a core resource role is missing' --argjson want "$(cr_roles_json)"
  json_assert "$roles" '[.[] | select(.name == "event:manage") | .description] == ["Her takımın etkinliklerini, etkinlik günlerini ve oturumlarını yönetir; kapı görevlisi atar (ADR-0059)"]' \
    'event:manage was created without its description'
  marks=$(cr_seed_marks)
  json_assert "$marks" '[.[]] | all(. == "")' 'the reconciler identity marked a role as seeded'
  for path in "${CR_PRIVILEGED[@]}"; do
    json_assert "$(cr_group_roles "$path")" '. == []' "the reconciler identity granted a core role to $path"
  done
}

# After the admin panel's stages, before the no-op reconciliation (which must then be quiet).
stage_core_roles_seeded_by_operator() {
  CURRENT_STAGE='core resource roles: seeded once by the operator step'
  local output marks path role want core_uuid yk_id sub_id user_id admin_sub_id refused
  local seeded_pattern
  core_uuid=$(lca_client_uuid core)
  want=$(cr_roles_json)

  # Before seeding: the YK member's panel token has only the role granted to them directly.
  cr_panel_login "$AP_USER" "$AP_PASSWORD"
  json_assert "$CR_SEEN" '. == ["url:create"]' \
    'the YK member already holds core resource roles before seeding'

  # A default group at or under a Privileged group would give the roles to every new user: refused,
  # nothing written.
  yk_id=$(cr_group_id /UYELER/YK)
  kcadm update "realms/$V2_REALM/default-groups/$yk_id" -n -b '{}' >/dev/null
  refused="$TEST_STATE_DIR/core-roles-refused.log"
  if cr_operator_reconcile >"$refused"; then
    fail 'the step seeded with a Privileged default group'
  fi
  grep -Fq 'The default group /UYELER/YK is at or under the Privileged group /UYELER/YK' "$refused" \
    || { cat "$refused" >&2; fail 'the refused step did not say why'; }
  kcadm delete "realms/$V2_REALM/default-groups/$yk_id" >/dev/null
  json_assert "$(cr_seed_marks)" '[.[]] | all(. == "")' 'the refused step marked a role'
  json_assert "$(cr_group_roles /ADMIN)" '. == []' 'the refused step granted a role'

  # Fail closed: a failed default-group read is not "no default group", and a failed group lookup is
  # not "group missing" (only Keycloak's not-found is; the missing DK below proves that path).
  "${COMPOSE[@]}" exec -T keycloak bash -c \
    'cat >/tmp/kcadm-core-roles-failure.sh && chmod 755 /tmp/kcadm-core-roles-failure.sh' \
    <"$SCRIPT_DIR/kcadm-core-roles-failure.sh"
  cr_injected_failure_refuses "realms/$V2_REALM/default-groups" \
    "The default groups of realm $V2_REALM could not be read; nothing was granted"
  cr_injected_failure_refuses group-by-path/UYELER/YK \
    "The Privileged group /UYELER/YK could not be looked up in realm $V2_REALM; nothing was granted"

  output=$(cr_operator_reconcile) || { printf '%s\n' "$output" >&2; fail 'the operator step failed'; }
  grep -Fq 'Core resource roles are reconciled.' <<<"$output" || fail 'the operator step did not report completion'
  grep -Fq '[reconcile] WARNING: no Privileged group DK (neither /DK nor /UYELER/DK)' <<<"$output" \
    || { printf '%s\n' "$output" >&2; fail 'the operator step did not report the missing DK group'; }
  for role in "${CR_ROLES[@]}"; do
    grep -Fq "[reconcile] core role $role: seeded once to /ADMIN,/UYELER/YK (granted to: /ADMIN, /UYELER/YK)" <<<"$output" \
      || { printf '%s\n' "$output" >&2; fail "the operator step did not seed $role"; }
  done
  marks=$(cr_seed_marks)
  seeded_pattern='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z /ADMIN,/UYELER/YK$'
  json_assert "$marks" '[.[$want[]]] | all(test($p))' 'a seeded role lacks its mark' \
    --argjson want "$want" --arg p "$seeded_pattern"
  json_assert "$marks" '.["url:create"] == "" and .["certificate:issue"] == ""' 'a role outside the list was marked'
  for path in "${CR_PRIVILEGED[@]}"; do
    json_assert "$(cr_group_roles "$path")" '. == $want' "$path does not hold exactly the core resource roles" \
      --argjson want "$want"
  done

  CURRENT_STAGE='core resource roles: in the tokens of Privileged people only'
  cr_panel_login "$AP_USER" "$AP_PASSWORD"
  json_assert "$CR_SEEN" '. == (($want + ["url:create"]) | sort)' \
    "the YK member's panel token lacks the seeded core roles" --argjson want "$want"
  # Not Privileged: nothing. In a subgroup of YK: inherited.
  cr_panel_login "$LCA_USER" "$LCA_PASSWORD"
  json_assert "$CR_SEEN" '. == []' \
    'a person outside the Privileged groups got core resource roles'
  sub_id=$(kcadm create "groups/$yk_id/children" -r "$V2_REALM" -s "name=$CR_SUBGROUP" -i)
  user_id=$(kcadm get users -r "$V2_REALM" -q "username=$LCA_USER" -q exact=true -c | jq -r '.[0].id')
  kcadm update "users/$user_id/groups/$sub_id" -r "$V2_REALM" -n -b '{}' >/dev/null
  cr_panel_login "$LCA_USER" "$LCA_PASSWORD"
  json_assert "$CR_SEEN" '. == $want' \
    'a member of a YK subgroup did not inherit the core resource roles' --argjson want "$want"
  kcadm delete "users/$user_id/groups/$sub_id" -r "$V2_REALM" >/dev/null
  kcadm delete "groups/$sub_id" -r "$V2_REALM" >/dev/null

  CURRENT_STAGE='core resource roles: the admin panel owns the mappings after seeding'
  # Removed in the panel: stays removed. Added in the panel: stays. Nothing is granted again.
  kcadm delete "groups/$yk_id/role-mappings/clients/$core_uuid" -r "$V2_REALM" \
    -b "$(v2_role_body "$core_uuid" event:manage)" >/dev/null
  admin_sub_id=$(cr_group_id /ADMIN/handoff-admin-subgroup-fixture)
  kcadm create "groups/$admin_sub_id/role-mappings/clients/$core_uuid" -r "$V2_REALM" \
    -b "$(v2_role_body "$core_uuid" ticket:validate)" >/dev/null
  output=$(cr_operator_reconcile) || { printf '%s\n' "$output" >&2; fail 'the second operator step failed'; }
  grep -Fq '[reconcile] group mappings of the core resource roles: unchanged' <<<"$output" \
    || { printf '%s\n' "$output" >&2; fail 'the second operator step did not leave the mappings alone'; }
  ! grep -Eq '^\[reconcile\] core role .*: seeded once' <<<"$output" || fail 'the second operator step seeded again'
  json_assert "$(cr_group_roles /UYELER/YK)" 'index("event:manage") == null' \
    'a mapping removed after seeding came back'
  json_assert "$(cr_group_roles /ADMIN/handoff-admin-subgroup-fixture)" '. == ["ticket:validate"]' \
    'a mapping added after seeding was removed'

  # A role added to the list later (no mark yet, held by only one group) is seeded on its own run.
  kcadm update "clients/$core_uuid/roles/season:manage" -r "$V2_REALM" -s 'attributes={}' >/dev/null
  kcadm delete "groups/$(cr_group_id /ADMIN)/role-mappings/clients/$core_uuid" -r "$V2_REALM" \
    -b "$(v2_role_body "$core_uuid" season:manage)" >/dev/null
  output=$(cr_operator_reconcile) || { printf '%s\n' "$output" >&2; fail 'the third operator step failed'; }
  grep -Fq '[reconcile] core role season:manage: seeded once to /ADMIN,/UYELER/YK (granted to: /ADMIN)' <<<"$output" \
    || { printf '%s\n' "$output" >&2; fail 'an unmarked role was not seeded on its own'; }
  [[ $(grep -Ec '^\[reconcile\] core role .*: seeded once' <<<"$output") == 1 ]] \
    || fail 'the third operator step seeded more than the unmarked role'
  json_assert "$(cr_group_roles /UYELER/YK)" 'index("event:manage") == null' \
    'seeding a new role restored a mapping removed after seeding'

  # Leave the fixture as seeded for the stages after this one.
  kcadm create "groups/$yk_id/role-mappings/clients/$core_uuid" -r "$V2_REALM" \
    -b "$(v2_role_body "$core_uuid" event:manage)" >/dev/null
  kcadm delete "groups/$admin_sub_id/role-mappings/clients/$core_uuid" -r "$V2_REALM" \
    -b "$(v2_role_body "$core_uuid" ticket:validate)" >/dev/null
}

# Part of v2_state_snapshot: the core roles with their marks and the Privileged groups' mappings.
cr_state_snapshot() {
  local path
  kcadm get "clients/$(lca_client_uuid core)/roles" -r "$V2_REALM" -q briefRepresentation=false -c \
    | jq -c 'map({name, description, attributes}) | sort_by(.name)'
  for path in "${CR_PRIVILEGED[@]}"; do
    cr_group_roles "$path"
  done
}
