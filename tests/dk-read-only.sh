#!/usr/bin/env bash
# Real-Keycloak contract for DK's read-only standing (grup-yonetimi ticket 08, decision GY1): the
# reconciler's core-roles step seeds DK's read roles, and config/dk-read-only.sh takes DK's write
# roles away once, with a backup it can restore. Stand-alone: starts the stock Keycloak image this
# repository builds on (the Dockerfile's KEYCLOAK_IMAGE) in dev mode with docker run --rm and no
# volume, copies config/ into the container and runs the scripts there the way an operator does;
# tokens are real password grants of a harness login client (full scope: every client's roles).
#
# Fixtures: realm e-skylab in production's shape before this change: core's 14 roles of the contract
# table (13 write roles and url:access) seeded once (marked) to /ADMIN, /UYELER/YK and /UYELER/DK;
# SkyMail's three Privileged roles seeded (system-mails:read and mails:tracking:read to the three,
# announcements:send to ADMIN and YK), the suppression list's two write roles marked as seeded to
# ADMIN and YK, and skymail:mails:approve on DK by hand; the event site client frontend-artlab with
# cms:access (a composite of content:read and content:write) on the three and client:admin on ADMIN and
# YK; forms with skyforms:* on /ADMIN and /UYELER/DK and the Forms seat skyforms:access on DK; the Java
# era's realm role DK on /UYELER/DK; a subgroup /UYELER/DK/ALT; a YK person, a DK person, a person in
# DK and YK and a person in DK's subgroup. Realm e-skylab-sandbox has no DK group.
#
# What it proves:
#   - every realm but e-skylab and e-skylab-sandbox is refused before a login (exit 2), and so are an
#     unreadable backup, a backup line that is no DK write role mapping (another group, another
#     client's role, realm-management, url:access, skyforms:access) and --forms or --backup-file next
#     to --restore;
#   - before the core-roles step DK holds no core/global:read: the dry run names the step as a
#     PROBLEM (exit 1) and nothing is written;
#   - the reconciler's core-roles step (operator session) creates core/global:read and audit:read and
#     forms/skyforms:read-all and seeds them once: global:read and skyforms:read-all to /UYELER/DK
#     only, audit:read to /ADMIN, /UYELER/YK and /UYELER/DK; the write roles' marks keep them where
#     they are; a second run seeds nothing;
#   - dk-read-only.sh --check lists the 13 core write roles, frontend-artlab/cms:access and
#     skymail:mails:approve to take away, content:read to grant in its place, the kept read roles, the
#     kept app roles (url:access, skyforms:access: Yusuf's Y1 and Y5), skyforms:* kept for Forms and
#     the realm role DK as a WARNING, and writes nothing (no admin event);
#   - --apply names its backup in its first line, writes it (mode 0600) before any change, takes
#     exactly that away and grants content:read; ADMIN's and YK's mappings do not change; the DK
#     person's token then carries core [audit:read, global:read, url:access], frontend-artlab
#     [content:read], skymail [mails:tracking:read, system-mails:read], forms [skyforms:*, skyforms:access,
#     skyforms:read-all]; the member of DK's subgroup carries the same core roles; the YK person's
#     token only gains audit:read; the person in DK and YK keeps YK's write roles; --check then says
#     "write roles held: none" with 0 changes, and a second --apply writes nothing (no admin event,
#     no backup);
#   - --restore BACKUP is a dry run by default and with --apply grants every mapping back (content:read
#     stays); a second restore writes nothing;
#   - --forms takes skyforms:* away too (skyforms:access stays), only while DK holds
#     skyforms:read-all (else a PROBLEM);
#   - a write role DK still gets through a composite role or a parent group (/UYELER), and one a
#     subgroup of DK holds directly, are WARNINGs; the /DK root is handled next to /UYELER/DK; a
#     default group under DK and a failed read (injected: the DK group, its role mappings) stop the run
#     with exit 1 and write nothing; a failed write (injected) stops it with exit 1, the backup named,
#     and --restore puts back what was taken; without --backup-file the backup gets its default name;
#     the sandbox realm without DK has nothing to do;
#   - the reconciliation session (config/reconcile-session.sh): every script run here uses it (the
#     container's KEYCLOAK_RECONCILE_SESSION=required); --check with nothing and with 15 write roles
#     to take away, a --restore that grants them back and an --apply that takes them away again print
#     the same bytes and status with a JVM per call (off) as with the session.
# Requirements on the host: docker, curl, jq. DK_READ_ONLY_TEST_PORT (default 18097),
# DK_READ_ONLY_TEST_CONTAINER (default dk-read-only-test-<pid>).
# shellcheck disable=SC2016  # jq programs name jq variables
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=kcadm-jvm.sh
source "$SCRIPT_DIR/kcadm-jvm.sh"
# shellcheck source=kcadm-rest.sh
source "$SCRIPT_DIR/kcadm-rest.sh"
# shellcheck source=session-parity.sh
source "$SCRIPT_DIR/session-parity.sh"
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
# core's roles of the contract table but global:read, as the core-roles step seeded them to ADMIN, YK
# and DK.
CORE_SEEDED_ROLES=(event:manage season:manage ticket:manage ticket:validate competitor:manage
  competition:manage media:manage media:private:read certificate:manage users:manage groups:manage
  github:activity:read url:moderator url:access)
