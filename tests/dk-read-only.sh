#!/usr/bin/env bash
# Real-Keycloak contract for DK's read-only standing (grup-yonetimi ticket 08, decision GY1): the
# reconciler's core-roles step seeds DK's read roles, and config/dk-read-only.sh takes DK's write
# roles away once, with a backup it can restore. Stand-alone: starts the stock Keycloak image this
# repository builds on (the Dockerfile's KEYCLOAK_IMAGE) in dev mode with docker run --rm and no
# volume, copies config/ into the container and runs the scripts there the way an operator does;
# tokens are real password grants of a harness login client (full scope: every client's roles).
#
# Fixtures: realm e-skylab in production's shape before this change: core's 14 write roles of the
# contract table seeded once (marked) to /ADMIN, /UYELER/YK and /UYELER/DK; SkyMail's two Privileged
# roles seeded (system-mails:read to the three, announcements:send to ADMIN and YK); the event site
# client frontend-artlab with cms:access (a composite of content:read and content:write) on the three
# and client:admin on ADMIN and YK; forms with skyforms:* on /ADMIN and /UYELER/DK; the Java era's realm
# role DK on /UYELER/DK; a YK person and a DK person. Realm e-skylab-sandbox has no DK group.
#
# What it proves:
#   - every realm but e-skylab and e-skylab-sandbox is refused before a login (exit 2), and so are an
#     unreadable backup, a backup line that is no DK write role mapping (another group, another
#     client's role, realm-management) and --forms or --backup-file next to --restore;
#   - before the core-roles step DK holds no core/global:read: the dry run names the step as a
#     PROBLEM (exit 1) and nothing is written;
#   - the reconciler's core-roles step (operator session) creates core/global:read and audit:read and
#     forms/skyforms:read-all and seeds them once: global:read and skyforms:read-all to /UYELER/DK
#     only, audit:read to /ADMIN, /UYELER/YK and /UYELER/DK; the write roles' marks keep them where
#     they are; a second run seeds nothing;
#   - dk-read-only.sh --check lists the 14 core roles and frontend-artlab/cms:access to take away,
#     content:read to grant in its place, the kept read roles, skyforms:* kept for Forms and the realm
#     role DK as a WARNING, and writes nothing (no admin event);
#   - --apply writes the backup, takes exactly that away and grants content:read; ADMIN's and YK's
#     mappings do not change; the DK person's token then carries core [audit:read, global:read],
#     frontend-artlab [content:read], skymail [system-mails:read], forms [skyforms:*,
#     skyforms:read-all]; the YK person's is unchanged; --check then says "write roles held: none"
#     with 0 changes, and a second --apply writes nothing (no admin event, no backup);
#   - --restore BACKUP is a dry run by default and with --apply grants every mapping back (content:read
#     stays); a second restore writes nothing;
#   - --forms takes skyforms:* away too, only while DK holds skyforms:read-all (else a PROBLEM);
#   - a write role DK still gets through a composite role is a WARNING; a default group under DK and a
#     failed read (injected: the DK group, its role mappings) stop the run with exit 1 and write
#     nothing; the sandbox realm without DK has nothing to do.
# Requirements on the host: docker, curl, jq. DK_READ_ONLY_TEST_PORT (default 18097),
# DK_READ_ONLY_TEST_CONTAINER (default dk-read-only-test-<pid>).
# shellcheck disable=SC2016  # jq programs name jq variables
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPOSITORY_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
IMAGE=$(sed -n 's/^ARG KEYCLOAK_IMAGE=//p' "$REPOSITORY_ROOT/Dockerfile")
PORT=${DK_READ_ONLY_TEST_PORT:-18097}
BASE_URL="http://127.0.0.1:$PORT"
CONTAINER=${DK_READ_ONLY_TEST_CONTAINER:-dk-read-only-test-$$}
ADMIN_PASSWORD=harness-admin-password
PEOPLE_PASSWORD=harness-people-password-1
KCADM_CONFIG=/tmp/harness-kcadm.config
IN_CONTAINER_CONFIG=/tmp/config
REALM=e-skylab
SANDBOX=e-skylab-sandbox
DK=/UYELER/DK
# core's write roles of the contract table (core-backend docs/authz-roles.md: the 12 write roles,
# url:moderator and url:access), as the core-roles step seeded them to ADMIN, YK and DK.
CORE_WRITE_ROLES=(event:manage season:manage ticket:manage ticket:validate competitor:manage
  competition:manage media:manage media:private:read certificate:manage users:manage groups:manage
  github:activity:read url:moderator url:access)
