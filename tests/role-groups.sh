#!/usr/bin/env bash
# Real-Keycloak contract for config/role-groups.sh (the application role groups /ROLLER/<APP>-<ROLE>,
# rol-temizligi ticket 05), config/leader-app-roles.sh (SkyCloud on the Leader groups of the top teams,
# ticket 09) and config/app-assignments.sh (the code and panel areas and the one-time initial
# assignment, ekip-yetkileri ticket 03), and for the reconciler's operator steps that run them
# (KEYCLOAK_RECONCILE_ONLY=role-groups, leader-app-roles, app-assignments and tohum-atamalar) and its
# step default-roles (the default role and the identity providers' token settings). Stand-alone: starts the stock Keycloak
# image this repository builds on (the Dockerfile's KEYCLOAK_IMAGE) in dev mode with docker run --rm
# and no volume, copies config/ into the container and runs the scripts there the way an operator
# does; tokens are real password grants of a harness login client.
#
# Fixtures: realm e-skylab with the clients forms, place, skymail, cloudflare-zero-trust and skycloud
# and their roles, the tree /ADMIN, /UYELER/YK (with a task group that has a LIDERLER group), the top teams
# /UYELER/ARGE/AIRLAB (LIDERLER, KOORDINATORLER and a Sub-team with its own LIDERLER) and
# /UYELER/ORGANIZASYON/ARTLAB (no Leader group); a person with a direct client role and a direct realm
# role, and /UYELER holding a realm role. Realm e-skylab-sandbox with forms (only skyforms:access) and
# skymail and nothing else (no skycloud).
#
# What it proves:
#   - every realm but e-skylab and e-skylab-sandbox is refused before a login (exit 2), an invalid
#     role group file too;
#   - role-groups: --check plans /ROLLER and the 15 leaves with their roles and writes nothing;
#     --apply makes exactly that (attributes, one client's roles a leaf, no member); a second --apply
#     writes nothing (no admin event); drift (a role taken away, an attribute changed) is repaired,
#     and what is beyond the file (an extra role on a leaf, a role on /ROLLER, a subgroup, a group
#     the file does not list) is a WARNING and stays; a member of a leaf carries its role in the
#     token; a default group under /ROLLER and a leaf named like a team are PROBLEMs (exit 1); in the
#     sandbox a leaf whose client is missing is skipped with a WARNING (exit 0);
#   - --audit counts direct holders and lists the groups outside the allowed places, and never
#     prints a person's name;
#   - leader-app-roles: only the top teams' LIDERLER and KOORDINATORLER get skycloud:access (not a
#     Sub-team's, not a YK task group's) and no Forms seat any more (the panel's, ekip-yetkileri 03); a
#     Leader group without a _LEADER realm role is a NEW SEAT line with a member count; a second
#     --apply writes nothing; a Leader's token carries SkyCloud and no Forms role; a Sub-team Leader
#     group holding it is a WARNING; in the sandbox the missing skycloud client is skipped with a
#     WARNING;
#   - app-assignments --check: every mapping lands in the code area (KOD|path|client|role|expected|
#     live) or the panel area (PANEL|path|client|role): an app role on a top team or a Sub-team and
#     on a person is the panel's and no drift; an admin role on a team, an app role on an area and a
#     realm role outside the Privileged roots are PROBLEMs; the role groups' and the Leader groups'
#     code area roles are as expected; through the reconciler's step the Privileged roots' own
#     expectations come in (present and missing); nothing is written and no person is named;
#   - its drift summary (ekip-yetkileri ticket 07): each drift is one SAPMA line of its class (S1 a
#     person's admin role, S1-realm a person's realm role, S2-eksik, S2-fazla, S2b an admin role on a
#     team or a Leader group, S5 a top team without a Leader), panel assignments and pending or
#     temporary roles none; with KEYCLOAK_APP_ASSIGNMENTS_ALARM=true the step exits 1 on drift,
#     --alarm without --privileged-file is refused (exit 2) and a failed read is exit 2;
#   - the nightly alarm's run (config/app-assignments-alarm.sh) on the sandbox, seeded and every top
#     team with a Leader: no drift (exit 0, alarm=0); a seeded role taken from or given to a root of
#     its own seed set (/<NAME>, /UYELER/<NAME> or a sub-group) in the panel is a BILGI line
#     (S2-tohum), never counted; given to a Privileged root or its sub-group outside its seed set, or
#     a role no seed covers there, it is S2-fazla (exit 1); a seeded DK write role on DK is S2-fazla, a
#     seeded read role on DK's sub-group BILGI; a reconciler that stops before the check prints no
#     summary: exit 2;
#   - app-assignments --seed: a dry run plans exactly the missing initial assignments (every top
#     team's Forms seat, the Leader groups' and ALGOLAB's SkyMail pair) with enabled member counts and
#     writes nothing; the reconciler's step tohum-atamalar applies them with a 0600 backup and marks
#     the realm; a second dry run plans nothing and a second --apply is refused; --restore takes
#     exactly the backup's assignments away and clears the mark; a missing target, a Privileged
#     target and a default group under a target are PROBLEMs (exit 1, nothing written); a failed
#     read stops it;
#   - default-roles: the dry run names broker/read-token in the default role, broker/read-token
#     inside the realm role USER the default role holds (production's shape, 2026-10-23) and an
#     identity provider's Stored tokens readable as changes, USER itself and Store tokens as WARNINGs,
#     an account console role as Keycloak's own and the direct holder as a count, and writes nothing;
#     the step takes read-token out of both and turns the setting off, leaves USER in the default role
#     and Store tokens and the direct holder alone; a second dry run plans nothing;
#   - a failed group read (injected) stops the scripts with exit 1 and writes nothing;
#   - the reconciler's operator steps run the scripts (dry run with KEYCLOAK_RECONCILE_CHECK=true)
#     and refuse to run without an operator session;
#   - SkyCloud's admin (Yusuf, 2026-10-24: the SkyCloud administrators are /ADMIN and /UYELER/YK): the
#     audit's K4 allows it on both, app-assignments --check expects it there (and skycloud:access
#     nowhere on them), and the core-roles step seeds it once (dry run first, a group that holds it
#     is left alone), marks it, creates no skycloud role; a YK sub-group's member carries it; a realm
#     without the client skycloud is skipped with a WARNING;
#   - the admin panel's inscribed roles (ADR-0056: News is written in the panel; grup-yonetimi GY1: DK
#     reads and does not write): app-assignments --check expects the panel client's content:read on
#     ADMIN, YK and DK and its content:write on ADMIN and YK, never DK's content:write; the core-roles
#     step seeds them once (dry run first, a group that holds a role is left alone), marks them,
#     creates no role of the panel client; a YK member's token carries both, a DK member's
#     content:read alone; a second run seeds nothing; in the sandbox the panel client is superadmin,
#     and a panel client without the roles is a "not in the realm" line, nothing seeded.
# Requirements on the host: docker, curl, jq. ROLE_GROUPS_TEST_PORT (default 18096),
# ROLE_GROUPS_TEST_CONTAINER (default role-groups-test-<pid>).
# shellcheck disable=SC2016  # jq programs name jq variables
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=kcadm-jvm.sh
source "$SCRIPT_DIR/kcadm-jvm.sh"
# shellcheck source=kcadm-rest.sh
source "$SCRIPT_DIR/kcadm-rest.sh"
REPOSITORY_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
IMAGE=$(sed -n 's/^ARG KEYCLOAK_IMAGE=//p' "$REPOSITORY_ROOT/Dockerfile")
PORT=${ROLE_GROUPS_TEST_PORT:-18096}
BASE_URL="http://127.0.0.1:$PORT"
CONTAINER=${ROLE_GROUPS_TEST_CONTAINER:-role-groups-test-$$}
ADMIN_PASSWORD=harness-admin-password
PEOPLE_PASSWORD=harness-people-password-1
KCADM_CONFIG=/tmp/harness-kcadm.config
IN_CONTAINER_CONFIG=/tmp/config
REALM=e-skylab
SANDBOX=e-skylab-sandbox
LEAVES=(FORMS-ACCESS FORMS-ALL PLACE-ADMIN PLACE-MODERATOR SKYMAIL-ACCESS SKYMAIL-TEMPLATES-READ
  SKYMAIL-TEMPLATES-WRITE SKYMAIL-LISTS-READ SKYMAIL-LISTS-WRITE SKYMAIL-MAILS-READ SKYMAIL-MAILS-WRITE
  SKYMAIL-MAILS-APPROVE CF-ZERO-TRUST-ACCESS SKYCLOUD-ACCESS SKYCLOUD-ADMIN)
LEADER_ROLES='["skycloud/skycloud:access"]'
CURRENT_STAGE=startup

