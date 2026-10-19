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
# what the admin panel changed. The fixture realm has /ADMIN and /UYELER/YK, no DK; the operator
# stage makes /UYELER/DK for its runs and removes it at its end (grup-yonetimi 08: DK reads and does
# not write): the write roles go to ADMIN and YK, global:read to DK alone, audit:read and url:access
# (the holder's own short links, Y1) to all three, and forms/skyforms:read-all (Forms' Privileged
# role, the same operator step) to DK alone.
# competition:manage renames competitor:manage (ADR-0068): it is seeded once wherever the old role is
# held (groups, service accounts, composite roles, role scopes of clients and client scopes), not to
# the Privileged groups. A person holding the old role directly is counted and warned about, never
# given the new one (people get roles only through groups).

CR_ATTRIBUTE=skylab.seeded-group-mappings
# The contract table of sky_lab_genel .scratch/admin-token-authz/spec.md: the write roles, seeded to
# ADMIN and YK.
CR_ROLES=(event:manage season:manage ticket:manage ticket:validate competitor:manage media:manage
  media:private:read certificate:manage users:manage groups:manage github:activity:read url:moderator)
# The holder's own short links: seeded to ADMIN, YK and DK (Y1).
CR_OWN_ROLE=url:access
# DK's read roles (grup-yonetimi 08): global:read to DK alone, audit:read to ADMIN, YK and DK.
CR_READER_ROLE=global:read
CR_AUDIT_ROLE=audit:read
CR_DK=/UYELER/DK
CR_RENAMED=competition:manage
CR_RENAMED_FROM=competitor:manage
CR_PRIVILEGED=(/ADMIN /UYELER/YK)
CR_SUBGROUP=core-roles-subgroup-fixture
CR_RENAME_GROUP=core-roles-rename-group-fixture
# Team-like groups with long names that also hold the old role: their paths together are far longer
# than a role attribute value may be (255), so a mark naming them could not be written.
CR_RENAME_LONG_GROUPS=8
CR_RENAME_LONG_PREFIX=core-roles-rename-long-team-group-fixture
CR_RENAME_USER=core-roles-rename-user-fixture
# A client whose service account holds the old role directly: the one user the new role goes to.
CR_RENAME_SA_CLIENT=core-roles-rename-service-account-fixture
CR_RENAME_COMPOSITE=core-roles-rename-composite-fixture
CR_RENAME_SCOPE=core-roles-rename-scope-fixture

# Every core resource role: the write ones, the renamed one and DK's two read roles.
cr_roles_json() {
  printf '%s\n' "${CR_ROLES[@]}" "$CR_RENAMED" "$CR_READER_ROLE" "$CR_AUDIT_ROLE" "$CR_OWN_ROLE" | jq -R . | jq -s -c 'sort'
}

# What ADMIN and YK hold once seeded: the write roles, the renamed one, audit:read and url:access.
cr_privileged_roles_json() {
  printf '%s\n' "${CR_ROLES[@]}" "$CR_RENAMED" "$CR_AUDIT_ROLE" "$CR_OWN_ROLE" | jq -R . | jq -s -c 'sort'
}