OLD_MARK='2026-10-04T09:00:00Z /ADMIN,/UYELER/YK,/UYELER/DK'
CURRENT_STAGE=startup

fail() {
  printf 'dk-read-only failure during %s: %s\n' "$CURRENT_STAGE" "$1" >&2
  exit 1
}
cleanup() {
  docker rm -fv "$CONTAINER" >/dev/null 2>&1 || true
}
trap 'status=$?; trap - EXIT; cleanup; exit "$status"' EXIT
on_error() {
  local status=$?
  printf 'dk-read-only command failed during %s (line %s)\n' "$CURRENT_STAGE" "$1" >&2
  exit "$status"
}
trap 'on_error "$LINENO"' ERR

kcadm() {
  local command=$1
  shift
  docker exec -i "$CONTAINER" /opt/keycloak/bin/kcadm.sh "$command" --config "$KCADM_CONFIG" "$@" \
    2> >(grep -v -e '^Created new ' -e '^$' >&2 || true)
}

# run_expecting STATUS REALM ARGS...: config/dk-read-only.sh with the harness's kcadm session, for a
# run that must exit STATUS; prints the output. DK_ENV holds extra docker exec -e options.
DK_ENV=()
run_expecting() {
  local wanted=$1 realm=$2 output status=0
  shift 2
  trap - ERR
  output=$(docker exec -e KEYCLOAK_ADMIN_URL=http://localhost:8080 -e KEYCLOAK_REALM="$realm" \
    ${DK_ENV[@]+"${DK_ENV[@]}"} "$CONTAINER" \
    bash "$IN_CONTAINER_CONFIG/dk-read-only.sh" --kcadm-config "$KCADM_CONFIG" "$@" 2>&1) || status=$?
  trap 'on_error "$LINENO"' ERR
  [[ $status == "$wanted" ]] || { printf '%s\n' "$output" >&2; fail "dk-read-only.sh $* did not exit $wanted (exit $status)"; }
  printf '%s\n' "$output"
}