fail() {
  printf 'role-groups failure during %s: %s\n' "$CURRENT_STAGE" "$1" >&2
  exit 1
}
cleanup() {
  kcadm_rest_cleanup
  docker rm -fv "$CONTAINER" >/dev/null 2>&1 || true
}
trap 'status=$?; trap - EXIT; cleanup; exit "$status"' EXIT
on_error() {
  local status=$?
  printf 'role-groups command failed during %s (line %s)\n' "$CURRENT_STAGE" "$1" >&2
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

# run SCRIPT REALM ARGS...: an operator script inside the container with the harness's kcadm session.
run() {
  local script=$1 realm=$2
  shift 2
  docker exec -e KEYCLOAK_ADMIN_URL=http://localhost:8080 -e KEYCLOAK_REALM="$realm" "$CONTAINER" \
    bash "$IN_CONTAINER_CONFIG/$script" --kcadm-config "$KCADM_CONFIG" "$@" 2>&1
}

# run_expecting STATUS SCRIPT REALM ARGS...: run for a run that must exit STATUS; prints the output.
run_expecting() {
  local wanted=$1 output status=0
  shift
  trap - ERR
  output=$(run "$@") || status=$?
  trap 'on_error "$LINENO"' ERR
  [[ $status == "$wanted" ]] || { printf '%s\n' "$output" >&2; fail "$1 did not exit $wanted (exit $status)"; }
  printf '%s\n' "$output"
}

# reconcile_step STATUS STEP ARGS...: the reconciler's operator step (extra docker exec -e options).
reconcile_step() {
  local wanted=$1 step=$2 output status=0
  shift 2
  trap - ERR
  output=$(docker exec -e KEYCLOAK_ADMIN_URL=http://localhost:8080 -e KEYCLOAK_REALM=$REALM \
    -e "KEYCLOAK_RECONCILE_ONLY=$step" "$@" "$CONTAINER" bash "$IN_CONTAINER_CONFIG/reconcile-account-center.sh" 2>&1) \
    || status=$?
  trap 'on_error "$LINENO"' ERR
  [[ $status == "$wanted" ]] || { printf '%s\n' "$output" >&2; fail "the reconciler step $step did not exit $wanted (exit $status)"; }
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

group_id() { # group_id REALM PATH
  kcadm get "group-by-path$2" -r "$1" | jq -r .id
}

# group_exists REALM PATH
group_exists() {
  kcadm get "group-by-path$2" -r "$1" >/dev/null 2>&1
}

# group_roles REALM PATH: the group's direct role mappings as sorted "client/role" (realm/role).
group_roles() {
  kcadm get "groups/$(group_id "$1" "$2")/role-mappings" -r "$1" \
    | jq -c '[(.realmMappings // [])[] | "realm/" + .name] + [(.clientMappings // {}) | to_entries[] | .key as $c | .value.mappings[] | $c + "/" + .name] | sort'
}

# create_group REALM PARENT_PATH NAME (PARENT_PATH empty for a top-level group)
create_group() {
  if [[ -z $2 ]]; then
    kcadm create groups -r "$1" -s "name=$3" >/dev/null
  else
    kcadm create "groups/$(group_id "$1" "$2")/children" -r "$1" -s "name=$3" >/dev/null
  fi
}

role_body() { # role_body REALM CLIENT ROLE
  kcadm get "clients/$(client_uuid "$1" "$2")/roles/$3" -r "$1" | jq -c '[{id, name}]'
}

events() { # events REALM: the number of admin events so far
  kcadm get admin-events -r "$1" -q max=100000 | jq length
}

# make_person REALM USERNAME [GROUP_PATH]: an enabled person with a full profile and a password.
make_person() {
  kcadm create users -r "$1" -s "username=$2" -s enabled=true -s "email=$2@example.test" -s emailVerified=true \
    -s firstName=Harness -s lastName=Person >/dev/null
  kcadm set-password -r "$1" --username "$2" --new-password "$PEOPLE_PASSWORD" >/dev/null
  if [[ -n ${3:-} ]]; then
    local user_id
    user_id=$(kcadm get users -r "$1" -q "username=$2" -q exact=true | jq -r '.[0].id')
    kcadm update "users/$user_id/groups/$(group_id "$1" "$3")" -r "$1" -n -b '{}' >/dev/null
  fi
}

# token_roles REALM USERNAME CLIENT: the CLIENT roles of the person's access token, sorted JSON array.
token_roles() {
  local token segment
  token=$(curl -fsS "$BASE_URL/realms/$1/protocol/openid-connect/token" \
    --data-urlencode grant_type=password --data-urlencode client_id=harness-login \
    --data-urlencode "username=$2" --data-urlencode "password=$PEOPLE_PASSWORD" | jq -r .access_token)
  segment=$(cut -d. -f2 <<<"$token" | tr '_-' '/+')
  case $(( ${#segment} % 4 )) in 2) segment+='==' ;; 3) segment+='=' ;; esac
  base64 -d <<<"$segment" | jq -c --arg c "$3" '(.resource_access[$c].roles // []) | sort'
}

# make_fixture REALM FULL: the clients and the tree (FULL=yes: production's shape; no: the sandbox's).
make_fixture() {
  local realm=$1 full=$2 client role
  kcadm create realms -s realm="$realm" -s enabled=true -s adminEventsEnabled=true >/dev/null
  kcadm create clients -r "$realm" -s clientId=harness-login -s publicClient=true -s standardFlowEnabled=false \
    -s directAccessGrantsEnabled=true >/dev/null
  kcadm create clients -r "$realm" -s clientId=forms -s publicClient=false -s standardFlowEnabled=false \
    -s serviceAccountsEnabled=true >/dev/null
  kcadm create clients -r "$realm" -s clientId=skymail -s publicClient=true >/dev/null
  if [[ $full == yes ]]; then
    for role in skyforms:access 'skyforms:*' skyforms:form:manage skyforms:response:manage skyforms:feedback:manage; do
      kcadm create "clients/$(client_uuid "$realm" forms)/roles" -r "$realm" -s "name=$role" >/dev/null
    done
    kcadm create clients -r "$realm" -s clientId=place -s publicClient=false >/dev/null
    for role in place:admin place:moderator; do
      kcadm create "clients/$(client_uuid "$realm" place)/roles" -r "$realm" -s "name=$role" >/dev/null
    done
    kcadm create clients -r "$realm" -s clientId=cloudflare-zero-trust -s publicClient=false >/dev/null
    kcadm create "clients/$(client_uuid "$realm" cloudflare-zero-trust)/roles" -r "$realm" \
      -s name=cloudflare:zero-trust:access >/dev/null
    kcadm create clients -r "$realm" -s clientId=skycloud -s publicClient=false >/dev/null
    for role in skycloud:access admin; do
      kcadm create "clients/$(client_uuid "$realm" skycloud)/roles" -r "$realm" -s "name=$role" >/dev/null
    done
  else
    kcadm create "clients/$(client_uuid "$realm" forms)/roles" -r "$realm" -s name=skyforms:access >/dev/null
  fi
  for role in skymail:access skymail:templates:read skymail:templates:write skymail:lists:read skymail:lists:write \
    skymail:mails:read skymail:mails:write skymail:mails:approve; do
    kcadm create "clients/$(client_uuid "$realm" skymail)/roles" -r "$realm" -s "name=$role" >/dev/null
  done
  create_group "$realm" '' ADMIN
  create_group "$realm" '' UYELER
  create_group "$realm" /UYELER YK
  create_group "$realm" /UYELER/YK BASKAN
  create_group "$realm" /UYELER/YK/BASKAN LIDERLER
  create_group "$realm" /UYELER ARGE
  create_group "$realm" /UYELER/ARGE AIRLAB
  create_group "$realm" /UYELER/ARGE/AIRLAB LIDERLER
  create_group "$realm" /UYELER/ARGE/AIRLAB KOORDINATORLER
  create_group "$realm" /UYELER/ARGE/AIRLAB SUB
  create_group "$realm" /UYELER/ARGE/AIRLAB/SUB LIDERLER
  create_group "$realm" /UYELER ORGANIZASYON
  create_group "$realm" /UYELER/ORGANIZASYON ARTLAB
}

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='Keycloak start'
[[ -n $IMAGE ]] || fail 'Dockerfile has no ARG KEYCLOAK_IMAGE'
for tool in jq curl; do command -v "$tool" >/dev/null || fail "$tool is required"; done
jq -e '.groups | length == 15' "$REPOSITORY_ROOT/config/role-groups.json" >/dev/null \
  || fail 'config/role-groups.json does not list the 15 role groups (ticket 05 and SkyCloud)'
# Static rules of the file (the script enforces them too): the team code name rule, one client a
# leaf, no leaf name containing a team code of the club.
jq -e '[.groups[].name] | all(test("^[A-Z][A-Z0-9-]{1,23}$")) and (unique | length == 15)' \
  "$REPOSITORY_ROOT/config/role-groups.json" >/dev/null || fail 'a role group name breaks the team code rule'
jq -e '.groups | all((.client | type) == "string" and (.roles | length) > 0)' \
  "$REPOSITORY_ROOT/config/role-groups.json" >/dev/null || fail 'a role group does not name exactly one client'
for code in AIRLAB ALGOLAB BIZBIZE GECEKODU MOBILAB SKYDEVOPS SKYSEC WEBLAB CHAINLAB GAMELAB SKYSIS ARTLAB \
  YILDIZJAM SKYDAYS AGC; do
  jq -e --arg c "$code" '[.groups[].name] | all(contains($c) | not)' "$REPOSITORY_ROOT/config/role-groups.json" >/dev/null \
    || fail "a role group name contains the team code $code"
done
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
docker exec -i "$CONTAINER" sh -c 'cat > /tmp/kcadm-fail.sh && chmod 755 /tmp/kcadm-fail.sh' \
  <"$SCRIPT_DIR/kcadm-core-roles-failure.sh"

# run_failing_read SCRIPT REALM READ ARGS...: the script with every kcadm read whose arguments contain
# READ failing as a dropped connection would (nothing says "not found"); prints the output, which must
# end in exit 1.
run_failing_read() {
  local script=$1 realm=$2 read=$3 output status=0
  shift 3
  trap - ERR
  output=$(docker exec -e KEYCLOAK_ADMIN_URL=http://localhost:8080 -e KEYCLOAK_REALM="$realm" \
    -e KCADM_BIN=/tmp/kcadm-fail.sh -e "KCADM_INJECT_FAIL=$read" "$CONTAINER" \
    bash "$IN_CONTAINER_CONFIG/$script" --kcadm-config "$KCADM_CONFIG" "$@" 2>&1) || status=$?
  trap 'on_error "$LINENO"' ERR
  [[ $status == 1 ]] || { printf '%s\n' "$output" >&2; fail "$script did not exit 1 when reading $read failed (exit $status)"; }
  printf '%s\n' "$output"
}

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='refused realms and an invalid file'
for script in role-groups.sh leader-app-roles.sh app-assignments.sh; do
  refused=$(run_expecting 2 "$script" master --apply)
  expect_line "$refused" 'refusing realm master' "$script did not refuse master"
  reject_line "$refused" 'realm=' "$script went on in master"
done
printf '{"root":"ROLLER","root_display_name_tr":"a","root_description_tr":"b","groups":[{"name":"FORMS-ACCESS","client":"forms","roles":["skyforms:access"],"display_name_tr":"x","description_tr":"y"},{"name":"FORMS-ACCESS","client":"forms","roles":["skyforms:*"],"display_name_tr":"x","description_tr":"y"}]}\n' \
  | docker exec -i "$CONTAINER" sh -c 'cat > /tmp/bad-role-groups.json'
trap - ERR
bad=$(docker exec -e KEYCLOAK_REALM=$REALM -e KEYCLOAK_ROLE_GROUPS_FILE=/tmp/bad-role-groups.json "$CONTAINER" \
  bash "$IN_CONTAINER_CONFIG/role-groups.sh" --kcadm-config "$KCADM_CONFIG" --apply 2>&1) && status=0 || status=$?
trap 'on_error "$LINENO"' ERR
[[ $status == 2 ]] || { printf '%s\n' "$bad" >&2; fail "a role group file with a name twice was not refused (exit $status)"; }
expect_line "$bad" 'is not a valid role group file; nothing was read or changed' 'the invalid file was not reported'
printf '    master refused (exit 2) by both scripts; a file with a name twice refused (exit 2)\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='fixtures'
make_fixture "$REALM" yes
make_fixture "$SANDBOX" no
make_person "$REALM" leader-person /UYELER/ARGE/AIRLAB/LIDERLER
make_person "$REALM" sub-leader-person /UYELER/ARGE/AIRLAB/SUB/LIDERLER
make_person "$REALM" role-group-person
make_person "$REALM" direct-person
kcadm create roles -r "$REALM" -s name=USER >/dev/null
kcadm add-roles -r "$REALM" --uusername direct-person --cclientid skymail --rolename skymail:mails:write >/dev/null
kcadm add-roles -r "$REALM" --uusername direct-person --cclientid forms --rolename skyforms:access >/dev/null
kcadm add-roles -r "$REALM" --uusername direct-person --rolename USER >/dev/null
kcadm add-roles -r "$REALM" --gpath /UYELER --rolename USER >/dev/null
[[ $(token_roles "$REALM" leader-person forms) == '[]' ]] || fail 'the Leader already holds a forms role'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='role-groups: the dry run plans and writes nothing'
before=$(events "$REALM")
checked=$(run_expecting 0 role-groups.sh "$REALM")
expect_line "$checked" 'would create the group /ROLLER (no role, no member)' 'the root was not planned'
for leaf in "${LEAVES[@]}"; do
  expect_line "$checked" "would create the role group /ROLLER/$leaf (" "the leaf $leaf was not planned"
done
expect_line "$checked" 'would map forms/skyforms:access to /ROLLER/FORMS-ACCESS' 'a mapping was not planned'
expect_line "$checked" 'would map cloudflare-zero-trust/cloudflare:zero-trust:access to /ROLLER/CF-ZERO-TRUST-ACCESS' 'a mapping was not planned'
expect_line "$checked" 'check: 31 change(s) pending, 0 warning(s), 0 problem(s)' 'the dry run did not count 1 + 15 + 15 changes'
! group_exists "$REALM" /ROLLER || fail 'the dry run created /ROLLER'
[[ $(events "$REALM") == "$before" ]] || fail 'the dry run wrote something'
printf '    --check plans /ROLLER, 15 leaves and 15 mappings and writes nothing\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='role-groups: applied, then nothing more'
applied=$(run_expecting 0 role-groups.sh "$REALM" --apply)
expect_line "$applied" 'applied 31 change(s), 0 warning(s), 0 problem(s)' 'the apply did not make the planned changes'
[[ $(group_roles "$REALM" /ROLLER) == '[]' ]] || fail '/ROLLER holds a role'
root=$(kcadm get "groups/$(group_id "$REALM" /ROLLER)" -r "$REALM")
jq -e '.attributes.display_name_tr == ["Rol grupları"] and (.attributes.description_tr[0] | length) > 20' <<<"$root" >/dev/null \
  || fail "/ROLLER lacks its attributes: $root"
[[ $(kcadm get "groups/$(group_id "$REALM" /ROLLER)/children" -r "$REALM" -q max=100 | jq -c '[.[].name] | sort') \
  == "$(printf '%s\n' "${LEAVES[@]}" | jq -R . | jq -sc 'sort')" ]] || fail '/ROLLER does not hold exactly the 15 leaves'
while IFS=$'\t' read -r name client roles; do
  want=$(jq -nc --arg c "$client" --arg r "$roles" '[$r | split(" ")[] | $c + "/" + .] | sort')
  [[ $(group_roles "$REALM" "/ROLLER/$name") == "$want" ]] || fail "/ROLLER/$name does not hold exactly $want: $(group_roles "$REALM" "/ROLLER/$name")"
  [[ $(kcadm get "groups/$(group_id "$REALM" "/ROLLER/$name")/members" -r "$REALM" | jq length) == 0 ]] \
    || fail "/ROLLER/$name has a member"
  jq -e '(.attributes.display_name_tr | length) == 1 and (.attributes.description_tr | length) == 1' \
    <<<"$(kcadm get "groups/$(group_id "$REALM" "/ROLLER/$name")" -r "$REALM")" >/dev/null \
    || fail "/ROLLER/$name lacks its attributes"
done < <(jq -r '.groups[] | [.name, .client, (.roles | join(" "))] | @tsv' "$REPOSITORY_ROOT/config/role-groups.json")
before=$(events "$REALM")
again=$(run_expecting 0 role-groups.sh "$REALM" --apply)
expect_line "$again" 'applied 0 change(s), 0 warning(s), 0 problem(s)' 'the second apply changed something'
expect_line "$again" '/ROLLER: unchanged' 'the second apply did not verify the root'
[[ $(events "$REALM") == "$before" ]] || fail 'the second apply wrote something'
printf '    --apply made /ROLLER and the 15 leaves (attributes, roles, no member); a second --apply writes nothing\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='role-groups: a member carries the role'
[[ $(token_roles "$REALM" role-group-person skymail) == '[]' ]] || fail 'the person holds a skymail role before joining'
person_id=$(kcadm get users -r "$REALM" -q username=role-group-person -q exact=true | jq -r '.[0].id')
kcadm update "users/$person_id/groups/$(group_id "$REALM" /ROLLER/SKYMAIL-ACCESS)" -r "$REALM" -n -b '{}' >/dev/null
[[ $(token_roles "$REALM" role-group-person skymail) == '["skymail:access"]' ]] \
  || fail "a member of /ROLLER/SKYMAIL-ACCESS does not carry exactly skymail:access: $(token_roles "$REALM" role-group-person skymail)"
printf '    a member of /ROLLER/SKYMAIL-ACCESS carries skymail:access in the token\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='role-groups: drift repaired, the rest reported and kept'
forms_access=$(group_id "$REALM" /ROLLER/FORMS-ACCESS)
kcadm delete "groups/$forms_access/role-mappings/clients/$(client_uuid "$REALM" forms)" -r "$REALM" \
  -b "$(role_body "$REALM" forms skyforms:access)" >/dev/null
kcadm create "groups/$forms_access/role-mappings/clients/$(client_uuid "$REALM" skymail)" -r "$REALM" \
  -b "$(role_body "$REALM" skymail skymail:access)" >/dev/null
kcadm update "groups/$(group_id "$REALM" /ROLLER/PLACE-ADMIN)" -r "$REALM" -s 'attributes.display_name_tr=["eski"]' >/dev/null
create_group "$REALM" /ROLLER/SKYMAIL-ACCESS NESTED
create_group "$REALM" /ROLLER OTHER
kcadm add-roles -r "$REALM" --gpath /ROLLER --rolename USER >/dev/null
checked=$(run_expecting 0 role-groups.sh "$REALM")
expect_line "$checked" 'would map forms/skyforms:access to /ROLLER/FORMS-ACCESS' 'the taken role was not planned back'
expect_line "$checked" 'would write display_name_tr and description_tr of /ROLLER/PLACE-ADMIN' 'the changed attribute was not planned back'
expect_line "$checked" 'WARNING: /ROLLER/FORMS-ACCESS also holds skymail/skymail:access' 'the extra role was not reported'
expect_line "$checked" 'WARNING: /ROLLER/SKYMAIL-ACCESS has 1 subgroup(s)' 'the subgroup was not reported'
expect_line "$checked" 'WARNING: /ROLLER/OTHER is not in role-groups.json; left as it is' 'the unlisted group was not reported'
expect_line "$checked" 'WARNING: /ROLLER itself holds roles (realm/USER)' 'the role on the root was not reported'
expect_line "$checked" 'check: 2 change(s) pending, 4 warning(s), 0 problem(s)' 'the drift was not counted'
applied=$(run_expecting 0 role-groups.sh "$REALM" --apply)
expect_line "$applied" 'applied 2 change(s), 4 warning(s), 0 problem(s)' 'the drift was not repaired'
[[ $(group_roles "$REALM" /ROLLER/FORMS-ACCESS) == '["forms/skyforms:access","skymail/skymail:access"]' ]] \
  || fail "the repair took the extra role away or did not map the listed one: $(group_roles "$REALM" /ROLLER/FORMS-ACCESS)"
group_exists "$REALM" /ROLLER/SKYMAIL-ACCESS/NESTED || fail 'the subgroup was removed'
group_exists "$REALM" /ROLLER/OTHER || fail 'the unlisted group was removed'
[[ $(group_roles "$REALM" /ROLLER) == '["realm/USER"]' ]] || fail 'the role on the root was taken away'
[[ $(kcadm get "groups/$(group_id "$REALM" /ROLLER/SKYMAIL-ACCESS)/members" -r "$REALM" | jq -r '[.[].username] | join(",")') == role-group-person ]] \
  || fail 'the run changed the members of a role group'
kcadm delete "groups/$forms_access/role-mappings/clients/$(client_uuid "$REALM" skymail)" -r "$REALM" \
  -b "$(role_body "$REALM" skymail skymail:access)" >/dev/null
kcadm delete "groups/$(group_id "$REALM" /ROLLER/SKYMAIL-ACCESS/NESTED)" -r "$REALM" >/dev/null
kcadm delete "groups/$(group_id "$REALM" /ROLLER/OTHER)" -r "$REALM" >/dev/null
kcadm remove-roles -r "$REALM" --gpath /ROLLER --rolename USER >/dev/null
printf '    drift repaired (a mapping, an attribute); extra role, subgroup, unlisted group and root role reported and kept\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='role-groups: the audit counts, it names nobody'
# core's RolePlacement refuses a role on a Privileged root's subgroup (a YK duty group) and on a role
# group with groups under it: the audit lists both, next to /UYELER.
create_group "$REALM" /ROLLER/SKYMAIL-ACCESS NESTED
kcadm create "groups/$(group_id "$REALM" /UYELER/YK/BASKAN)/role-mappings/clients/$(client_uuid "$REALM" skymail)" -r "$REALM" \
  -b "$(role_body "$REALM" skymail skymail:access)" >/dev/null
# A top team's Leader group holds admin roles by name only: skycloud:access (every top team) and a
# site's cms:access for that site's own teams (AIRLAB is ArtLab's lab team, not YıldızJam's).
for site in frontend-artlab frontend-yildizjam; do
  kcadm create clients -r "$REALM" -s "clientId=$site" -s publicClient=true >/dev/null
  kcadm create "clients/$(client_uuid "$REALM" "$site")/roles" -r "$REALM" -s name=cms:access >/dev/null
  kcadm create "groups/$(group_id "$REALM" /UYELER/ARGE/AIRLAB/LIDERLER)/role-mappings/clients/$(client_uuid "$REALM" "$site")" \
    -r "$REALM" -b "$(role_body "$REALM" "$site" cms:access)" >/dev/null
done
kcadm create "groups/$(group_id "$REALM" /UYELER/ARGE/AIRLAB/KOORDINATORLER)/role-mappings/clients/$(client_uuid "$REALM" skycloud)" \
  -r "$REALM" -b "$(role_body "$REALM" skycloud skycloud:access)" >/dev/null
# SkyCloud's admin on the Privileged roots ADMIN and YK (Yusuf, 2026-10-24; the core-roles step seeds
# it): an allowed place.
for path in /ADMIN /UYELER/YK; do
  kcadm create "groups/$(group_id "$REALM" "$path")/role-mappings/clients/$(client_uuid "$REALM" skycloud)" \
    -r "$REALM" -b "$(role_body "$REALM" skycloud admin)" >/dev/null
done
audited=$(run_expecting 0 role-groups.sh "$REALM" --audit)
expect_line "$audited" 'audit: skymail/skymail:mails:write: 1 person(s) directly; groups: /ROLLER/SKYMAIL-MAILS-WRITE' 'the per-role count is wrong'
expect_line "$audited" 'audit K1: 1 person(s) hold admin or unclassified client roles directly, 1 person(s) hold realm roles directly' 'K1 is wrong'
expect_line "$audited" 'audit K1: 1 person(s) hold app roles directly (panel assignments' 'K1 did not count the app role apart'
expect_line "$audited" 'audit K4: 4 group(s) hold roles outside the allowed places:' 'K4 is wrong'
expect_line "$audited" 'audit K4:   /UYELER: realm/USER' 'K4 did not name /UYELER'
expect_line "$audited" 'audit K4:   /ROLLER/SKYMAIL-ACCESS: skymail/skymail:access' 'K4 did not name the role group with a subgroup'
expect_line "$audited" 'audit K4:   /UYELER/YK/BASKAN: skymail/skymail:access' 'K4 did not name the YK duty group'
expect_line "$audited" 'audit K4:   /UYELER/ARGE/AIRLAB/LIDERLER: frontend-yildizjam/cms:access' 'K4 did not name another site'"'"'s cms:access'
reject_line "$audited" 'audit K4:   /ROLLER/SKYMAIL-MAILS' 'K4 reported a leaf role group'
reject_line "$audited" 'audit K4:   /UYELER/ARGE/AIRLAB/KOORDINATORLER' 'K4 reported skycloud:access on a top team Leader group'
reject_line "$audited" 'audit K4:   /ADMIN' 'K4 reported SkyCloud'"'"'s admin on ADMIN'
reject_line "$audited" 'audit K4:   /UYELER/YK:' 'K4 reported SkyCloud'"'"'s admin on YK'
grep -F 'audit: skycloud/admin: ' <<<"$audited" | grep -F '/ADMIN' | grep -Fq '/UYELER/YK' \
  || { printf '%s\n' "$audited" >&2; fail 'the audit did not read SkyCloud'"'"'s admin on ADMIN and YK'; }
for path in /ADMIN /UYELER/YK; do
  kcadm delete "groups/$(group_id "$REALM" "$path")/role-mappings/clients/$(client_uuid "$REALM" skycloud)" \
    -r "$REALM" -b "$(role_body "$REALM" skycloud admin)" >/dev/null
done
kcadm delete "groups/$(group_id "$REALM" /ROLLER/SKYMAIL-ACCESS/NESTED)" -r "$REALM" >/dev/null
kcadm delete "groups/$(group_id "$REALM" /UYELER/YK/BASKAN)/role-mappings/clients/$(client_uuid "$REALM" skymail)" -r "$REALM" \
  -b "$(role_body "$REALM" skymail skymail:access)" >/dev/null
for site in frontend-artlab frontend-yildizjam; do
  kcadm delete "clients/$(client_uuid "$REALM" "$site")" -r "$REALM" >/dev/null
done
kcadm delete "groups/$(group_id "$REALM" /UYELER/ARGE/AIRLAB/KOORDINATORLER)/role-mappings/clients/$(client_uuid "$REALM" skycloud)" \
  -r "$REALM" -b "$(role_body "$REALM" skycloud skycloud:access)" >/dev/null
for name in direct-person leader-person role-group-person sub-leader-person; do
  reject_line "$audited" "$name" 'the audit printed a person'
done
printf '    --audit: per-role counts, K1 and K4 (core'"'"'s placement rule) without a name\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='role-groups: a default group under /ROLLER and a team-like name are refused'
mail_access=$(group_id "$REALM" /ROLLER/SKYMAIL-ACCESS)
kcadm update "realms/$REALM/default-groups/$mail_access" -n -b '{}' >/dev/null
before=$(events "$REALM")
refused=$(run_expecting 1 role-groups.sh "$REALM" --apply)
expect_line "$refused" 'PROBLEM: the default group /ROLLER/SKYMAIL-ACCESS is at or under /ROLLER' 'the default group was not refused'
[[ $(events "$REALM") == "$before" ]] || fail 'the run wrote something next to a default group under /ROLLER'
kcadm delete "realms/$REALM/default-groups/$mail_access" >/dev/null
create_group "$REALM" /UYELER/ARGE LISTS
create_group "$REALM" /UYELER/ARGE/AIRLAB MAILS
refused=$(run_expecting 1 role-groups.sh "$REALM")
expect_line "$refused" 'PROBLEM: /ROLLER/SKYMAIL-LISTS-READ: the name contains the team code LISTS' 'a leaf named like a top team was not refused'
expect_line "$refused" 'PROBLEM: /ROLLER/SKYMAIL-MAILS-READ: the name contains the team code MAILS' 'a leaf named like a Sub-team was not refused'
reject_line "$refused" 'the team code LIDERLER' 'a Leader group was taken for a team code'
kcadm delete "groups/$(group_id "$REALM" /UYELER/ARGE/LISTS)" -r "$REALM" >/dev/null
kcadm delete "groups/$(group_id "$REALM" /UYELER/ARGE/AIRLAB/MAILS)" -r "$REALM" >/dev/null
printf '    a default group under /ROLLER and a leaf named like a top team or a Sub-team are PROBLEMs (exit 1)\n'

CURRENT_STAGE='role-groups: a failed group read stops the run'
before=$(events "$REALM")
failed=$(run_failing_read role-groups.sh "$REALM" group-by-path/ROLLER --apply)
expect_line "$failed" '[role-groups] the group /ROLLER could not be read in realm e-skylab; stopped' 'the failed read was not reported'
reject_line "$failed" 'applied' 'the run went on after a failed read'
[[ $(events "$REALM") == "$before" ]] || fail 'the run wrote something after a failed read'
printf '    a failed read of /ROLLER stops role-groups.sh (exit 1), nothing written\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='role-groups: the sandbox skips the leaves of missing clients'
applied=$(run_expecting 0 role-groups.sh "$SANDBOX" --apply)
for leaf in PLACE-ADMIN PLACE-MODERATOR; do
  expect_line "$applied" "WARNING: /ROLLER/$leaf: the client place does not exist in realm $SANDBOX; skipped (not created)" "$leaf was not skipped"
done
expect_line "$applied" "WARNING: /ROLLER/FORMS-ALL: the role forms/skyforms:* does not exist in realm $SANDBOX; skipped (not created)" 'FORMS-ALL was not skipped'
expect_line "$applied" "WARNING: /ROLLER/CF-ZERO-TRUST-ACCESS: the client cloudflare-zero-trust does not exist in realm $SANDBOX" 'CF was not skipped'
expect_line "$applied" "WARNING: /ROLLER/SKYCLOUD-ADMIN: the client skycloud does not exist in realm $SANDBOX" 'SKYCLOUD-ADMIN was not skipped'
expect_line "$applied" 'applied 19 change(s), 6 warning(s), 0 problem(s)' 'the sandbox apply did not make the 9 leaves'
! group_exists "$SANDBOX" /ROLLER/PLACE-ADMIN || fail 'a leaf without its client was created'
# A leaf whose role is missing (as SKYCLOUD-ADMIN would be if production's role were not named admin)
# is only a WARNING: not created, nothing mapped, the run goes on.
! group_exists "$SANDBOX" /ROLLER/FORMS-ALL || fail 'a leaf without its role was created'
[[ $(group_roles "$SANDBOX" /ROLLER/FORMS-ACCESS) == '["forms/skyforms:access"]' ]] || fail 'the sandbox FORMS-ACCESS is wrong'
printf '    sandbox: 9 leaves made, 6 skipped with a WARNING (exit 0)\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='leader-app-roles: only the top teams Leader groups'
# KOORDINATORLER holds the Java era's AIRLAB_LEADER (its members already have the seat through the
# composite); LIDERLER does not: its member gets the roles newly, in a NEW SEAT line.
kcadm create roles -r "$REALM" -s name=AIRLAB_LEADER >/dev/null
# (by id: kcadm add-roles --gpath finds no exact match for a nested path)
kcadm create "groups/$(group_id "$REALM" /UYELER/ARGE/AIRLAB/KOORDINATORLER)/role-mappings/realm" -r "$REALM" \
  -b "$(kcadm get roles/AIRLAB_LEADER -r "$REALM" | jq -c '[{id, name}]')" >/dev/null
before=$(events "$REALM")
checked=$(run_expecting 0 leader-app-roles.sh "$REALM")
expect_line "$checked" 'Leader groups of the top teams: 2' 'the top teams were not read from the tree'
for path in /UYELER/ARGE/AIRLAB/LIDERLER /UYELER/ARGE/AIRLAB/KOORDINATORLER; do
  expect_line "$checked" "would grant skycloud/skycloud:access to the group $path" "SkyCloud was not planned for $path"
done
reject_line "$checked" 'forms/skyforms:access' 'the Forms seat (now the panel'"'"'s) was planned'
expect_line "$checked" 'NEW SEAT: /UYELER/ARGE/AIRLAB/LIDERLER holds no <TEAM>_LEADER realm role: its 1 member(s) get the roles newly' 'the new seat was not reported'
reject_line "$checked" 'NEW SEAT: /UYELER/ARGE/AIRLAB/KOORDINATORLER' 'a Leader group with a _LEADER role was reported as a new seat'
expect_line "$checked" 'new seats: 1 Leader group(s) without a <TEAM>_LEADER realm role, 1 member(s) in all' 'the new seat summary is wrong'
expect_line "$checked" 'NOTE: /UYELER/ORGANIZASYON/ARTLAB has no LIDERLER or KOORDINATORLER group' 'the team without Leaders was not noted'
reject_line "$checked" 'skyforms:form:manage' 'an unread Forms role was planned'
reject_line "$checked" 'SUB/LIDERLER' 'a Sub-team Leader group was planned'
reject_line "$checked" '/UYELER/YK/' 'a YK task group was planned'
for name in direct-person leader-person; do reject_line "$checked" "$name" 'a person was named'; done
expect_line "$checked" 'check: 2 change(s) pending, 0 warning(s), 0 problem(s)' 'the dry run did not count two grants'
[[ $(events "$REALM") == "$before" ]] || fail 'the dry run wrote something'
applied=$(run_expecting 0 leader-app-roles.sh "$REALM" --apply)
expect_line "$applied" 'applied 2 change(s), 0 warning(s), 0 problem(s)' 'the apply did not grant'
for path in /UYELER/ARGE/AIRLAB/LIDERLER /UYELER/ARGE/AIRLAB/KOORDINATORLER; do
  [[ $(group_roles "$REALM" "$path" | jq -c 'map(select(startswith("realm/") | not))') == "$LEADER_ROLES" ]] \
    || fail "$path does not hold exactly skycloud:access: $(group_roles "$REALM" "$path")"
done
[[ $(group_roles "$REALM" /UYELER/ARGE/AIRLAB/SUB/LIDERLER) == '[]' ]] || fail 'the Sub-team Leader group got a role'
[[ $(group_roles "$REALM" /UYELER/YK/BASKAN/LIDERLER) == '[]' ]] || fail 'the YK task group got a role'
[[ $(token_roles "$REALM" leader-person forms) == '[]' ]] || fail "the Leader's token carries a Forms role from leader-app-roles: $(token_roles "$REALM" leader-person forms)"
[[ $(token_roles "$REALM" leader-person skycloud) == '["skycloud:access"]' ]] || fail "the Leader's token lacks SkyCloud: $(token_roles "$REALM" leader-person skycloud)"
[[ $(token_roles "$REALM" sub-leader-person forms) == '[]' ]] || fail "the Sub-team Leader's token carries a Forms role"
before=$(events "$REALM")
again=$(run_expecting 0 leader-app-roles.sh "$REALM" --apply)
expect_line "$again" 'applied 0 change(s), 0 warning(s), 0 problem(s)' 'the second apply changed something'
expect_line "$again" 'new seats: 0 Leader group(s)' 'the second apply reported a new seat'
[[ $(events "$REALM") == "$before" ]] || fail 'the second apply wrote something'
kcadm create "groups/$(group_id "$REALM" /UYELER/ARGE/AIRLAB/SUB/LIDERLER)/role-mappings/clients/$(client_uuid "$REALM" skycloud)" \
  -r "$REALM" -b "$(role_body "$REALM" skycloud skycloud:access)" >/dev/null
checked=$(run_expecting 0 leader-app-roles.sh "$REALM")
expect_line "$checked" 'WARNING: skycloud/skycloud:access is also held by the group(s) /UYELER/ARGE/AIRLAB/SUB/LIDERLER' 'the Sub-team holder was not reported'
reject_line "$checked" '/ROLLER/SKYCLOUD-ACCESS (' 'the role group was reported as a stray holder'
expected=$(run_expecting 0 leader-app-roles.sh "$REALM" --print-expected)
[[ $expected == $'top-team-leaders\tskycloud\tskycloud:access' ]] || fail "--print-expected is not the one code area role: $expected"
printf '    leader-app-roles: the two top team Leader groups get skycloud:access, no Forms seat; NEW SEAT counted; idempotent\n'

CURRENT_STAGE='leader-app-roles: a failed group read stops the run'
before=$(events "$REALM")
failed=$(run_failing_read leader-app-roles.sh "$REALM" group-by-path/UYELER --apply)
expect_line "$failed" '[leader-app-roles] the group /UYELER could not be read in realm e-skylab; stopped' 'the failed read was not reported'
reject_line "$failed" 'applied' 'the run went on after a failed read'
reject_line "$failed" '/UYELER does not exist' 'the failed read was taken for a missing /UYELER'
[[ $(events "$REALM") == "$before" ]] || fail 'the run wrote something after a failed read'
printf '    a failed read of /UYELER stops leader-app-roles.sh (exit 1), nothing written\n'

CURRENT_STAGE='leader-app-roles: the sandbox skips the missing client'
applied=$(run_expecting 0 leader-app-roles.sh "$SANDBOX" --apply)
expect_line "$applied" "WARNING: the client skycloud does not exist in realm $SANDBOX; skycloud/skycloud:access skipped" 'the missing skycloud client was not skipped'
expect_line "$applied" 'applied 0 change(s), 1 warning(s), 0 problem(s)' 'the sandbox grants are wrong'
[[ $(group_roles "$SANDBOX" /UYELER/ARGE/AIRLAB/LIDERLER) == '[]' ]] || fail 'the sandbox Leader group got a role'
printf '    sandbox: the missing skycloud client skipped with a WARNING, nothing granted\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='app-assignments: an invalid catalogue'
printf '{"apps":[{"client":"forms","name":"SkyForms","assignmentRequired":true,"roles":["skyforms:access"]}],"initialAssignments":[{"client":"forms","roles":["skyforms:*"],"target":"top-teams"}]}\n' \
  | docker exec -i "$CONTAINER" sh -c 'cat > /tmp/bad-app-assignments.json'
trap - ERR
bad=$(docker exec -e KEYCLOAK_REALM=$REALM -e KEYCLOAK_APP_ASSIGNMENTS_FILE=/tmp/bad-app-assignments.json "$CONTAINER" \
  bash "$IN_CONTAINER_CONFIG/app-assignments.sh" --kcadm-config "$KCADM_CONFIG" --seed 2>&1) && status=0 || status=$?
trap 'on_error "$LINENO"' ERR
[[ $status == 2 ]] || { printf '%s\n' "$bad" >&2; fail "an initial assignment of an admin role was not refused (exit $status)"; }
expect_line "$bad" 'is not a valid app catalogue; nothing was read or changed' 'the invalid catalogue was not reported'
printf '    a catalogue whose initial assignment names an admin role is refused (exit 2)\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='app-assignments: every mapping in the code area or the panel area'
# The panel area: the Forms seat on a top team, SkyMail on a Sub-team, the Forms seat on direct-person.
# Outside it: an admin role on a top team, an app role on an area. /ADMIN holds the Forms seat (code).
grant_group() { # grant_group PATH CLIENT ROLE
  kcadm create "groups/$(group_id "$REALM" "$1")/role-mappings/clients/$(client_uuid "$REALM" "$2")" -r "$REALM" \
    -b "$(role_body "$REALM" "$2" "$3")" >/dev/null
}
grant_group /UYELER/ARGE/AIRLAB forms skyforms:access
grant_group /UYELER/ARGE/AIRLAB/SUB skymail skymail:access
grant_group /UYELER/ARGE/AIRLAB skymail skymail:mails:write
grant_group /UYELER/ARGE skymail skymail:access
grant_group /ADMIN forms skyforms:access
# SkyCloud's admin: the reconciler expects it on ADMIN and YK (Yusuf, 2026-10-24); ADMIN holds it, YK
# not yet. It stays on ADMIN for the core-roles stage at the end.
grant_group /ADMIN skycloud admin
# frontend-arge (Fatih rebuilds arge, Ek-2): every group holding its roles waits for his decision, a
# Privileged root as well as a top team's Leader group (production: ADMIN, YK and the Leaders).
kcadm create clients -r "$REALM" -s clientId=frontend-arge -s publicClient=true >/dev/null
kcadm create "clients/$(client_uuid "$REALM" frontend-arge)/roles" -r "$REALM" -s name=cms:access >/dev/null
grant_group /ADMIN frontend-arge cms:access
grant_group /UYELER/ARGE/AIRLAB/LIDERLER frontend-arge cms:access
# The admin panel's client (admin in e-skylab) and its inscribed roles (config/inscribed-cms-roles.sh
# makes them), as production holds them since 2026-09-28 (runbook "Admin panelinden verilecek roller",
# then dk-read-only.sh): ADMIN reads and writes, DK reads; YK not yet. DK also holds content:write here,
# the shape before dk-read-only.sh, which the code does not expect. /UYELER/DK for this stage only.
kcadm create clients -r "$REALM" -s clientId=admin -s publicClient=false >/dev/null
for role in content:read content:write; do
  kcadm create "clients/$(client_uuid "$REALM" admin)/roles" -r "$REALM" -s "name=$role" >/dev/null
done
create_group "$REALM" /UYELER DK
grant_group /ADMIN admin content:read
grant_group /ADMIN admin content:write
grant_group /UYELER/DK admin content:read
grant_group /UYELER/DK admin content:write
# The panel's roles as seeded once (the reconciler's mark: content:read to ADMIN, YK and DK,
# content:write to ADMIN and YK): DK's content:write is a write role on DK, never the panel's (S2-fazla);
# content:read on a sub-group of DK is in its seed set (BILGI, ekip-yetkileri ticket 17).
for role in content:read content:write; do
  role_id=$(kcadm get "clients/$(client_uuid "$REALM" admin)/roles/$role" -r "$REALM" | jq -r .id)
  kcadm update "roles-by-id/$role_id" -r "$REALM" \
    -s 'attributes."skylab.seeded-group-mappings"=["2026-10-26T00:00:00Z test"]' >/dev/null
done
create_group "$REALM" /UYELER/DK ALT
grant_group /UYELER/DK/ALT admin content:read
before=$(events "$REALM")
output=$(reconcile_step 2 app-assignments)
expect_line "$output" 'KEYCLOAK_RECONCILE_ONLY=app-assignments is an operator step' 'the check ran without an operator session'
# One run (every role's holders are read: minutes), through the reconciler's step, which passes the
# Privileged roots' expectations; as the nightly drift alarm runs it (ticket 07): drift is exit 1.
sorted=$(reconcile_step 1 app-assignments -e "KEYCLOAK_RECONCILE_KCADM_CONFIG=$KCADM_CONFIG" \
  -e KEYCLOAK_APP_ASSIGNMENTS_ALARM=true)
reject_line "$sorted" 'NOTE: no --privileged-file' 'the reconciler'"'"'s step did not pass its expectations'
expect_line "$sorted" '[app-assignments] PANEL|/UYELER/ARGE/AIRLAB|forms|skyforms:access' 'the top team'"'"'s Forms seat is not the panel'"'"'s'
expect_line "$sorted" '[app-assignments] PANEL|/UYELER/ARGE/AIRLAB/SUB|skymail|skymail:access' 'the Sub-team'"'"'s SkyMail is not the panel'"'"'s'
expect_line "$sorted" '[app-assignments] PANEL|kişi:1|forms|skyforms:access' 'the person'"'"'s Forms seat is not a panel assignment'
expect_line "$sorted" '[app-assignments] KOD|kişi:1|skymail|skymail:mails:write|hayır|var' 'the person'"'"'s admin role is not the code area'"'"'s'
expect_line "$sorted" '[app-assignments] KOD|/UYELER/ARGE/AIRLAB|skymail|skymail:mails:write|hayır|var' 'the admin role on a team is not reported'
expect_line "$sorted" 'PROBLEM: skymail/skymail:mails:write (an admin, unclassified or realm role) is mapped to /UYELER/ARGE/AIRLAB' 'the admin role on a team is no PROBLEM'
expect_line "$sorted" '[app-assignments] KOD|/UYELER/ARGE|skymail|skymail:access|hayır|var' 'the app role on an area is not the code area'"'"'s'
expect_line "$sorted" 'PROBLEM: skymail/skymail:access (an app role) is mapped to /UYELER/ARGE, which is no panel target' 'the app role on an area is no PROBLEM'
expect_line "$sorted" '[app-assignments] KOD|/ROLLER/SKYMAIL-ACCESS|skymail|skymail:access|evet|var' 'a role group'"'"'s role is not as expected'
expect_line "$sorted" '[app-assignments] KOD|/UYELER/ARGE/AIRLAB/LIDERLER|skycloud|skycloud:access|evet|var' 'the Leader group'"'"'s SkyCloud is not as expected'
expect_line "$sorted" '[app-assignments] KOD|/UYELER/ARGE/AIRLAB/SUB/LIDERLER|skycloud|skycloud:access|hayır|var' 'SkyCloud on a Sub-team'"'"'s Leader group is not reported'
expect_line "$sorted" '[app-assignments] KOD|/UYELER|realm|USER|hayır|var' 'the realm role on /UYELER is not reported'
expect_line "$sorted" '[app-assignments] KOD|/ADMIN|forms|skyforms:access|evet|var' 'the reconciler does not expect the Forms seat on ADMIN'
expect_line "$sorted" '[app-assignments] KOD|/UYELER/YK|forms|skyforms:access|evet|yok' 'the missing Forms seat of YK is not reported'
expect_line "$sorted" '[app-assignments] KOD|/UYELER/YK|skymail|skymail:mails:approve|evet|yok' 'the missing SkyMail approver role of YK is not reported'
expect_line "$sorted" '[app-assignments] KOD|/UYELER/YK|forms|skyforms:*|evet|yok' 'the missing skyforms:* of YK is not reported'
reject_line "$sorted" 'KOD|/ADMIN|skymail|skymail:mails:approve' 'ADMIN was expected to approve (YK alone does)'
expect_line "$sorted" '[app-assignments] KOD|/ADMIN|skycloud|admin|evet|var' 'the reconciler does not expect SkyCloud'"'"'s admin on ADMIN'
expect_line "$sorted" '[app-assignments] KOD|/UYELER/YK|skycloud|admin|evet|yok' 'the missing SkyCloud admin of YK is not reported'
expect_line "$sorted" '[app-assignments] KOD|/ROLLER/SKYCLOUD-ADMIN|skycloud|admin|evet|var' 'the SkyCloud admin role group is not as expected'
reject_line "$sorted" 'KOD|/ADMIN|skycloud|skycloud:access' 'ADMIN was expected to hold skycloud:access (the Leader groups do)'
reject_line "$sorted" 'KOD|/UYELER/YK|skycloud|skycloud:access' 'YK was expected to hold skycloud:access (the Leader groups do)'
reject_line "$sorted" 'PROBLEM: skycloud/admin' 'SkyCloud'"'"'s admin on ADMIN was a PROBLEM'
# The admin panel's inscribed roles: News is written in the panel (ADR-0056), DK reads (GY1).
expect_line "$sorted" '[app-assignments] KOD|/ADMIN|admin|content:read|evet|var' 'the reconciler does not expect the panel'"'"'s content:read on ADMIN'
expect_line "$sorted" '[app-assignments] KOD|/ADMIN|admin|content:write|evet|var' 'the reconciler does not expect the panel'"'"'s content:write on ADMIN'
expect_line "$sorted" '[app-assignments] KOD|/UYELER/YK|admin|content:read|evet|yok' 'the missing panel content:read of YK is not reported'
expect_line "$sorted" '[app-assignments] KOD|/UYELER/YK|admin|content:write|evet|yok' 'the missing panel content:write of YK is not reported'
expect_line "$sorted" '[app-assignments] KOD|/UYELER/DK|admin|content:read|evet|var' 'the reconciler does not expect the panel'"'"'s content:read on DK'
expect_line "$sorted" '[app-assignments] KOD|/UYELER/DK|admin|content:write|hayır|var' 'DK'"'"'s panel content:write was expected (DK reads, GY1)'
reject_line "$sorted" 'PROBLEM: admin/content' 'the panel'"'"'s inscribed roles on a Privileged root were a PROBLEM'
expect_line "$sorted" '[app-assignments] SAPMA|S2-fazla|/UYELER/DK|admin|content:write' 'a seeded write role on DK is no S2-fazla (DK reads)'
reject_line "$sorted" 'BILGI|S2-tohum|/UYELER/DK|admin|content:write' 'a seeded write role on DK was taken for the panel'"'"'s'
expect_line "$sorted" '[app-assignments] BILGI|S2-tohum|/UYELER/DK/ALT|admin|content:read|fazla' \
  'a seeded read role on a sub-group of DK (its seed set) is no BILGI line'
reject_line "$sorted" 'SAPMA|S2-fazla|/UYELER/DK/ALT' 'a seeded read role on a sub-group of DK was taken for drift'
expect_line "$sorted" '[app-assignments] BILGI|S2-tohum|/UYELER/YK|admin|content:write|eksik' \
  'a seeded role missing from YK (its seed set) is no BILGI line'
# DK's temporary Forms admin role missing is dk-read-only.sh --forms's goal: BILGI, never drift.
expect_line "$sorted" '[app-assignments] BILGI|S2-geçici|/UYELER/DK|forms|skyforms:*|eksik' \
  'DK'"'"'s missing temporary Forms role is no BILGI line'
reject_line "$sorted" 'SAPMA|S2-eksik|/UYELER/DK|forms|skyforms:*' 'DK'"'"'s missing temporary Forms role was taken for drift'
expect_line "$sorted" '[app-assignments] KOD|/ADMIN|frontend-arge|cms:access|karar-bekliyor|var' 'ADMIN'"'"'s frontend-arge role is not pending'
expect_line "$sorted" '[app-assignments] KOD|/UYELER/ARGE/AIRLAB/LIDERLER|frontend-arge|cms:access|karar-bekliyor|var' 'the Leader group'"'"'s frontend-arge role is not pending'
reject_line "$sorted" 'PROBLEM: frontend-arge' 'a pending frontend-arge role was a PROBLEM'
expect_line "$sorted" 'PANEL: SkyForms (forms): 1 group assignment(s), 1 person assignment(s)' 'the SkyForms panel count is wrong'
expect_line "$sorted" 'PANEL: SkyMail (skymail): 1 group assignment(s), 0 person assignment(s)' 'the SkyMail panel count is wrong'
reject_line "$sorted" 'PANEL|/ROLLER' 'a role group was taken for the panel area'
reject_line "$sorted" 'PANEL|/ADMIN' 'a Privileged root was taken for the panel area'
expect_line "$sorted" 'check: 0 change(s) pending' 'the check planned a change'
# The drift summary: one SAPMA line a drift, of its class.
expect_line "$sorted" '[app-assignments] SAPMA|S1|kişi:1|skymail|skymail:mails:write' 'the person'"'"'s admin role is no S1'
expect_line "$sorted" '[app-assignments] SAPMA|S1-realm|kişi:' 'the person'"'"'s realm role is no S1-realm'
expect_line "$sorted" '[app-assignments] SAPMA|S2b|/UYELER/ARGE/AIRLAB|skymail|skymail:mails:write' 'the admin role on a team is no S2b'
expect_line "$sorted" '[app-assignments] SAPMA|S2b|/UYELER/ARGE/AIRLAB/SUB/LIDERLER|skycloud|skycloud:access' 'SkyCloud on a Sub-team'"'"'s Leader group is no S2b'
expect_line "$sorted" '[app-assignments] SAPMA|S2-fazla|/UYELER/ARGE|skymail|skymail:access' 'the app role on an area is no S2-fazla'
expect_line "$sorted" '[app-assignments] SAPMA|S2-fazla|/UYELER|realm|USER' 'the realm role on /UYELER is no S2-fazla'
expect_line "$sorted" '[app-assignments] SAPMA|S2-eksik|/UYELER/YK|forms|skyforms:access' 'the missing Forms seat of YK is no S2-eksik'
expect_line "$sorted" '[app-assignments] SAPMA|S5|/UYELER/ORGANIZASYON/ARTLAB|-|-' 'the top team without a Leader group is no S5'
reject_line "$sorted" 'SAPMA|S5|/UYELER/ARGE/AIRLAB|' 'a top team with an enabled Leader was taken for one without'
reject_line "$sorted" 'SAPMA|S1|kişi:1|forms' 'a person'"'"'s panel seat was taken for drift'
reject_line "$sorted" 'SAPMA|S2-fazla|/UYELER/ARGE/AIRLAB|forms' 'a team'"'"'s panel seat was taken for drift'
reject_line "$sorted" 'SAPMA|S2b|/UYELER/ARGE/AIRLAB/SUB|skymail' 'a Sub-team'"'"'s panel SkyMail was taken for drift'
reject_line "$(grep -F 'SAPMA|' <<<"$sorted")" '|frontend-arge|' 'a pending frontend-arge role was taken for drift'
reject_line "$(grep -F 'SAPMA|' <<<"$sorted")" 'SAPMA|S2-fazla|/ROLLER/SKYMAIL-ACCESS' 'a role group'"'"'s expected role was taken for drift'
expect_line "$sorted" '[app-assignments] SAPMA: S1=1 S1-realm=' 'the drift summary is missing'
expect_line "$sorted" '(bilgi) S2-eksik=' 'a person'"'"'s realm role counts towards the alarm by default'
for name in direct-person leader-person role-group-person sub-leader-person; do
  reject_line "$sorted" "$name" 'the check printed a person'
done
[[ $(events "$REALM") == "$before" ]] || fail 'the check wrote something'
kcadm delete "groups/$(group_id "$REALM" /UYELER/ARGE/AIRLAB)/role-mappings/clients/$(client_uuid "$REALM" skymail)" -r "$REALM" \
  -b "$(role_body "$REALM" skymail skymail:mails:write)" >/dev/null
kcadm delete "groups/$(group_id "$REALM" /UYELER/ARGE)/role-mappings/clients/$(client_uuid "$REALM" skymail)" -r "$REALM" \
  -b "$(role_body "$REALM" skymail skymail:access)" >/dev/null
kcadm delete "clients/$(client_uuid "$REALM" frontend-arge)" -r "$REALM" >/dev/null
# The panel's client and /UYELER/DK go: the core-roles stage at the end makes its own shape.
kcadm delete "clients/$(client_uuid "$REALM" admin)" -r "$REALM" >/dev/null
kcadm delete "groups/$(group_id "$REALM" /UYELER/DK)" -r "$REALM" >/dev/null
printf '    --check: panel assignments counted, code area compared (expected, missing, not in code), PROBLEMs named, nothing written, nobody named\n'
printf '    drift summary: SAPMA lines by class, the alarm step exits 1 on drift\n'

CURRENT_STAGE='app-assignments: the drift alarm'"'"'s refusals and a failed read'
refused=$(run_expecting 2 app-assignments.sh "$REALM" --check --alarm)
expect_line "$refused" '--alarm belongs to --check with --privileged-file' 'the alarm without the Privileged expectations was not refused'
refused=$(run_expecting 2 app-assignments.sh "$REALM" --check --realm-roles hepsi)
expect_line "$refused" '--realm-roles bilgi or alarm' 'an unknown --realm-roles was not refused'
docker exec "$CONTAINER" sh -c ': > /tmp/no-privileged.tsv'
trap - ERR
failed=$(docker exec -e KEYCLOAK_ADMIN_URL=http://localhost:8080 -e KEYCLOAK_REALM="$REALM" \
  -e KCADM_BIN=/tmp/kcadm-fail.sh -e KCADM_INJECT_FAIL=group-by-path/UYELER "$CONTAINER" \
  bash "$IN_CONTAINER_CONFIG/app-assignments.sh" --kcadm-config "$KCADM_CONFIG" --check --alarm \
  --privileged-file /tmp/no-privileged.tsv 2>&1) && status=0 || status=$?
trap 'on_error "$LINENO"' ERR
[[ $status == 2 ]] || { printf '%s\n' "$failed" >&2; fail "a failed read under --alarm did not exit 2 (exit $status)"; }
expect_line "$failed" 'the group /UYELER could not be read in realm e-skylab; stopped' 'the failed read was not reported'
reject_line "$failed" 'SAPMA:' 'the alarm summed up after a failed read'
printf '    --alarm: refused without --privileged-file and with an unknown --realm-roles (exit 2); a failed read is exit 2\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='app-assignments: the one-time initial assignment'
create_group "$REALM" /UYELER/ARGE ALGOLAB
make_person "$REALM" algolab-member /UYELER/ARGE/ALGOLAB
make_person "$REALM" algolab-off /UYELER/ARGE/ALGOLAB
kcadm update "users/$(kcadm get users -r "$REALM" -q username=algolab-off -q exact=true | jq -r '.[0].id')" -r "$REALM" \
  -s enabled=false >/dev/null
before=$(events "$REALM")
planned=$(run_expecting 0 app-assignments.sh "$REALM" --seed)
expect_line "$planned" 'top teams: 3, their Leader groups: 2' 'the top teams were not read from the tree'
expect_line "$planned" 'YENI ATAMA /UYELER/ARGE/ALGOLAB forms skyforms:access (1 etkin üye)' 'ALGOLAB'"'"'s Forms seat was not planned with its enabled member'
expect_line "$planned" 'YENI ATAMA /UYELER/ORGANIZASYON/ARTLAB forms skyforms:access (0 etkin üye)' 'ARTLAB'"'"'s Forms seat was not planned'
for role in skymail:access skymail:templates:read; do
  expect_line "$planned" "YENI ATAMA /UYELER/ARGE/AIRLAB/LIDERLER skymail $role (1 etkin üye)" "LIDERLER's $role was not planned"
  expect_line "$planned" "YENI ATAMA /UYELER/ARGE/AIRLAB/KOORDINATORLER skymail $role (0 etkin üye)" "KOORDINATORLER's $role was not planned"
  expect_line "$planned" "YENI ATAMA /UYELER/ARGE/ALGOLAB skymail $role (1 etkin üye)" "ALGOLAB's $role was not planned"
done
reject_line "$planned" 'YENI ATAMA /UYELER/ARGE/AIRLAB forms' 'a team that holds the seat was planned again'
reject_line "$planned" 'SUB/LIDERLER' 'a Sub-team Leader group was planned'
reject_line "$planned" '/UYELER/YK' 'a Privileged group was planned'
expect_line "$planned" 'already held (by the group or a parent): 1' 'the held seat was not counted'
expect_line "$planned" 'check: 8 change(s) pending, 0 warning(s), 0 problem(s)' 'the dry run did not plan eight assignments'
for name in algolab-member algolab-off leader-person; do reject_line "$planned" "$name" 'the seed printed a person'; done
[[ $(events "$REALM") == "$before" ]] || fail 'the dry run wrote something'
output=$(reconcile_step 0 tohum-atamalar -e "KEYCLOAK_RECONCILE_KCADM_CONFIG=$KCADM_CONFIG" \
  -e KEYCLOAK_APP_ASSIGNMENTS_BACKUP_FILE=/tmp/seed-backup.tsv)
expect_line "$output" '[app-assignments] backup: /tmp/seed-backup.tsv' 'the backup was not named'
expect_line "$output" 'applied 8 change(s), 0 warning(s), 0 problem(s)' 'the step did not apply the eight assignments'
expect_line "$output" 'realm attribute skylab.app-assignments-seeded=' 'the realm was not marked'
[[ $(docker exec "$CONTAINER" stat -c %a /tmp/seed-backup.tsv) == 600 ]] || fail 'the backup is not mode 0600'
[[ $(docker exec "$CONTAINER" wc -l </dev/null /tmp/seed-backup.tsv | cut -d' ' -f1) == 8 ]] || fail 'the backup does not hold eight lines'
[[ $(group_roles "$REALM" /UYELER/ARGE/ALGOLAB) == '["forms/skyforms:access","skymail/skymail:access","skymail/skymail:templates:read"]' ]] \
  || fail "ALGOLAB does not hold the seat and the SkyMail pair: $(group_roles "$REALM" /UYELER/ARGE/ALGOLAB)"
[[ $(group_roles "$REALM" /UYELER/ORGANIZASYON/ARTLAB) == '["forms/skyforms:access"]' ]] || fail 'ARTLAB does not hold the Forms seat'
[[ $(token_roles "$REALM" leader-person skymail) == '["skymail:access","skymail:templates:read"]' ]] \
  || fail "the Leader does not carry the SkyMail pair: $(token_roles "$REALM" leader-person skymail)"
[[ $(token_roles "$REALM" leader-person forms) == '["skyforms:access"]' ]] || fail 'the Leader does not inherit the team'"'"'s Forms seat'
[[ $(token_roles "$REALM" algolab-member forms) == '["skyforms:access"]' ]] || fail 'the ALGOLAB member does not carry the Forms seat'
again=$(run_expecting 0 app-assignments.sh "$REALM" --seed)
expect_line "$again" 'NOTE: the initial assignment ran in realm e-skylab before' 'the second dry run did not see the mark'
expect_line "$again" 'check: 0 change(s) pending' 'the second dry run planned something'
before=$(events "$REALM")
refused=$(run_expecting 1 app-assignments.sh "$REALM" --seed --apply)
expect_line "$refused" 'PROBLEM: the initial assignment ran in realm e-skylab before' 'a second --apply was not refused'
[[ $(events "$REALM") == "$before" ]] || fail 'the refused second --apply wrote something'
restore=$(run_expecting 0 app-assignments.sh "$REALM" --restore /tmp/seed-backup.tsv)
expect_line "$restore" 'would take forms/skyforms:access away from the group /UYELER/ARGE/ALGOLAB' 'the restore did not plan the seat away'
expect_line "$restore" 'check: 9 change(s) pending' 'the restore did not plan the eight assignments and the mark'
[[ $(events "$REALM") == "$before" ]] || fail 'the restore dry run wrote something'
restore=$(run_expecting 0 app-assignments.sh "$REALM" --restore /tmp/seed-backup.tsv --apply)
expect_line "$restore" 'applied 9 change(s), 0 warning(s), 0 problem(s)' 'the restore did not take the eight assignments and the mark away'
[[ $(group_roles "$REALM" /UYELER/ARGE/ALGOLAB) == '[]' ]] || fail 'the restore left an assignment on ALGOLAB'
[[ $(group_roles "$REALM" /UYELER/ARGE/AIRLAB) == '["forms/skyforms:access"]' ]] || fail 'the restore took away what the seed had not made'
replanned=$(run_expecting 0 app-assignments.sh "$REALM" --seed)
reject_line "$replanned" 'NOTE: the initial assignment ran' 'the restore did not clear the mark'
expect_line "$replanned" 'check: 8 change(s) pending' 'after the restore the dry run does not plan the eight again'
printf '    --seed: eight missing assignments planned with enabled member counts, applied once with a backup and a mark; a second --apply refused; --restore takes exactly them away\n'

CURRENT_STAGE='app-assignments: refused targets and a failed read'
kcadm update "realms/$REALM/default-groups/$(group_id "$REALM" /UYELER/ORGANIZASYON/ARTLAB)" -n -b '{}' >/dev/null
before=$(events "$REALM")
refused=$(run_expecting 1 app-assignments.sh "$REALM" --seed --apply)
expect_line "$refused" 'PROBLEM: refusing /UYELER/ORGANIZASYON/ARTLAB as a target of forms' 'a default group target was not refused'
reject_line "$refused" 'YENI ATAMA' 'a refused run planned assignments'
[[ $(events "$REALM") == "$before" ]] || fail 'the refused run wrote something'
kcadm delete "realms/$REALM/default-groups/$(group_id "$REALM" /UYELER/ORGANIZASYON/ARTLAB)" >/dev/null
before=$(events "$REALM")
printf '{"apps":[{"client":"skymail","name":"SkyMail","assignmentRequired":true,"roles":["skymail:access"]}],"initialAssignments":[{"client":"skymail","roles":["skymail:access"],"target":"/UYELER/YK/BASKAN"}]}\n' \
  | docker exec -i "$CONTAINER" sh -c 'cat > /tmp/privileged-target.json'
trap - ERR
refused=$(docker exec -e KEYCLOAK_REALM=$REALM -e KEYCLOAK_APP_ASSIGNMENTS_FILE=/tmp/privileged-target.json "$CONTAINER" \
  bash "$IN_CONTAINER_CONFIG/app-assignments.sh" --kcadm-config "$KCADM_CONFIG" --seed --apply 2>&1) && status=0 || status=$?
trap 'on_error "$LINENO"' ERR
[[ $status == 1 ]] || { printf '%s\n' "$refused" >&2; fail "a Privileged target was not refused (exit $status)"; }
expect_line "$refused" 'PROBLEM: refusing /UYELER/YK/BASKAN as a target of skymail' 'the Privileged target was not named'
refused=$(run_expecting 1 app-assignments.sh "$SANDBOX" --seed)
expect_line "$refused" "PROBLEM: the target /UYELER/ARGE/ALGOLAB does not exist in realm $SANDBOX" 'the missing target was not refused'
[[ $(events "$REALM") == "$before" ]] || fail 'a refused run wrote something'
failed=$(run_failing_read app-assignments.sh "$REALM" group-by-path/UYELER --seed --apply)
expect_line "$failed" '[app-assignments] the group /UYELER could not be read in realm e-skylab; stopped' 'the failed read was not reported'
reject_line "$failed" 'applied' 'the run went on after a failed read'
[[ $(events "$REALM") == "$before" ]] || fail 'the run wrote something after a failed read'
printf '    --seed: a default group under a target, a Privileged target and a missing target are PROBLEMs (exit 1); a failed read stops it\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='default-roles: broker/read-token and the identity providers'"'"' token settings'
# Production's shape (10-22 precheck): broker/read-token in the default role; an identity provider
# with Store tokens and Stored tokens readable on; a person who got read-token at a first login.
if [[ -z $(client_uuid "$REALM" broker) ]]; then
  kcadm create clients -r "$REALM" -s clientId=broker -s bearerOnly=true >/dev/null
  kcadm create "clients/$(client_uuid "$REALM" broker)/roles" -r "$REALM" -s name=read-token >/dev/null
fi
default_role=$(kcadm get "realms/$REALM" | jq -r .defaultRole.name)
default_role_id=$(kcadm get "realms/$REALM" | jq -r .defaultRole.id)
kcadm create "roles-by-id/$default_role_id/composites" -r "$REALM" -b "$(role_body "$REALM" broker read-token)" >/dev/null
kcadm create identity-provider/instances -r "$REALM" -s alias=obs-test -s providerId=oidc -s enabled=true \
  -s storeToken=true -s addReadTokenRoleOnCreate=true -s config.clientId=harness -s config.clientSecret=harness-idp-secret \
  -s config.authorizationUrl=https://idp.invalid/auth -s config.tokenUrl=https://idp.invalid/token >/dev/null
kcadm add-roles -r "$REALM" --uusername direct-person --cclientid broker --rolename read-token >/dev/null
# Production's shape of the 2026-10-23 precheck: the Java era's realm role USER is in the default role and
# carries broker/read-token as a composite; the account console's view-groups is in the default role too.
user_role_id=$(kcadm get roles/USER -r "$REALM" | jq -r .id)
kcadm create "roles-by-id/$user_role_id/composites" -r "$REALM" -b "$(role_body "$REALM" broker read-token)" >/dev/null
kcadm create "roles-by-id/$default_role_id/composites" -r "$REALM" -b "[{\"id\":\"$user_role_id\"}]" >/dev/null
kcadm create "roles-by-id/$default_role_id/composites" -r "$REALM" -b "$(role_body "$REALM" account view-groups)" >/dev/null
user_composites() {
  kcadm get "roles-by-id/$user_role_id/composites" -r "$REALM" | jq -c '[.[].name] | sort'
}
default_composites() {
  kcadm get "roles-by-id/$default_role_id/composites" -r "$REALM" | jq -c '[.[].name] | sort'
}
before=$(events "$REALM")
composites_before=$(default_composites)
output=$(reconcile_step 2 default-roles)
expect_line "$output" 'KEYCLOAK_RECONCILE_ONLY=default-roles is an operator step' 'the step ran without an operator session'
checked=$(reconcile_step 0 default-roles -e "KEYCLOAK_RECONCILE_KCADM_CONFIG=$KCADM_CONFIG" -e KEYCLOAK_RECONCILE_CHECK=true)
expect_line "$checked" "[reconcile] KOD|$default_role|broker|read-token|hayır|var" 'read-token in the default role is not reported'
expect_line "$checked" "[reconcile] would remove broker/read-token from the default role $default_role" 'the removal was not planned'
expect_line "$checked" "[reconcile] KOD|$default_role|realm|offline_access|evet|var" 'a Keycloak default role is not reported as expected'
expect_line "$checked" "[reconcile] KOD|$default_role|account|view-groups|evet|var" 'an account console role is not taken as Keycloak'"'"'s own'
reject_line "$checked" 'WARNING: account/view-groups' 'an account console role was warned about'
expect_line "$checked" "[reconcile] KOD|$default_role|realm|USER|hayır|var" 'the realm role USER in the default role is not reported'
expect_line "$checked" "WARNING: realm/USER is in the default role $default_role" 'the realm role USER in the default role is not warned about'
expect_line "$checked" "[reconcile] KOD|$default_role>realm/USER|broker|read-token|hayır|var" 'read-token inside USER is not reported'
expect_line "$checked" "[reconcile] would remove broker/read-token from the composite role realm/USER, which is in the default role $default_role" \
  'taking read-token out of USER was not planned'
reject_line "$checked" 'broker/read-token is in the composite role(s)' 'the composite the step takes read-token from was warned about again'
expect_line "$checked" '[reconcile] KOD|idp:obs-test|-|addReadTokenRoleOnCreate|false|true' 'the token setting is not reported'
expect_line "$checked" '[reconcile] would turn off Stored tokens readable of identity provider obs-test' 'turning the setting off was not planned'
expect_line "$checked" 'WARNING: identity provider obs-test stores the tokens of its logins' 'Store tokens was not reported'
expect_line "$checked" 'NOTE: broker/read-token is held directly by 1 person(s)' 'the direct holder was not counted'
expect_line "$checked" '[reconcile] check: 3 change(s) pending; nothing was written' 'the dry run did not count three changes'
expect_line "$checked" 'Default roles and identity provider token settings are checked; nothing was written.' 'the dry run did not end as one'
reject_line "$checked" 'direct-person' 'the step printed a person'
reject_line "$checked" 'harness-idp-secret' 'the step printed a secret'
[[ $(events "$REALM") == "$before" ]] || fail 'the dry run wrote something'
[[ $(default_composites) == "$composites_before" ]] || fail 'the dry run changed the default role'
[[ $(user_composites) == '["read-token"]' ]] || fail "the dry run changed USER: $(user_composites)"
applied=$(reconcile_step 0 default-roles -e "KEYCLOAK_RECONCILE_KCADM_CONFIG=$KCADM_CONFIG")
expect_line "$applied" '[reconcile] applied 3 change(s)' 'the step did not apply the three changes'
default_composites | jq -e 'index("read-token") == null' >/dev/null || fail 'read-token is still in the default role'
default_composites | jq -e 'index("USER") != null and index("view-groups") != null' >/dev/null \
  || fail "the step took USER or view-groups out of the default role: $(default_composites)"
[[ $(user_composites) == '[]' ]] || fail "read-token is still in USER: $(user_composites)"
idp=$(kcadm get identity-provider/instances/obs-test -r "$REALM")
jq -e '.addReadTokenRoleOnCreate == false and .storeToken == true' <<<"$idp" >/dev/null \
  || fail "the token settings are not Stored tokens readable off and Store tokens untouched: $(jq -c '{storeToken, addReadTokenRoleOnCreate}' <<<"$idp")"
[[ $(token_roles "$REALM" direct-person broker) == '["read-token"]' ]] || fail 'the direct holder lost read-token (the reset window'"'"'s job)'
again=$(reconcile_step 0 default-roles -e "KEYCLOAK_RECONCILE_KCADM_CONFIG=$KCADM_CONFIG" -e KEYCLOAK_RECONCILE_CHECK=true)
expect_line "$again" '[reconcile] check: 0 change(s) pending; nothing was written' 'the second dry run planned a change'
for role in "{\"id\":\"$user_role_id\"}" "$(role_body "$REALM" account view-groups | jq -c '.[0]')"; do
  kcadm delete "roles-by-id/$default_role_id/composites" -r "$REALM" -b "[$role]" >/dev/null
done
printf '    default-roles: read-token out of the default role and out of USER inside it, Stored tokens readable off (dry run first, then 0); USER warned and kept, account roles kept; Store tokens and the direct holder reported, kept\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='the reconciler operator steps'
for step in role-groups leader-app-roles; do
  output=$(reconcile_step 2 "$step")
  expect_line "$output" "KEYCLOAK_RECONCILE_ONLY=$step is an operator step" "the step $step ran without an operator session"
  output=$(reconcile_step 0 "$step" -e "KEYCLOAK_RECONCILE_KCADM_CONFIG=$KCADM_CONFIG" -e KEYCLOAK_RECONCILE_CHECK=true)
  expect_line "$output" 'check: 0 change(s) pending' "the dry run of the step $step planned a change"
done
output=$(reconcile_step 0 leader-app-roles -e "KEYCLOAK_RECONCILE_KCADM_CONFIG=$KCADM_CONFIG")
expect_line "$output" 'applied 0 change(s)' 'the operator step did not run the script with --apply'
output=$(reconcile_step 2 tohum-atamalar)
expect_line "$output" 'KEYCLOAK_RECONCILE_ONLY=tohum-atamalar is an operator step' 'the seed ran without an operator session'
before=$(events "$REALM")
output=$(reconcile_step 0 tohum-atamalar -e "KEYCLOAK_RECONCILE_KCADM_CONFIG=$KCADM_CONFIG" -e KEYCLOAK_RECONCILE_CHECK=true)
expect_line "$output" 'check: 8 change(s) pending' 'the seed'"'"'s dry run through the reconciler is not the dry run'
[[ $(events "$REALM") == "$before" ]] || fail 'the seed'"'"'s dry run through the reconciler wrote something'
printf '    KEYCLOAK_RECONCILE_ONLY=role-groups, leader-app-roles and tohum-atamalar run the scripts (dry run with KEYCLOAK_RECONCILE_CHECK=true); refused without an operator session\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='core-roles: SkyCloud'"'"'s admin seeded once to ADMIN and YK'
# The client skycloud is made by hand (production) and its role admin is SkyCloud's own: the step never
# creates either, it grants the role once to ADMIN and YK (ADMIN holds it since the app-assignments
# stage) and marks it; a sub-group of YK inherits it; skycloud:access stays off the Privileged roots.
make_person "$REALM" yk-person /UYELER/YK/BASKAN
skycloud_seed_mark() {
  kcadm get "clients/$(client_uuid "$REALM" skycloud)/roles" -r "$REALM" -q briefRepresentation=false \
    | jq -r '.[] | select(.name == "admin") | ((.attributes // {})["skylab.seeded-group-mappings"][0] // "")'
}
skycloud_roles_before=$(kcadm get "clients/$(client_uuid "$REALM" skycloud)/roles" -r "$REALM" | jq -c '[.[].name] | sort')
before=$(events "$REALM")
checked=$(reconcile_step 0 core-roles -e "KEYCLOAK_RECONCILE_KCADM_CONFIG=$KCADM_CONFIG" -e KEYCLOAK_RECONCILE_CHECK=true)
expect_line "$checked" '[reconcile] Privileged roles of skycloud (1): unchanged' 'the SkyCloud role was not found'
expect_line "$checked" '[reconcile] skycloud role admin: seeded once to /ADMIN,/UYELER/YK (granted to: /UYELER/YK)' \
  'the dry run did not plan SkyCloud'"'"'s admin for YK alone'
expect_line "$checked" "[reconcile] would kcadm create groups/$(group_id "$REALM" /UYELER/YK)/role-mappings/clients/$(client_uuid "$REALM" skycloud) (body)" \
  'the dry run did not withhold the YK mapping'
reject_line "$checked" "would kcadm create groups/$(group_id "$REALM" /ADMIN)/role-mappings/clients/$(client_uuid "$REALM" skycloud) " \
  'the dry run planned a mapping ADMIN holds'
expect_line "$checked" 'Core resource roles are checked; nothing was written' 'the dry run did not end as one'
[[ $(events "$REALM") == "$before" ]] || fail 'the core-roles dry run wrote something'
[[ -z $(skycloud_seed_mark) ]] || fail 'the dry run marked SkyCloud'"'"'s admin'
seeded=$(reconcile_step 0 core-roles -e "KEYCLOAK_RECONCILE_KCADM_CONFIG=$KCADM_CONFIG")
expect_line "$seeded" '[reconcile] skycloud role admin: seeded once to /ADMIN,/UYELER/YK (granted to: /UYELER/YK)' \
  'SkyCloud'"'"'s admin was not seeded to YK'
expect_line "$seeded" 'Core resource roles are reconciled.' 'the step did not end'
for path in /ADMIN /UYELER/YK; do
  group_roles "$REALM" "$path" | jq -e 'index("skycloud/admin") != null and index("skycloud/skycloud:access") == null' >/dev/null \
    || fail "$path does not hold SkyCloud's admin alone of skycloud's roles: $(group_roles "$REALM" "$path")"
done
[[ $(skycloud_seed_mark) =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\ /ADMIN,/UYELER/YK$ ]] \
  || fail "SkyCloud's admin lacks its mark: $(skycloud_seed_mark)"
[[ $(kcadm get "clients/$(client_uuid "$REALM" skycloud)/roles" -r "$REALM" | jq -c '[.[].name] | sort') == "$skycloud_roles_before" ]] \
  || fail 'the step created or removed a skycloud role'
[[ $(token_roles "$REALM" yk-person skycloud) == '["admin"]' ]] || fail "a YK duty member does not carry SkyCloud's admin: $(token_roles "$REALM" yk-person skycloud)"
again=$(reconcile_step 0 core-roles -e "KEYCLOAK_RECONCILE_KCADM_CONFIG=$KCADM_CONFIG")
reject_line "$again" 'skycloud role admin: seeded once' 'the second core-roles step seeded SkyCloud again'
expect_line "$again" '[reconcile] group mappings of the skycloud Privileged roles: unchanged' 'the second step did not leave the SkyCloud mapping alone'
# A realm without the client skycloud (the sandbox) skips it with a WARNING.
trap - ERR
skipped=$(docker exec -e KEYCLOAK_ADMIN_URL=http://localhost:8080 -e KEYCLOAK_REALM=$SANDBOX \
  -e KEYCLOAK_RECONCILE_ONLY=core-roles -e "KEYCLOAK_RECONCILE_KCADM_CONFIG=$KCADM_CONFIG" -e KEYCLOAK_RECONCILE_CHECK=true \
  "$CONTAINER" bash "$IN_CONTAINER_CONFIG/reconcile-account-center.sh" 2>&1) && status=0 || status=$?
trap 'on_error "$LINENO"' ERR
[[ $status == 0 ]] || { printf '%s\n' "$skipped" >&2; fail "the sandbox core-roles dry run failed (exit $status)"; }
expect_line "$skipped" "[reconcile] WARNING: client skycloud does not exist in realm $SANDBOX; skipped SkyCloud's Privileged roles" \
  'the missing skycloud client was not skipped'
reject_line "$skipped" 'skycloud role admin' 'the sandbox seeded SkyCloud'
reject_line "$checked$seeded$again" 'yk-person' 'the step printed a person'
printf '    core-roles: SkyCloud'"'"'s admin to ADMIN and YK once (dry run first), marked, inherited by a YK sub-group, skycloud:access untouched; the sandbox without skycloud skipped with a WARNING\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='core-roles: the admin panel'"'"'s inscribed roles seeded once to ADMIN, YK and DK'
# The panel's client (admin; superadmin in the sandbox) and its roles content:read and content:write are
# made elsewhere (production's client by hand, the roles by config/inscribed-cms-roles.sh): the step
# never creates either. It grants content:read once to ADMIN, YK and DK and content:write once to ADMIN
# and YK (DK reads, GY1), leaves a group that holds a role alone and marks both roles. Production's shape
# before the step: ADMIN holds both (the panel's grants of 2026-09-28), YK content:read alone, DK none.
kcadm create clients -r "$REALM" -s clientId=admin -s publicClient=false >/dev/null
for role in content:read content:write; do
  kcadm create "clients/$(client_uuid "$REALM" admin)/roles" -r "$REALM" -s "name=$role" >/dev/null
done
create_group "$REALM" /UYELER DK
grant_group /ADMIN admin content:read
grant_group /ADMIN admin content:write
grant_group /UYELER/YK admin content:read
make_person "$REALM" dk-person /UYELER/DK
panel_uuid=$(client_uuid "$REALM" admin)
panel_seed_marks() {
  kcadm get "clients/$panel_uuid/roles" -r "$REALM" -q briefRepresentation=false \
    | jq -c 'map({key: .name, value: ((.attributes // {})["skylab.seeded-group-mappings"][0] // "")}) | from_entries'
}
panel_roles_before=$(kcadm get "clients/$panel_uuid/roles" -r "$REALM" | jq -c '[.[].name] | sort')
before=$(events "$REALM")
checked=$(reconcile_step 0 core-roles -e "KEYCLOAK_RECONCILE_KCADM_CONFIG=$KCADM_CONFIG" -e KEYCLOAK_RECONCILE_CHECK=true)
expect_line "$checked" '[reconcile] Privileged roles of admin (2): unchanged' 'the panel'"'"'s roles were not found'
expect_line "$checked" '[reconcile] admin role content:read: seeded once to /ADMIN,/UYELER/YK,/UYELER/DK (granted to: /UYELER/DK)' \
  'the dry run did not plan the panel'"'"'s content:read for DK alone'
expect_line "$checked" '[reconcile] admin role content:write: seeded once to /ADMIN,/UYELER/YK (granted to: /UYELER/YK)' \
  'the dry run did not plan the panel'"'"'s content:write for YK alone'
expect_line "$checked" "[reconcile] would kcadm create groups/$(group_id "$REALM" /UYELER/DK)/role-mappings/clients/$panel_uuid (body)" \
  'the dry run did not withhold the DK mapping'
expect_line "$checked" "[reconcile] would kcadm create groups/$(group_id "$REALM" /UYELER/YK)/role-mappings/clients/$panel_uuid (body)" \
  'the dry run did not withhold the YK mapping'
reject_line "$checked" "would kcadm create groups/$(group_id "$REALM" /ADMIN)/role-mappings/clients/$panel_uuid " \
  'the dry run planned a mapping ADMIN holds'
[[ $(grep -c 'would kcadm update roles-by-id/.* (-s attributes."skylab.seeded-group-mappings"' <<<"$checked" || true) -ge 2 ]] \
  || { printf '%s\n' "$checked" >&2; fail 'the dry run did not withhold the two marks'; }
expect_line "$checked" 'Core resource roles are checked; nothing was written' 'the dry run did not end as one'
[[ $(events "$REALM") == "$before" ]] || fail 'the core-roles dry run wrote something'
json_marks=$(panel_seed_marks)
jq -e '.["content:read"] == "" and .["content:write"] == ""' <<<"$json_marks" >/dev/null \
  || fail "the dry run marked a panel role: $json_marks"
seeded=$(reconcile_step 0 core-roles -e "KEYCLOAK_RECONCILE_KCADM_CONFIG=$KCADM_CONFIG")
expect_line "$seeded" '[reconcile] admin role content:read: seeded once to /ADMIN,/UYELER/YK,/UYELER/DK (granted to: /UYELER/DK)' \
  'the panel'"'"'s content:read was not seeded to DK'
expect_line "$seeded" '[reconcile] admin role content:write: seeded once to /ADMIN,/UYELER/YK (granted to: /UYELER/YK)' \
  'the panel'"'"'s content:write was not seeded to YK'
expect_line "$seeded" 'Core resource roles are reconciled.' 'the step did not end'
for path in /ADMIN /UYELER/YK; do
  group_roles "$REALM" "$path" | jq -e '(map(select(startswith("admin/")))) == ["admin/content:read", "admin/content:write"]' >/dev/null \
    || fail "$path does not hold exactly the panel's content:read and content:write: $(group_roles "$REALM" "$path")"
done
group_roles "$REALM" /UYELER/DK | jq -e '(map(select(startswith("admin/")))) == ["admin/content:read"]' >/dev/null \
  || fail "/UYELER/DK does not hold exactly the panel's content:read: $(group_roles "$REALM" /UYELER/DK)"
json_marks=$(panel_seed_marks)
jq -e '(.["content:read"] | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z /ADMIN,/UYELER/YK,/UYELER/DK$"))
  and (.["content:write"] | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z /ADMIN,/UYELER/YK$"))' <<<"$json_marks" >/dev/null \
  || fail "the panel's roles lack their marks: $json_marks"
[[ $(kcadm get "clients/$panel_uuid/roles" -r "$REALM" | jq -c '[.[].name] | sort') == "$panel_roles_before" ]] \
  || fail 'the step created or removed a role of the panel client'
[[ $(token_roles "$REALM" yk-person admin) == '["content:read","content:write"]' ]] \
  || fail "a YK duty member does not carry the panel's content:read and content:write: $(token_roles "$REALM" yk-person admin)"
[[ $(token_roles "$REALM" dk-person admin) == '["content:read"]' ]] \
  || fail "a DK member does not carry the panel's content:read alone: $(token_roles "$REALM" dk-person admin)"
again=$(reconcile_step 0 core-roles -e "KEYCLOAK_RECONCILE_KCADM_CONFIG=$KCADM_CONFIG")
reject_line "$again" '[reconcile] admin role content:' 'the second core-roles step seeded the panel'"'"'s roles again'
expect_line "$again" '[reconcile] group mappings of the admin Privileged roles: unchanged' 'the second step did not leave the panel mappings alone'
# The sandbox's panel client is superadmin: without its roles a "not in the realm" line and no seed;
# with them the dry run seeds superadmin's roles (the sandbox fixture has no DK: a WARNING), never admin's.
kcadm create clients -r "$SANDBOX" -s clientId=superadmin -s publicClient=false >/dev/null
sandbox_core_roles() {
  local output status
  trap - ERR
  output=$(docker exec -e KEYCLOAK_ADMIN_URL=http://localhost:8080 -e KEYCLOAK_REALM=$SANDBOX \
    -e KEYCLOAK_RECONCILE_ONLY=core-roles -e "KEYCLOAK_RECONCILE_KCADM_CONFIG=$KCADM_CONFIG" -e KEYCLOAK_RECONCILE_CHECK=true \
    "$CONTAINER" bash "$IN_CONTAINER_CONFIG/reconcile-account-center.sh" 2>&1) && status=0 || status=$?
  trap 'on_error "$LINENO"' ERR
  [[ $status == 0 ]] || { printf '%s\n' "$output" >&2; fail "the sandbox core-roles dry run failed (exit $status)"; }
  printf '%s\n' "$output"
}
skipped=$(sandbox_core_roles)
expect_line "$skipped" '[reconcile] Privileged roles of superadmin (2): unchanged; not in the realm, the application makes them, seeded once they exist: content:read content:write' \
  'the sandbox panel client without its roles was not reported'
reject_line "$skipped" 'role content:' 'the sandbox seeded a panel role the realm lacks'
for role in content:read content:write; do
  kcadm create "clients/$(client_uuid "$SANDBOX" superadmin)/roles" -r "$SANDBOX" -s "name=$role" >/dev/null
done
sandbox_before=$(events "$SANDBOX")
planned=$(sandbox_core_roles)
expect_line "$planned" '[reconcile] superadmin role content:read: seeded once to /ADMIN,/UYELER/YK (granted to: /ADMIN, /UYELER/YK)' \
  'the sandbox did not plan superadmin'"'"'s content:read'
expect_line "$planned" '[reconcile] superadmin role content:write: seeded once to /ADMIN,/UYELER/YK (granted to: /ADMIN, /UYELER/YK)' \
  'the sandbox did not plan superadmin'"'"'s content:write'
expect_line "$planned" "[reconcile] WARNING: no Privileged group DK (neither /DK nor /UYELER/DK) in realm $SANDBOX; it gets none of the superadmin Privileged roles" \
  'the sandbox without DK did not say so'
reject_line "$planned" '[reconcile] admin role content:' 'the sandbox seeded the production panel client'
[[ $(events "$SANDBOX") == "$sandbox_before" ]] || fail 'the sandbox dry run wrote something'
reject_line "$checked$seeded$again" 'dk-person' 'the step printed a person'
reject_line "$checked$seeded$again" 'yk-person' 'the step printed a person'
printf '    core-roles: the panel'"'"'s content:read to ADMIN, YK and DK and content:write to ADMIN and YK once (dry run first), marked, in the tokens; the sandbox seeds superadmin'"'"'s\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='app-assignments: the alarm on a realm without drift, the panel'"'"'s seeded Privileged mappings'
# The nightly alarm's run (config/app-assignments-alarm.sh) on the sandbox once its Privileged roles
# are seeded and every top team has a Leader: no drift (exit 0, alarm=0). After the seed a seeded
# role's Privileged mappings are the panel's: one taken away and one added in the panel are BILGI
# lines (S2-tohum) that never count, while a role no seed covers on a Privileged root is the code's
# (S2-fazla, exit 1, alarm=1). A not yet seeded role's missing mapping is S2-eksik (the stage above,
# YK's Forms seat). A reconciler that stops before the check prints no summary: exit 2. Every check
# reads every role's holders (minutes), so two runs.
alarm_run() { # alarm_run STATUS [docker exec -e options...]: the wrapper on the sandbox; prints the output
  local wanted=$1 output status=0
  shift
  trap - ERR
  output=$(docker exec -e KEYCLOAK_ADMIN_URL=http://localhost:8080 -e KEYCLOAK_REALM=$SANDBOX \
    -e "KEYCLOAK_RECONCILE_KCADM_CONFIG=$KCADM_CONFIG" "$@" "$CONTAINER" \
    bash "$IN_CONTAINER_CONFIG/app-assignments-alarm.sh" 2>&1) || status=$?
  trap 'on_error "$LINENO"' ERR
  [[ $status == "$wanted" ]] || { printf '%s\n' "$output" >&2; fail "the alarm did not exit $wanted (exit $status)"; }
  printf '%s\n' "$output"
}
trap - ERR
seeded=$(docker exec -e KEYCLOAK_ADMIN_URL=http://localhost:8080 -e KEYCLOAK_REALM=$SANDBOX \
  -e KEYCLOAK_RECONCILE_ONLY=core-roles -e "KEYCLOAK_RECONCILE_KCADM_CONFIG=$KCADM_CONFIG" \
  "$CONTAINER" bash "$IN_CONTAINER_CONFIG/reconcile-account-center.sh" 2>&1) && status=0 || status=$?
trap 'on_error "$LINENO"' ERR
[[ $status == 0 ]] || { printf '%s\n' "$seeded" >&2; fail "the sandbox core-roles step failed (exit $status)"; }
expect_line "$seeded" '[reconcile] skymail role skymail:access: seeded once to /ADMIN,/UYELER/YK' 'the sandbox did not seed SkyMail'"'"'s access'
make_person "$SANDBOX" sandbox-leader /UYELER/ARGE/AIRLAB/LIDERLER
create_group "$SANDBOX" /UYELER/ORGANIZASYON/ARTLAB LIDERLER
make_person "$SANDBOX" sandbox-artlab-leader /UYELER/ORGANIZASYON/ARTLAB/LIDERLER
sandbox_before=$(events "$SANDBOX")
clean=$(alarm_run 0)
expect_line "$clean" 'S2-eksik=0 S2-fazla=0 S2b=0 S3=0 S5=0 S2-tohum=0 (bilgi), alarm=0' 'the realm without drift is no alarm=0'
reject_line "$clean" 'SAPMA|' 'the realm without drift has a SAPMA line'
reject_line "$clean" 'not measured' 'the clean run was taken for one not measured'
expect_line "$clean" 'check: 0 change(s) pending' 'the check planned a change'
[[ $(events "$SANDBOX") == "$sandbox_before" ]] || fail 'the alarm wrote something'
printf '    alarm: the sandbox without drift exits 0 (alarm=0), writes nothing\n'
# The panel takes skymail:mails:write from ADMIN (its seed set ADMIN and YK): BILGI. skymail:mails:approve
# is seeded to YK alone: on a sub-group of /UYELER/YK it is the panel's (BILGI), on ADMIN and on a
# sub-group of ADMIN outside its seed set (ekip-yetkileri ticket 17: S2-fazla). skymail:templates:write is
# in no Privileged list: on ADMIN it is the code area's drift.
kcadm remove-roles -r "$SANDBOX" --gpath /ADMIN --cclientid skymail --rolename skymail:mails:write >/dev/null
kcadm add-roles -r "$SANDBOX" --gpath /ADMIN --cclientid skymail --rolename skymail:mails:approve >/dev/null
kcadm add-roles -r "$SANDBOX" --gpath /ADMIN --cclientid skymail --rolename skymail:templates:write >/dev/null
create_group "$SANDBOX" /ADMIN ALT
create_group "$SANDBOX" /UYELER/YK ALT
# By id: kcadm's --gpath search refuses a sub-group path ("not an exact match").
for path in /ADMIN/ALT /UYELER/YK/ALT; do
  kcadm create "groups/$(group_id "$SANDBOX" "$path")/role-mappings/clients/$(client_uuid "$SANDBOX" skymail)" -r "$SANDBOX" \
    -b "$(role_body "$SANDBOX" skymail skymail:mails:approve)" >/dev/null
done
sandbox_before=$(events "$SANDBOX")
changed=$(alarm_run 1)
expect_line "$changed" '[app-assignments] BILGI|S2-tohum|/ADMIN|skymail|skymail:mails:write|eksik' \
  'a seeded role the panel took from a Privileged root is no BILGI line'
expect_line "$changed" '[app-assignments] BILGI|S2-tohum|/UYELER/YK/ALT|skymail|skymail:mails:approve|fazla' \
  'a seeded role the panel gave a sub-group of its seed set is no BILGI line'
reject_line "$changed" 'SAPMA|S2-eksik|/ADMIN|skymail|skymail:mails:write' 'a panel change on a seeded Privileged role was taken for drift'
reject_line "$changed" 'SAPMA|S2-fazla|/UYELER/YK/ALT|' 'a panel change in a seed set was taken for drift'
expect_line "$changed" '[app-assignments] SAPMA|S2-fazla|/ADMIN|skymail|skymail:mails:approve' \
  'a seeded role on a Privileged root outside its seed set is no S2-fazla'
expect_line "$changed" '[app-assignments] SAPMA|S2-fazla|/ADMIN/ALT|skymail|skymail:mails:approve' \
  'a seeded role on a sub-group outside its seed set is no S2-fazla'
reject_line "$changed" 'BILGI|S2-tohum|/ADMIN|skymail|skymail:mails:approve' 'a seeded role outside its seed set was taken for the panel'"'"'s'
reject_line "$changed" 'BILGI|S2-tohum|/ADMIN/ALT|' 'a seeded role outside its seed set was taken for the panel'"'"'s'
expect_line "$changed" '[app-assignments] SAPMA|S2-fazla|/ADMIN|skymail|skymail:templates:write' \
  'a role no seed covers on a Privileged root is no S2-fazla'
reject_line "$changed" 'PROBLEM: skymail/skymail:mails:approve' 'a Privileged sub-group'"'"'s role was a PROBLEM'
expect_line "$changed" 'S2-eksik=0 S2-fazla=3 S2b=0 S3=0 S5=0 S2-tohum=2 (bilgi), alarm=3' \
  'the panel'"'"'s changes counted towards the alarm, or the code area'"'"'s did not'
[[ $(events "$SANDBOX") == "$sandbox_before" ]] || fail 'the alarm wrote something'
kcadm remove-roles -r "$SANDBOX" --gpath /ADMIN --cclientid skymail --rolename skymail:templates:write >/dev/null
kcadm delete "groups/$(group_id "$SANDBOX" /ADMIN/ALT)" -r "$SANDBOX" >/dev/null
kcadm delete "groups/$(group_id "$SANDBOX" /UYELER/YK/ALT)" -r "$SANDBOX" >/dev/null
printf '    alarm: a seeded Privileged role changed in its seed set (/<NAME>, /UYELER/<NAME>, a sub-group) is BILGI (S2-tohum), never counted; outside its seed set or with no seed it is S2-fazla (exit 1)\n'
# The reconciler stops at its realm read, before the check: no summary line, never drift.
stopped=$(alarm_run 2 -e KCADM_BIN=/tmp/kcadm-fail.sh -e "KCADM_INJECT_FAIL=realms/$SANDBOX")
expect_line "$stopped" '[app-assignments-alarm] not measured: exit ' 'the run without a summary was not reported'
expect_line "$stopped" '0 summary line(s)' 'the run without a summary was not counted'
reject_line "$stopped" '[app-assignments] SAPMA: S1=' 'the stopped reconciler summed up'
for name in sandbox-leader sandbox-artlab-leader; do
  reject_line "$clean$changed" "$name" 'the alarm printed a person'
done
printf '    alarm: a reconciler stopped before the check (no summary line) exits 2\n'

printf 'role-groups, leader-app-roles, app-assignments and default-roles contract passed.\n'