# Of them, the ones DK loses: all but url:access (the holder's own short links, Yusuf's Y1).
CORE_REMOVED_ROLES=(event:manage season:manage ticket:manage ticket:validate competitor:manage
  competition:manage media:manage media:private:read certificate:manage users:manage groups:manage
  github:activity:read url:moderator)
# DK's direct mappings once the step has run (the realm role DK stays: rol-temizligi F3).
DK_AFTER='["core/audit:read","core/global:read","core/url:access","forms/skyforms:*","forms/skyforms:access","forms/skyforms:read-all","frontend-artlab/content:read","realm/DK","skymail/skymail:mails:tracking:read","skymail/skymail:system-mails:read"]'
OLD_MARK='2026-10-04T09:00:00Z /ADMIN,/UYELER/YK,/UYELER/DK'
CURRENT_STAGE=startup
SESSION_PARITY_DIR=$(mktemp -d)

fail() {
  printf 'dk-read-only failure during %s: %s\n' "$CURRENT_STAGE" "$1" >&2
  exit 1
}
cleanup() {
  kcadm_rest_cleanup
  docker rm -fv "$CONTAINER" >/dev/null 2>&1 || true
  rm -rf "$SESSION_PARITY_DIR"
}
trap 'status=$?; trap - EXIT; cleanup; exit "$status"' EXIT
on_error() {
  local status=$?
  printf 'dk-read-only command failed during %s (line %s)\n' "$CURRENT_STAGE" "$1" >&2
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
  -e KC_OPTS="$KCADM_JVM_OPTS" -e KEYCLOAK_RECONCILE_SESSION=required \
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
  '/UYELER/DK\tcore' '/UYELER/DK/SUB\tcore\tevent:manage' '/UYELER/DK\tcore\turl:access' '/UYELER/DK\tforms\tskyforms:access'; do
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
for role in "${CORE_SEEDED_ROLES[@]}" url:create; do
  kcadm create "clients/$(client_uuid "$REALM" core)/roles" -r "$REALM" -s "name=$role" >/dev/null
done
for role in skymail:access skymail:system-mails:read skymail:mails:tracking:read skymail:announcements:send skymail:mails:approve \
  skymail:suppressions:manage skymail:unsubscribes:reactivate; do
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
create_group "$REALM" "$DK" ALT
create_group "$SANDBOX" '' ADMIN
for path in /ADMIN /UYELER/YK "$DK"; do
  grant "$path" core "${CORE_SEEDED_ROLES[@]}"
  grant "$path" skymail skymail:system-mails:read skymail:mails:tracking:read
  grant "$path" frontend-artlab cms:access
done
for path in /ADMIN /UYELER/YK; do
  grant "$path" skymail skymail:announcements:send
  grant "$path" frontend-artlab client:admin
done
for path in /ADMIN "$DK"; do grant "$path" forms 'skyforms:*'; done
grant "$DK" forms skyforms:access
grant "$DK" skymail skymail:mails:approve
kcadm create "groups/$(group_id "$REALM" "$DK")/role-mappings/realm" -r "$REALM" \
  -b "$(kcadm get roles/DK -r "$REALM" | jq -c '[{id, name}]')" >/dev/null
for role in "${CORE_SEEDED_ROLES[@]}"; do mark core "$role" "$OLD_MARK"; done
mark skymail skymail:system-mails:read "$OLD_MARK"
mark skymail skymail:mails:tracking:read "$OLD_MARK"
mark skymail skymail:announcements:send '2026-10-13T09:00:00Z /ADMIN,/UYELER/YK'
# The code area's SkyMail and Forms roles of ekip-yetkileri ticket 03 as if already seeded (this
# stage proves DK's read roles; tests/role-groups.sh and the integration harness prove those seeds).
mark skymail skymail:access '2026-10-24T09:00:00Z /ADMIN,/UYELER/YK'
mark skymail skymail:mails:approve '2026-10-24T09:00:00Z /UYELER/YK'
mark skymail skymail:suppressions:manage '2026-10-25T09:00:00Z /ADMIN,/UYELER/YK'
mark skymail skymail:unsubscribes:reactivate '2026-10-25T09:00:00Z /ADMIN,/UYELER/YK'
mark forms skyforms:access "$OLD_MARK"
# skyforms:* by id, as the reconciler marks it (a "*" never goes into an admin path).
kcadm update "roles-by-id/$(kcadm get "clients/$(client_uuid "$REALM" forms)/roles" -r "$REALM" | jq -r '.[] | select(.name == "skyforms:*") | .id')" \
  -r "$REALM" -s 'attributes."skylab.seeded-group-mappings"=["2026-10-24T09:00:00Z /UYELER/YK"]' >/dev/null
make_person yk-person /UYELER/YK
make_person dk-person "$DK"
make_person dk-sub-person "$DK/ALT"
make_person dk-yk-person "$DK"
kcadm update "users/$(kcadm get users -r "$REALM" -q username=dk-yk-person -q exact=true | jq -r '.[0].id')/groups/$(group_id "$REALM" /UYELER/YK)" \
  -r "$REALM" -n -b '{}' >/dev/null
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
expect_line "$seeded" '[reconcile] Privileged roles of forms (3): created (skyforms:read-all)' 'skyforms:read-all was not created'
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
for role in "${CORE_REMOVED_ROLES[@]}"; do
  expect_line "$checked" "would take core/$role away from $DK" "core/$role was not planned away"
done
reject_line "$checked" 'core/url:access away' 'url:access was planned away (Y1: DK keeps its own short links)'
reject_line "$checked" 'forms/skyforms:access away' 'the Forms seat was planned away'
expect_line "$checked" "would take frontend-artlab/cms:access away from $DK" 'the site editor role was not planned away'
expect_line "$checked" "would take skymail/skymail:mails:approve away from $DK" 'the SkyMail approval role was not planned away'
expect_line "$checked" "$DK: app roles kept (the holder's own, core's app roles): core/url:access, forms/skyforms:access" 'the app roles were not kept'
expect_line "$checked" "would grant frontend-artlab/content:read to $DK (in place of cms:access)" 'content:read was not planned in its place'
expect_line "$checked" "$DK: read roles kept: core/audit:read, core/global:read, forms/skyforms:read-all, skymail/skymail:mails:tracking:read, skymail/skymail:system-mails:read" 'the read roles were not listed'
expect_line "$checked" "NOTE: $DK: Forms roles kept until forms-backend reads forms/skyforms:read-all: forms/skyforms:*" 'the Forms roles were not kept'
expect_line "$checked" "WARNING: $DK holds realm/DK, which this step does not sort; kept" 'the realm role was not a WARNING'
expect_line "$checked" "$DK: write roles held: 15 (" 'the write roles were not counted'
expect_line "$checked" 'check: 16 change(s) pending, 1 warning(s), 0 problem(s)' 'the dry run did not count 15 removals and 1 grant'
reject_line "$checked" 'ALT' 'a subgroup without roles was reported'
reject_line "$checked" '/ADMIN' 'the dry run planned something on ADMIN'
reject_line "$checked" '/UYELER/YK' 'the dry run planned something on YK'
for name in yk-person dk-person dk-sub-person dk-yk-person; do reject_line "$checked" "$name" 'a person was named'; done
[[ $(events) == "$before" ]] || fail 'the dry run wrote something'
[[ $(group_roles "$DK") == "$dk_after_seed" ]] || fail 'the dry run changed DK'
printf '    --check: 15 write roles away, content:read in place, reads, app roles and Forms kept, realm role a WARNING; nothing written\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='dk-read-only.sh --apply'
applied=$(run_expecting 0 "$REALM" --apply --backup-file /tmp/dk-backup.tsv)
[[ $(head -n 1 <<<"$applied") == '[dk-read-only] realm=e-skylab mode=apply forms=keep backup=/tmp/dk-backup.tsv' ]] \
  || fail "the first line does not name the backup: $(head -n 1 <<<"$applied")"
expect_line "$applied" 'applied 16 change(s), 1 warning(s), 0 problem(s)' 'the apply did not make the planned changes'
expect_line "$applied" 'backup: /tmp/dk-backup.tsv (15 mapping(s) to take away; put them back with --restore /tmp/dk-backup.tsv --apply)' 'the backup was not reported'
[[ $(group_roles "$DK") == "$DK_AFTER" ]] \
  || fail "DK does not hold exactly its read roles, its app roles, Forms' kept role and the realm role: $(group_roles "$DK")"
[[ $(group_roles /ADMIN) == "$admin_after_seed" ]] || fail 'the apply changed ADMIN'
[[ $(group_roles /UYELER/YK) == "$yk_after_seed" ]] || fail 'the apply changed YK'
backup=$(docker exec "$CONTAINER" cat /tmp/dk-backup.tsv)
[[ $(docker exec "$CONTAINER" stat -c %a /tmp/dk-backup.tsv) == 600 ]] || fail 'the backup is readable by others'
[[ $(grep -vc '^#' <<<"$backup") == 15 ]] || fail "the backup does not hold the 15 mappings: $backup"
for role in "${CORE_REMOVED_ROLES[@]}"; do
  grep -Fxq "$DK"$'\t'core$'\t'"$role" <<<"$backup" || fail "the backup lacks core/$role"
done
grep -Fxq "$DK"$'\t'frontend-artlab$'\t'cms:access <<<"$backup" || fail 'the backup lacks frontend-artlab/cms:access'
grep -Fxq "$DK"$'\t'skymail$'\t'skymail:mails:approve <<<"$backup" || fail 'the backup lacks skymail:mails:approve'
dk_token=$(token_roles dk-person)
[[ $dk_token == '{"core":["audit:read","global:read","url:access"],"forms":["skyforms:*","skyforms:access","skyforms:read-all"],"frontend-artlab":["content:read"],"skymail":["skymail:mails:tracking:read","skymail:system-mails:read"]}' ]] \
  || fail "the DK person's token is not read-only: $dk_token"
[[ $(token_roles dk-sub-person) == "$dk_token" ]] || fail "the member of DK's subgroup does not inherit exactly DK's roles: $(token_roles dk-sub-person)"
yk_token=$(token_roles yk-person)
jq -e --argjson before "$yk_token_before" '. == ($before | .core = ((.core + ["audit:read"]) | sort))' <<<"$yk_token" >/dev/null \
  || fail "the YK person's token changed beyond audit:read: $yk_token (before $yk_token_before)"
token_roles dk-yk-person | jq -e '(.core | index("event:manage") != null and index("groups:manage") != null and index("global:read") != null)
  and (.["frontend-artlab"] | index("cms:access") != null)' >/dev/null \
  || fail "the person in DK and YK lost YK's write roles: $(token_roles dk-yk-person)"
printf '    --apply: DK token %s; DK subgroup the same; YK unchanged but audit:read; DK + YK keeps YK'"'"'s writes\n' "$dk_token"

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
[[ $(group_roles "$DK") == "$DK_AFTER" ]] || fail 'the restore dry run wrote something'
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
[[ $(group_roles "$DK") == '["core/audit:read","core/global:read","core/url:access","forms/skyforms:access","forms/skyforms:read-all","frontend-artlab/content:read","realm/DK","skymail/skymail:mails:tracking:read","skymail/skymail:system-mails:read"]' ]] \
  || fail "DK does not hold its read and app roles alone after --forms: $(group_roles "$DK")"
docker exec "$CONTAINER" grep -Fxq "$DK"$'\t'forms$'\t''skyforms:*' /tmp/dk-backup-forms.tsv || fail 'the backup lacks skyforms:*'
[[ $(token_roles dk-person | jq -c .forms) == '["skyforms:access","skyforms:read-all"]' ]] || fail 'the DK token still carries a Forms admin role, or lost the seat'
printf '    --forms: PROBLEM without skyforms:read-all; with it skyforms:* goes, the seat skyforms:access stays\n'

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
printf '    a composite write role and the realm role are WARNINGs; a default group under DK and failed reads stop the run (exit 1)\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='a failed write stops the run; the backup puts back what was taken'
# DK holds core/event:manage (above) and frontend-artlab/cms:access again; the cms:access delete fails.
grant "$DK" frontend-artlab cms:access
docker exec -i "$CONTAINER" sh -c 'cat > /tmp/kcadm-fail-write.sh && chmod 755 /tmp/kcadm-fail-write.sh' <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == delete && -n ${KCADM_INJECT_FAIL:-} && " $* " == *"$KCADM_INJECT_FAIL"* ]]; then
  printf 'Injected write failure\n' >&2
  exit 42
