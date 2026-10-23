#!/usr/bin/env bash
# Idempotent group grants of the event sites' CMS editor roles (ADR-0056, addendum of 2026-10-03;
# CONTEXT.md "Site editor"). For each Site client frontend-<site> it grants
#   - cms:access to the Privileged groups ADMIN and YK (each at /<NAME> and/or /UYELER/<NAME>,
#     whichever exist) and to the Leader groups (the direct subgroups LIDERLER and KOORDINATORLER)
#     of the site's teams: the owning lab team and the event's organization team;
#   - client:admin to the ADMIN and YK groups (Yusuf, 2026-10-12);
#   - content:read to the DK groups: DK reads and does not write (grup-yonetimi GY1, ticket 08), so it
#     gets the site's read role instead of the editor role. A DK holding cms:access or client:admin is
#     a WARNING, like any holder outside the set; config/dk-read-only.sh takes it away once (runbook
#     §28).
# Teams of each site (decision of 2026-10-03, CONTEXT.md "Site editor"):
#   artlab     /UYELER/ARGE/AIRLAB   and  /UYELER/ORGANIZASYON/ARTLAB
#   yildizjam  /UYELER/ARGE/GAMELAB  and  /UYELER/ORGANIZASYON/YILDIZJAM
#   skydays    /UYELER/ARGE/SKYSEC   and  /UYELER/ORGANIZASYON/SKYDAYS
#   main       e-skylab: the top teams of MAIN_SITE_TEAMS_E_SKYLAB (ekip-yetkileri ticket 03, Yusuf's
#              Ek-2 of 2026-10-23: the Leader groups that hold the main site's cms:access today are
#              taken into code, nobody loses it and no new group gets it; measured in production
#              before the release, as group paths only); e-skylab-sandbox (frontend-main made by
#              site-clients.sh --site main): none. Production's frontend-main itself is hand-made
#              (site-clients.sh still refuses --site main there); its grants were made in the SKY LAB
#              admin panel and are the code area's now, so this script checks and keeps them.
#   arge       not here: frontend-arge's grants wait for Fatih, who rebuilds arge (the code area's
#              check, config/app-assignments.sh, reports them as pending, never as drift).
# --team SITE=PATH adds one more team for one site; its Leader groups get cms:access too. PATH must
# be a top team, /UYELER/<area>/<team>: a Sub-team's Leader groups never get cms:access (ADR-0065
# addendum of 2026-10-12: a Group that holds site-wide write is not delegated, and only top teams'
# Leaders are Site editors until inscribed writes per collection), so a deeper or shallower PATH is
# a usage error (exit 2) before a login.
#
# Grants go to groups only, never to a person, never to /UYELER, never to a group at or above a
# default group (a planned grant to one is a PROBLEM and is not made). Nothing is ever taken away: a group or a
# person that holds cms:access or client:admin directly but is not in the expected set is a
# WARNING (take it away in the SKY LAB admin panel if it is unintended). Other holders of
# content:read (a service account, a group given it in the panel) are not reported: it reads only.
# A missing team or a team without Leader groups is a WARNING; the other grants are still made.
#
# It refuses every realm but e-skylab and e-skylab-sandbox, before it logs in; KEYCLOAK_REALM has no
# default. The client and its cms:access, client:admin and content:read roles must exist (config/site-clients.sh,
# then config/inscribed-cms-roles.sh --client frontend-<site>); a site without them is reported and
# skipped (exit 1).
#
# Usage (inside the Keycloak image, as an operator):
#   KEYCLOAK_REALM=<realm> site-editor-grants.sh --admin-user <admin>            # --check (default)
#   KEYCLOAK_REALM=<realm> site-editor-grants.sh --admin-user <admin> --apply    # grants
#   KEYCLOAK_REALM=<realm> site-editor-grants.sh --kcadm-config <file> [--apply]
#   ... [--site artlab|yildizjam|skydays]... [--team SITE=/PATH]...
#   KEYCLOAK_REALM=<realm> site-editor-grants.sh ... --site main [--team main=/PATH]...
#   KEYCLOAK_REALM=<realm> site-editor-grants.sh --print-expected
# --print-expected prints what the code area expects of the Site clients for config/app-assignments.sh
# (no login): "privileged<TAB>NAMES<TAB>client<TAB>role", "team-leaders<TAB>team path<TAB>client<TAB>
# role" and "pending<TAB>*<TAB>client<TAB>*" (frontend-arge), for every site of the realm.
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
READER_ROLE=content:read
# The Privileged names whose groups read and do not write (core's AUTHZ_PRIVILEGED_READER_ROOTS).
READER_NAMES=(DK)

# The top teams whose Leader groups hold frontend-main's cms:access in production (Ek-2): the
# production measurement's group paths, before the release (ekip-yetkileri ticket 03; the
# --server-precheck of 2026-10-23, 13 EK2_MAIN_LEADER lines: ARTLAB, SKYDAYS and YILDIZJAM through
# KOORDINATORLER, the others through LIDERLER). A top team only (/UYELER/<area>/<team>); a Sub-team's
# Leader group holding it is not taken into code.
MAIN_SITE_TEAMS_E_SKYLAB=(
  /UYELER/ARGE/AIRLAB
  /UYELER/ARGE/ALGOLAB
  /UYELER/ARGE/CHAINLAB
  /UYELER/ARGE/GAMELAB
  /UYELER/ARGE/MOBILAB
  /UYELER/ARGE/SKYSEC
  /UYELER/ARGE/SKYSIS
  /UYELER/ARGE/WEBLAB
  /UYELER/ORGANIZASYON/ARTLAB
  /UYELER/ORGANIZASYON/BIZBIZE
  /UYELER/ORGANIZASYON/GECEKODU
  /UYELER/ORGANIZASYON/SKYDAYS
  /UYELER/ORGANIZASYON/YILDIZJAM
)