# What DK holds once seeded: global:read, audit:read and url:access.
cr_dk_roles_json() {
  printf '%s\n' "$CR_READER_ROLE" "$CR_AUDIT_ROLE" "$CR_OWN_ROLE" | jq -R . | jq -s -c 'sort'
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
  grep -E '^\[reconcile\] client roles of core \(16 resource roles\): created \(' "$log" \
    | grep -Fq 'event:manage' \
    || fail 'the first reconciliation did not create the core resource roles'
  grep -Fq '[reconcile] WARNING: core roles not yet granted to the Privileged groups: event:manage season:manage' "$log" \
    || fail 'the first reconciliation did not report the unseeded core roles'
  grep -Fq "url:access $CR_READER_ROLE $CR_AUDIT_ROLE (granting a role to a group" "$log" \
    || fail "the first reconciliation did not report $CR_READER_ROLE and $CR_AUDIT_ROLE as unseeded"
  # Forms' Privileged role waits for the forms client (core-erasure-client.sh makes it later).
  grep -Fq "[reconcile] WARNING: client forms does not exist in realm $V2_REALM; skipped Forms' Privileged roles" "$log" \
    || fail 'the first reconciliation did not skip the missing forms client'
  grep -Fq "[reconcile] WARNING: core roles not yet carried over from their old names: $CR_RENAMED (from $CR_RENAMED_FROM)" "$log" \
    || fail "the first reconciliation did not report $CR_RENAMED as waiting for its old name"
  ! grep -E '^\[reconcile\] WARNING: core roles not yet granted to the Privileged groups: ' "$log" | grep -Fq "$CR_RENAMED" \
    || fail "the first reconciliation said $CR_RENAMED goes to the Privileged groups"
  grep -Fq 'KEYCLOAK_RECONCILE_ONLY=core-roles' "$log" \
    || fail 'the warning does not name the operator step'
  roles=$(kcadm get "clients/$(lca_client_uuid core)/roles" -r "$V2_REALM" -c)
  json_assert "$roles" '($want - [.[].name]) == []' 'a core resource role is missing' --argjson want "$(cr_roles_json)"
  json_assert "$roles" '[.[] | select(.name == "event:manage") | .description] == ["Her takımın etkinliklerini, etkinlik günlerini ve oturumlarını yönetir; kapı görevlisi atar (ADR-0059)"]' \
    'event:manage was created without its description'
  json_assert "$roles" '[.[] | select(.name == $n) | .description | test("competitor:manage") and test("ADR-0068")] == [true]' \
    "$CR_RENAMED was created without its description" --arg n "$CR_RENAMED"
  marks=$(cr_seed_marks)
  json_assert "$marks" '[.[]] | all(. == "")' 'the reconciler identity marked a role as seeded'
  for path in "${CR_PRIVILEGED[@]}"; do
    json_assert "$(cr_group_roles "$path")" '. == []' "the reconciler identity granted a core role to $path"
  done
}

