#!/usr/bin/env bash
# Idempotent application role groups under /ROLLER (rol-temizligi ticket 05; decisions R1, R3, S4,
# S5, S7, S8 in sky_lab_genel .scratch/rol-temizligi). Microsoft Entra assigns an application role to
# a security group, never to a person; here a person gets a client role by being a member of a leaf
# /ROLLER/<APP>-<ROLE>, and the leaf holds that one client's roles.
#
# config/role-groups.json lists the leaves (name, client, roles, display_name_tr, description_tr). The
# script
#   - creates /ROLLER (it holds no role) and every leaf that is missing, with the attributes
#     display_name_tr and description_tr (written again when they differ);
#   - maps each leaf's roles to it; a role mapped to a leaf beyond its list (another role of the
#     client, another client's role, a realm role), a role mapped to /ROLLER itself, a subgroup under
#     a leaf and a group under /ROLLER that the file does not list are WARNINGs and are never taken
#     away;
#   - never adds or removes a member: membership is made in the SKY LAB admin panel (and moved there
#     from the direct grants by the rol-temizligi F2 wizard).
# A leaf whose client or one of whose roles does not exist in the realm is a WARNING and is skipped
# (not created), so the same file serves e-skylab and e-skylab-sandbox. A leaf name that contains a
# team code of the realm (a top team /UYELER/<area>/<team> or a Sub-team right under one) is a
# PROBLEM and is skipped (spec §7.3: role group names never read as a team). A default group at or under /ROLLER is a PROBLEM and
# nothing is written (every new user would get the roles).
#
# --audit adds the rules' read-only report (spec §4.1), with counts and group paths only, never a
# person's name:
#   K1  people (service accounts excluded) who hold client roles or realm roles directly, per role;
#       an app role (config/app-assignments.json, core's AppRoles) held by a person is a panel
#       assignment (ekip-yetkileri ticket 03, Yusuf's S1 of 2026-10-23: Microsoft Entra's individual
#       assignment) and is counted apart; the target 0 is for admin, unclassified and realm roles;
#   K3  people and groups that hold a realm-management role;
#   K4  groups that hold a role outside the allowed places (ekip-yetkileri ticket 03 §6):
#       - every role: a Privileged root itself (/ADMIN, /YK, /DK, /UYELER/ADMIN, /UYELER/YK,
#         /UYELER/DK; production has three of them) and a leaf /ROLLER/<NAME> without subgroups;
#       - an app role also: any team group under /UYELER/<area>/<team> (a top team, a Sub-team, a
#         Leader group; the panel area), never /UYELER itself or an area;
#       - an admin or unclassified role also, by name only, in a top team's Leader group
#         (/UYELER/<area>/<team>/LIDERLER or KOORDINATORLER): the roles config/leader-app-roles.sh
#         --print-expected gives every top team's Leaders (skycloud/skycloud:access), a Site client's
#         cms:access for that site's own teams only (config/site-editor-grants.sh --print-expected:
#         the event sites' lab and organization teams, the main site's Ek-2 list) and a client whose
#         decision is pending there (frontend-arge, Fatih); any other site's cms:access is K4.
# A failed read of a group (anything but Keycloak's "not found") stops the run with exit 1: it is
# never taken for "absent".
# The audit reads every client role's and realm role's holders (two kcadm calls a role): minutes in
# production.
#
# It refuses every realm but e-skylab and e-skylab-sandbox, before it logs in; KEYCLOAK_REALM has no
# default. The reconciler runs it as its operator step KEYCLOAK_RECONCILE_ONLY=role-groups (with
# --apply unless KEYCLOAK_RECONCILE_CHECK=true).
#
# Usage (inside the Keycloak image, as an operator):
#   KEYCLOAK_REALM=<realm> role-groups.sh --admin-user <admin>             # --check (default)
#   KEYCLOAK_REALM=<realm> role-groups.sh --admin-user <admin> --apply     # creates and maps
#   KEYCLOAK_REALM=<realm> role-groups.sh --kcadm-config <file> [--apply] [--audit]
#
# Environment: KEYCLOAK_ADMIN_URL (default http://keycloak:8080), KEYCLOAK_REALM (required),
# KEYCLOAK_ADMIN_REALM (default master), KEYCLOAK_ROLE_GROUPS_ADMIN_USERNAME (or --admin-user),
# KEYCLOAK_ROLE_GROUPS_FILE (default config/role-groups.json next to this script),
# KEYCLOAK_RECONCILE_SESSION (on, the default: every kcadm read and ReconcileJson call in one JVM,
# config/reconcile-session.sh; off: a JVM a call, as before; required: the tests).
# Output: "[role-groups] ..." lines, then "check: N change(s) pending, W warning(s), P problem(s)" or
# "applied N change(s), ...". Exit 0 unless a PROBLEM (1) or a usage error, a refused realm or an
# invalid file (2).
set -Eeuo pipefail
shopt -s inherit_errexit

