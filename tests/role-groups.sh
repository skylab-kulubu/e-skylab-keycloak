#!/usr/bin/env bash
# Real-Keycloak contract for config/role-groups.sh (the application role groups /ROLLER/<APP>-<ROLE>,
# rol-temizligi ticket 05) and config/leader-app-roles.sh (the Forms seat on the Leader groups of the
# top teams, ticket 09), and for the reconciler's operator steps that run them
# (KEYCLOAK_RECONCILE_ONLY=role-groups and leader-app-roles). Stand-alone: starts the stock Keycloak
# image this repository builds on (the Dockerfile's KEYCLOAK_IMAGE) in dev mode with docker run --rm
# and no volume, copies config/ into the container and runs the scripts there the way an operator
# does; tokens are real password grants of a harness login client.
#
# Fixtures: realm e-skylab with the clients forms, place, skymail and cloudflare-zero-trust and their
# roles, the tree /ADMIN, /UYELER/YK (with a task group that has a LIDERLER group), the top teams
# /UYELER/ARGE/AIRLAB (LIDERLER, KOORDINATORLER and a Sub-team with its own LIDERLER) and
# /UYELER/ORGANIZASYON/ARTLAB (no Leader group); a person with a direct client role and a direct realm
# role, and /UYELER holding a realm role. Realm e-skylab-sandbox with forms (only skyforms:access) and
# skymail and nothing else.
#
# What it proves:
#   - every realm but e-skylab and e-skylab-sandbox is refused before a login (exit 2), an invalid
#     role group file too;
#   - role-groups: --check plans /ROLLER and the 13 leaves with their roles and writes nothing;
#     --apply makes exactly that (attributes, one client's roles a leaf, no member); a second --apply
#     writes nothing (no admin event); drift (a role taken away, an attribute changed) is repaired,
#     and what is beyond the file (an extra role on a leaf, a role on /ROLLER, a subgroup, a group
#     the file does not list) is a WARNING and stays; a member of a leaf carries its role in the
#     token; a default group under /ROLLER and a leaf named like a team are PROBLEMs (exit 1); in the
#     sandbox a leaf whose client is missing is skipped with a WARNING (exit 0);
#   - --audit counts direct holders and lists the groups outside the allowed places, and never
#     prints a person's name;
#   - leader-app-roles: only the top teams' LIDERLER and KOORDINATORLER get the four Forms roles (not
#     a Sub-team's, not a YK task group's); a second --apply writes nothing; a Leader's token carries
#     skyforms:access; a Sub-team Leader group holding it is a WARNING, a direct holder a NOTE with a
#     count; in the sandbox a missing role is skipped with a WARNING;
#   - the reconciler's operator steps run both scripts (dry run with KEYCLOAK_RECONCILE_CHECK=true)
#     and refuse to run without an operator session.
# Requirements on the host: docker, curl, jq. ROLE_GROUPS_TEST_PORT (default 18096),
# ROLE_GROUPS_TEST_CONTAINER (default role-groups-test-<pid>).
# shellcheck disable=SC2016  # jq programs name jq variables
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
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
  SKYMAIL-MAILS-APPROVE CF-ZERO-TRUST-ACCESS)
FORMS_ROLES='["skyforms:access","skyforms:feedback:manage","skyforms:form:manage","skyforms:response:manage"]'
CURRENT_STAGE=startup

fail() {
  printf 'role-groups failure during %s: %s\n' "$CURRENT_STAGE" "$1" >&2
  exit 1
}
cleanup() {
  docker rm -fv "$CONTAINER" >/dev/null 2>&1 || true
}
trap 'status=$?; trap - EXIT; cleanup; exit "$status"' EXIT
on_error() {
  local status=$?
  printf 'role-groups command failed during %s (line %s)\n' "$CURRENT_STAGE" "$1" >&2
  exit "$status"
}
trap 'on_error "$LINENO"' ERR

