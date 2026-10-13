#!/usr/bin/env bash
# Idempotent application roles of the Leader groups (rol-temizligi ticket 09; decisions S5, S7, S8 in
# sky_lab_genel .scratch/rol-temizligi). The Java era's realm role <TEAM>_LEADER does one live thing:
# its composite gives the Forms seat. This script maps the Forms seat to the Leader groups as client
# roles, so that the realm role can go (rol-temizligi F3) without a Leader losing anything:
#   forms  skyforms:access, skyforms:form:manage, skyforms:response:manage, skyforms:feedback:manage
# (the composite of <TEAM>_LEADER today; skycloud:access is not mapped, S8: SkyCloud is not used).
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
# missing client forms is a PROBLEM (exit 1); a missing role is a WARNING and is skipped (the sandbox
# realm may lack an old Forms role).
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

APP_CLIENT=forms
APP_ROLES=(skyforms:access skyforms:form:manage skyforms:response:manage skyforms:feedback:manage)
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

# group_id PATH: the id of the group at exactly this path (empty when absent).
group_id() {
  [[ $1 =~ ^(/[A-Za-z0-9_.-]+)+$ ]] || { printf 'refusing the group path %s\n' "$1" >&2; exit 2; }
  csv "group-by-path$1" id,path 2>/dev/null | while IFS=, read -r id path; do
    if [[ $path == "$1" ]]; then printf '%s\n' "$id"; fi
  done || true
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
log "realm=$TARGET_REALM mode=$MODE roles=$APP_CLIENT: ${APP_ROLES[*]}"

if ! realm_name=$(kcadm get "realms/$TARGET_REALM" --fields realm --format csv --noquotes 2>/dev/null | tr -d '\r') \
  || [[ $realm_name != "$TARGET_REALM" ]]; then
  printf '[leader-app-roles] realm %s does not exist or cannot be read; nothing was changed\n' "$TARGET_REALM" >&2
  exit 1
fi

uuid=$(uuid_by "$APP_CLIENT")
if [[ -z $uuid ]]; then
  problem "the client $APP_CLIENT does not exist in realm $TARGET_REALM; nothing was granted"
  log "check: 0 change(s) pending, $warnings warning(s), $problems problem(s)"
  exit 1
fi
role_lines=$(csv "clients/$uuid/roles" id,name -q first=0 -q max=10000)
roles=()
declare -A role_ids=()
for role in "${APP_ROLES[@]}"; do
  role_id=$(awk -F, -v r="$role" '$2 == r { print $1 }' <<<"$role_lines")
  if [[ -z $role_id ]]; then
    warning "the role $APP_CLIENT/$role does not exist in realm $TARGET_REALM; skipped (not created)"
    continue
  fi
  roles+=("$role")
  role_ids[$role]=$role_id
done

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
        id=$(awk -F, -v n="$leader" '$2 == n { print $1 }' <<<"$subgroups")
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
for path in ${leaders[@]+"${leaders[@]}"}; do
  refused=''
  while IFS= read -r default; do
    [[ -n $default ]] || continue
    # A grant reaches the subgroups: a default group at or under PATH would hand it to everyone.
    if [[ $default == "$path" || $default == "$path"/* ]]; then refused=$default; fi
  done <<<"$default_groups"
  if [[ -n $refused ]]; then
    problem "refusing to grant the $APP_CLIENT roles to $path: the default group $refused would give them to every new user"
    continue
  fi
  gid=${gid_of[$path]}
  held=$(csv "groups/$gid/role-mappings/clients/$uuid" name)
  body=''
  added=()
  for role in ${roles[@]+"${roles[@]}"}; do
    grep -Fxq -- "$role" <<<"$held" && continue
    body+=",{\"id\":\"${role_ids[$role]}\",\"name\":\"$role\"}"
    added+=("$role")
  done
  if [[ -z $body ]]; then
    log "$path: unchanged (holds ${roles[*]:-nothing to grant})"
    continue
  fi
  change "grant $APP_CLIENT/${added[*]} to the group $path"
  if [[ $MODE == apply ]]; then
    kcadm_write create "groups/$gid/role-mappings/clients/$uuid" -r "$TARGET_REALM" -b "[${body#,}]"
  fi
done

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
for role in ${roles[@]+"${roles[@]}"}; do
  holder_groups=$(csv "clients/$uuid/roles/$role/groups" path -q first=0 -q max=100000)
  others=''
  while IFS= read -r holder; do
    [[ -n $holder ]] || continue
    expected_holder "$holder" || others+=", $holder"
  done <<<"$holder_groups"
  [[ -z $others ]] || warning "$APP_CLIENT/$role is also held by the group(s) ${others#, } (a Sub-team's Leader group or another place; not taken away, remove it in the SKY LAB admin panel if unintended)"
  holder_users=$(csv "clients/$uuid/roles/$role/users" username -q first=0 -q max=100000)
  people=$(sed '/^$/d' <<<"$holder_users" | grep -vc '^service-account-' || true)
  [[ $people == 0 ]] || log "NOTE: $APP_CLIENT/$role is granted directly to $people person(s): rol-temizligi F2 moves them to $ROLE_GROUP_ROOT/FORMS-ACCESS or FORMS-ALL (not taken away here)"
done

if [[ $MODE == apply ]]; then
  log "applied $changes change(s), $warnings warning(s), $problems problem(s)"
else
  log "check: $changes change(s) pending, $warnings warning(s), $problems problem(s)"
fi
if [[ $problems != 0 ]]; then
  exit 1
fi