# After the admin panel's stages, before the no-op reconciliation (which must then be quiet).
stage_core_roles_seeded_by_operator() {
  CURRENT_STAGE='core resource roles: seeded once by the operator step'
  local output marks path role core_uuid yk_id sub_id user_id admin_sub_id refused
  local seeded_pattern
  core_uuid=$(lca_client_uuid core)

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

  # Holders of the old role outside the Privileged groups: the renamed role must follow each of them
  # (core reads the two names as one; nobody gains or loses a right).
  cr_rename_fixtures_create
  # DK as production has it (/UYELER/DK), for this stage's runs: it reads and does not write.
  kcadm create "groups/$(cr_group_id /UYELER)/children" -r "$V2_REALM" -s name=DK >/dev/null

  output=$(cr_operator_reconcile) || { printf '%s\n' "$output" >&2; fail 'the operator step failed'; }
  grep -Fq 'Core resource roles are reconciled.' <<<"$output" || fail 'the operator step did not report completion'
  ! grep -Fq 'WARNING: no Privileged group' <<<"$output" \
    || { printf '%s\n' "$output" >&2; fail 'the operator step reported a missing Privileged group'; }
  for role in "${CR_ROLES[@]}"; do
    grep -Fq "[reconcile] core role $role: seeded once to /ADMIN,/UYELER/YK (granted to: /ADMIN, /UYELER/YK)" <<<"$output" \
      || { printf '%s\n' "$output" >&2; fail "the operator step did not seed $role to ADMIN and YK alone"; }
  done
  for role in "$CR_AUDIT_ROLE" "$CR_OWN_ROLE"; do
    grep -Fq "[reconcile] core role $role: seeded once to /ADMIN,/UYELER/YK,$CR_DK (granted to: /ADMIN, /UYELER/YK, $CR_DK)" <<<"$output" \
      || { printf '%s\n' "$output" >&2; fail "the operator step did not seed $role to ADMIN, YK and DK"; }
  done
  grep -Fq "[reconcile] core role $CR_READER_ROLE: seeded once to $CR_DK (granted to: $CR_DK)" <<<"$output" \
    || { printf '%s\n' "$output" >&2; fail "the operator step did not seed $CR_READER_ROLE to DK alone"; }
  grep -Fq "[reconcile] forms role skyforms:read-all: seeded once to $CR_DK (granted to: $CR_DK)" <<<"$output" \
    || { printf '%s\n' "$output" >&2; fail 'the operator step did not seed skyforms:read-all to DK alone'; }
  marks=$(cr_seed_marks)
  seeded_pattern='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z /ADMIN,/UYELER/YK$'
  json_assert "$marks" '[.[$write[]]] | all(test($p))' 'a seeded write role lacks its mark' \
    --argjson write "$(printf '%s\n' "${CR_ROLES[@]}" | jq -R . | jq -s -c .)" --arg p "$seeded_pattern"
  json_assert "$marks" '(.[$audit] | test("Z /ADMIN,/UYELER/YK,/UYELER/DK$")) and (.[$own] | test("Z /ADMIN,/UYELER/YK,/UYELER/DK$"))
    and (.[$reader] | test("Z /UYELER/DK$"))' \
    "$CR_AUDIT_ROLE, $CR_OWN_ROLE or $CR_READER_ROLE lacks its mark" --arg audit "$CR_AUDIT_ROLE" --arg reader "$CR_READER_ROLE" \
    --arg own "$CR_OWN_ROLE"
  json_assert "$marks" '.["url:create"] == "" and .["certificate:issue"] == ""' 'a role outside the list was marked'
  cr_assert_renamed_follows_old "$output"
  for path in "${CR_PRIVILEGED[@]}"; do
    json_assert "$(cr_group_roles "$path")" '. == $want' "$path does not hold exactly the write roles and $CR_AUDIT_ROLE" \
      --argjson want "$(cr_privileged_roles_json)"
  done
  json_assert "$(cr_group_roles "$CR_DK")" '. == $want' "$CR_DK does not hold exactly $CR_AUDIT_ROLE, $CR_READER_ROLE and $CR_OWN_ROLE" \
    --argjson want "$(cr_dk_roles_json)"
  json_assert "$(kcadm get "groups/$(cr_group_id "$CR_DK")/role-mappings/clients/$(lca_client_uuid forms)" -r "$V2_REALM" -c | jq -c '[.[].name]')" \
    '. == ["skyforms:read-all"]' "$CR_DK does not hold exactly forms/skyforms:read-all"

  cr_rename_fixtures_delete

  CURRENT_STAGE='core resource roles: in the tokens of Privileged people only'
  cr_panel_login "$AP_USER" "$AP_PASSWORD"
  json_assert "$CR_SEEN" '. == (($want + ["url:create"]) | sort)' \
    "the YK member's panel token lacks the seeded core roles" --argjson want "$(cr_privileged_roles_json)"
  # Not Privileged: nothing. In a subgroup of YK: inherited.
  cr_panel_login "$LCA_USER" "$LCA_PASSWORD"
  json_assert "$CR_SEEN" '. == []' \
    'a person outside the Privileged groups got core resource roles'
  sub_id=$(kcadm create "groups/$yk_id/children" -r "$V2_REALM" -s "name=$CR_SUBGROUP" -i)
  user_id=$(kcadm get users -r "$V2_REALM" -q "username=$LCA_USER" -q exact=true -c | jq -r '.[0].id')
  kcadm update "users/$user_id/groups/$sub_id" -r "$V2_REALM" -n -b '{}' >/dev/null
  cr_panel_login "$LCA_USER" "$LCA_PASSWORD"
  json_assert "$CR_SEEN" '. == $want' \
    'a member of a YK subgroup did not inherit the core resource roles' --argjson want "$(cr_privileged_roles_json)"
  kcadm delete "users/$user_id/groups/$sub_id" -r "$V2_REALM" >/dev/null
  kcadm delete "groups/$sub_id" -r "$V2_REALM" >/dev/null
  # A DK member: the two read roles and their own short links, no write role.
  kcadm update "users/$user_id/groups/$(cr_group_id "$CR_DK")" -r "$V2_REALM" -n -b '{}' >/dev/null
  cr_panel_login "$LCA_USER" "$LCA_PASSWORD"
  json_assert "$CR_SEEN" '. == $want' "a DK member's panel token carries other core roles than $CR_AUDIT_ROLE, $CR_READER_ROLE and $CR_OWN_ROLE" \
    --argjson want "$(cr_dk_roles_json)"
  kcadm delete "users/$user_id/groups/$(cr_group_id "$CR_DK")" -r "$V2_REALM" >/dev/null

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

  # The renamed role unmarked (as if new) and missing from /ADMIN: a failed read stops it before any
  # write; the next run grants it to /ADMIN only, where the old role is held.
  CURRENT_STAGE='core resource roles: the renamed role is seeded where the old one is held'
  kcadm update "clients/$core_uuid/roles/$CR_RENAMED" -r "$V2_REALM" -s 'attributes={}' >/dev/null
  kcadm delete "groups/$(cr_group_id /ADMIN)/role-mappings/clients/$core_uuid" -r "$V2_REALM" \
    -b "$(v2_role_body "$core_uuid" "$CR_RENAMED")" >/dev/null
  refused="$TEST_STATE_DIR/core-roles-rename-refused.log"
  if cr_operator_reconcile -e KCADM_BIN=/tmp/kcadm-core-roles-failure.sh -e KCADM_INJECT_FAIL=client-scopes >"$refused"; then
    cat "$refused" >&2
    fail 'the renamed role was seeded although reading the client scopes failed'
  fi
  grep -Fq "The client scopes could not be read in realm $V2_REALM; nothing was granted" "$refused" \
    || { cat "$refused" >&2; fail 'the refused rename step did not say why'; }
  json_assert "$(cr_seed_marks)" '.[$n] == ""' 'the refused rename step marked the role' --arg n "$CR_RENAMED"
  json_assert "$(cr_group_roles /ADMIN)" 'index($n) == null' 'the refused rename step granted the role' \
    --arg n "$CR_RENAMED"
  output=$(cr_operator_reconcile) || { printf '%s\n' "$output" >&2; fail 'the rename operator step failed'; }
  grep -Eq "^\[reconcile\] core role $CR_RENAMED: seeded once where $CR_RENAMED_FROM is held: .*\(granted to 1 of them;" <<<"$output" \
    || { printf '%s\n' "$output" >&2; fail 'the renamed role was not seeded to the one holder that lacked it'; }
  [[ $(grep -Ec '^\[reconcile\] core role .*: seeded once' <<<"$output") == 1 ]] \
    || fail 'the rename operator step seeded more than the renamed role'
  json_assert "$(cr_group_roles /ADMIN)" 'index($n) != null' 'the renamed role did not come back to /ADMIN' \
    --arg n "$CR_RENAMED"
  json_assert "$(cr_group_roles /UYELER/YK)" 'index("event:manage") == null' \
    'seeding the renamed role restored a mapping removed after seeding'

  # Leave the fixture as seeded for the stages after this one; /UYELER/DK goes (the later stages
  # prove a missing DK group; the marks keep DK's roles from being seeded again).
  kcadm create "groups/$yk_id/role-mappings/clients/$core_uuid" -r "$V2_REALM" \
    -b "$(v2_role_body "$core_uuid" event:manage)" >/dev/null
  kcadm delete "groups/$admin_sub_id/role-mappings/clients/$core_uuid" -r "$V2_REALM" \
    -b "$(v2_role_body "$core_uuid" ticket:validate)" >/dev/null
  kcadm delete "groups/$(cr_group_id "$CR_DK")" -r "$V2_REALM" >/dev/null
}

