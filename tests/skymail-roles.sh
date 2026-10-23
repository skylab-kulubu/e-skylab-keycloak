# shellcheck shell=bash
# Sourced by run-integration.sh; uses its kcadm, fail, json_assert, V2_REALM and TEST_STATE_DIR,
# lca_client_uuid and LCA_USER from login-client-audiences.sh, AP_USER from admin-panel-client.sh,
# and cr_group_id, cr_operator_reconcile and CR_ATTRIBUTE from core-roles.sh.
#
# SkyMail's Privileged roles (runbook §25): skymail:system-mails:read (skymail-backend #61, the
# content of single system mails) and skymail:mails:tracking:read (iletisim-servisi 14b/17, T2) are
# made by the reconciler on every run (it only warns while they are unseeded); the operator's
# core-roles step grants them once to ADMIN, YK and DK and marks them, the same way as core's resource
# roles. SkyMail's own roles of the code area (ekip-yetkileri ticket 03): skymail:access,
# skymail:templates:read, skymail:lists:read, skymail:mails:read, skymail:mails:send and
# skymail:mails:write to ADMIN and YK, skymail:mails:approve to YK alone (S2), are never created here:
# each is seeded once it exists. The fixture realm has skymail:access and skymail:lists:read (and the
# mailer stage makes skymail:mails:send), /ADMIN and /UYELER/YK, no DK; the core-roles stage's
# operator run (which seeds them) has /UYELER/DK, and removes it after. The stage makes
# skymail:mails:approve later, as SkyMail would, and proves it goes to YK alone. skymail:announcements:send
# left the list (ticket 03, D-1): it is made nowhere and seeded nowhere.

SR_ROLE=skymail:system-mails:read
SR_TRACK_ROLE=skymail:mails:tracking:read
SR_GONE_ROLE=skymail:announcements:send
# SkyMail's own roles the fixture has when the operator seeds (skymail:mails:send from the mailer stage).
SR_OWN_ROLES=(skymail:access skymail:lists:read skymail:mails:send)
SR_ABSENT='skymail:templates:read skymail:mails:read skymail:mails:send skymail:mails:write skymail:mails:approve'
SR_APPROVE_ROLE=skymail:mails:approve
SR_PRIVILEGED=(/ADMIN /UYELER/YK)

# The skymail roles a group holds directly, sorted JSON array.
sr_group_roles() {
  kcadm get "groups/$(cr_group_id "$1")/role-mappings/clients/$(lca_client_uuid skymail)" -r "$V2_REALM" -c \
    | jq -c '[.[].name] | sort'
}

# The value of the seed attribute of a role ("" when absent); $1 defaults to SR_ROLE.
sr_seed_mark() {
  kcadm get "clients/$(lca_client_uuid skymail)/roles" -r "$V2_REALM" -q briefRepresentation=false -c \
    | jq -r --arg r "${1:-$SR_ROLE}" --arg a "$CR_ATTRIBUTE" '.[] | select(.name == $r) | ((.attributes // {})[$a][0] // "")'
}

# The effective skymail roles of a person (groups included), sorted JSON array.
sr_effective_roles() {
  local user_id
  user_id=$(kcadm get users -r "$V2_REALM" -q "username=$1" -q exact=true -c | jq -r '.[0].id')
  kcadm get "users/$user_id/role-mappings/clients/$(lca_client_uuid skymail)/composite" -r "$V2_REALM" -c \
    | jq -c '[.[].name] | sort'
}

# First reconciliation (the reconciler identity): the two reading roles are created with their
# descriptions, SkyMail's own roles are not created, nothing is granted or marked, and the warning
# names the operator step.
stage_skymail_roles_after_first_reconciliation() {
  CURRENT_STAGE='skymail Privileged roles: created by the first reconciliation, not granted'
  local log="$TEST_STATE_DIR/reconcile-first.log" roles path role
  grep -Fq "[reconcile] Privileged roles of skymail (9): created ($SR_ROLE, $SR_TRACK_ROLE); not in the realm, the application makes them, seeded once they exist: $SR_ABSENT" "$log" \
    || fail "the first reconciliation did not create $SR_ROLE and $SR_TRACK_ROLE alone, or did not name SkyMail's absent roles"
  grep -Fq "[reconcile] WARNING: skymail roles not yet granted to the Privileged groups: $SR_ROLE $SR_TRACK_ROLE skymail:access skymail:lists:read" "$log" \
    || fail 'the first reconciliation did not report the unseeded skymail roles'
  roles=$(kcadm get "clients/$(lca_client_uuid skymail)/roles" -r "$V2_REALM" -c)
  json_assert "$roles" '[.[] | select(.name == $r) | .description] == ["Tekil sistem postalarının (doğrulama, bildirim) içeriğini görür (skymail-backend #61)"]' \
    "$SR_ROLE was not created with its description" --arg r "$SR_ROLE"
  json_assert "$roles" '[.[] | select(.name == $r) | (.description | startswith("Her gönderimin kişi bazındaki açılma ve tıklama raporunu görür")) and .composite == false] == [true]' \
    "$SR_TRACK_ROLE was not created with its description or was created as a composite" --arg r "$SR_TRACK_ROLE"
  for role in $SR_ABSENT "$SR_GONE_ROLE"; do
    [[ $role == skymail:mails:send ]] && continue
    json_assert "$roles" '[.[] | select(.name == $r)] | length == 0' "the reconciler created SkyMail's own role $role" --arg r "$role"
  done
  [[ -z $(sr_seed_mark) && -z $(sr_seed_mark "$SR_TRACK_ROLE") && -z $(sr_seed_mark skymail:access) ]] \
    || fail 'the reconciler identity marked a skymail role as seeded'
  for path in "${SR_PRIVILEGED[@]}"; do
    json_assert "$(sr_group_roles "$path")" 'index($r) == null and index($t) == null and index("skymail:access") == null' \
      "the reconciler identity granted a skymail Privileged role to $path" --arg r "$SR_ROLE" --arg t "$SR_TRACK_ROLE"
  done
}