fi
exec /opt/keycloak/bin/kcadm.sh "$@"
EOF
dk_before_cut=$(group_roles "$DK")
DK_ENV=(-e KCADM_BIN=/tmp/kcadm-fail-write.sh -e "KCADM_INJECT_FAIL=role-mappings/clients/$artlab")
cut=$(run_expecting 1 "$REALM" --apply --backup-file /tmp/dk-backup-cut.tsv)
DK_ENV=()
expect_line "$cut" 'backup=/tmp/dk-backup-cut.tsv' 'the cut run did not name its backup first'
expect_line "$cut" 'a write failed in realm e-skylab; stopped. The backup /tmp/dk-backup-cut.tsv holds every planned removal' 'the cut run did not point at its backup'
reject_line "$cut" 'applied' 'the cut run reported success'
[[ $(group_roles "$DK" | jq 'index("frontend-artlab/cms:access") != null') == true ]] || fail 'the failed delete took cms:access away'
restored=$(run_expecting 0 "$REALM" --restore /tmp/dk-backup-cut.tsv --apply)
[[ $(group_roles "$DK") == "$dk_before_cut" ]] || fail "the restore after a cut run did not give back what was taken: $(group_roles "$DK")"
applied=$(run_expecting 0 "$REALM" --apply)
default_backup=$(sed -n 's/^\[dk-read-only\] realm=e-skylab mode=apply forms=keep backup=\(\/tmp\/dk-read-only-e-skylab-[0-9]\{8\}T[0-9]\{6\}Z\.tsv\)$/\1/p' <<<"$applied")
[[ -n $default_backup ]] || { printf '%s\n' "$applied" >&2; fail 'without --backup-file the first line does not name the default backup'; }
expect_line "$applied" "backup: $default_backup (2 mapping(s) to take away" 'the default backup was not written'
expect_line "$applied" 'applied 2 change(s), 1 warning(s), 0 problem(s)' 'the run after the cut one did not finish the job'
[[ $(docker exec "$CONTAINER" stat -c %a "$default_backup") == 600 ]] || fail 'the default backup is readable by others'
[[ $(group_roles "$DK") == "$(jq -c '. - ["forms/skyforms:*"]' <<<"$DK_AFTER")" ]] || fail "DK is not read-only after the cut run was redone: $(group_roles "$DK")"
printf '    a failed write: exit 1, backup named; --restore gives back what was taken; the next run (default backup name, 0600) finishes\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='a parent group, a subgroup and the /DK root'
grant /UYELER core event:manage
grant "$DK/ALT" core groups:manage
checked=$(run_expecting 0 "$REALM")
expect_line "$checked" "WARNING: $DK still gets core/event:manage through a composite role or a parent group" 'the write role from /UYELER was not reported'
expect_line "$checked" "WARNING: $DK/ALT, a subgroup of $DK, holds core/groups:manage directly; not taken away" 'the subgroup'"'"'s write role was not reported'
expect_line "$checked" 'check: 0 change(s) pending, 3 warning(s), 0 problem(s)' 'the parent and the subgroup changed the plan'
ungrant /UYELER core event:manage
ungrant "$DK/ALT" core groups:manage
create_group "$REALM" '' DK
grant /DK core event:manage url:access global:read audit:read
before=$(events)
checked=$(run_expecting 0 "$REALM")
expect_line "$checked" "DK groups: /DK $DK" 'the two DK roots were not both read'
expect_line "$checked" 'would take core/event:manage away from /DK' 'the /DK root was not planned'
expect_line "$checked" 'check: 1 change(s) pending, 1 warning(s), 0 problem(s)' 'the /DK root planned more than its write role'
[[ $(events) == "$before" ]] || fail 'the dry run with /DK wrote something'
applied=$(run_expecting 0 "$REALM" --apply --backup-file /tmp/dk-backup-root.tsv)
expect_line "$applied" 'applied 1 change(s), 1 warning(s), 0 problem(s)' 'the /DK root was not handled'
expect_line "$applied" '/DK: write roles held: 1 (core/event:manage)' 'the /DK root was not counted'
[[ $(group_roles /DK) == '["core/audit:read","core/global:read","core/url:access"]' ]] || fail "/DK does not hold its read and app roles alone: $(group_roles /DK)"
checked=$(run_expecting 0 "$REALM")
expect_line "$checked" '/DK: write roles held: none' 'the /DK root still holds a write role'
kcadm delete "groups/$(group_id "$REALM" /DK)" -r "$REALM" >/dev/null
printf '    a write role from /UYELER and one on DK'"'"'s subgroup are WARNINGs; /DK is handled next to /UYELER/DK\n'

