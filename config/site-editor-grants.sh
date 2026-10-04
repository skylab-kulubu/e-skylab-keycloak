#!/usr/bin/env bash
# Idempotent group grants of the event sites' CMS editor roles (ADR-0056, addendum of 2026-10-03;
# CONTEXT.md "Site editor"). For each Site client frontend-<site> it grants
#   - cms:access to the Privileged groups (ADMIN, YK, DK: each at /<NAME> and/or /UYELER/<NAME>,
#     whichever exist) and to the Leader groups (the direct subgroups LIDERLER and KOORDINATORLER)
#     of the site's teams: the owning lab team and the event's organization team;
#   - client:admin to the ADMIN group(s) only.
# Teams of each site (decision of 2026-10-03, CONTEXT.md "Site editor"):
#   artlab     /UYELER/ARGE/AIRLAB   and  /UYELER/ORGANIZASYON/ARTLAB
#   yildizjam  /UYELER/ARGE/GAMELAB  and  /UYELER/ORGANIZASYON/YILDIZJAM
#   skydays    /UYELER/ARGE/SKYSEC   and  /UYELER/ORGANIZASYON/SKYDAYS
#   main       none: the main site's sandbox client (frontend-main in e-skylab-sandbox only, made by
#              site-clients.sh --site main) gets the Privileged groups; production's frontend-main
#              grants are made in the SKY LAB admin panel and --site main is refused in e-skylab
# --team SITE=PATH adds one more team for one site; its Leader groups get cms:access too.
#
# Grants go to groups only, never to a person, never to /UYELER, never to a group at or above a
# default group (a planned grant to one is a PROBLEM and is not made). Nothing is ever taken away: a group or a
# person that holds cms:access or client:admin directly but is not in the expected set is a
# WARNING (take it away in the SKY LAB admin panel if it is unintended). A missing team or a team
# without Leader groups is a WARNING; the other grants are still made.
#
# It refuses every realm but e-skylab and e-skylab-sandbox, before it logs in; KEYCLOAK_REALM has no
# default. The client and its cms:access and client:admin roles must exist (config/site-clients.sh,
# then config/inscribed-cms-roles.sh --client frontend-<site>); a site without them is reported and
# skipped (exit 1).
#
# Usage (inside the Keycloak image, as an operator):
#   KEYCLOAK_REALM=<realm> site-editor-grants.sh --admin-user <admin>            # --check (default)
#   KEYCLOAK_REALM=<realm> site-editor-grants.sh --admin-user <admin> --apply    # grants
#   KEYCLOAK_REALM=<realm> site-editor-grants.sh --kcadm-config <file> [--apply]
#   ... [--site artlab|yildizjam|skydays]... [--team SITE=/PATH]...
#   KEYCLOAK_REALM=e-skylab-sandbox site-editor-grants.sh ... --site main [--team main=/PATH]...
#
# Environment: KEYCLOAK_ADMIN_URL (default http://keycloak:8080), KEYCLOAK_REALM (required),
# KEYCLOAK_ADMIN_REALM (default master), KEYCLOAK_SITE_GRANTS_ADMIN_USERNAME (or --admin-user).
# Output: "[site-grants] ..." lines, then "check: N change(s) pending, W warning(s), P problem(s)" or
# "applied N change(s), ...". Exit 0 unless a PROBLEM or a missing client or role (1) or a usage
# error or a refused realm (2).
set -Eeuo pipefail
shopt -s inherit_errexit

umask 077

KCADM=${KCADM_BIN:-/opt/keycloak/bin/kcadm.sh}
ADMIN_URL=${KEYCLOAK_ADMIN_URL:-http://keycloak:8080}
ADMIN_REALM=${KEYCLOAK_ADMIN_REALM:-master}
TARGET_REALM=${KEYCLOAK_REALM:-}
ADMIN_USER=${KEYCLOAK_SITE_GRANTS_ADMIN_USERNAME:-}
KCADM_CONFIG=''
OWN_CONFIG=false
MODE=check
SITES=()
EXTRA_TEAMS=()

ALL_SITES=(artlab yildizjam skydays)
PRIVILEGED_NAMES=(ADMIN YK DK)
LEADER_GROUPS=(LIDERLER KOORDINATORLER)
EDITOR_ROLE=cms:access
ADMIN_ROLE=client:admin

# site_teams SITE: the site's teams, one per line: the owning lab team, then the event's
# organization team.
site_teams() {
  case $1 in
    artlab) printf '%s\n' /UYELER/ARGE/AIRLAB /UYELER/ORGANIZASYON/ARTLAB ;;
    yildizjam) printf '%s\n' /UYELER/ARGE/GAMELAB /UYELER/ORGANIZASYON/YILDIZJAM ;;
    skydays) printf '%s\n' /UYELER/ARGE/SKYSEC /UYELER/ORGANIZASYON/SKYDAYS ;;
    main) ;;
  esac
}