# After stage_core_roles_seeded_by_operator (whose operator runs seeded the roles), before the
# no-op reconciliation (which must then be quiet).
stage_skymail_roles_seeded_by_operator() {
  CURRENT_STAGE='skymail Privileged roles: seeded once by the core-roles operator step'
  local output path skymail_uuid yk_id role want
  skymail_uuid=$(lca_client_uuid skymail)
  [[ $(sr_seed_mark) =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\ /ADMIN,/UYELER/YK,/UYELER/DK$ ]] \
    || fail "$SR_ROLE lacks its seed mark after the operator step (got: $(sr_seed_mark))"
  [[ $(sr_seed_mark "$SR_TRACK_ROLE") =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\ /ADMIN,/UYELER/YK,/UYELER/DK$ ]] \
    || fail "$SR_TRACK_ROLE lacks its seed mark after the operator step (got: $(sr_seed_mark "$SR_TRACK_ROLE"))"
  for role in "${SR_OWN_ROLES[@]}"; do
    [[ $(sr_seed_mark "$role") =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\ /ADMIN,/UYELER/YK$ ]] \
      || fail "$role was not seeded to ADMIN and YK alone (got: $(sr_seed_mark "$role"))"
  done
  [[ -z $(sr_seed_mark "$SR_GONE_ROLE") ]] || fail "$SR_GONE_ROLE was seeded"
  want=$(printf '%s\n' "$SR_ROLE" "$SR_TRACK_ROLE" "${SR_OWN_ROLES[@]}" | jq -R . | jq -sc .)
  for path in "${SR_PRIVILEGED[@]}"; do
    json_assert "$(sr_group_roles "$path")" '. as $held | $want | all(. as $r | $held | index($r) != null)' \
      "$path did not get the skymail code area roles" --argjson want "$want"
  done
  # The YK member holds them through the group (skymail:access also directly); a person outside the
  # Privileged groups does not.
  json_assert "$(sr_effective_roles "$AP_USER")" '. == ($want | sort)' \
    "the YK member's effective skymail roles are wrong" --argjson want "$want"
  json_assert "$(sr_effective_roles "$LCA_USER")" '. as $held | $want | all(. as $r | $held | index($r) == null)' \
    "a person outside the Privileged groups got a skymail Privileged role" --argjson want "$want"

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

  CURRENT_STAGE='skymail Privileged roles: mails:approve goes to YK alone once SkyMail makes it'
  local dk_id
  kcadm create groups -r "$V2_REALM" -s name=DK >/dev/null
  dk_id=$(cr_group_id /DK)
  kcadm create "clients/$skymail_uuid/roles" -r "$V2_REALM" -s "name=$SR_APPROVE_ROLE" >/dev/null
  output=$(cr_operator_reconcile) || { printf '%s\n' "$output" >&2; fail 'the operator step failed'; }
  grep -Fq "[reconcile] skymail role $SR_APPROVE_ROLE: seeded once to /UYELER/YK (granted to: /UYELER/YK)" <<<"$output" \
    || { printf '%s\n' "$output" >&2; fail "$SR_APPROVE_ROLE was not seeded to YK alone once it existed"; }
  ! grep -Fq 'WARNING: no Privileged group' <<<"$output" || { printf '%s\n' "$output" >&2; fail 'seeding mails:approve looked for ADMIN or DK'; }
  json_assert "$(sr_group_roles /ADMIN)" 'index($r) == null' "/ADMIN got $SR_APPROVE_ROLE (YK alone approves)" --arg r "$SR_APPROVE_ROLE"
  json_assert "$(sr_group_roles /DK)" 'length == 0' "/DK got a skymail role"

  CURRENT_STAGE='skymail Privileged roles: mails:tracking:read goes to DK too (a reading role)'
  kcadm update "clients/$skymail_uuid/roles/$SR_TRACK_ROLE" -r "$V2_REALM" -s 'attributes={}' >/dev/null
  output=$(cr_operator_reconcile) || { printf '%s\n' "$output" >&2; fail 'the operator step failed'; }
  grep -F "[reconcile] skymail role $SR_TRACK_ROLE: seeded once to " <<<"$output" | grep -Fq '(granted to: /DK)' \
    || { printf '%s\n' "$output" >&2; fail "the unmarked $SR_TRACK_ROLE was not seeded to /DK (ADMIN and YK already held it)"; }
  [[ $(sr_seed_mark "$SR_TRACK_ROLE") == *,/DK* || $(sr_seed_mark "$SR_TRACK_ROLE") == *\ /DK,* ]] \
    || fail "the seed mark of $SR_TRACK_ROLE does not name /DK: $(sr_seed_mark "$SR_TRACK_ROLE")"
  json_assert "$(sr_group_roles /DK)" '. == [$t]' "/DK does not hold exactly $SR_TRACK_ROLE" --arg t "$SR_TRACK_ROLE"
  kcadm delete "groups/$dk_id" -r "$V2_REALM" >/dev/null
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