umask 077

KCADM=${KCADM_BIN:-/opt/keycloak/bin/kcadm.sh}
JAVA_BIN=${JAVA_BIN:-java}
# The reconciliation session (config/reconcile-session.sh): on, off or required.
SESSION_MODE=${KEYCLOAK_RECONCILE_SESSION:-on}
KEYCLOAK_LIB_DIR=${KEYCLOAK_LIB_DIR:-/opt/keycloak/lib/lib/main}
CONFIG_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG_FILE=${KEYCLOAK_ROLE_GROUPS_FILE:-$CONFIG_DIR/role-groups.json}
ADMIN_URL=${KEYCLOAK_ADMIN_URL:-http://keycloak:8080}
ADMIN_REALM=${KEYCLOAK_ADMIN_REALM:-master}
TARGET_REALM=${KEYCLOAK_REALM:-}
ADMIN_USER=${KEYCLOAK_ROLE_GROUPS_ADMIN_USERNAME:-}
KCADM_CONFIG=''
OWN_CONFIG=false
MODE=check
AUDIT=false
PRIVILEGED_NAMES=(ADMIN YK DK)
LEADER_GROUPS=(LIDERLER KOORDINATORLER)

usage() {
  printf 'usage: KEYCLOAK_REALM=(e-skylab|e-skylab-sandbox) %s (--admin-user <administrator> | --kcadm-config <file>) [--check | --apply] [--audit]\n' \
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
    --audit)
      AUDIT=true
      shift
      ;;
    *)
      usage
      ;;
  esac
done

if [[ $TARGET_REALM != e-skylab && $TARGET_REALM != e-skylab-sandbox ]]; then
  printf '[role-groups] refusing realm %s: set KEYCLOAK_REALM to e-skylab (production) or e-skylab-sandbox; nothing was read or changed\n' \
    "${TARGET_REALM:-(unset)}" >&2
  exit 2
fi

# shellcheck source=reconcile-session.sh
source "$CONFIG_DIR/reconcile-session.sh"
session_mode_valid || exit 2

WORK_DIR=$(mktemp -d /tmp/role-groups.XXXXXX)
if [[ -z $KCADM_CONFIG ]]; then
  if [[ -z $ADMIN_USER ]]; then
    if [[ -t 0 ]]; then
      read -r -p "Keycloak administrator username: " ADMIN_USER
    fi
    [[ -n $ADMIN_USER ]] || { rm -rf "$WORK_DIR"; usage; }
  fi
  KCADM_CONFIG=$(mktemp /tmp/role-groups-kcadm.XXXXXX)
  OWN_CONFIG=true
elif [[ ! -r $KCADM_CONFIG ]]; then
  rm -rf "$WORK_DIR"
  printf 'kcadm config %s is not readable\n' "$KCADM_CONFIG" >&2
  exit 2
fi

