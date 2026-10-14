#!/usr/bin/env bash
# Idempotent application roles of the Leader groups (rol-temizligi ticket 09; decisions S5, S7, S8 in
# sky_lab_genel .scratch/rol-temizligi). The Java era's realm role <TEAM>_LEADER does live things
# only through its composite: the Forms seat and SkyCloud. This script maps them to the Leader groups
# as client roles, so that the realm role can go (rol-temizligi F3) without a Leader losing access:
#   forms     skyforms:access  (the Forms seat, S7; required)
#   skycloud  skycloud:access  (Yusuf 2026-10-13: SkyCloud is used and stays; optional: a realm
#                               without the client skycloud skips it with a WARNING)
# The composite's other three Forms roles (skyforms:form:manage, response:manage, feedback:manage)
# are not mapped: nothing reads them (forms-backend, forms-frontend), Fatih confirms (ticket 15).
# A Leader group that holds no <TEAM>_LEADER realm role today gets the roles newly: the run says so in
# a "NEW SEAT" line with the member count (never a name).
# The groups: LIDERLER and KOORDINATORLER, the direct subgroups of every top team
# /UYELER/<area>/<team>, read from the live tree (no list is kept here). A Sub-team's Leader groups
# never get them (ADR-0065 addendum of 2026-10-12, as site-editor-grants.sh). The areas ADMIN, YK and
# DK under /UYELER are Privileged, not areas, and are skipped. Run it again whenever a top team or a
# Leader group is opened (rol-temizligi F5 too).
#
# Grants go to groups only, never to a person, never to a group at or above a default group (a
# PROBLEM: the grant is not made). Nothing is ever taken away: a group outside the expected places
# (the Leader groups above, the role groups /ROLLER/<NAME>, the Privileged roots) or a person holding
# one of the roles directly is a WARNING (counts and group paths only, never a person's name). A
# missing client forms is a PROBLEM (exit 1); a missing optional client or a missing role is a
# WARNING and is skipped. A failed read of a group (anything but Keycloak's "not found") stops the run
# with exit 1: it is never taken for "absent".
#
# It refuses every realm but e-skylab and e-skylab-sandbox, before it logs in; KEYCLOAK_REALM has no
# default. The reconciler runs it as its operator step KEYCLOAK_RECONCILE_ONLY=leader-app-roles (with
# --apply unless KEYCLOAK_RECONCILE_CHECK=true).
#
# Usage (inside the Keycloak image, as an operator):
#   KEYCLOAK_REALM=<realm> leader-app-roles.sh --admin-user <admin>            # --check (default)
#   KEYCLOAK_REALM=<realm> leader-app-roles.sh --admin-user <admin> --apply    # grants
#   KEYCLOAK_REALM=<realm> leader-app-roles.sh --kcadm-config <file> [--apply]
#
# Environment: KEYCLOAK_ADMIN_URL (default http://keycloak:8080), KEYCLOAK_REALM (required),
# KEYCLOAK_ADMIN_REALM (default master), KEYCLOAK_LEADER_ROLES_ADMIN_USERNAME (or --admin-user).
# Output: "[leader-app-roles] ..." lines, then "check: N change(s) pending, W warning(s), P
# problem(s)" or "applied N change(s), ...". Exit 0 unless a PROBLEM (1) or a usage error or a refused
# realm (2).
set -Eeuo pipefail
shopt -s inherit_errexit

umask 077

