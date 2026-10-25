#!/usr/bin/env bash
# The code area and the panel area of the realm's role mappings (ekip-yetkileri ticket 03, Yusuf's S1
# of 2026-10-23: Microsoft Entra's Enterprise app model; sky_lab_genel
# .scratch/ekip-yetkileri-20261022/YETKI-MATRISI.md §6.1). In Entra the app registration (its roles,
# "Assignment required") and the admin roles of role-assignable groups are configuration; which group
# or person an app is assigned to ("Users and groups") is data an administrator keeps in the portal.
# Here:
#   code area   every mapping on a Privileged root or under it (/ADMIN, /YK, /DK, /UYELER/ADMIN,
#               /UYELER/YK, /UYELER/DK), every mapping on /ROLLER and its leaves, every mapping of an
#               admin or unclassified role (anything that is no app role) and of a realm role
#               wherever it is, the service accounts' roles, the default role; the reconciler and its
#               operator scripts make it, this script reports how far the realm is from it;
#   panel area  an app role (config/app-assignments.json: exactly core's AppRoles) mapped to a team
#               group (a top team /UYELER/<area>/<team>, a Sub-team, a Leader group) or to a person
#               directly: the SKY LAB admin panel's Uygulamalar page (ekip-yetkileri ticket 15) owns
#               it. Nothing here and in the reconciler ever writes or removes one, and it is no drift.
# An app role on /UYELER, on an area or at or above a default group would reach every member: no panel
# target (a default role's job), so it counts as a code area mapping nobody expects.
#
# --check (the default; read only): one line per mapping, after the "[app-assignments] " prefix:
#   KOD|<group path or kişi:<n>>|<client or realm>|<role>|<expected>|<live>
#       expected: evet (the code expects it), hayır (it does not), geçici (DK's Forms admin roles until
#       forms-backend reads skyforms:read-all, config/dk-read-only.sh --forms), karar-bekliyor
#       (frontend-arge: Fatih rebuilds arge); live: var or yok. A person's line has no identity, only
#       the number of people (kişi:<n>);
#   PANEL|<group path or kişi:<n>>|<client>|<role>
# then the counts: KOD as expected, missing, not in code, temporary, pending; PANEL per app (group and
# person assignments); PROBLEM lines for an admin, unclassified or realm role in the panel area or on a
# person, and for an app role on a target that reaches every member. The code area's expectations:
# the reconciler's Privileged roles (--privileged-file, written by its operator step
# KEYCLOAK_RECONCILE_ONLY=app-assignments: core's resource roles, SkyMail's, Forms' and SkyCloud's
# Privileged roles), config/role-groups.json, config/leader-app-roles.sh --print-expected,
# config/site-editor-grants.sh --print-expected and DK's temporary Forms roles. Without
# --privileged-file the Privileged roots' own expectations are unknown (a NOTE). The service
# accounts are counted only (the service-roles step checks them), the default role and the identity
# providers' token settings are the default-roles step's (KEYCLOAK_RECONCILE_ONLY=default-roles). It
# reads every role's direct holders (two reads a role, as role-groups.sh --audit): minutes in
# production. Exit 0 with drift and PROBLEMs (they are reported for ticket 07's alarm), 1 when a read
# fails, 2 on a usage error, a refused realm or an invalid file.
#
# The drift summary (ekip-yetkileri ticket 07: Entra PIM's "roles assigned outside PIM"): after the
# counts, one line per drift "SAPMA|<class>|<group path or kişi:<n>>|<client or realm>|<role>" and
# "SAPMA: S1=… S1-realm=… S2-eksik=… S2-fazla=… S2b=… S3=… S5=…, alarm=<n>". The panel area (PANEL
# lines) is never drift; geçici and karar-bekliyor neither.
#   S1        an admin or unclassified client role held by people directly (one line a role);
#   S1-realm  a realm role held by people directly: the old Java era's (rol-temizligi ticket 19 takes
#             them away in its own window), so it counts towards the alarm only with
#             --realm-roles alarm (KEYCLOAK_APP_ASSIGNMENTS_REALM_ROLES); the default is bilgi;
#   S2-eksik  a mapping the code expects and the realm lacks (KOD|…|evet|yok);
#   S2-fazla  a code area mapping the code does not expect: on a Privileged root, on /ROLLER or a
#             leaf config/role-groups.json names, on /UYELER, an area or any other group, an app role
#             on a target that reaches every member;
#   S2b       an admin, unclassified or realm role on a panel target (a team, a Sub-team, a Leader
#             group): e.g. skymail:mails:write on a team;
#   S3        a mapping on a group under /ROLLER that config/role-groups.json does not name (a leaf
#             it does not list, or a group under a leaf);
#   S5        a top team none of whose Leader groups (LIDERLER, KOORDINATORLER) has an enabled member
#             (Entra's ownerless group policy); the line names the team.
# The default role and the identity providers' token settings (S4, S7) are the default-roles step's,
# the console writes (S6) Keycloak's admin events, the catalogue against core (S8)
# tests/check-app-assignments.sh: none of them is read here.
# --alarm (KEYCLOAK_APP_ASSIGNMENTS_ALARM=true; --check only, with --privileged-file, since without it
# every Privileged mapping would read as drift): exit 0 when alarm=0, 1 when there is drift, 2 when
# anything could not be measured (a failed read included).
#
# --seed: the one-time initial assignment (YETKI-MATRISI §6.3, Yusuf's K1 of 2026-10-23), the
# catalogue's initialAssignments: forms skyforms:access to every top team /UYELER/<area>/<team> (its
# Sub-teams and Leader groups inherit it), skymail skymail:access and skymail:templates:read to every
# top team's LIDERLER and KOORDINATORLER and to /UYELER/ARGE/ALGOLAB. A dry run without --apply. It
# adds what is missing only (a group that holds the role, or whose parent holds it, is left alone),
# never takes anything away, and is no part of a routine reconciliation: it runs once per realm, then
# the panel keeps the assignments. Each planned assignment is one line "YENI ATAMA <group path>
# <client> <role> (<n> etkin üye)", n being the enabled people in the group and its subgroups, never a
# name. Refused, nothing written, exit 1 (PROBLEM): a target that does not exist, a target under a
# Privileged root or at or above a default group, a client or a role the realm lacks, and with --apply
# a realm that carries the realm attribute SEED_MARK_ATTRIBUTE (the seed ran there before: once the
# panel has removed an assignment on purpose, a second seed would bring it back). --apply names its
# backup in its first line (--backup-file, default /tmp/app-assignments-seed-<realm>-<UTC time>.tsv;
# never overwritten), writes one "path<TAB>client<TAB>role" line per planned assignment (mode 0600)
# before any change, then grants, then sets the realm attribute last (a run cut before it adds the
# rest next time). --restore FILE takes the backup's assignments away again (a dry run without
# --apply) and clears the realm attribute; a line naming anything but an initial assignment's role
# makes the file invalid (exit 2), before a login.
#
# It refuses every realm but e-skylab and e-skylab-sandbox, before it logs in; KEYCLOAK_REALM has no
# default. The reconciler runs it as its operator steps KEYCLOAK_RECONCILE_ONLY=app-assignments (the
# check) and tohum-atamalar (the seed; --apply unless KEYCLOAK_RECONCILE_CHECK=true).
#
# Usage (inside the Keycloak image, as an operator):
#   KEYCLOAK_REALM=<realm> app-assignments.sh --admin-user <admin> [--check] [--privileged-file <file>]
#   KEYCLOAK_REALM=<realm> app-assignments.sh --kcadm-config <file> --seed [--apply] [--backup-file <file>]
#   KEYCLOAK_REALM=<realm> app-assignments.sh --kcadm-config <file> --restore <backup> [--apply]
#
# Environment: KEYCLOAK_ADMIN_URL (default http://keycloak:8080), KEYCLOAK_REALM (required),
# KEYCLOAK_ADMIN_REALM (default master), KEYCLOAK_APP_ASSIGNMENTS_ADMIN_USERNAME (or --admin-user),
# KEYCLOAK_APP_ASSIGNMENTS_FILE (default config/app-assignments.json next to this script),
# KEYCLOAK_APP_ASSIGNMENTS_BACKUP_FILE (--seed --apply's backup when --backup-file is not given).
# Output: "[app-assignments] ..." lines (group paths, role names and counts, never a person), then
# "check: N change(s) pending, W warning(s), P problem(s)" or "applied N change(s), ...".
set -Eeuo pipefail
shopt -s inherit_errexit