# core_roles_step: the reconciler's operator step KEYCLOAK_RECONCILE_ONLY=core-roles; prints the output.
core_roles_step() {
  local output status=0
  trap - ERR
  output=$(docker exec -e KEYCLOAK_ADMIN_URL=http://localhost:8080 -e KEYCLOAK_REALM=$REALM \
    -e KEYCLOAK_RECONCILE_ONLY=core-roles -e "KEYCLOAK_RECONCILE_KCADM_CONFIG=$KCADM_CONFIG" "$CONTAINER" \
    bash "$IN_CONTAINER_CONFIG/reconcile-account-center.sh" 2>&1) || status=$?
  trap 'on_error "$LINENO"' ERR
  [[ $status == 0 ]] || { printf '%s\n' "$output" >&2; fail "the core-roles step failed (exit $status)"; }
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

# group_roles PATH: the group's direct role mappings in REALM as sorted "client/role" (realm/role).
group_roles() {
  kcadm get "groups/$(group_id "$REALM" "$1")/role-mappings" -r "$REALM" \
    | jq -c '[(.realmMappings // [])[] | "realm/" + .name] + [(.clientMappings // {}) | to_entries[] | .key as $c | .value.mappings[] | $c + "/" + .name] | sort'
}

create_group() { # create_group REALM PARENT_PATH NAME (PARENT_PATH empty for a top-level group)
  if [[ -z $2 ]]; then
    kcadm create groups -r "$1" -s "name=$3" >/dev/null
  else
    kcadm create "groups/$(group_id "$1" "$2")/children" -r "$1" -s "name=$3" >/dev/null
  fi
}

role_body() { # role_body CLIENT ROLE... (in REALM)
  local client=$1 uuid
  shift
  uuid=$(client_uuid "$REALM" "$client")
  kcadm get "clients/$uuid/roles" -r "$REALM" | jq -c --args '[.[] | select(.name as $n | $ARGS.positional | index($n)) | {id, name}]' "$@"
}

grant() { # grant PATH CLIENT ROLE...
  local path=$1 client=$2
  shift 2
  kcadm create "groups/$(group_id "$REALM" "$path")/role-mappings/clients/$(client_uuid "$REALM" "$client")" -r "$REALM" \
    -b "$(role_body "$client" "$@")" >/dev/null
}

ungrant() { # ungrant PATH CLIENT ROLE...
  local path=$1 client=$2
  shift 2
  kcadm delete "groups/$(group_id "$REALM" "$path")/role-mappings/clients/$(client_uuid "$REALM" "$client")" -r "$REALM" \
    -b "$(role_body "$client" "$@")" >/dev/null
}

mark() { # mark CLIENT ROLE VALUE: the seed mark of the reconciler (skylab.seeded-group-mappings)
  kcadm update "clients/$(client_uuid "$REALM" "$1")/roles/$2" -r "$REALM" \
    -s "attributes.\"skylab.seeded-group-mappings\"=[\"$3\"]" >/dev/null
}

seed_mark() { # seed_mark CLIENT ROLE: the role's seed mark ("" when absent)
  kcadm get "clients/$(client_uuid "$REALM" "$1")/roles/$2" -r "$REALM" \
    | jq -r '(.attributes // {})["skylab.seeded-group-mappings"][0] // ""'
}

events() { # events: the number of admin events of REALM so far
  kcadm get admin-events -r "$REALM" -q max=100000 | jq length
}

make_person() { # make_person USERNAME GROUP_PATH
  local user_id
  kcadm create users -r "$REALM" -s "username=$1" -s enabled=true -s "email=$1@example.test" -s emailVerified=true \
    -s firstName=Harness -s lastName=Person >/dev/null
  kcadm set-password -r "$REALM" --username "$1" --new-password "$PEOPLE_PASSWORD" >/dev/null
  user_id=$(kcadm get users -r "$REALM" -q "username=$1" -q exact=true | jq -r '.[0].id')
  kcadm update "users/$user_id/groups/$(group_id "$REALM" "$2")" -r "$REALM" -n -b '{}' >/dev/null
}

# token_roles USERNAME: resource_access of the person's access token as {client: sorted roles}.
token_roles() {
  local token segment
  token=$(curl -fsS "$BASE_URL/realms/$REALM/protocol/openid-connect/token" \
    --data-urlencode grant_type=password --data-urlencode client_id=harness-login \
    --data-urlencode "username=$1" --data-urlencode "password=$PEOPLE_PASSWORD" | jq -r .access_token)
  segment=$(cut -d. -f2 <<<"$token" | tr '_-' '/+')
  case $(( ${#segment} % 4 )) in 2) segment+='==' ;; 3) segment+='=' ;; esac
  base64 -d <<<"$segment" | jq -cS '(.resource_access // {}) | del(.account) | map_values(.roles | sort)'
}

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='Keycloak start'
[[ -n $IMAGE ]] || fail 'Dockerfile has no ARG KEYCLOAK_IMAGE'
for tool in jq curl; do command -v "$tool" >/dev/null || fail "$tool is required"; done
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
docker exec -i "$CONTAINER" sh -c 'cat > /tmp/kcadm-fail.sh && chmod 755 /tmp/kcadm-fail.sh' \
  <"$SCRIPT_DIR/kcadm-core-roles-failure.sh"

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='refused realms, backups and options'
refused=$(run_expecting 2 master --apply)
expect_line "$refused" 'refusing realm master' 'master was not refused'
reject_line "$refused" 'realm=' 'the script went on in master'
refused=$(run_expecting 2 "$REALM" --restore /tmp/no-such-backup.tsv)
expect_line "$refused" 'is not readable' 'an unreadable backup was not refused'
for line in '/ADMIN\tcore\tevent:manage' '/UYELER/DK\trealm-management\tmanage-users' '/UYELER/DK\tcore\tglobal:read' \
  '/UYELER/DK\tcore' '/UYELER/DK/SUB\tcore\tevent:manage'; do
  printf '# dk-read-only backup\n%b\n' "$line" | docker exec -i "$CONTAINER" sh -c 'cat > /tmp/bad-backup.tsv'
  refused=$(run_expecting 2 "$REALM" --restore /tmp/bad-backup.tsv --apply)
  expect_line "$refused" 'is not a dk-read-only backup' "the backup line $line was not refused"
  reject_line "$refused" 'realm=' "the script logged in for the backup line $line"
done
refused=$(run_expecting 2 "$REALM" --restore /tmp/bad-backup.tsv --forms)
expect_line "$refused" 'usage:' '--forms with --restore was not a usage error'
refused=$(run_expecting 2 "$REALM" --restore /tmp/bad-backup.tsv --backup-file /tmp/x.tsv)
expect_line "$refused" 'usage:' '--backup-file with --restore was not a usage error'
printf '    master, unreadable and foreign backups, --forms and --backup-file with --restore refused (exit 2)\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='fixtures (production before the change)'
kcadm create realms -s realm="$REALM" -s enabled=true -s adminEventsEnabled=true >/dev/null
kcadm create realms -s realm="$SANDBOX" -s enabled=true >/dev/null
kcadm create clients -r "$REALM" -s clientId=harness-login -s publicClient=true -s standardFlowEnabled=false \
  -s directAccessGrantsEnabled=true >/dev/null
for client in core forms frontend-artlab; do
  kcadm create clients -r "$REALM" -s clientId=$client -s publicClient=false -s standardFlowEnabled=false \
    -s serviceAccountsEnabled=true >/dev/null
done
kcadm create clients -r "$REALM" -s clientId=skymail -s publicClient=true >/dev/null
for role in "${CORE_WRITE_ROLES[@]}" url:create; do
  kcadm create "clients/$(client_uuid "$REALM" core)/roles" -r "$REALM" -s "name=$role" >/dev/null
done
for role in skymail:access skymail:system-mails:read skymail:announcements:send; do
  kcadm create "clients/$(client_uuid "$REALM" skymail)/roles" -r "$REALM" -s "name=$role" >/dev/null
done
for role in 'skyforms:*' skyforms:access; do
  kcadm create "clients/$(client_uuid "$REALM" forms)/roles" -r "$REALM" -s "name=$role" >/dev/null
done
artlab=$(client_uuid "$REALM" frontend-artlab)
for role in content:read content:write cms:access client:admin; do
  kcadm create "clients/$artlab/roles" -r "$REALM" -s "name=$role" >/dev/null
done
kcadm create "clients/$artlab/roles/cms:access/composites" -r "$REALM" \
  -b "$(role_body frontend-artlab content:read content:write)" >/dev/null
kcadm create roles -r "$REALM" -s name=DK >/dev/null
create_group "$REALM" '' ADMIN
create_group "$REALM" '' UYELER
create_group "$REALM" /UYELER YK
create_group "$REALM" /UYELER DK
create_group "$SANDBOX" '' ADMIN
for path in /ADMIN /UYELER/YK "$DK"; do
  grant "$path" core "${CORE_WRITE_ROLES[@]}"
  grant "$path" skymail skymail:system-mails:read
  grant "$path" frontend-artlab cms:access
done
for path in /ADMIN /UYELER/YK; do
  grant "$path" skymail skymail:announcements:send
  grant "$path" frontend-artlab client:admin
done
for path in /ADMIN "$DK"; do grant "$path" forms 'skyforms:*'; done
kcadm create "groups/$(group_id "$REALM" "$DK")/role-mappings/realm" -r "$REALM" \
  -b "$(kcadm get roles/DK -r "$REALM" | jq -c '[{id, name}]')" >/dev/null
for role in "${CORE_WRITE_ROLES[@]}"; do mark core "$role" "$OLD_MARK"; done
mark skymail skymail:system-mails:read "$OLD_MARK"
mark skymail skymail:announcements:send '2026-10-13T09:00:00Z /ADMIN,/UYELER/YK'
make_person yk-person /UYELER/YK
make_person dk-person "$DK"
yk_token_before=$(token_roles yk-person)

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='before the core-roles step: DK holds no global:read'
before=$(events)
refused=$(run_expecting 1 "$REALM")
expect_line "$refused" "PROBLEM: $DK holds no core/global:read" 'the missing read role was not a PROBLEM'
expect_line "$refused" 'KEYCLOAK_RECONCILE_ONLY=core-roles' 'the PROBLEM does not name the core-roles step'
[[ $(events) == "$before" ]] || fail 'the refused run wrote something'
printf '    before the core-roles step: PROBLEM (no core/global:read on DK), exit 1, nothing written\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='the core-roles step seeds DK'"'"'s read roles'
seeded=$(core_roles_step)
expect_line "$seeded" '[reconcile] client roles of core (16 resource roles): created (global:read, audit:read)' 'the core read roles were not created'
expect_line "$seeded" "[reconcile] core role global:read: seeded once to $DK (granted to: $DK)" 'global:read was not seeded to DK alone'
expect_line "$seeded" "[reconcile] core role audit:read: seeded once to /ADMIN,/UYELER/YK,$DK (granted to: /ADMIN, /UYELER/YK, $DK)" 'audit:read was not seeded to ADMIN, YK and DK'
expect_line "$seeded" '[reconcile] Privileged roles of forms (1): created (skyforms:read-all)' 'skyforms:read-all was not created'
expect_line "$seeded" "[reconcile] forms role skyforms:read-all: seeded once to $DK (granted to: $DK)" 'skyforms:read-all was not seeded to DK alone'
expect_line "$seeded" '[reconcile] group mappings of the skymail Privileged roles: unchanged' 'the seeded skymail roles were touched'
reject_line "$seeded" 'core role event:manage' 'a marked write role was seeded again'
reject_line "$seeded" 'WARNING: no Privileged group' 'a Privileged group was reported missing'
[[ $(seed_mark core global:read) =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\ /UYELER/DK$ ]] \
  || fail "global:read lacks its mark: $(seed_mark core global:read)"
[[ $(seed_mark core event:manage) == "$OLD_MARK" ]] || fail 'the mark of a write role changed'
for path in /ADMIN /UYELER/YK; do
  group_roles "$path" | jq -e 'index("core/audit:read") != null and index("core/global:read") == null and index("forms/skyforms:read-all") == null' >/dev/null \
    || fail "$path does not hold audit:read alone of the read roles: $(group_roles "$path")"
done
group_roles "$DK" | jq -e 'index("core/audit:read") != null and index("core/global:read") != null and index("forms/skyforms:read-all") != null' >/dev/null \
  || fail "DK did not get its read roles: $(group_roles "$DK")"
again=$(core_roles_step)
reject_line "$again" ': seeded once' 'the second core-roles step seeded something'
expect_line "$again" '[reconcile] group mappings of the core resource roles: unchanged' 'the second step did not leave the core mappings alone'
expect_line "$again" '[reconcile] group mappings of the forms Privileged roles: unchanged' 'the second step did not leave the forms mapping alone'
admin_after_seed=$(group_roles /ADMIN)
yk_after_seed=$(group_roles /UYELER/YK)
dk_after_seed=$(group_roles "$DK")
printf '    core-roles: global:read and skyforms:read-all to DK, audit:read to ADMIN, YK and DK, once; write roles untouched\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='dk-read-only.sh --check plans and writes nothing'
before=$(events)
checked=$(run_expecting 0 "$REALM")
for role in "${CORE_WRITE_ROLES[@]}"; do
  expect_line "$checked" "would take core/$role away from $DK" "core/$role was not planned away"
done
expect_line "$checked" "would take frontend-artlab/cms:access away from $DK" 'the site editor role was not planned away'
expect_line "$checked" "would grant frontend-artlab/content:read to $DK (in place of cms:access)" 'content:read was not planned in its place'
expect_line "$checked" "$DK: read roles kept: core/audit:read, core/global:read, forms/skyforms:read-all, skymail/skymail:system-mails:read" 'the read roles were not listed'
expect_line "$checked" "NOTE: $DK: Forms roles kept until forms-backend reads forms/skyforms:read-all: forms/skyforms:*" 'the Forms roles were not kept'
expect_line "$checked" "WARNING: $DK holds realm/DK, which this step does not sort; kept" 'the realm role was not a WARNING'
expect_line "$checked" "$DK: write roles held: 15 (" 'the write roles were not counted'
expect_line "$checked" 'check: 16 change(s) pending, 1 warning(s), 0 problem(s)' 'the dry run did not count 15 removals and 1 grant'
reject_line "$checked" '/ADMIN' 'the dry run planned something on ADMIN'
reject_line "$checked" '/UYELER/YK' 'the dry run planned something on YK'
for name in yk-person dk-person; do reject_line "$checked" "$name" 'a person was named'; done
[[ $(events) == "$before" ]] || fail 'the dry run wrote something'
[[ $(group_roles "$DK") == "$dk_after_seed" ]] || fail 'the dry run changed DK'
printf '    --check: 15 write roles away, content:read in place, reads and Forms kept, realm role a WARNING; nothing written\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='dk-read-only.sh --apply'
applied=$(run_expecting 0 "$REALM" --apply --backup-file /tmp/dk-backup.tsv)
expect_line "$applied" 'applied 16 change(s), 1 warning(s), 0 problem(s)' 'the apply did not make the planned changes'
expect_line "$applied" 'backup: /tmp/dk-backup.tsv (15 mapping(s) taken away; put them back with --restore /tmp/dk-backup.tsv --apply)' 'the backup was not reported'
[[ $(group_roles "$DK") == '["core/audit:read","core/global:read","forms/skyforms:*","forms/skyforms:read-all","frontend-artlab/content:read","realm/DK","skymail/skymail:system-mails:read"]' ]] \
  || fail "DK does not hold exactly its read roles, Forms' kept role and the realm role: $(group_roles "$DK")"
[[ $(group_roles /ADMIN) == "$admin_after_seed" ]] || fail 'the apply changed ADMIN'
[[ $(group_roles /UYELER/YK) == "$yk_after_seed" ]] || fail 'the apply changed YK'
backup=$(docker exec "$CONTAINER" cat /tmp/dk-backup.tsv)
[[ $(grep -vc '^#' <<<"$backup") == 15 ]] || fail "the backup does not hold the 15 mappings: $backup"
for role in "${CORE_WRITE_ROLES[@]}"; do
  grep -Fxq "$DK"$'\t'core$'\t'"$role" <<<"$backup" || fail "the backup lacks core/$role"
done
grep -Fxq "$DK"$'\t'frontend-artlab$'\t'cms:access <<<"$backup" || fail 'the backup lacks frontend-artlab/cms:access'
dk_token=$(token_roles dk-person)
[[ $dk_token == '{"core":["audit:read","global:read"],"forms":["skyforms:*","skyforms:read-all"],"frontend-artlab":["content:read"],"skymail":["skymail:system-mails:read"]}' ]] \
  || fail "the DK person's token is not read-only: $dk_token"
yk_token=$(token_roles yk-person)
jq -e --argjson before "$yk_token_before" '. == ($before | .core = ((.core + ["audit:read"]) | sort))' <<<"$yk_token" >/dev/null \
  || fail "the YK person's token changed beyond audit:read: $yk_token (before $yk_token_before)"
printf '    --apply: DK token %s; YK unchanged but audit:read\n' "$dk_token"

CURRENT_STAGE='dk-read-only.sh after the apply: nothing more'
checked=$(run_expecting 0 "$REALM")
expect_line "$checked" "$DK: write roles held: none" 'the check after the apply did not say DK holds no write role'
expect_line "$checked" 'check: 0 change(s) pending, 1 warning(s), 0 problem(s)' 'the check after the apply planned a change'
before=$(events)
again=$(run_expecting 0 "$REALM" --apply --backup-file /tmp/dk-backup-2.tsv)
expect_line "$again" 'applied 0 change(s), 1 warning(s), 0 problem(s)' 'the second apply changed something'
expect_line "$again" 'nothing to take away; no backup written' 'the second apply wrote a backup'
[[ $(events) == "$before" ]] || fail 'the second apply wrote something'
docker exec "$CONTAINER" test ! -e /tmp/dk-backup-2.tsv || fail 'the second apply wrote a backup file'
printf '    after the apply: write roles held: none, 0 changes; a second --apply writes nothing\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='--restore puts the mappings back'
checked=$(run_expecting 0 "$REALM" --restore /tmp/dk-backup.tsv)
expect_line "$checked" "would grant core/event:manage to $DK (restore)" 'the restore dry run did not plan a core role'
expect_line "$checked" 'check: 15 change(s) pending, 0 warning(s), 0 problem(s)' 'the restore dry run did not plan 15 grants'
[[ $(group_roles "$DK") == '["core/audit:read","core/global:read","forms/skyforms:*","forms/skyforms:read-all","frontend-artlab/content:read","realm/DK","skymail/skymail:system-mails:read"]' ]] \
  || fail 'the restore dry run wrote something'
restored=$(run_expecting 0 "$REALM" --restore /tmp/dk-backup.tsv --apply)
expect_line "$restored" 'applied 15 change(s), 0 warning(s), 0 problem(s)' 'the restore did not grant the mappings back'
jq -e --argjson before "$dk_after_seed" '. == (($before + ["frontend-artlab/content:read"]) | sort)' <<<"$(group_roles "$DK")" >/dev/null \
  || fail "the restore did not give DK back what it held (content:read stays): $(group_roles "$DK")"
again=$(run_expecting 0 "$REALM" --restore /tmp/dk-backup.tsv --apply)
expect_line "$again" 'applied 0 change(s), 0 warning(s), 0 problem(s)' 'the second restore changed something'
printf '    --restore: dry run by default, --apply grants the 15 back (content:read stays), a second restore writes nothing\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='--forms takes skyforms:* away while DK reads Forms through skyforms:read-all'
ungrant "$DK" forms skyforms:read-all
refused=$(run_expecting 1 "$REALM" --forms)
expect_line "$refused" "PROBLEM: $DK holds no forms/skyforms:read-all" 'Forms without the read role was not a PROBLEM'
grant "$DK" forms skyforms:read-all
applied=$(run_expecting 0 "$REALM" --apply --forms --backup-file /tmp/dk-backup-forms.tsv)
expect_line "$applied" "take forms/skyforms:* away from $DK" 'skyforms:* was not taken away'
expect_line "$applied" 'applied 16 change(s), 1 warning(s), 0 problem(s)' 'the apply with --forms did not take the 15 and skyforms:* away'
[[ $(group_roles "$DK") == '["core/audit:read","core/global:read","forms/skyforms:read-all","frontend-artlab/content:read","realm/DK","skymail/skymail:system-mails:read"]' ]] \
  || fail "DK does not hold its read roles alone after --forms: $(group_roles "$DK")"
docker exec "$CONTAINER" grep -Fxq "$DK"$'\t'forms$'\t''skyforms:*' /tmp/dk-backup-forms.tsv || fail 'the backup lacks skyforms:*'
[[ $(token_roles dk-person | jq -c .forms) == '["skyforms:read-all"]' ]] || fail 'the DK token still carries a Forms write role'
printf '    --forms: PROBLEM without skyforms:read-all; with it skyforms:* goes too\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='a composite, a default group and failed reads'
kcadm create roles -r "$REALM" -s name=LEGACY-COMPOSITE >/dev/null
kcadm create roles/LEGACY-COMPOSITE/composites -r "$REALM" -b "$(role_body core event:manage)" >/dev/null
kcadm create "groups/$(group_id "$REALM" "$DK")/role-mappings/realm" -r "$REALM" \
  -b "$(kcadm get roles/LEGACY-COMPOSITE -r "$REALM" | jq -c '[{id, name}]')" >/dev/null
checked=$(run_expecting 0 "$REALM")
expect_line "$checked" "WARNING: $DK holds realm/LEGACY-COMPOSITE, which this step does not sort; kept" 'the composite realm role was not a WARNING'
expect_line "$checked" "WARNING: $DK still gets core/event:manage through a composite role or a parent group" 'the composite write role was not reported'
expect_line "$checked" 'check: 0 change(s) pending, 3 warning(s), 0 problem(s)' 'the composite changed the plan'
kcadm delete "groups/$(group_id "$REALM" "$DK")/role-mappings/realm" -r "$REALM" \
  -b "$(kcadm get roles/LEGACY-COMPOSITE -r "$REALM" | jq -c '[{id, name}]')" >/dev/null
dk_id=$(group_id "$REALM" "$DK")
kcadm update "realms/$REALM/default-groups/$dk_id" -n -b '{}' >/dev/null
grant "$DK" core event:manage
before=$(events)
refused=$(run_expecting 1 "$REALM" --apply --backup-file /tmp/dk-backup-refused.tsv)
expect_line "$refused" "PROBLEM: the default group $DK is at or under the DK group $DK" 'the default group was not a PROBLEM'
[[ $(events) == "$before" ]] || fail 'the run wrote something next to a default group under DK'
kcadm delete "realms/$REALM/default-groups/$dk_id" >/dev/null
before=$(events)
DK_ENV=(-e KCADM_BIN=/tmp/kcadm-fail.sh -e "KCADM_INJECT_FAIL=group-by-path$DK")
failed=$(run_expecting 1 "$REALM" --apply --backup-file /tmp/dk-backup-failed-1.tsv)
expect_line "$failed" "[dk-read-only] the group $DK could not be read in realm $REALM; stopped" 'the failed group read was not reported'
DK_ENV=(-e KCADM_BIN=/tmp/kcadm-fail.sh -e KCADM_INJECT_FAIL=/role-mappings)
failed=$(run_expecting 1 "$REALM" --apply --backup-file /tmp/dk-backup-failed-2.tsv)
reject_line "$failed" 'applied' 'the run went on after a failed role mapping read'
DK_ENV=()
[[ $(events) == "$before" ]] || fail 'a run wrote something after a failed read'
docker exec "$CONTAINER" sh -c 'test ! -e /tmp/dk-backup-refused.tsv && test ! -e /tmp/dk-backup-failed-1.tsv && test ! -e /tmp/dk-backup-failed-2.tsv' \
  || fail 'a refused run wrote a backup'
applied=$(run_expecting 0 "$REALM" --apply --backup-file /tmp/dk-backup-last.tsv)
expect_line "$applied" 'applied 1 change(s), 1 warning(s), 0 problem(s)' 'the last write role was not taken away'
printf '    a composite write role and the realm role are WARNINGs; a default group under DK and failed reads stop the run (exit 1)\n'

CURRENT_STAGE='the sandbox realm without DK'
sandbox=$(run_expecting 0 "$SANDBOX" --apply)
expect_line "$sandbox" "no DK group (neither /DK nor /UYELER/DK) in realm $SANDBOX; nothing to do" 'the missing DK group was not reported'
expect_line "$sandbox" 'applied 0 change(s), 0 warning(s), 0 problem(s)' 'the sandbox run changed something'
printf '    sandbox without DK: nothing to do\n'

printf 'dk-read-only contract passed.\n'