# Holders of the old role that are not Privileged groups: a group, a person, a service account, a
# realm composite role and a client scope (the admin panel client's role scope already maps every
# core role).
cr_rename_fixtures_create() {
  local core_uuid old_body group_id user_id scope_id client_id sa_id
  core_uuid=$(lca_client_uuid core)
  old_body=$(v2_role_body "$core_uuid" "$CR_RENAMED_FROM")
  group_id=$(kcadm create groups -r "$V2_REALM" -s "name=$CR_RENAME_GROUP" -i)
  kcadm create "groups/$group_id/role-mappings/clients/$core_uuid" -r "$V2_REALM" -b "$old_body" >/dev/null
  for n in $(seq 1 "$CR_RENAME_LONG_GROUPS"); do
    group_id=$(kcadm create groups -r "$V2_REALM" -s "name=$CR_RENAME_LONG_PREFIX-$n" -i)
    kcadm create "groups/$group_id/role-mappings/clients/$core_uuid" -r "$V2_REALM" -b "$old_body" >/dev/null
  done
  user_id=$(kcadm create users -r "$V2_REALM" -i -s "username=$CR_RENAME_USER" -s enabled=true \
    -s "email=$CR_RENAME_USER@example.invalid" -s emailVerified=true -s firstName=Rename -s lastName=Fixture)
  kcadm create "users/$user_id/role-mappings/clients/$core_uuid" -r "$V2_REALM" -b "$old_body" >/dev/null
  client_id=$(kcadm create clients -r "$V2_REALM" -i -s "clientId=$CR_RENAME_SA_CLIENT" -s publicClient=false \
    -s serviceAccountsEnabled=true -s standardFlowEnabled=false -s directAccessGrantsEnabled=false)
  sa_id=$(kcadm get "clients/$client_id/service-account-user" -r "$V2_REALM" -c | jq -r .id)
  kcadm create "users/$sa_id/role-mappings/clients/$core_uuid" -r "$V2_REALM" -b "$old_body" >/dev/null
  kcadm create roles -r "$V2_REALM" -s "name=$CR_RENAME_COMPOSITE" >/dev/null
  kcadm create "roles/$CR_RENAME_COMPOSITE/composites" -r "$V2_REALM" -b "$old_body" >/dev/null
  scope_id=$(kcadm create client-scopes -r "$V2_REALM" -s "name=$CR_RENAME_SCOPE" -s protocol=openid-connect -i)
  kcadm create "client-scopes/$scope_id/scope-mappings/clients/$core_uuid" -r "$V2_REALM" -b "$old_body" >/dev/null
}