usage() {
  printf 'usage: KEYCLOAK_REALM=(e-skylab|e-skylab-sandbox) %s (--admin-user <administrator> | --kcadm-config <file>) [--check | --apply] [--site artlab|yildizjam|skydays|main]... [--team SITE=/PATH]...\n' \
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
    --site)
      [[ $# -ge 2 ]] || usage
      case $2 in
        artlab | yildizjam | skydays | main) SITES+=("$2") ;;
        *) printf 'unknown site %s (artlab, yildizjam, skydays or main)\n' "$2" >&2; exit 2 ;;
      esac
      shift 2
      ;;
    --team)
      [[ $# -ge 2 ]] || usage
      [[ $2 =~ ^(artlab|yildizjam|skydays|main)=/[A-Za-z0-9_./-]+$ && $2 != *//* && $2 != */ ]] \
        || { printf 'bad --team %s (SITE=/GROUP/PATH)\n' "$2" >&2; exit 2; }
      EXTRA_TEAMS+=("$2")
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
[[ ${#SITES[@]} -gt 0 ]] || SITES=("${ALL_SITES[@]}")

if [[ $TARGET_REALM != e-skylab && $TARGET_REALM != e-skylab-sandbox ]]; then
  printf '[site-grants] refusing realm %s: set KEYCLOAK_REALM to e-skylab (production) or e-skylab-sandbox; nothing was read or changed\n' \
    "${TARGET_REALM:-(unset)}" >&2
  exit 2
fi
for site in "${SITES[@]}"; do
  if [[ $site == main && $TARGET_REALM != e-skylab-sandbox ]]; then
    printf '[site-grants] refusing --site main in realm %s: production'"'"'s frontend-main grants are made in the SKY LAB admin panel; --site main is for e-skylab-sandbox; nothing was read or changed\n' \
      "$TARGET_REALM" >&2
    exit 2
  fi
done

if [[ -z $KCADM_CONFIG ]]; then
  if [[ -z $ADMIN_USER ]]; then
    if [[ -t 0 ]]; then
      read -r -p "Keycloak administrator username: " ADMIN_USER
    fi
    [[ -n $ADMIN_USER ]] || usage
  fi
  KCADM_CONFIG=$(mktemp /tmp/site-grants-kcadm.XXXXXX)
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
  printf '[site-grants] %s\n' "$1"
}

changes=0
warnings=0
problems=0
missing=0

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
  stderr_file=$(mktemp /tmp/site-grants-stderr.XXXXXX)
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

# group_id PATH: the id of the group at exactly this path (empty when absent). Paths are plain
# (letters, digits, _ . -), so they go into the admin URL as they are.
group_id() {
  [[ $1 =~ ^(/[A-Za-z0-9_.-]+)+$ ]] || { printf 'refusing the group path %s\n' "$1" >&2; exit 2; }
  csv "group-by-path$1" id,path 2>/dev/null | while IFS=, read -r id path; do
    if [[ $path == "$1" ]]; then printf '%s\n' "$id"; fi
  done || true
}

# child_path PARENT_ID NAME: the path of the direct subgroup NAME (empty when absent).
child_path() {
  csv "groups/$1/children" name,path -q max=1000 2>/dev/null | while IFS=, read -r name path; do
    if [[ $name == "$2" ]]; then printf '%s\n' "$path"; fi
  done || true
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
log "realm=$TARGET_REALM mode=$MODE sites=${SITES[*]}"

if ! realm_name=$(kcadm get "realms/$TARGET_REALM" --fields realm --format csv --noquotes 2>/dev/null | tr -d '\r') \
  || [[ $realm_name != "$TARGET_REALM" ]]; then
  printf '[site-grants] realm %s does not exist or cannot be read; nothing was changed\n' "$TARGET_REALM" >&2
  exit 1
fi
default_groups=$(csv default-groups path)

# --- the Privileged groups (the same for every site) ---------------------------------------------
declare -A gid_of=()
privileged=()
admin_groups=()
for name in "${PRIVILEGED_NAMES[@]}"; do
  found=false
  for path in "/$name" "/UYELER/$name"; do
    id=$(group_id "$path")
    [[ -n $id ]] || continue
    gid_of[$path]=$id
    privileged+=("$path")
    [[ $name != ADMIN ]] || admin_groups+=("$path")
    found=true
  done
  [[ $found == true ]] || warning "no Privileged group $name (neither /$name nor /UYELER/$name)"
done
log "Privileged groups: ${privileged[*]:-none}"

# --- per site ---------------------------------------------------------------------------------
# grant CLIENT CLIENT_UUID ROLE ROLE_ID PATH: the group at PATH holds the client role directly.
grant() {
  local client=$1 uuid=$2 role=$3 role_id=$4 path=$5 gid default
  gid=${gid_of[$path]}
  if [[ $path == /UYELER ]]; then problem "refusing to grant $client/$role to /UYELER (every member)"; return 0; fi
  while IFS= read -r default; do
    [[ -n $default ]] || continue
    # A grant reaches the subgroups: a default group at or under PATH would hand it to everyone.
    if [[ $default == "$path" || $default == "$path"/* ]]; then
      problem "refusing to grant $client/$role to $path: the default group $default would give it to every new user"
      return 0
    fi
  done <<<"$default_groups"
  if csv "groups/$gid/role-mappings/clients/$uuid" name | grep -Fx "$role" >/dev/null; then
    log "$client: $path holds $role"
    return 0
  fi
  change "grant $client/$role to the group $path"
  if [[ $MODE == apply ]]; then
    kcadm_write create "groups/$gid/role-mappings/clients/$uuid" -r "$TARGET_REALM" \
      -b "[{\"id\":\"$role_id\",\"name\":\"$role\"}]"
  fi
}

# report_extra CLIENT UUID ROLE EXPECTED...: direct holders of ROLE outside EXPECTED.
report_extra() {
  local client=$1 uuid=$2 role=$3 holder people=''
  shift 3
  while IFS= read -r holder; do
    [[ -n $holder ]] || continue
    local expected=false item
    for item in "$@"; do [[ $item != "$holder" ]] || expected=true; done
    [[ $expected == true ]] || warning "$client/$role is also held by the group $holder (not taken away; remove it in the SKY LAB admin panel if unintended)"
  done < <(csv "clients/$uuid/roles/$role/groups" path -q max=100000)
  while IFS=, read -r _ holder; do
    [[ -n $holder && $holder != service-account-* ]] || continue
    people+="${people:+, }$holder"
  done < <(csv "clients/$uuid/roles/$role/users" id,username -q max=100000)
  [[ -z $people ]] || warning "$client/$role is granted directly to user(s) $people: grant it to a group and take the direct grant away"
}

for site in "${SITES[@]}"; do
  client="frontend-$site"
  uuid=$(uuid_by "$client")
  if [[ -z $uuid ]]; then
    log "MISSING: client $client does not exist in realm $TARGET_REALM; run site-clients.sh first (nothing granted for it)"
    missing=$((missing + 1))
    continue
  fi
  editor_id=$(csv "clients/$uuid/roles" id,name | sed -n "s/^\([^,]*\),$EDITOR_ROLE\$/\1/p")
  admin_id=$(csv "clients/$uuid/roles" id,name | sed -n "s/^\([^,]*\),$ADMIN_ROLE\$/\1/p")
  if [[ -z $editor_id || -z $admin_id ]]; then
    log "MISSING: $client has no $EDITOR_ROLE or $ADMIN_ROLE role; run inscribed-cms-roles.sh --client $client first (nothing granted for it)"
    missing=$((missing + 1))
    continue
  fi
  teams=()
  while IFS= read -r team; do teams+=("$team"); done < <(site_teams "$site")
  for item in "${EXTRA_TEAMS[@]}"; do
    # A team named twice is planned once.
    [[ ${item%%=*} == "$site" && " ${teams[*]} " != *" ${item#*=} "* ]] || continue
    teams+=("${item#*=}")
  done
  editors=("${privileged[@]}")
  for team in "${teams[@]}"; do
    team_id=$(group_id "$team")
    if [[ -z $team_id ]]; then
      warning "$client: the team $team does not exist in realm $TARGET_REALM; its Leaders get nothing"
      continue
    fi
    leaders=0
    for leader in "${LEADER_GROUPS[@]}"; do
      path=$(child_path "$team_id" "$leader")
      [[ -n $path ]] || continue
      gid_of[$path]=$(group_id "$path")
      editors+=("$path")
      leaders=$((leaders + 1))
    done
    [[ $leaders -gt 0 ]] || warning "$client: the team $team has no LIDERLER or KOORDINATORLER subgroup; its Leaders get nothing"
  done
  log "$client: $EDITOR_ROLE for ${editors[*]:-nobody}; $ADMIN_ROLE for ${admin_groups[*]:-nobody}"
  for path in "${editors[@]}"; do grant "$client" "$uuid" "$EDITOR_ROLE" "$editor_id" "$path"; done
  for path in "${admin_groups[@]}"; do grant "$client" "$uuid" "$ADMIN_ROLE" "$admin_id" "$path"; done
  report_extra "$client" "$uuid" "$EDITOR_ROLE" "${editors[@]}"
  report_extra "$client" "$uuid" "$ADMIN_ROLE" "${admin_groups[@]}"
done

if [[ $MODE == apply ]]; then
  log "applied $changes change(s), $warnings warning(s), $problems problem(s)"
else
  log "check: $changes change(s) pending, $warnings warning(s), $problems problem(s)"
fi
if [[ $problems != 0 || $missing != 0 ]]; then
  exit 1
fi