cleanup() {
  stop_session
  if [[ $OWN_CONFIG == true ]]; then
    rm -f "$KCADM_CONFIG"
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

log() {
  printf '[role-groups] %s\n' "$1"
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

# A read (get) in the session when it runs (config/reconcile-session.sh), a write in its own JVM.
kcadm() {
  session_kcadm "$@"
}

kcadm_write() {
  local stderr_file status
  stderr_file=$(mktemp "$WORK_DIR/stderr.XXXXXX")
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

# The in-image JSON helper (config/ReconcileJson.java, the reconciler's): the image has a JDK and
# Jackson but no jq. The session's class is compiled with it when the session runs.
compile_json_tool() {
  local jackson_jars=("$KEYCLOAK_LIB_DIR"/com.fasterxml.jackson.core.jackson-*.jar) classpath='' jar
  local sources=("$CONFIG_DIR/ReconcileJson.java")
  [[ -f ${jackson_jars[0]} ]] || { printf 'Jackson libraries were not found under %s\n' "$KEYCLOAK_LIB_DIR" >&2; exit 2; }
  for jar in "${jackson_jars[@]}"; do classpath="$classpath$jar:"; done
  mkdir -p "$WORK_DIR/classes"
  if session_wanted; then
    sources+=("$CONFIG_DIR/ReconcileSession.java")
  fi
  "$JAVA_BIN" -XX:TieredStopAtLevel=1 -XX:+UseSerialGC -m jdk.compiler/com.sun.tools.javac.Main \
    -d "$WORK_DIR/classes" -cp "$classpath" "${sources[@]}" >/dev/null
  JSON_TOOL_CLASSPATH="$WORK_DIR/classes:$classpath"
}

json_tool() {
  if session_takes json "$@"; then
    session_call json "$@"
    return
  fi
  "$JAVA_BIN" -XX:TieredStopAtLevel=1 -XX:+UseSerialGC -cp "$JSON_TOOL_CLASSPATH" ReconcileJson "$@"
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
  local out err
  [[ $1 =~ ^(/[A-Za-z0-9_.-]+)+$ ]] || { printf 'refusing the group path %s\n' "$1" >&2; exit 2; }
  err=$(mktemp "$WORK_DIR/stderr.XXXXXX")
  if out=$(kcadm get "group-by-path$1" -r "$TARGET_REALM" --fields id,path --format csv --noquotes 2>"$err"); then
    out=$(tr -d '\r' <<<"$out" | sed '/^$/d')
    if [[ ${out#*,} == "$1" && -n ${out%%,*} ]]; then printf '%s\n' "${out%%,*}"; fi
    return 0
  fi
  if grep -Eqi 'not found|does not exist|could not find' "$err"; then
    return 0
  fi
  cat "$err" >&2
  printf '[role-groups] the group %s could not be read in realm %s; stopped (a failed read is never taken for "absent")\n' \
    "$1" "$TARGET_REALM" >&2
  exit 1
}

# children ID: the direct subgroups of the group, one "id,name" per line.
children() {
  csv "groups/$1/children" id,name -q first=0 -q max=1000
}

# attribute ID NAME: the first value of the group's attribute NAME (empty when absent).
attribute() {
  local group
  group=$(kcadm get "groups/$1" -r "$TARGET_REALM")
  printf '[%s]' "$group" | json_tool role-attribute "$2" | cut -f2-
}

# mappings ID: the group's role mappings, one "client<TAB>role" per line ("-" for a realm role).
mappings() {
  kcadm get "groups/$1/role-mappings" -r "$TARGET_REALM" | json_tool scope-mappings | cut -f1,4
}

# attribute_options DISPLAY DESCRIPTION: kcadm -s options that write both attributes. The texts
# carry no double quote and no backslash (ReconcileJson role-groups refuses them).
attribute_options() {
  ATTRIBUTE_OPTIONS=(-s "attributes.display_name_tr=[\"$1\"]" -s "attributes.description_tr=[\"$2\"]")
}

# --- the file, before a login ---------------------------------------------------------------------
compile_json_tool
if ! parsed=$(json_tool role-groups "$CONFIG_FILE" 2>"$WORK_DIR/parse.err"); then
  cat "$WORK_DIR/parse.err" >&2
  printf '[role-groups] %s is not a valid role group file; nothing was read or changed\n' "$CONFIG_FILE" >&2
  exit 2
fi
IFS=$'\t' read -r _ ROOT ROOT_DISPLAY ROOT_DESCRIPTION <<<"$(head -n 1 <<<"$parsed")"
LEAVES=()
while IFS= read -r line; do
  if [[ $line == group$'\t'* ]]; then LEAVES+=("${line#group$'\t'}"); fi
done <<<"$parsed"

credential_arguments=(
  --config "$KCADM_CONFIG"
  --server "$ADMIN_URL"
  --realm "$ADMIN_REALM"
  --user "$ADMIN_USER"
)
if [[ $OWN_CONFIG == true ]]; then
  "$KCADM" config credentials "${credential_arguments[@]}"
fi
start_session
log "realm=$TARGET_REALM mode=$MODE root=/$ROOT leaves=${#LEAVES[@]} audit=$AUDIT"

if ! realm_name=$(kcadm get "realms/$TARGET_REALM" --fields realm --format csv --noquotes 2>/dev/null | tr -d '\r') \
  || [[ $realm_name != "$TARGET_REALM" ]]; then
  printf '[role-groups] realm %s does not exist or cannot be read; nothing was changed\n' "$TARGET_REALM" >&2
  exit 1
fi

# --- default groups: a default group at or under /ROLLER would give every new user the roles -------
default_groups=$(csv default-groups path)
while IFS= read -r default; do
  [[ -n $default ]] || continue
  if [[ $default == "/$ROOT" || $default == "/$ROOT"/* ]]; then
    problem "the default group $default is at or under /$ROOT: every new user would get its roles; nothing was changed (remove it from the realm's default groups first)"
  fi
done <<<"$default_groups"
if [[ $problems != 0 ]]; then
  log "check: 0 change(s) pending, $warnings warning(s), $problems problem(s)"
  exit 1
fi

# --- the team codes of the realm (spec §7.3): the top teams /UYELER/<area>/<team> and the
# Sub-teams right under them (not their Leader groups) ----------------------------------------------
# Every list is read into a variable first: a failed read must stop the run, not pass as "empty".
team_codes=()
members_id=$(group_id /UYELER)
if [[ -n $members_id ]]; then
  areas=$(children "$members_id")
  while IFS=, read -r area_id area; do
    [[ -n $area_id && " ${PRIVILEGED_NAMES[*]} " != *" $area "* ]] || continue
    teams=$(children "$area_id")
    while IFS=, read -r team_id team; do
      [[ -n $team_id ]] || continue
      team_codes+=("$team")
      sub_teams=$(children "$team_id")
      while IFS=, read -r _ sub_team; do
        if [[ -n $sub_team && " ${LEADER_GROUPS[*]} " != *" $sub_team "* ]]; then team_codes+=("$sub_team"); fi
      done <<<"$sub_teams"
    done <<<"$teams"
  done <<<"$areas"
fi

# --- the root ---------------------------------------------------------------------------------------
root_id=$(group_id "/$ROOT")
if [[ -z $root_id ]]; then
  change "create the group /$ROOT (no role, no member)"
  if [[ $MODE == apply ]]; then
    attribute_options "$ROOT_DISPLAY" "$ROOT_DESCRIPTION"
    kcadm_write create groups -r "$TARGET_REALM" -s "name=$ROOT" "${ATTRIBUTE_OPTIONS[@]}"
    root_id=$(group_id "/$ROOT")
    [[ -n $root_id ]] || { problem "/$ROOT could not be read back after it was created"; exit 1; }
  fi
else
  if [[ $(attribute "$root_id" display_name_tr) != "$ROOT_DISPLAY" || $(attribute "$root_id" description_tr) != "$ROOT_DESCRIPTION" ]]; then
    change "write display_name_tr and description_tr of /$ROOT"
    if [[ $MODE == apply ]]; then
      attribute_options "$ROOT_DISPLAY" "$ROOT_DESCRIPTION"
      kcadm_write update "groups/$root_id" -r "$TARGET_REALM" "${ATTRIBUTE_OPTIONS[@]}"
    fi
  else
    log "/$ROOT: unchanged"
  fi
  root_roles=$(mappings "$root_id" | tr '\t' '/' | sed 's|^-/|realm/|' | paste -sd, -)
  [[ -z $root_roles ]] || warning "/$ROOT itself holds roles ($root_roles): every member of every role group gets them; not taken away (remove them in the SKY LAB admin panel)"
fi

# --- the leaves -------------------------------------------------------------------------------------
declare -A existing=() client_uuids=()
if [[ -n $root_id ]]; then
  leaves_read=$(children "$root_id")
  while IFS=, read -r id name; do
    if [[ -n $id ]]; then existing[$name]=$id; fi
  done <<<"$leaves_read"
fi
managed=()
for leaf in "${LEAVES[@]}"; do
  IFS=$'\t' read -r name client roles display description <<<"$leaf"
  managed+=("$name")
  path="/$ROOT/$name"
  for code in ${team_codes[@]+"${team_codes[@]}"}; do
    if [[ $name == *"$code"* ]]; then
      problem "$path: the name contains the team code $code (a role group name never reads as a team, spec §7.3); skipped"
      continue 2
    fi
  done
  if [[ -z ${client_uuids[$client]+set} ]]; then
    client_uuids[$client]=$(uuid_by "$client")
  fi
  uuid=${client_uuids[$client]}
  if [[ -z $uuid ]]; then
    warning "$path: the client $client does not exist in realm $TARGET_REALM; skipped (not created)"
    continue
  fi
  role_lines=$(csv "clients/$uuid/roles" id,name -q first=0 -q max=10000)
  bodies=()
  # Into an array: a role name like skyforms:* must never be expanded as a file name.
  read -r -a role_list <<<"$roles"
  for role in "${role_list[@]}"; do
    role_id=$(id_of "$role_lines" "$role")
    if [[ -z $role_id ]]; then
      warning "$path: the role $client/$role does not exist in realm $TARGET_REALM; skipped (not created)"
      continue 2
    fi
    bodies+=("$role|{\"id\":\"$role_id\",\"name\":\"$role\"}")
  done

  id=${existing[$name]:-}
  if [[ -z $id ]]; then
    change "create the role group $path ($client: ${roles// /, }; no member)"
    if [[ $MODE == apply ]]; then
      attribute_options "$display" "$description"
      kcadm_write create "groups/$root_id/children" -r "$TARGET_REALM" -s "name=$name" "${ATTRIBUTE_OPTIONS[@]}"
      id=$(group_id "$path")
      [[ -n $id ]] || { problem "$path could not be read back after it was created"; continue; }
    fi
  elif [[ $(attribute "$id" display_name_tr) != "$display" || $(attribute "$id" description_tr) != "$description" ]]; then
    change "write display_name_tr and description_tr of $path"
    if [[ $MODE == apply ]]; then
      attribute_options "$display" "$description"
      kcadm_write update "groups/$id" -r "$TARGET_REALM" "${ATTRIBUTE_OPTIONS[@]}"
    fi
  fi

  held=''
  if [[ -n $id ]]; then
    held=$(mappings "$id")
  fi
  missing=()
  for body in "${bodies[@]}"; do
    role=${body%%|*}
    if grep -Fxq -- "$client"$'\t'"$role" <<<"$held"; then
      continue
    fi
    missing+=("${body#*|}")
    change "map $client/$role to $path"
  done
  if [[ ${#missing[@]} -gt 0 && $MODE == apply ]]; then
    body=$(IFS=,; printf '[%s]' "${missing[*]}")
    kcadm_write create "groups/$id/role-mappings/clients/$uuid" -r "$TARGET_REALM" -b "$body"
  fi
  if [[ ${#missing[@]} == 0 && -n ${existing[$name]:-} ]]; then
    log "$path: roles unchanged ($client: ${roles// /, })"
  fi

  if [[ -n ${existing[$name]:-} ]]; then
    extra=''
    while IFS=$'\t' read -r held_client held_role; do
      [[ -n $held_role ]] || continue
      [[ $held_client == "$client" && " $roles " == *" $held_role "* ]] && continue
      [[ $held_client == - ]] && held_client=realm
      extra+=", $held_client/$held_role"
    done <<<"$held"
    [[ -z $extra ]] || warning "$path also holds ${extra#, } (a role group holds one client's listed roles only); not taken away"
    subgroups=$(children "$id")
    subgroups=$(sed '/^$/d' <<<"$subgroups" | wc -l | tr -d ' ')
    [[ $subgroups == 0 ]] || warning "$path has $subgroups subgroup(s): a role group is a leaf (its roles would reach them); not removed"
  fi
done

for name in "${!existing[@]}"; do
  [[ " ${managed[*]} " == *" $name "* ]] || warning "/$ROOT/$name is not in ${CONFIG_FILE##*/}; left as it is"
done

# --- the audit (read only, counts and group paths only) --------------------------------------------
# The app roles (config/app-assignments.json, a copy of core's AppRoles): "client/role" keys.
declare -A app_role=()
if [[ $AUDIT == true ]]; then
  if ! catalogue=$(json_tool app-assignments "$CONFIG_DIR/app-assignments.json" 2>"$WORK_DIR/catalogue.err"); then
    cat "$WORK_DIR/catalogue.err" >&2
    printf '[role-groups] %s is not a valid app catalogue; the audit cannot tell app roles from admin roles\n' "$CONFIG_DIR/app-assignments.json" >&2
    exit 2
  fi
  while IFS=$'\t' read -r kind client _ roles _; do
    [[ $kind == app ]] || continue
    read -r -a role_list <<<"$roles"
    for role in "${role_list[@]}"; do app_role[$client/$role]=1; done
  done <<<"$catalogue"
fi
# The named exceptions of a top team's Leader group: every top team's (leader_role, "client/role")
# and one team's (team_role, "team path|client/role"), from the code area's own lists; pending_client:
# a client whose place is not decided yet.
declare -A leader_role=() team_role=() pending_client=()
if [[ $AUDIT == true ]]; then
  if ! expected=$(bash "$CONFIG_DIR/leader-app-roles.sh" --print-expected 2>"$WORK_DIR/expected.err"); then
    cat "$WORK_DIR/expected.err" >&2
    printf '[role-groups] leader-app-roles.sh --print-expected failed; the audit cannot tell the allowed places\n' >&2
    exit 2
  fi
  while IFS=$'\t' read -r kind client role; do
    [[ $kind != top-team-leaders ]] || leader_role[$client/$role]=1
  done <<<"$expected"
  if ! expected=$(KEYCLOAK_REALM=$TARGET_REALM bash "$CONFIG_DIR/site-editor-grants.sh" --print-expected 2>"$WORK_DIR/expected.err"); then
    cat "$WORK_DIR/expected.err" >&2
    printf '[role-groups] site-editor-grants.sh --print-expected failed; the audit cannot tell the allowed places\n' >&2
    exit 2
  fi
  while IFS=$'\t' read -r kind holder client role; do
    case $kind in
      team-leaders) team_role[$holder|$client/$role]=1 ;;
      pending) pending_client[$client]=1 ;;
    esac
  done <<<"$expected"
fi
# allowed_place PATH LABEL: true for the places the role LABEL ("client/role", "realm/role") may be
# mapped to (ekip-yetkileri ticket 03 §6; core's RolePlacement for the Privileged roots and the role
# groups).
declare -A roles_not_leaf=()
allowed_place() {
  local path=$1 label=$2
  case $path in
    /ADMIN | /YK | /DK | /UYELER/ADMIN | /UYELER/YK | /UYELER/DK) return 0 ;;
  esac
  if [[ $path =~ ^/$ROOT/[^/]+$ && -z ${roles_not_leaf[$path]:-} ]]; then
    return 0
  fi
  if [[ $label != realm/* && -n ${app_role[$label]:-} ]]; then
    [[ $path =~ ^/UYELER/([^/]+)/[^/]+(/.*)?$ && " ${PRIVILEGED_NAMES[*]} " != *" ${BASH_REMATCH[1]} "* ]]
    return
  fi
  if [[ $path =~ ^(/UYELER/([^/]+)/[^/]+)/(LIDERLER|KOORDINATORLER)$ && " ${PRIVILEGED_NAMES[*]} " != *" ${BASH_REMATCH[2]} "* ]]; then
    [[ -n ${leader_role[$label]:-} || -n ${team_role[${BASH_REMATCH[1]}|$label]:-} || -n ${pending_client[${label%%/*}]:-} ]]
    return
  fi
  return 1
}

if [[ $AUDIT == true ]]; then
  # The role groups with groups under them (core refuses a role there: it would flow down).
  for name in "${!existing[@]}"; do
    leaf_children=$(children "${existing[$name]}")
    if [[ -n $leaf_children ]]; then roles_not_leaf[/$ROOT/$name]=1; fi
  done
  declare -A client_people=() app_people=() realm_people=() k3_people=() k4=()
  k3_groups=''
  default_role="default-roles-${TARGET_REALM,,}"
  # audit_role LABEL BASE: the direct holders of one role (BASE is its admin path).
  audit_role() {
    local label=$1 base=$2 kind=$3 user people=0 path groups='' users_read groups_read
    users_read=$(csv "$base/users" username -q first=0 -q max=100000)
    groups_read=$(csv "$base/groups" path -q first=0 -q max=100000)
    while IFS= read -r user; do
      [[ -n $user && $user != service-account-* ]] || continue
      people=$((people + 1))
      if [[ $kind == realm ]]; then
        realm_people[$user]=1
      elif [[ -n ${app_role[$label]:-} ]]; then
        app_people[$user]=1
      else
        client_people[$user]=1
      fi
      [[ $label != realm-management/* ]] || k3_people[$user]=1
    done <<<"$users_read"
    while IFS= read -r path; do
      [[ -n $path ]] || continue
      groups+=", $path"
      allowed_place "$path" "$label" || k4[$path]="${k4[$path]:-}, $label"
      [[ $label != realm-management/* ]] || k3_groups+=", $path"
    done <<<"$groups_read"
    if [[ $people -gt 0 || -n $groups ]]; then
      log "audit: $label: $people person(s) directly; groups: ${groups#, }"
    fi
    return 0
  }
  log 'audit: reading the direct holders of every role (two reads a role; minutes in production)'
  audit_clients=$(csv clients id,clientId -q first=0 -q max=10000)
  while IFS=, read -r uuid client; do
    [[ -n $uuid ]] || continue
    audit_roles=$(csv "clients/$uuid/roles" name -q first=0 -q max=10000)
    while IFS= read -r role; do
      if [[ -n $role ]]; then audit_role "$client/$role" "clients/$uuid/roles/$role" client; fi
    done <<<"$audit_roles"
  done <<<"$audit_clients"
  audit_roles=$(csv roles name -q first=0 -q max=10000)
  while IFS= read -r role; do
    if [[ -n $role && $role != "$default_role" ]]; then audit_role "realm/$role" "roles/$role" realm; fi
  done <<<"$audit_roles"
  log "audit K1: ${#client_people[@]} person(s) hold admin or unclassified client roles directly, ${#realm_people[@]} person(s) hold realm roles directly (service accounts and $default_role left out; target 0, rol-temizligi F2 and F3)"
  log "audit K1: ${#app_people[@]} person(s) hold app roles directly (panel assignments of config/app-assignments.json's apps; allowed, ekip-yetkileri ticket 03)"
  k3_groups=${k3_groups#, }
  log "audit K3: ${#k3_people[@]} person(s) hold realm-management roles directly; groups holding them: ${k3_groups:-none} (target 0 and none)"
  if [[ ${#k4[@]} == 0 ]]; then
    log 'audit K4: every role is mapped to an allowed place (Privileged roots, role groups without subgroups, team groups for app roles, top team Leader groups for the named exceptions: SkyCloud, a site'"'"'s cms:access for its own teams, frontend-arge pending)'
  else
    log "audit K4: ${#k4[@]} group(s) hold roles outside the allowed places:"
    while IFS= read -r path; do
      log "audit K4:   $path: ${k4[$path]#, }"
    done < <(printf '%s\n' "${!k4[@]}" | sort)
  fi
fi

if [[ $MODE == apply ]]; then
  log "applied $changes change(s), $warnings warning(s), $problems problem(s)"
else
  log "check: $changes change(s) pending, $warnings warning(s), $problems problem(s)"
fi
if [[ $problems != 0 ]]; then
  exit 1
fi