cr_rename_fixture_ids() {
  kcadm get client-scopes -r "$V2_REALM" -c | jq -r --arg n "$CR_RENAME_SCOPE" '.[] | select(.name == $n) | .id'
}

cr_rename_fixtures_delete() {
  kcadm delete "groups/$(cr_group_id "/$CR_RENAME_GROUP")" -r "$V2_REALM" >/dev/null
  for n in $(seq 1 "$CR_RENAME_LONG_GROUPS"); do
    kcadm delete "groups/$(cr_group_id "/$CR_RENAME_LONG_PREFIX-$n")" -r "$V2_REALM" >/dev/null
  done
  kcadm delete "users/$(kcadm get users -r "$V2_REALM" -q "username=$CR_RENAME_USER" -q exact=true -c | jq -r '.[0].id')" \
    -r "$V2_REALM" >/dev/null
  kcadm delete "clients/$(lca_client_uuid "$CR_RENAME_SA_CLIENT")" -r "$V2_REALM" >/dev/null
  kcadm delete "roles/$CR_RENAME_COMPOSITE" -r "$V2_REALM" >/dev/null
  kcadm delete "client-scopes/$(cr_rename_fixture_ids)" -r "$V2_REALM" >/dev/null
}

# The names of core roles a role-scope or composite endpoint returns, sorted JSON array.
cr_names() {
  kcadm get "$1" -r "$V2_REALM" -c | jq -c '[.[].name] | sort'
}