umask 077

KCADM=${KCADM_BIN:-/opt/keycloak/bin/kcadm.sh}
JAVA_BIN=${JAVA_BIN:-java}
KEYCLOAK_LIB_DIR=${KEYCLOAK_LIB_DIR:-/opt/keycloak/lib/lib/main}
CONFIG_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CATALOGUE=${KEYCLOAK_APP_ASSIGNMENTS_FILE:-$CONFIG_DIR/app-assignments.json}
ADMIN_URL=${KEYCLOAK_ADMIN_URL:-http://keycloak:8080}
ADMIN_REALM=${KEYCLOAK_ADMIN_REALM:-master}
TARGET_REALM=${KEYCLOAK_REALM:-}
ADMIN_USER=${KEYCLOAK_APP_ASSIGNMENTS_ADMIN_USERNAME:-}
KCADM_CONFIG=''
OWN_CONFIG=false
MODE=check
APPLY=false
ALARM=${KEYCLOAK_APP_ASSIGNMENTS_ALARM:-false}
REALM_ROLES=${KEYCLOAK_APP_ASSIGNMENTS_REALM_ROLES:-bilgi}
# Set just before the drift's exit 1, which --alarm keeps (every other failure is 2 there).
DRIFT_EXIT=false
PRIVILEGED_FILE=''
BACKUP_FILE=''
RESTORE_FILE=''
SEED_MARK_ATTRIBUTE=skylab.app-assignments-seeded
PRIVILEGED_NAMES=(ADMIN YK DK)
LEADER_GROUPS=(LIDERLER KOORDINATORLER)
ROLE_GROUP_ROOT=ROLLER
# DK's Forms admin roles stay until forms-backend reads skyforms:read-all (config/dk-read-only.sh --forms).
DK_TEMPORARY_ROLES=('forms|skyforms:*' 'forms|skyforms:feedback:*')

usage() {
  printf 'usage: KEYCLOAK_REALM=(e-skylab|e-skylab-sandbox) %s (--admin-user <administrator> | --kcadm-config <file>) [--check [--privileged-file <file>] | --seed [--apply] [--backup-file <file>] | --restore <backup> [--apply]]\n' \
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
    --privileged-file)
      [[ $# -ge 2 ]] || usage
      PRIVILEGED_FILE=$2
      shift 2
      ;;
    --backup-file)
      [[ $# -ge 2 ]] || usage
      BACKUP_FILE=$2
      shift 2
      ;;
    --check)
      MODE=check
      shift
      ;;
    --seed)
      MODE=seed
      shift
      ;;
    --restore)
      [[ $# -ge 2 ]] || usage
      MODE=restore
      RESTORE_FILE=$2
      shift 2
      ;;
    --apply)
      APPLY=true
      shift
      ;;
    --alarm)
      ALARM=true
      shift
      ;;
    --realm-roles)
      [[ $# -ge 2 ]] || usage
      REALM_ROLES=$2
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done
if [[ $TARGET_REALM != e-skylab && $TARGET_REALM != e-skylab-sandbox ]]; then
  printf '[app-assignments] refusing realm %s: set KEYCLOAK_REALM to e-skylab (production) or e-skylab-sandbox; nothing was read or changed\n' \
    "${TARGET_REALM:-(unset)}" >&2
  exit 2
fi

# The reconciler's operator step tohum-atamalar names the backup through the environment.
if [[ $MODE == seed && -z $BACKUP_FILE ]]; then
  BACKUP_FILE=${KEYCLOAK_APP_ASSIGNMENTS_BACKUP_FILE:-}
fi
if [[ $ALARM != true && $ALARM != false ]] || [[ $REALM_ROLES != bilgi && $REALM_ROLES != alarm ]]; then
  printf 'app-assignments.sh: --alarm is true or false, --realm-roles bilgi or alarm\n' >&2
  exit 2
fi
if [[ $ALARM == true && ( $MODE != check || -z $PRIVILEGED_FILE ) ]]; then
  printf 'app-assignments.sh: --alarm belongs to --check with --privileged-file (KEYCLOAK_RECONCILE_ONLY=app-assignments passes it)\n' >&2
  exit 2
fi
if [[ $MODE == check && ( $APPLY == true || -n $BACKUP_FILE ) ]]; then
  printf 'app-assignments.sh: --check only reads (--apply and --backup-file belong to --seed)\n' >&2
  exit 2
fi
if [[ $MODE == restore && -n $BACKUP_FILE ]]; then
  printf 'app-assignments.sh: --backup-file belongs to --seed, not to --restore\n' >&2
  exit 2
fi

WORK_DIR=$(mktemp -d /tmp/app-assignments.XXXXXX)
if [[ -z $KCADM_CONFIG ]]; then
  if [[ -z $ADMIN_USER ]]; then
    if [[ -t 0 ]]; then
      read -r -p "Keycloak administrator username: " ADMIN_USER
    fi
    [[ -n $ADMIN_USER ]] || { rm -rf "$WORK_DIR"; usage; }
  fi
  KCADM_CONFIG=$(mktemp /tmp/app-assignments-kcadm.XXXXXX)
  OWN_CONFIG=true
elif [[ ! -r $KCADM_CONFIG ]]; then
  rm -rf "$WORK_DIR"
  printf 'kcadm config %s is not readable\n' "$KCADM_CONFIG" >&2
  exit 2
fi

cleanup() {
  local status=$?
  if [[ $OWN_CONFIG == true ]]; then
    rm -f "$KCADM_CONFIG"
  fi
  rm -rf "$WORK_DIR"
  # --alarm: 1 is the drift's alone; a failed read (exit 1 elsewhere) could not be measured.
  if [[ $ALARM == true && $status -ne 0 && $DRIFT_EXIT != true ]]; then
    exit 2
  fi
}
trap cleanup EXIT

log() {
  printf '[app-assignments] %s\n' "$1"
}

changes=0
warnings=0
problems=0

change() {
  changes=$((changes + 1))
  if [[ $APPLY == true ]]; then
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

# csv PATH FIELDS [ARGS...]: a read as CSV lines; a failed read stops the run (exit 1): it is never
# taken for "none".
csv() {
  local out
  if ! out=$(kcadm get "$1" -r "$TARGET_REALM" --fields "$2" --format csv --noquotes "${@:3}"); then
    printf '[app-assignments] %s could not be read in realm %s; stopped (a failed read is never taken for "none")\n' \
      "$1" "$TARGET_REALM" >&2
    exit 1
  fi
  tr -d '\r' <<<"$out" | sed '/^$/d'
}

# The in-image JSON helper (config/ReconcileJson.java, the reconciler's): the image has a JDK and
# Jackson but no jq.
compile_json_tool() {
  local jackson_jars=("$KEYCLOAK_LIB_DIR"/com.fasterxml.jackson.core.jackson-*.jar) classpath='' jar
  [[ -f ${jackson_jars[0]} ]] || { printf 'Jackson libraries were not found under %s\n' "$KEYCLOAK_LIB_DIR" >&2; exit 2; }
  for jar in "${jackson_jars[@]}"; do classpath="$classpath$jar:"; done
  mkdir -p "$WORK_DIR/classes"
  "$JAVA_BIN" -XX:TieredStopAtLevel=1 -XX:+UseSerialGC -m jdk.compiler/com.sun.tools.javac.Main \
    -d "$WORK_DIR/classes" -cp "$classpath" "$CONFIG_DIR/ReconcileJson.java" >/dev/null
  JSON_TOOL_CLASSPATH="$WORK_DIR/classes:$classpath"
}

json_tool() {
  "$JAVA_BIN" -XX:TieredStopAtLevel=1 -XX:+UseSerialGC -cp "$JSON_TOOL_CLASSPATH" ReconcileJson "$@"
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
# exist). Any other failed read stops the run (exit 1).
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
  printf '[app-assignments] the group %s could not be read in realm %s; stopped (a failed read is never taken for "absent")\n' \
    "$1" "$TARGET_REALM" >&2
  exit 1
}

# children ID: the direct subgroups of the group, one "id,name" per line.
children() {
  csv "groups/$1/children" id,name -q first=0 -q max=1000
}

# privileged_root PATH: true at or under a Privileged root.
privileged_root() {
  local name
  for name in "${PRIVILEGED_NAMES[@]}"; do
    [[ $1 == "/$name" || $1 == "/$name"/* || $1 == "/UYELER/$name" || $1 == "/UYELER/$name"/* ]] && return 0
  done
  return 1
}

# reaches_everyone PATH: /UYELER, an area, or a group at or above a default group.
reaches_everyone() {
  local default
  [[ $1 == /UYELER ]] && return 0
  if [[ $1 =~ ^/UYELER/([^/]+)$ ]] && ! privileged_root "$1"; then
    return 0
  fi
  while IFS= read -r default; do
    [[ -n $default ]] || continue
    [[ $default == "$1" || $default == "$1"/* ]] && return 0
  done <<<"$DEFAULT_GROUPS"
  return 1
}

# panel_target PATH: a group the panel may assign an app role to: a team group under
# /UYELER/<area>/<team> (a top team, a Sub-team, a Leader group) that is no Privileged root or under
# one and reaches no default group.
panel_target() {
  [[ $1 =~ ^/UYELER/[^/]+/[^/]+(/.*)?$ ]] && ! privileged_root "$1" && ! reaches_everyone "$1"
}

# --- the files, before a login -------------------------------------------------------------------
compile_json_tool
if ! parsed=$(json_tool app-assignments "$CATALOGUE" 2>"$WORK_DIR/parse.err"); then
  cat "$WORK_DIR/parse.err" >&2
  printf '[app-assignments] %s is not a valid app catalogue; nothing was read or changed\n' "$CATALOGUE" >&2
  exit 2
fi
declare -A app_role=() app_name_of=() seed_role=()
APPS=()
SEEDS=()
while IFS=$'\t' read -r kind client third roles name; do
  read -r -a role_list <<<"$roles"
  if [[ $kind == app ]]; then
    APPS+=("$client")
    app_name_of[$client]=$name
    for role in "${role_list[@]}"; do app_role[$client/$role]=1; done
  elif [[ $kind == seed ]]; then
    SEEDS+=("$client|$third|$roles")
    for role in "${role_list[@]}"; do seed_role[$client/$role]=1; done
  fi
done <<<"$parsed"

RESTORE_LINES=()
if [[ $MODE == restore ]]; then
  [[ -r $RESTORE_FILE ]] || { printf '[app-assignments] the backup %s is not readable; nothing was read or changed\n' "$RESTORE_FILE" >&2; exit 2; }
  while IFS=$'\t' read -r path client role extra; do
    [[ -n $path ]] || continue
    if [[ -n ${extra:-} || ! $path =~ ^/UYELER/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)?$ || -z ${seed_role[$client/$role]:-} ]] \
      || privileged_root "$path"; then
      printf '[app-assignments] %s is no backup of the initial assignment (a line names %s %s %s); nothing was read or changed\n' \
        "$RESTORE_FILE" "$path" "$client" "$role" >&2
      exit 2
    fi
    RESTORE_LINES+=("$path|$client|$role")
  done <"$RESTORE_FILE"
fi

credential_arguments=(
  --config "$KCADM_CONFIG"
  --server "$ADMIN_URL"
  --realm "$ADMIN_REALM"
  --user "$ADMIN_USER"
)
if [[ $OWN_CONFIG == true ]]; then
  "$KCADM" config credentials "${credential_arguments[@]}"
fi
log "realm=$TARGET_REALM mode=$MODE apply=$APPLY apps=${#APPS[@]}"

if ! realm_name=$(kcadm get "realms/$TARGET_REALM" --fields realm --format csv --noquotes 2>/dev/null | tr -d '\r') \
  || [[ $realm_name != "$TARGET_REALM" ]]; then
  printf '[app-assignments] realm %s does not exist or cannot be read; nothing was changed\n' "$TARGET_REALM" >&2
  exit 1
fi
DEFAULT_GROUPS=$(csv default-groups path)

# --- the top teams and their Leader groups, from the live tree ----------------------------------
TOP_TEAMS=()
TOP_LEADERS=()
declare -A gid_of=()
members_id=$(group_id /UYELER)
if [[ -n $members_id ]]; then
  gid_of[/UYELER]=$members_id
  areas=$(children "$members_id")
  while IFS=, read -r area_id area; do
    [[ -n $area_id && " ${PRIVILEGED_NAMES[*]} " != *" $area "* ]] || continue
    gid_of[/UYELER/$area]=$area_id
    teams=$(children "$area_id")
    while IFS=, read -r team_id team; do
      [[ -n $team_id ]] || continue
      TOP_TEAMS+=("/UYELER/$area/$team")
      gid_of[/UYELER/$area/$team]=$team_id
      subgroups=$(children "$team_id")
      for leader in "${LEADER_GROUPS[@]}"; do
        id=$(id_of "$subgroups" "$leader")
        [[ -n $id ]] || continue
        TOP_LEADERS+=("/UYELER/$area/$team/$leader")
        gid_of[/UYELER/$area/$team/$leader]=$id
      done
    done <<<"$teams"
  done <<<"$areas"
fi

declare -A client_uuid_of=()
client_list=$(csv clients id,clientId -q first=0 -q max=10000)
while IFS=, read -r id client; do
  [[ -z $id ]] || client_uuid_of[$client]=$id
done <<<"$client_list"

# ==================================================================================================
# --check: the code area and the panel area
# ==================================================================================================
run_check() {
  local kind names client role path name leader entry holder
  local users groups uuid roles_read
  declare -A expect=() pending_client=() live=() existing_role=()
  # expect["path|client|role"] = evet | geçici; pending_client[client] = 1 (frontend-arge).
  add_privileged() { # NAMES CLIENT ROLE VALUE
    local item p p_id
    for item in $1; do
      for p in "/$item" "/UYELER/$item"; do
        p_id=$(group_id "$p")
        [[ -n $p_id ]] || continue
        expect[$p|$2|$3]=$4
      done
    done
  }
  if [[ -n $PRIVILEGED_FILE ]]; then
    [[ -r $PRIVILEGED_FILE ]] || { printf '[app-assignments] %s is not readable\n' "$PRIVILEGED_FILE" >&2; exit 2; }
    while IFS=$'\t' read -r kind names client role; do
      [[ $kind == privileged ]] || continue
      add_privileged "$names" "$client" "$role" evet
    done <"$PRIVILEGED_FILE"
  else
    log 'NOTE: no --privileged-file: the Privileged roots'"'"' own expectations are unknown here (run KEYCLOAK_RECONCILE_ONLY=app-assignments); only their other mappings are compared'
  fi
  for entry in "${DK_TEMPORARY_ROLES[@]}"; do
    add_privileged DK "${entry%%|*}" "${entry#*|}" geçici
  done
  # Every list into a variable first: a failed read or script must stop the run, not pass as "none".
  local role_groups leader_roles site_roles
  # /ROLLER: config/role-groups.json.
  role_groups=$(json_tool role-groups "$CONFIG_DIR/role-groups.json")
  declare -A known_leaf=()
  while IFS=$'\t' read -r kind name client roles _; do
    [[ $kind == group ]] || continue
    known_leaf[/$ROLE_GROUP_ROOT/$name]=1
    read -r -a role_list <<<"$roles"
    for role in "${role_list[@]}"; do expect[/$ROLE_GROUP_ROOT/$name|$client|$role]=evet; done
  done <<<"$role_groups"
  # The Leader groups' code area roles (config/leader-app-roles.sh).
  leader_roles=$(bash "$CONFIG_DIR/leader-app-roles.sh" --print-expected)
  while IFS=$'\t' read -r kind client role; do
    [[ $kind == top-team-leaders ]] || continue
    for leader in ${TOP_LEADERS[@]+"${TOP_LEADERS[@]}"}; do expect[$leader|$client|$role]=evet; done
  done <<<"$leader_roles"
  # The Site clients (config/site-editor-grants.sh).
  site_roles=$(KEYCLOAK_REALM=$TARGET_REALM bash "$CONFIG_DIR/site-editor-grants.sh" --print-expected)
  while IFS=$'\t' read -r kind holder client role; do
    case $kind in
      privileged) add_privileged "$holder" "$client" "$role" evet ;;
      team-leaders)
        for leader in "${LEADER_GROUPS[@]}"; do
          [[ -z ${gid_of[$holder/$leader]:-} ]] || expect[$holder/$leader|$client|$role]=evet
        done
        ;;
      pending) pending_client[$client]=1 ;;
    esac
  done <<<"$site_roles"

  # Every role's direct holders: groups by path, people and service accounts by number.
  declare -A panel_groups=() panel_people=()
  local kod_ok=0 kod_missing=0 kod_extra=0 kod_temporary=0 kod_pending=0 service_held=0
  # The drift summary (ticket 07): one SAPMA line an item, kept for after the counts.
  local drift_lines=() s1=0 s1_realm=0 s2_missing=0 s2_extra=0 s2b=0 s3=0 s5=0
  drift() { # CLASS TARGET CLIENT ROLE
    drift_lines+=("SAPMA|$1|$2|$3|$4")
  }
  # drift_class PATH CLIENT ROLE: the class of a group mapping the code does not expect.
  drift_class() {
    local path=$1 rest leaf
    if [[ $path == "/$ROLE_GROUP_ROOT"/* ]]; then
      rest=${path#/"$ROLE_GROUP_ROOT"/}
      leaf=/$ROLE_GROUP_ROOT/${rest%%/*}
      if [[ $path != "$leaf" || -z ${known_leaf[$leaf]:-} ]]; then
        printf 'S3\n'
        return
      fi
    elif ! privileged_root "$path" && panel_target "$path" \
      && [[ $2 == realm || -z ${app_role[$2/$3]:-} ]]; then
      printf 'S2b\n'
      return
    fi
    printf 'S2-fazla\n'
  }
  read_holders() { # BASE CLIENT ROLE
    local base=$1 client=$2 role=$3 path user persons=0 accounts=0 value
    users=$(csv "$base/users" username -q first=0 -q max=100000)
    groups=$(csv "$base/groups" path -q first=0 -q max=100000)
    while IFS= read -r user; do
      [[ -n $user ]] || continue
      if [[ $user == service-account-* ]]; then accounts=$((accounts + 1)); else persons=$((persons + 1)); fi
    done <<<"$users"
    service_held=$((service_held + accounts))
    if [[ $persons -gt 0 ]]; then
      if [[ $client != realm && -n ${app_role[$client/$role]:-} ]]; then
        log "PANEL|kişi:$persons|$client|$role"
        panel_people[$client]=$(( ${panel_people[$client]:-0} + persons ))
      else
        log "KOD|kişi:$persons|$client|$role|hayır|var"
        kod_extra=$((kod_extra + 1))
        if [[ $client == realm ]]; then
          s1_realm=$((s1_realm + 1))
          drift S1-realm "kişi:$persons" "$client" "$role"
        else
          s1=$((s1 + 1))
          drift S1 "kişi:$persons" "$client" "$role"
        fi
        problem "$client/$role is held directly by $persons person(s): an admin, unclassified or realm role goes to a Privileged root or a role group, never to a person (the reset window, ekip-yetkileri ticket 06)"
      fi
    fi
    while IFS= read -r path; do
      [[ -n $path ]] || continue
      live[$path|$client|$role]=1
      if [[ $client != realm && -n ${app_role[$client/$role]:-} ]] && panel_target "$path"; then
        log "PANEL|$path|$client|$role"
        panel_groups[$client]=$(( ${panel_groups[$client]:-0} + 1 ))
        continue
      fi
      value=${expect[$path|$client|$role]:-}
      # A pending client's every group holder, a Privileged root included (Fatih decides who keeps
      # frontend-arge's roles, ADMIN and YK too), waits for that decision.
      if [[ -n ${pending_client[$client]:-} ]]; then
        value=${value:-karar-bekliyor}
      fi
      case $value in
        evet) kod_ok=$((kod_ok + 1)) ;;
        geçici) kod_temporary=$((kod_temporary + 1)) ;;
        karar-bekliyor) kod_pending=$((kod_pending + 1)) ;;
        *)
          value=hayır
          kod_extra=$((kod_extra + 1))
          drift "$(drift_class "$path" "$client" "$role")" "$path" "$client" "$role"
          if ! privileged_root "$path" && [[ $path != "/$ROLE_GROUP_ROOT" && $path != "/$ROLE_GROUP_ROOT"/* ]]; then
            if [[ $client != realm && -n ${app_role[$client/$role]:-} ]]; then
              problem "$client/$role (an app role) is mapped to $path, which is no panel target (no team group, or it reaches every member: a default role's job)"
            else
              problem "$client/$role (an admin, unclassified or realm role) is mapped to $path, outside the code area's places: only a Privileged root, a role group or a named exception may hold it"
            fi
          fi
          ;;
      esac
      log "KOD|$path|$client|$role|$value|var"
    done <<<"$groups"
  }
  log 'reading the direct holders of every role (two reads a role; minutes in production)'
  local sorted_clients
  sorted_clients=$(printf '%s\n' "${!client_uuid_of[@]}" | sort)
  while IFS= read -r client; do
    [[ -n $client ]] || continue
    uuid=${client_uuid_of[$client]}
    roles_read=$(csv "clients/$uuid/roles" name -q first=0 -q max=10000)
    while IFS= read -r role; do
      [[ -n $role ]] || continue
      existing_role[$client|$role]=1
      read_holders "clients/$uuid/roles/$role" "$client" "$role"
    done <<<"$roles_read"
  done <<<"$sorted_clients"
  roles_read=$(csv roles name -q first=0 -q max=10000)
  while IFS= read -r role; do
    [[ -n $role && $role != "default-roles-${TARGET_REALM,,}" ]] || continue
    existing_role[realm|$role]=1
    read_holders "roles/$role" realm "$role"
  done <<<"$roles_read"

  # What the code expects and the realm lacks (only roles the realm has: a client or a role of
  # another realm's shape is no drift).
  for entry in "${!expect[@]}"; do
    [[ -z ${live[$entry]:-} ]] || continue
    IFS='|' read -r path client role <<<"$entry"
    [[ -n ${existing_role[$client|$role]:-} ]] || continue
    log "KOD|$path|$client|$role|${expect[$entry]}|yok"
    kod_missing=$((kod_missing + 1))
    drift S2-eksik "$path" "$client" "$role"
  done

  log "KOD: $kod_ok as expected, $kod_missing missing, $kod_extra not in code, $kod_temporary temporary (DK's Forms admin roles), $kod_pending pending a decision (frontend-arge: Fatih); service accounts: $service_held role(s) held (the service-roles step checks them); the default role and the identity providers: KEYCLOAK_RECONCILE_ONLY=default-roles"
  for client in "${APPS[@]}"; do
    log "PANEL: ${app_name_of[$client]} ($client): ${panel_groups[$client]:-0} group assignment(s), ${panel_people[$client]:-0} person assignment(s)"
  done

  # S5: a top team none of whose Leader groups has an enabled member.
  local team leader_id members_read has_leader member enabled
  for team in ${TOP_TEAMS[@]+"${TOP_TEAMS[@]}"}; do
    has_leader=false
    for leader in "${LEADER_GROUPS[@]}"; do
      leader_id=${gid_of[$team/$leader]:-}
      [[ -n $leader_id ]] || continue
      members_read=$(csv "groups/$leader_id/members" id,enabled -q first=0 -q max=100000)
      while IFS=, read -r member enabled; do
        if [[ -n $member && $enabled == true ]]; then has_leader=true; fi
      done <<<"$members_read"
    done
    [[ $has_leader == true ]] || drift S5 "$team" - -
  done

  local line alarm
  for line in ${drift_lines[@]+"${drift_lines[@]}"}; do
    log "$line"
    case $line in
      SAPMA\|S2-eksik\|*) s2_missing=$((s2_missing + 1)) ;;
      SAPMA\|S2-fazla\|*) s2_extra=$((s2_extra + 1)) ;;
      SAPMA\|S2b\|*) s2b=$((s2b + 1)) ;;
      SAPMA\|S3\|*) s3=$((s3 + 1)) ;;
      SAPMA\|S5\|*) s5=$((s5 + 1)) ;;
    esac
  done
  alarm=$((s1 + s2_missing + s2_extra + s2b + s3 + s5))
  if [[ $REALM_ROLES == alarm ]]; then alarm=$((alarm + s1_realm)); fi
  log "SAPMA: S1=$s1 S1-realm=$s1_realm ($REALM_ROLES) S2-eksik=$s2_missing S2-fazla=$s2_extra S2b=$s2b S3=$s3 S5=$s5, alarm=$alarm"
  log "check: 0 change(s) pending, $warnings warning(s), $problems problem(s)"
  if [[ $ALARM == true && $alarm -gt 0 ]]; then
    DRIFT_EXIT=true
    exit 1
  fi
}

# ==================================================================================================
# --seed: the one-time initial assignment
# ==================================================================================================
# enabled_members ID: the enabled people of the group and its subgroups (each counted once).
declare -A counted=()
enabled_members() {
  local queue=("$1") id member enabled child_id total=0 members subgroups
  counted=()
  while [[ ${#queue[@]} -gt 0 ]]; do
    id=${queue[0]}
    queue=("${queue[@]:1}")
    members=$(csv "groups/$id/members" id,enabled -q first=0 -q max=100000)
    while IFS=, read -r member enabled; do
      [[ -n $member && -z ${counted[$member]:-} ]] || continue
      counted[$member]=1
      if [[ $enabled == true ]]; then total=$((total + 1)); fi
    done <<<"$members"
    subgroups=$(children "$id")
    while IFS=, read -r child_id _; do
      [[ -z $child_id ]] || queue+=("$child_id")
    done <<<"$subgroups"
  done
  printf '%s\n' "$total"
}

# held_here_or_above PATH CLIENT ROLE: "yes" when the group or one of its parents holds the role
# directly, else "no". Called as a plain statement, so that a failed read stops the run.
held_here_or_above() {
  local path=$1 id held
  while [[ $path == /UYELER/* ]]; do
    id=${gid_of[$path]:-}
    if [[ -z $id ]]; then
      id=$(group_id "$path")
    fi
    if [[ -n $id ]]; then
      held=$(csv "groups/$id/role-mappings/clients/${client_uuid_of[$2]}" name)
      if grep -Fxq -- "$3" <<<"$held"; then
        printf 'yes\n'
        return 0
      fi
    fi
    path=${path%/*}
  done
  printf 'no\n'
}

seed_mark() {
  kcadm get "realms/$TARGET_REALM" --fields 'attributes(*)' >"$WORK_DIR/realm.json"
  json_tool field attributes <"$WORK_DIR/realm.json" | json_tool field "$SEED_MARK_ATTRIBUTE"
}

set_seed_mark() {
  kcadm get "realms/$TARGET_REALM" --fields 'attributes(*)' >"$WORK_DIR/realm.json"
  json_tool realm-attribute "$SEED_MARK_ATTRIBUTE" "$1" <"$WORK_DIR/realm.json" >"$WORK_DIR/realm-write.json"
  kcadm_write update "realms/$TARGET_REALM" -n -f "$WORK_DIR/realm-write.json"
}

run_seed() {
  local entry client target roles role path id uuid role_lines role_id mark planned=() plan targets held=0 state
  local members stamp file body
  mark=$(seed_mark)
  if [[ -n $mark ]]; then
    if [[ $APPLY == true ]]; then
      problem "the initial assignment ran in realm $TARGET_REALM before ($SEED_MARK_ATTRIBUTE=$mark): it runs once, the SKY LAB admin panel keeps the assignments since (a second run would bring back an assignment the panel removed on purpose); nothing was written"
      log "applied 0 change(s), $warnings warning(s), $problems problem(s)"
      exit 1
    fi
    log "NOTE: the initial assignment ran in realm $TARGET_REALM before ($SEED_MARK_ATTRIBUTE=$mark); this dry run only shows what is missing since"
  fi
  [[ ${#TOP_TEAMS[@]} -gt 0 ]] || warning "/UYELER has no top team in realm $TARGET_REALM"
  log "top teams: ${#TOP_TEAMS[@]}, their Leader groups: ${#TOP_LEADERS[@]}"
  declare -A role_id_of=()
  for entry in "${SEEDS[@]}"; do
    IFS='|' read -r client target roles <<<"$entry"
    uuid=${client_uuid_of[$client]:-}
    if [[ -z $uuid ]]; then
      problem "the client $client does not exist in realm $TARGET_REALM; nothing was written"
      continue
    fi
    role_lines=$(csv "clients/$uuid/roles" id,name -q first=0 -q max=10000)
    read -r -a role_list <<<"$roles"
    for role in "${role_list[@]}"; do
      role_id=$(id_of "$role_lines" "$role")
      if [[ -z $role_id ]]; then
        problem "the role $client/$role does not exist in realm $TARGET_REALM; nothing was written"
        continue
      fi
      role_id_of[$client/$role]=$role_id
    done
    case $target in
      top-teams) targets=(${TOP_TEAMS[@]+"${TOP_TEAMS[@]}"}) ;;
      top-team-leaders) targets=(${TOP_LEADERS[@]+"${TOP_LEADERS[@]}"}) ;;
      *)
        id=$(group_id "$target")
        if [[ -z $id ]]; then
          problem "the target $target does not exist in realm $TARGET_REALM; nothing was written"
          continue
        fi
        gid_of[$target]=$id
        targets=("$target")
        ;;
    esac
    for path in ${targets[@]+"${targets[@]}"}; do
      if privileged_root "$path" || [[ $path == "/$ROLE_GROUP_ROOT" || $path == "/$ROLE_GROUP_ROOT"/* ]] || reaches_everyone "$path"; then
        problem "refusing $path as a target of $client: a Privileged root, a role group, /UYELER, an area or a group at or above a default group is no panel target; nothing was written"
        continue
      fi
      for role in "${role_list[@]}"; do
        [[ -n ${role_id_of[$client/$role]:-} ]] || continue
        state=$(held_here_or_above "$path" "$client" "$role")
        if [[ $state == yes ]]; then
          held=$((held + 1))
          continue
        fi
        planned+=("$path|$client|$role")
      done
    done
  done
  if [[ $problems != 0 ]]; then
    if [[ $APPLY == true ]]; then
      log "applied 0 change(s), $warnings warning(s), $problems problem(s)"
    else
      log "check: 0 change(s) pending, $warnings warning(s), $problems problem(s)"
    fi
    exit 1
  fi
  declare -A members_of=()
  for plan in ${planned[@]+"${planned[@]}"}; do
    IFS='|' read -r path client role <<<"$plan"
    if [[ -z ${members_of[$path]+set} ]]; then
      members_of[$path]=$(enabled_members "${gid_of[$path]}")
    fi
    log "YENI ATAMA $path $client $role (${members_of[$path]} etkin üye)"
  done
  log "already held (by the group or a parent): $held"
  if [[ $APPLY == true && ${#planned[@]} -gt 0 ]]; then
    file=${BACKUP_FILE:-/tmp/app-assignments-seed-$TARGET_REALM-$(date -u +%Y%m%dT%H%M%SZ).tsv}
    if [[ -e $file ]]; then
      problem "the backup $file exists; nothing was written (never overwritten)"
      log "applied 0 change(s), $warnings warning(s), $problems problem(s)"
      exit 1
    fi
    log "backup: $file"
    : >"$file"
    chmod 0600 "$file"
    for plan in "${planned[@]}"; do
      IFS='|' read -r path client role <<<"$plan"
      printf '%s\t%s\t%s\n' "$path" "$client" "$role" >>"$file"
    done
  fi
  for plan in ${planned[@]+"${planned[@]}"}; do
    IFS='|' read -r path client role <<<"$plan"
    change "grant $client/$role to the group $path"
    if [[ $APPLY == true ]]; then
      body="[{\"id\":\"${role_id_of[$client/$role]}\",\"name\":\"$role\"}]"
      kcadm_write create "groups/${gid_of[$path]}/role-mappings/clients/${client_uuid_of[$client]}" -r "$TARGET_REALM" -b "$body"
    fi
  done
  if [[ $APPLY == true && -z $mark ]]; then
    stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    set_seed_mark "$stamp ${#planned[@]} assignment(s)"
    log "realm attribute $SEED_MARK_ATTRIBUTE=$stamp ${#planned[@]} assignment(s): the initial assignment ran; the panel keeps the assignments from now on"
  fi
  if [[ $APPLY == true ]]; then
    log "applied $changes change(s), $warnings warning(s), $problems problem(s)"
  else
    log "check: $changes change(s) pending, $warnings warning(s), $problems problem(s)"
  fi
}

# ==================================================================================================
# --restore: the backup's assignments taken away again
# ==================================================================================================
run_restore() {
  local line path client role id uuid body role_lines role_id held mark
  for line in ${RESTORE_LINES[@]+"${RESTORE_LINES[@]}"}; do
    IFS='|' read -r path client role <<<"$line"
    id=$(group_id "$path")
    uuid=${client_uuid_of[$client]:-}
    if [[ -z $id || -z $uuid ]]; then
      log "$path: $client/$role: unchanged (the group or the client is gone)"
      continue
    fi
    held=$(csv "groups/$id/role-mappings/clients/$uuid" name)
    if ! grep -Fxq -- "$role" <<<"$held"; then
      log "$path: $client/$role: unchanged (not held)"
      continue
    fi
    change "take $client/$role away from the group $path"
    if [[ $APPLY == true ]]; then
      role_lines=$(csv "clients/$uuid/roles" id,name -q first=0 -q max=10000)
      role_id=$(id_of "$role_lines" "$role")
      body="[{\"id\":\"$role_id\",\"name\":\"$role\"}]"
      kcadm_write delete "groups/$id/role-mappings/clients/$uuid" -r "$TARGET_REALM" -b "$body"
    fi
  done
  mark=$(seed_mark)
  if [[ -n $mark ]]; then
    change "clear the realm attribute $SEED_MARK_ATTRIBUTE (the initial assignment may run again)"
    if [[ $APPLY == true ]]; then set_seed_mark ''; fi
  fi
  if [[ $APPLY == true ]]; then
    log "applied $changes change(s), $warnings warning(s), $problems problem(s)"
  else
    log "check: $changes change(s) pending, $warnings warning(s), $problems problem(s)"
  fi
}

case $MODE in
  check) run_check ;;
  seed) run_seed ;;
  restore) run_restore ;;
esac
