# shellcheck shell=bash
# Sourced by run-integration.sh; uses its kcadm, fail, json_assert, V2_REALM and TEST_STATE_DIR,
# lca_client_uuid and LCA_USER from login-client-audiences.sh, AP_USER from admin-panel-client.sh,
# and cr_group_id, cr_operator_reconcile and CR_ATTRIBUTE from core-roles.sh.
#
# SkyMail's Privileged roles (runbook §25): skymail:system-mails:read (skymail-backend #61, the
# content of single system mails). The reconciler creates it on every run and only warns while it is
# unseeded; the operator's core-roles step grants it once to the Privileged groups and marks it, the
# same way as core's resource roles. The fixture realm has /ADMIN and /UYELER/YK, no DK.

SR_ROLE=skymail:system-mails:read
SR_PRIVILEGED=(/ADMIN /UYELER/YK)

# The skymail roles a group holds directly, sorted JSON array.
sr_group_roles() {
  kcadm get "groups/$(cr_group_id "$1")/role-mappings/clients/$(lca_client_uuid skymail)" -r "$V2_REALM" -c \
    | jq -c '[.[].name] | sort'
}

# The value of the seed attribute of SR_ROLE ("" when absent).
sr_seed_mark() {
  kcadm get "clients/$(lca_client_uuid skymail)/roles" -r "$V2_REALM" -q briefRepresentation=false -c \
    | jq -r --arg r "$SR_ROLE" --arg a "$CR_ATTRIBUTE" '.[] | select(.name == $r) | ((.attributes // {})[$a][0] // "")'
}

# The effective skymail roles of a person (groups included), sorted JSON array.
sr_effective_roles() {
  local user_id
  user_id=$(kcadm get users -r "$V2_REALM" -q "username=$1" -q exact=true -c | jq -r '.[0].id')
  kcadm get "users/$user_id/role-mappings/clients/$(lca_client_uuid skymail)/composite" -r "$V2_REALM" -c \
    | jq -c '[.[].name] | sort'
}

# First reconciliation (the reconciler identity): the role is created with its description, granted
# to nobody, unmarked, and the warning names the operator step.
stage_skymail_roles_after_first_reconciliation() {
  CURRENT_STAGE='skymail Privileged roles: created by the first reconciliation, not granted'
  local log="$TEST_STATE_DIR/reconcile-first.log" roles path
  grep -Fq "[reconcile] Privileged roles of skymail (1): created ($SR_ROLE)" "$log" \
    || fail "the first reconciliation did not create $SR_ROLE"
  grep -Fq "[reconcile] WARNING: skymail roles not yet granted to the Privileged groups: $SR_ROLE" "$log" \
    || fail 'the first reconciliation did not report the unseeded skymail role'
  roles=$(kcadm get "clients/$(lca_client_uuid skymail)/roles" -r "$V2_REALM" -c)
  json_assert "$roles" '[.[] | select(.name == $r) | .description] == ["Tekil sistem postalarının (doğrulama, bildirim) içeriğini görür (skymail-backend #61)"]' \
    "$SR_ROLE was not created with its description" --arg r "$SR_ROLE"
  [[ -z $(sr_seed_mark) ]] || fail "the reconciler identity marked $SR_ROLE as seeded"
  for path in "${SR_PRIVILEGED[@]}"; do
    json_assert "$(sr_group_roles "$path")" 'index($r) == null' \
      "the reconciler identity granted $SR_ROLE to $path" --arg r "$SR_ROLE"
  done
}

# After stage_core_roles_seeded_by_operator (whose operator runs seeded the role), before the
# no-op reconciliation (which must then be quiet).
stage_skymail_roles_seeded_by_operator() {
  CURRENT_STAGE='skymail Privileged roles: seeded once by the core-roles operator step'
  local output path skymail_uuid yk_id
  skymail_uuid=$(lca_client_uuid skymail)
  [[ $(sr_seed_mark) =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\ /ADMIN,/UYELER/YK$ ]] \
    || fail "$SR_ROLE lacks its seed mark after the operator step (got: $(sr_seed_mark))"
  for path in "${SR_PRIVILEGED[@]}"; do
    json_assert "$(sr_group_roles "$path")" 'index($r) != null' "$path did not get $SR_ROLE" --arg r "$SR_ROLE"
  done
  # The YK member holds it through the group (next to skymail:access granted directly); a person
  # outside the Privileged groups does not.
  json_assert "$(sr_effective_roles "$AP_USER")" '. == (["skymail:access", $r] | sort)' \
    "the YK member's effective skymail roles are wrong" --arg r "$SR_ROLE"
  json_assert "$(sr_effective_roles "$LCA_USER")" 'index($r) == null' \
    "a person outside the Privileged groups got $SR_ROLE" --arg r "$SR_ROLE"

  CURRENT_STAGE='skymail Privileged roles: the admin panel owns the mapping after seeding'
  yk_id=$(cr_group_id /UYELER/YK)
  kcadm delete "groups/$yk_id/role-mappings/clients/$skymail_uuid" -r "$V2_REALM" \
    -b "$(v2_role_body "$skymail_uuid" "$SR_ROLE")" >/dev/null
  output=$(cr_operator_reconcile) || { printf '%s\n' "$output" >&2; fail 'the operator step failed'; }
  grep -Fq '[reconcile] group mappings of the skymail Privileged roles: unchanged' <<<"$output" \
    || { printf '%s\n' "$output" >&2; fail 'the operator step did not leave the skymail mappings alone'; }
  json_assert "$(sr_group_roles /UYELER/YK)" 'index($r) == null' 'a skymail mapping removed after seeding came back' \
    --arg r "$SR_ROLE"

  # Unmarked again (as a role added to the list later): seeded on its own, only where it is missing.
  kcadm update "clients/$skymail_uuid/roles/$SR_ROLE" -r "$V2_REALM" -s 'attributes={}' >/dev/null
  output=$(cr_operator_reconcile) || { printf '%s\n' "$output" >&2; fail 'the operator step failed'; }
  grep -Fq "[reconcile] skymail role $SR_ROLE: seeded once to /ADMIN,/UYELER/YK (granted to: /UYELER/YK)" <<<"$output" \
    || { printf '%s\n' "$output" >&2; fail "the unmarked $SR_ROLE was not seeded again"; }
  ! grep -Eq '^\[reconcile\] core role .*: seeded once' <<<"$output" || fail 'reseeding skymail seeded a core role'
  # The shared seeding (seed_privileged_client_roles) names each missing Privileged group.
  grep -Fq '[reconcile] WARNING: no Privileged group DK (neither /DK nor /UYELER/DK) in realm '"$V2_REALM"'; it gets none of the skymail Privileged roles' <<<"$output" \
    || { printf '%s\n' "$output" >&2; fail 'reseeding skymail did not report the missing DK group'; }
  json_assert "$(sr_group_roles /UYELER/YK)" 'index($r) != null' "/UYELER/YK did not get $SR_ROLE back" --arg r "$SR_ROLE"
}

# Part of v2_state_snapshot: the skymail roles with their marks and the Privileged groups' mappings.
sr_state_snapshot() {
  local path
  kcadm get "clients/$(lca_client_uuid skymail)/roles" -r "$V2_REALM" -q briefRepresentation=false -c \
    | jq -c 'map({name, description, attributes}) | sort_by(.name)'
  for path in "${SR_PRIVILEGED[@]}"; do
    sr_group_roles "$path"
  done
}