# After the first operator run: the renamed role is held exactly where the old one is, and nowhere
# else. $1: the run's output.
cr_assert_renamed_follows_old() {
  local output=$1 core_uuid line mark old_groups new_groups scope_id
  core_uuid=$(lca_client_uuid core)
  line=$(grep -E "^\[reconcile\] core role $CR_RENAMED: seeded once where $CR_RENAMED_FROM is held: " <<<"$output") \
    || { printf '%s\n' "$output" >&2; fail "the operator step did not seed $CR_RENAMED where $CR_RENAMED_FROM is held"; }
  ! grep -Fq "core role $CR_RENAMED: seeded once to /ADMIN" <<<"$output" \
    || fail "$CR_RENAMED was seeded to the Privileged groups instead of where $CR_RENAMED_FROM is held"
  grep -Fq 'users 2 (people 1 not granted);' <<<"$line" \
    || fail "the rename did not count the person and the service account holding $CR_RENAMED_FROM: $line"
  grep -Fq "[reconcile] WARNING: core role $CR_RENAMED not granted to 1 people holding $CR_RENAMED_FROM directly" <<<"$output" \
    || { printf '%s\n' "$output" >&2; fail "the rename did not warn about the person holding $CR_RENAMED_FROM directly"; }
  grep -Eq "composite roles ([^;]*,)?${CR_RENAME_COMPOSITE}[,;]" <<<"$line" || fail "the rename missed the composite role: $line"
  grep -Eq "client scopes ([^(]*,)?${CR_RENAME_SCOPE}[, ]" <<<"$line" || fail "the rename missed the client scope: $line"
  grep -Eq "role scopes ([^;]*,)?${AP_CLIENT}[,;]" <<<"$line" || fail "the rename missed the admin panel's role scope: $line"
  mark=$(cr_seed_marks | jq -r --arg n "$CR_RENAMED" '.[$n]')
  # The paths of the long-named groups are all in the log, but the mark holds counts only and fits a
  # role attribute value (255).
  for n in $(seq 1 "$CR_RENAME_LONG_GROUPS"); do
    grep -Fq "/$CR_RENAME_LONG_PREFIX-$n" <<<"$line" || fail "the rename log does not name /$CR_RENAME_LONG_PREFIX-$n: $line"
  done
  ((${#mark} <= 255)) || fail "the mark of $CR_RENAMED is ${#mark} characters, more than a role attribute holds: $mark"
  [[ $mark == *" groups $((${#CR_PRIVILEGED[@]} + 1 + CR_RENAME_LONG_GROUPS)); users 2 (people 1 not granted); composite roles 1; "* ]] \
    || fail "the mark of $CR_RENAMED does not count the holders of $CR_RENAMED_FROM: $mark"
  [[ $mark =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\ where\ $CR_RENAMED_FROM\ is\ held: ]] \
    || fail "$CR_RENAMED lacks its mark: $mark"
  grep -Fq "$CR_RENAME_USER" <<<"$mark$output" && fail 'the rename wrote a user name into its log or mark'
  old_groups=$(kcadm get "clients/$core_uuid/roles/$CR_RENAMED_FROM/groups" -r "$V2_REALM" -c | jq -c '[.[].path] | sort')
  new_groups=$(kcadm get "clients/$core_uuid/roles/$CR_RENAMED/groups" -r "$V2_REALM" -c | jq -c '[.[].path] | sort')
  json_assert "$new_groups" '. == $old' "$CR_RENAMED is not mapped to exactly the groups of $CR_RENAMED_FROM" \
    --argjson old "$old_groups"
  json_assert "$new_groups" 'index($g) != null and index("/ADMIN") != null and index("/UYELER/YK") != null' \
    "$CR_RENAMED did not reach the Privileged groups and the fixture group" --arg g "/$CR_RENAME_GROUP"
  # The service account follows the old role; the person keeps only the old one (no direct roles to
  # people).
  json_assert "$(kcadm get "clients/$core_uuid/roles/$CR_RENAMED/users" -r "$V2_REALM" -c | jq -c '[.[].username]')" \
    '. == $u' "$CR_RENAMED is not held directly by exactly the service account holding $CR_RENAMED_FROM" \
    --argjson u "[\"service-account-$CR_RENAME_SA_CLIENT\"]"
  json_assert "$(kcadm get "clients/$core_uuid/roles/$CR_RENAMED_FROM/users" -r "$V2_REALM" -c | jq -c '[.[].username] | sort')" \
    '. == ([$p, $s] | sort)' "the holders of $CR_RENAMED_FROM changed" \
    --arg p "$CR_RENAME_USER" --arg s "service-account-$CR_RENAME_SA_CLIENT"
  json_assert "$(cr_names "roles/$CR_RENAME_COMPOSITE/composites/clients/$core_uuid")" \
    '. == ([$a, $b] | sort)' "the composite role does not contain both names" --arg a "$CR_RENAMED" --arg b "$CR_RENAMED_FROM"
  scope_id=$(cr_rename_fixture_ids)
  json_assert "$(cr_names "client-scopes/$scope_id/scope-mappings/clients/$core_uuid")" \
    '. == ([$a, $b] | sort)' "the client scope does not map both names" --arg a "$CR_RENAMED" --arg b "$CR_RENAMED_FROM"
  json_assert "$(cr_names "clients/$(lca_client_uuid "$AP_CLIENT")/scope-mappings/clients/$core_uuid")" \
    'index($a) != null and index($b) != null' "the admin panel's role scope lacks a name" \
    --arg a "$CR_RENAMED" --arg b "$CR_RENAMED_FROM"
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