# site_teams SITE: the site's teams, one per line: the owning lab team, then the event's
# organization team (main: MAIN_SITE_TEAMS_E_SKYLAB in e-skylab).
site_teams() {
  case $1 in
    artlab) printf '%s\n' /UYELER/ARGE/AIRLAB /UYELER/ORGANIZASYON/ARTLAB ;;
    yildizjam) printf '%s\n' /UYELER/ARGE/GAMELAB /UYELER/ORGANIZASYON/YILDIZJAM ;;
    skydays) printf '%s\n' /UYELER/ARGE/SKYSEC /UYELER/ORGANIZASYON/SKYDAYS ;;
    main)
      if [[ $TARGET_REALM == e-skylab && ${#MAIN_SITE_TEAMS_E_SKYLAB[@]} -gt 0 ]]; then
        printf '%s\n' "${MAIN_SITE_TEAMS_E_SKYLAB[@]}"
      fi
      ;;
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
      [[ ${2#*=} =~ ^/UYELER/[^/]+/[^/]+$ ]] \
        || { printf 'refusing --team %s: only a top team (/UYELER/<area>/<team>) gets cms:access; a Sub-team'"'"'s Leader groups never do (ADR-0065 addendum of 2026-10-12); nothing was read or changed\n' "$2" >&2; exit 2; }
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
    --print-expected)
      MODE=print-expected
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
if [[ $MODE == print-expected ]]; then
  for site in "${ALL_SITES[@]}" main; do
    client="frontend-$site"
    printf 'privileged\tADMIN YK\t%s\t%s\n' "$client" "$EDITOR_ROLE" "$client" "$ADMIN_ROLE"
    printf 'privileged\t%s\t%s\t%s\n' "${READER_NAMES[*]}" "$client" "$READER_ROLE"
    while IFS= read -r team; do
      [[ -z $team ]] || printf 'team-leaders\t%s\t%s\t%s\n' "$team" "$client" "$EDITOR_ROLE"
    done < <(site_teams "$site")
  done
  printf 'pending\t*\tfrontend-arge\t*\n'
  exit 0
fi

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
reader_groups=()
for name in "${PRIVILEGED_NAMES[@]}"; do
  found=false
  for path in "/$name" "/UYELER/$name"; do
    id=$(group_id "$path")
    [[ -n $id ]] || continue
    gid_of[$path]=$id
    privileged+=("$path")
    if [[ " ${READER_NAMES[*]} " == *" $name "* ]]; then
      reader_groups+=("$path")
    else
      admin_groups+=("$path")
    fi
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
  local client=$1 uuid=$2 role=$3 holder people='' hint
  shift 3
  while IFS= read -r holder; do
    [[ -n $holder ]] || continue
    local expected=false item
    for item in "$@"; do [[ $item != "$holder" ]] || expected=true; done
    hint='remove it in the SKY LAB admin panel if unintended'
    for item in ${reader_groups[@]+"${reader_groups[@]}"}; do
      [[ $item != "$holder" ]] || hint='DK reads and does not write: config/dk-read-only.sh takes it away once, runbook §28'
    done
    [[ $expected == true ]] || warning "$client/$role is also held by the group $holder (not taken away; $hint)"
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
  reader_id=$(csv "clients/$uuid/roles" id,name | sed -n "s/^\([^,]*\),$READER_ROLE\$/\1/p")
  if [[ -z $editor_id || -z $admin_id || -z $reader_id ]]; then
    log "MISSING: $client has no $EDITOR_ROLE, $ADMIN_ROLE or $READER_ROLE role; run inscribed-cms-roles.sh --client $client first (nothing granted for it)"
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
  editors=(${admin_groups[@]+"${admin_groups[@]}"})
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
  log "$client: $EDITOR_ROLE for ${editors[*]:-nobody}; $ADMIN_ROLE for ${admin_groups[*]:-nobody}; $READER_ROLE for ${reader_groups[*]:-nobody}"
  for path in ${editors[@]+"${editors[@]}"}; do grant "$client" "$uuid" "$EDITOR_ROLE" "$editor_id" "$path"; done
  for path in ${admin_groups[@]+"${admin_groups[@]}"}; do grant "$client" "$uuid" "$ADMIN_ROLE" "$admin_id" "$path"; done
  for path in ${reader_groups[@]+"${reader_groups[@]}"}; do grant "$client" "$uuid" "$READER_ROLE" "$reader_id" "$path"; done
  report_extra "$client" "$uuid" "$EDITOR_ROLE" ${editors[@]+"${editors[@]}"}
  report_extra "$client" "$uuid" "$ADMIN_ROLE" ${admin_groups[@]+"${admin_groups[@]}"}
done

if [[ $MODE == apply ]]; then
  log "applied $changes change(s), $warnings warning(s), $problems problem(s)"
else
  log "check: $changes change(s) pending, $warnings warning(s), $problems problem(s)"
fi
if [[ $problems != 0 || $missing != 0 ]]; then
  exit 1
fi