kcadm() {
  local command=$1
  shift
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
jq -e '.groups | length == 13' "$REPOSITORY_ROOT/config/role-groups.json" >/dev/null \
  || fail 'config/role-groups.json does not list the 13 role groups of the ticket'
# Static rules of the file (the script enforces them too): the team code name rule, one client a
# leaf, no leaf name containing a team code of the club.
jq -e '[.groups[].name] | all(test("^[A-Z][A-Z0-9-]{1,23}$")) and (unique | length == 13)' \
  "$REPOSITORY_ROOT/config/role-groups.json" >/dev/null || fail 'a role group name breaks the team code rule'
jq -e '.groups | all((.client | type) == "string" and (.roles | length) > 0)' \
  "$REPOSITORY_ROOT/config/role-groups.json" >/dev/null || fail 'a role group does not name exactly one client'
for code in AIRLAB ALGOLAB BIZBIZE GECEKODU MOBILAB SKYDEVOPS SKYSEC WEBLAB CHAINLAB GAMELAB SKYSIS ARTLAB \
  YILDIZJAM SKYDAYS AGC; do
  jq -e --arg c "$code" '[.groups[].name] | all(contains($c) | not)' "$REPOSITORY_ROOT/config/role-groups.json" >/dev/null \
    || fail "a role group name contains the team code $code"
done
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
docker cp "$REPOSITORY_ROOT/config/." "$CONTAINER:$IN_CONTAINER_CONFIG/" >/dev/null

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='refused realms and an invalid file'
for script in role-groups.sh leader-app-roles.sh; do
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
expect_line "$checked" 'check: 27 change(s) pending, 0 warning(s), 0 problem(s)' 'the dry run did not count 1 + 13 + 13 changes'
! group_exists "$REALM" /ROLLER || fail 'the dry run created /ROLLER'
[[ $(events "$REALM") == "$before" ]] || fail 'the dry run wrote something'
printf '    --check plans /ROLLER, 13 leaves and 13 mappings and writes nothing\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='role-groups: applied, then nothing more'
applied=$(run_expecting 0 role-groups.sh "$REALM" --apply)
expect_line "$applied" 'applied 27 change(s), 0 warning(s), 0 problem(s)' 'the apply did not make the planned changes'
[[ $(group_roles "$REALM" /ROLLER) == '[]' ]] || fail '/ROLLER holds a role'
root=$(kcadm get "groups/$(group_id "$REALM" /ROLLER)" -r "$REALM")
jq -e '.attributes.display_name_tr == ["Rol grupları"] and (.attributes.description_tr[0] | length) > 20' <<<"$root" >/dev/null \
  || fail "/ROLLER lacks its attributes: $root"
[[ $(kcadm get "groups/$(group_id "$REALM" /ROLLER)/children" -r "$REALM" -q max=100 | jq -c '[.[].name] | sort') \
  == "$(printf '%s\n' "${LEAVES[@]}" | jq -R . | jq -sc 'sort')" ]] || fail '/ROLLER does not hold exactly the 13 leaves'
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
printf '    --apply made /ROLLER and the 13 leaves (attributes, roles, no member); a second --apply writes nothing\n'

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
audited=$(run_expecting 0 role-groups.sh "$REALM" --audit)
expect_line "$audited" 'audit: skymail/skymail:mails:write: 1 person(s) directly; groups: /ROLLER/SKYMAIL-MAILS-WRITE' 'the per-role count is wrong'
expect_line "$audited" 'audit K1: 1 person(s) hold client roles directly, 1 person(s) hold realm roles directly' 'K1 is wrong'
expect_line "$audited" 'audit K4: 1 group(s) hold roles outside the allowed places:' 'K4 is wrong'
expect_line "$audited" 'audit K4:   /UYELER: realm/USER' 'K4 did not name /UYELER'
reject_line "$audited" 'audit K4:   /ROLLER/' 'K4 reported a role group'
for name in direct-person leader-person role-group-person sub-leader-person; do
  reject_line "$audited" "$name" 'the audit printed a person'
done
printf '    --audit: per-role counts, K1 and K4 without a name\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='role-groups: a default group under /ROLLER and a team-like name are refused'
mail_access=$(group_id "$REALM" /ROLLER/SKYMAIL-ACCESS)
kcadm update "realms/$REALM/default-groups/$mail_access" -n -b '{}' >/dev/null
before=$(events "$REALM")
refused=$(run_expecting 1 role-groups.sh "$REALM" --apply)
expect_line "$refused" 'PROBLEM: the default group /ROLLER/SKYMAIL-ACCESS is at or under /ROLLER' 'the default group was not refused'
[[ $(events "$REALM") == "$before" ]] || fail 'the run wrote something next to a default group under /ROLLER'
kcadm delete "realms/$REALM/default-groups/$mail_access" >/dev/null
create_group "$REALM" /UYELER/ARGE MAILS
refused=$(run_expecting 1 role-groups.sh "$REALM")
expect_line "$refused" 'PROBLEM: /ROLLER/SKYMAIL-MAILS-READ: the name contains the team code MAILS' 'a team-like leaf name was not refused'
kcadm delete "groups/$(group_id "$REALM" /UYELER/ARGE/MAILS)" -r "$REALM" >/dev/null
printf '    a default group under /ROLLER and a leaf named like a team are PROBLEMs (exit 1)\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='role-groups: the sandbox skips the leaves of missing clients'
applied=$(run_expecting 0 role-groups.sh "$SANDBOX" --apply)
for leaf in PLACE-ADMIN PLACE-MODERATOR; do
  expect_line "$applied" "WARNING: /ROLLER/$leaf: the client place does not exist in realm $SANDBOX; skipped (not created)" "$leaf was not skipped"
done
expect_line "$applied" "WARNING: /ROLLER/FORMS-ALL: the role forms/skyforms:* does not exist in realm $SANDBOX; skipped (not created)" 'FORMS-ALL was not skipped'
expect_line "$applied" "WARNING: /ROLLER/CF-ZERO-TRUST-ACCESS: the client cloudflare-zero-trust does not exist in realm $SANDBOX" 'CF was not skipped'
expect_line "$applied" 'applied 19 change(s), 4 warning(s), 0 problem(s)' 'the sandbox apply did not make the 9 leaves'
! group_exists "$SANDBOX" /ROLLER/PLACE-ADMIN || fail 'a leaf without its client was created'
[[ $(group_roles "$SANDBOX" /ROLLER/FORMS-ACCESS) == '["forms/skyforms:access"]' ]] || fail 'the sandbox FORMS-ACCESS is wrong'
printf '    sandbox: 9 leaves made, 4 skipped with a WARNING (exit 0)\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='leader-app-roles: only the top teams Leader groups'
before=$(events "$REALM")
checked=$(run_expecting 0 leader-app-roles.sh "$REALM")
expect_line "$checked" 'Leader groups of the top teams: 2' 'the top teams were not read from the tree'
expect_line "$checked" 'would grant forms/skyforms:access skyforms:form:manage skyforms:response:manage skyforms:feedback:manage to the group /UYELER/ARGE/AIRLAB/LIDERLER' 'LIDERLER was not planned'
expect_line "$checked" 'would grant forms/skyforms:access skyforms:form:manage skyforms:response:manage skyforms:feedback:manage to the group /UYELER/ARGE/AIRLAB/KOORDINATORLER' 'KOORDINATORLER was not planned'
expect_line "$checked" 'NOTE: /UYELER/ORGANIZASYON/ARTLAB has no LIDERLER or KOORDINATORLER group' 'the team without Leaders was not noted'
expect_line "$checked" 'NOTE: forms/skyforms:access is granted directly to 1 person(s)' 'the direct holder was not counted'
reject_line "$checked" 'SUB/LIDERLER' 'a Sub-team Leader group was planned'
reject_line "$checked" '/UYELER/YK/' 'a YK task group was planned'
reject_line "$checked" 'direct-person' 'a person was named'
expect_line "$checked" 'check: 2 change(s) pending, 0 warning(s), 0 problem(s)' 'the dry run did not count two grants'
[[ $(events "$REALM") == "$before" ]] || fail 'the dry run wrote something'
applied=$(run_expecting 0 leader-app-roles.sh "$REALM" --apply)
expect_line "$applied" 'applied 2 change(s), 0 warning(s), 0 problem(s)' 'the apply did not grant'
for path in /UYELER/ARGE/AIRLAB/LIDERLER /UYELER/ARGE/AIRLAB/KOORDINATORLER; do
  [[ $(group_roles "$REALM" "$path" | jq -c 'map(ltrimstr("forms/"))') == "$FORMS_ROLES" ]] || fail "$path does not hold exactly the four Forms roles"
done
[[ $(group_roles "$REALM" /UYELER/ARGE/AIRLAB/SUB/LIDERLER) == '[]' ]] || fail 'the Sub-team Leader group got a role'
[[ $(group_roles "$REALM" /UYELER/YK/BASKAN/LIDERLER) == '[]' ]] || fail 'the YK task group got a role'
[[ $(token_roles "$REALM" leader-person forms) == "$FORMS_ROLES" ]] || fail "the Leader's token lacks the Forms seat: $(token_roles "$REALM" leader-person forms)"
[[ $(token_roles "$REALM" sub-leader-person forms) == '[]' ]] || fail "the Sub-team Leader's token carries a Forms role"
before=$(events "$REALM")
again=$(run_expecting 0 leader-app-roles.sh "$REALM" --apply)
expect_line "$again" 'applied 0 change(s), 0 warning(s), 0 problem(s)' 'the second apply changed something'
[[ $(events "$REALM") == "$before" ]] || fail 'the second apply wrote something'
kcadm create "groups/$(group_id "$REALM" /UYELER/ARGE/AIRLAB/SUB/LIDERLER)/role-mappings/clients/$(client_uuid "$REALM" forms)" \
  -r "$REALM" -b "$(role_body "$REALM" forms skyforms:access)" >/dev/null
checked=$(run_expecting 0 leader-app-roles.sh "$REALM")
expect_line "$checked" 'WARNING: forms/skyforms:access is also held by the group(s) /UYELER/ARGE/AIRLAB/SUB/LIDERLER' 'the Sub-team holder was not reported'
reject_line "$checked" '/ROLLER/FORMS-ACCESS (' 'the role group was reported as a stray holder'
printf '    leader-app-roles: the two top team Leader groups get the four Forms roles, nothing more; idempotent\n'

CURRENT_STAGE='leader-app-roles: the sandbox skips the missing roles'
applied=$(run_expecting 0 leader-app-roles.sh "$SANDBOX" --apply)
expect_line "$applied" "WARNING: the role forms/skyforms:form:manage does not exist in realm $SANDBOX; skipped (not created)" 'a missing role was not skipped'
expect_line "$applied" 'applied 2 change(s), 3 warning(s), 0 problem(s)' 'the sandbox grants are wrong'
[[ $(group_roles "$SANDBOX" /UYELER/ARGE/AIRLAB/LIDERLER) == '["forms/skyforms:access"]' ]] || fail 'the sandbox Leader group is wrong'
printf '    sandbox: skyforms:access granted, three missing roles skipped with a WARNING\n'

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
printf '    KEYCLOAK_RECONCILE_ONLY=role-groups and leader-app-roles run the scripts; refused without an operator session\n'

printf 'role-groups and leader-app-roles contract passed.\n'