KCADM=${KCADM_BIN:-/opt/keycloak/bin/kcadm.sh}
ADMIN_URL=${KEYCLOAK_ADMIN_URL:-http://keycloak:8080}
ADMIN_REALM=${KEYCLOAK_ADMIN_REALM:-master}
TARGET_REALM=${KEYCLOAK_REALM:-}
ADMIN_USER=${KEYCLOAK_LEADER_ROLES_ADMIN_USERNAME:-}
KCADM_CONFIG=''
OWN_CONFIG=false
MODE=check

# client|role|required or optional
APP_ROLES=(
  'forms|skyforms:access|required'
  'skycloud|skycloud:access|optional'
)
PRIVILEGED_NAMES=(ADMIN YK DK)
LEADER_GROUPS=(LIDERLER KOORDINATORLER)
ROLE_GROUP_ROOT=/ROLLER

usage() {
  printf 'usage: KEYCLOAK_REALM=(e-skylab|e-skylab-sandbox) %s (--admin-user <administrator> | --kcadm-config <file>) [--check | --apply]\n' \
    "${BASH_SOURCE[0]##*/}" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --admin-user)
      [[ $# -ge 2 ]] || usage
      ADMIN_USER=$2
      shift 2
      ;;
    --kcadm-config)
      [[ $# -ge 2 ]] || usage
      KCADM_CONFIG=$2
      shift 2
      ;;
    --apply)
      MODE=apply
      shift
      ;;
    --check | --dry-run)
      MODE=check
      shift
      ;;
    *)
      usage
      ;;
  esac
done

if [[ $TARGET_REALM != e-skylab && $TARGET_REALM != e-skylab-sandbox ]]; then
  printf '[leader-app-roles] refusing realm %s: set KEYCLOAK_REALM to e-skylab (production) or e-skylab-sandbox; nothing was read or changed\n' \
    "${TARGET_REALM:-(unset)}" >&2
  exit 2
fi

if [[ -z $KCADM_CONFIG ]]; then
  if [[ -z $ADMIN_USER ]]; then
    if [[ -t 0 ]]; then
      read -r -p "Keycloak administrator username: " ADMIN_USER
    fi
    [[ -n $ADMIN_USER ]] || usage
  fi
  KCADM_CONFIG=$(mktemp /tmp/leader-app-roles-kcadm.XXXXXX)
  OWN_CONFIG=true
elif [[ ! -r $KCADM_CONFIG ]]; then
  printf 'kcadm config %s is not readable\n' "$KCADM_CONFIG" >&2
  exit 2
fi

cleanup() {
  if [[ $OWN_CONFIG == true ]]; then
    rm -f "$KCADM_CONFIG"
  fi
}
trap cleanup EXIT

log() {
  printf '[leader-app-roles] %s\n' "$1"
}

changes=0
warnings=0
problems=0

change() {
  changes=$((changes + 1))
  if [[ $MODE == apply ]]; then
    log "$1"
  else
    log "would $1"
  fi
}

warning() {
  warnings=$((warnings + 1))
  log "WARNING: $1"
}

problem() {
  problems=$((problems + 1))
  log "PROBLEM: $1"
}

kcadm() {
  local command=$1
  shift
  "$KCADM" "$command" --config "$KCADM_CONFIG" "$@"
}

kcadm_write() {
  local stderr_file status
  stderr_file=$(mktemp /tmp/leader-app-roles-stderr.XXXXXX)
  if kcadm "$@" >/dev/null 2>"$stderr_file"; then
    status=0
  else
    status=$?
    cat "$stderr_file" >&2
  fi
  rm -f "$stderr_file"
  return "$status"
}

csv() {
  kcadm get "$1" -r "$TARGET_REALM" --fields "$2" --format csv --noquotes "${@:3}" | tr -d '\r' | sed '/^$/d'
}

uuid_by() {
  csv clients id,clientId -q "clientId=$1" | while IFS=, read -r id client_id; do
    if [[ $client_id == "$1" ]]; then printf '%s\n' "$id"; fi
  done
}

# id_of LINES NAME: the id of the "id,name" line whose name is NAME (the image has no awk).
id_of() {
  local id name
  while IFS=, read -r id name; do
    if [[ $name == "$2" ]]; then printf '%s\n' "$id"; fi
  done <<<"$1"
  return 0
}

# group_id PATH: the id of the group at exactly this path (empty when Keycloak says it does not
# exist). Any other failed read stops the run (exit 1): a read error is never "absent".
group_id() {
  local out err status=0
  [[ $1 =~ ^(/[A-Za-z0-9_.-]+)+$ ]] || { printf 'refusing the group path %s\n' "$1" >&2; exit 2; }
  err=$(mktemp /tmp/leader-app-roles-stderr.XXXXXX)
  out=$(kcadm get "group-by-path$1" -r "$TARGET_REALM" --fields id,path --format csv --noquotes 2>"$err") || status=$?
  if [[ $status == 0 ]]; then
    rm -f "$err"
    out=$(tr -d '\r' <<<"$out" | sed '/^$/d')
    if [[ ${out#*,} == "$1" && -n ${out%%,*} ]]; then printf '%s\n' "${out%%,*}"; fi
    return 0
  fi
  if grep -Eqi 'not found|does not exist|could not find' "$err"; then
    rm -f "$err"
    return 0
  fi
  cat "$err" >&2
  rm -f "$err"
  printf '[leader-app-roles] the group %s could not be read in realm %s; stopped (a failed read is never taken for "absent")\n' \
    "$1" "$TARGET_REALM" >&2
  exit 1
}

# children ID: the direct subgroups of the group, one "id,name" per line.
children() {
  csv "groups/$1/children" id,name -q first=0 -q max=1000
}

credential_arguments=(
  --config "$KCADM_CONFIG"
  --server "$ADMIN_URL"
  --realm "$ADMIN_REALM"
  --user "$ADMIN_USER"
)
if [[ $OWN_CONFIG == true ]]; then
  "$KCADM" config credentials "${credential_arguments[@]}"
fi
log "realm=$TARGET_REALM mode=$MODE roles=$(printf '%s ' "${APP_ROLES[@]%|*}" | sed 's/|/\//g; s/ $//')"

if ! realm_name=$(kcadm get "realms/$TARGET_REALM" --fields realm --format csv --noquotes 2>/dev/null | tr -d '\r') \
  || [[ $realm_name != "$TARGET_REALM" ]]; then
  printf '[leader-app-roles] realm %s does not exist or cannot be read; nothing was changed\n' "$TARGET_REALM" >&2
  exit 1
fi

# --- the roles: client|uuid|role|role id, one entry each -------------------------------------------
grants=()
declare -A client_uuid_of=()
for entry in "${APP_ROLES[@]}"; do
  IFS='|' read -r client role need <<<"$entry"
  if [[ -z ${client_uuid_of[$client]+set} ]]; then
    client_uuid_of[$client]=$(uuid_by "$client")
  fi
  client_uuid=${client_uuid_of[$client]}
  if [[ -z $client_uuid ]]; then
    if [[ $need == required ]]; then
      problem "the client $client does not exist in realm $TARGET_REALM; nothing was granted"
    else
      warning "the client $client does not exist in realm $TARGET_REALM; $client/$role skipped"
    fi
    continue
  fi
  role_lines=$(csv "clients/$client_uuid/roles" id,name -q first=0 -q max=10000)
  role_id=$(id_of "$role_lines" "$role")
  if [[ -z $role_id ]]; then
    warning "the role $client/$role does not exist in realm $TARGET_REALM; skipped (not created)"
    continue
  fi
  grants+=("$client|$client_uuid|$role|$role_id")
done
if [[ $problems != 0 ]]; then
  log "check: 0 change(s) pending, $warnings warning(s), $problems problem(s)"
  exit 1
fi

# --- the Leader groups of the top teams, from the live tree -----------------------------------------
# Every list is read into a variable first: a failed read must stop the run, not pass as "empty".
leaders=()
declare -A gid_of=()
members_id=$(group_id /UYELER)
if [[ -z $members_id ]]; then
  warning "/UYELER does not exist in realm $TARGET_REALM; there is no team"
else
  areas=$(children "$members_id")
  while IFS=, read -r area_id area; do
    [[ -n $area_id && " ${PRIVILEGED_NAMES[*]} " != *" $area "* ]] || continue
    teams=$(children "$area_id")
    while IFS=, read -r team_id team; do
      [[ -n $team_id ]] || continue
      subgroups=$(children "$team_id")
      found=0
      for leader in "${LEADER_GROUPS[@]}"; do
        id=$(id_of "$subgroups" "$leader")
        [[ -n $id ]] || continue
        path="/UYELER/$area/$team/$leader"
        leaders+=("$path")
        gid_of[$path]=$id
        found=$((found + 1))
      done
      [[ $found -gt 0 ]] || log "NOTE: /UYELER/$area/$team has no LIDERLER or KOORDINATORLER group (rol-temizligi F5 opens it; run this step again then)"
    done <<<"$teams"
  done <<<"$areas"
fi
log "Leader groups of the top teams: ${#leaders[@]}"

default_groups=$(csv default-groups path)

# --- grants -----------------------------------------------------------------------------------------
new_seat_groups=0
new_seat_members=0
for path in ${leaders[@]+"${leaders[@]}"}; do
  refused=''
  while IFS= read -r default; do
    [[ -n $default ]] || continue
    # A grant reaches the subgroups: a default group at or under PATH would hand it to everyone.
    if [[ $default == "$path" || $default == "$path"/* ]]; then refused=$default; fi
  done <<<"$default_groups"
  if [[ -n $refused ]]; then
    problem "refusing to grant the Leader roles to $path: the default group $refused would give them to every new user"
    continue
  fi
  gid=${gid_of[$path]}
  declare -A held_of=()
  planned=0
  for entry in ${grants[@]+"${grants[@]}"}; do
    IFS='|' read -r client client_uuid role role_id <<<"$entry"
    if [[ -z ${held_of[$client]+set} ]]; then
      held_of[$client]=$(csv "groups/$gid/role-mappings/clients/$client_uuid" name)
    fi
    if grep -Fxq -- "$role" <<<"${held_of[$client]}"; then
      continue
    fi
    planned=$((planned + 1))
    change "grant $client/$role to the group $path"
    if [[ $MODE == apply ]]; then
      kcadm_write create "groups/$gid/role-mappings/clients/$client_uuid" -r "$TARGET_REALM" \
        -b "[{\"id\":\"$role_id\",\"name\":\"$role\"}]"
    fi
  done
  unset held_of
  if [[ $planned == 0 ]]; then
    log "$path: unchanged"
    continue
  fi
  # B7 of the #97 review: a Leader group without a <TEAM>_LEADER realm role gets the roles newly.
  realm_held=$(csv "groups/$gid/role-mappings/realm" name)
  if ! grep -q '_LEADER$' <<<"$realm_held"; then
    members=$(csv "groups/$gid/members" id -q first=0 -q max=100000)
    count=$(sed '/^$/d' <<<"$members" | wc -l | tr -d ' ')
    new_seat_groups=$((new_seat_groups + 1))
    new_seat_members=$((new_seat_members + count))
    log "NEW SEAT: $path holds no <TEAM>_LEADER realm role: its $count member(s) get the roles newly (not carried over from the Java role)"
  fi
done
log "new seats: $new_seat_groups Leader group(s) without a <TEAM>_LEADER realm role, $new_seat_members member(s) in all"

# --- other holders: reported, never taken away ------------------------------------------------------
# expected_holder PATH: a Leader group of a top team, a role group or a Privileged root.
expected_holder() {
  local item
  for item in ${leaders[@]+"${leaders[@]}"}; do [[ $item != "$1" ]] || return 0; done
  case $1 in
    /ADMIN | /YK | /DK | /UYELER/ADMIN | /UYELER/YK | /UYELER/DK) return 0 ;;
  esac
  [[ $1 =~ ^$ROLE_GROUP_ROOT/[^/]+$ ]]
}
for entry in ${grants[@]+"${grants[@]}"}; do
  IFS='|' read -r client client_uuid role role_id <<<"$entry"
  holder_groups=$(csv "clients/$client_uuid/roles/$role/groups" path -q first=0 -q max=100000)
  others=''
  while IFS= read -r holder; do
    [[ -n $holder ]] || continue
    expected_holder "$holder" || others+=", $holder"
  done <<<"$holder_groups"
  [[ -z $others ]] || warning "$client/$role is also held by the group(s) ${others#, } (a Sub-team's Leader group or another place; not taken away, remove it in the SKY LAB admin panel if unintended)"
  holder_users=$(csv "clients/$client_uuid/roles/$role/users" username -q first=0 -q max=100000)
  people=$(sed '/^$/d' <<<"$holder_users" | grep -vc '^service-account-' || true)
  [[ $people == 0 ]] || log "NOTE: $client/$role is granted directly to $people person(s): rol-temizligi F2 moves them to a role group under $ROLE_GROUP_ROOT (not taken away here)"
done

if [[ $MODE == apply ]]; then
  log "applied $changes change(s), $warnings warning(s), $problems problem(s)"
else
  log "check: $changes change(s) pending, $warnings warning(s), $problems problem(s)"
fi
if [[ $problems != 0 ]]; then
  exit 1
fi