CURRENT_STAGE='the sandbox realm without DK'
sandbox=$(run_expecting 0 "$SANDBOX" --apply)
expect_line "$sandbox" "no DK group (neither /DK nor /UYELER/DK) in realm $SANDBOX; nothing to do" 'the missing DK group was not reported'
expect_line "$sandbox" 'applied 0 change(s), 0 warning(s), 0 problem(s)' 'the sandbox run changed something'
printf '    sandbox without DK: nothing to do\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='the reconciliation session: the same bytes and status as a JVM per call'
# Every run above used the session (the container's KEYCLOAK_RECONCILE_SESSION=required). Here whole
# runs on e-skylab as the stages above left it (DK read-only), once with a JVM per call and once with
# the session: --check, a --restore of the first backup (15 write roles back), --check again (15 to
# take away) and an --apply (the same backup file name both times: the first is removed before the
# second run).
parity_options=(-e KEYCLOAK_ADMIN_URL=http://localhost:8080 -e "KEYCLOAK_REALM=$REALM")
dk_parity_run=(bash "$IN_CONTAINER_CONFIG/dk-read-only.sh" --kcadm-config "$KCADM_CONFIG")
session_parity 'dk-read-only --check (read-only DK)' : "${parity_options[@]}" -- "${dk_parity_run[@]}"
# The restore with a JVM per call grants the 15 back; the --apply between takes them away again, so that
# the restore with the session starts from the same realm.
dk_parity_restored=false
dk_parity_back_to_read_only() {
  if [[ $dk_parity_restored == true ]]; then
    docker exec "$CONTAINER" rm -f /tmp/dk-parity-between.tsv
    run_expecting 0 "$REALM" --apply --backup-file /tmp/dk-parity-between.tsv >/dev/null
  fi
  dk_parity_restored=true
}
session_parity 'dk-read-only --restore --apply (15 write roles back)' dk_parity_back_to_read_only "${parity_options[@]}" -- \
  "${dk_parity_run[@]}" --restore /tmp/dk-backup.tsv --apply
expect_line "$(cat "$SESSION_PARITY_LOG")" 'applied 15 change(s), ' 'the compared restore did not grant the 15 back'
session_parity 'dk-read-only --check (15 write roles to take away)' : "${parity_options[@]}" -- "${dk_parity_run[@]}"
expect_line "$(cat "$SESSION_PARITY_LOG")" 'check: 15 change(s) pending, ' 'the compared check did not plan the 15'
dk_parity_apply_runs=0
dk_parity_restore_again() {
  docker exec "$CONTAINER" rm -f /tmp/dk-parity.tsv
  if ((dk_parity_apply_runs++ > 0)); then
    run_expecting 0 "$REALM" --restore /tmp/dk-backup.tsv --apply >/dev/null
  fi
}
session_parity 'dk-read-only --apply (15 write roles away)' dk_parity_restore_again "${parity_options[@]}" -- \
  "${dk_parity_run[@]}" --apply --backup-file /tmp/dk-parity.tsv
expect_line "$(cat "$SESSION_PARITY_LOG")" 'applied 15 change(s), ' 'the compared apply did not take the 15 away'
expect_line "$(cat "$SESSION_PARITY_LOG")" "$DK: write roles held: 15 (" 'the compared apply did not count the 15'

printf 'dk-read-only contract passed.\n'
