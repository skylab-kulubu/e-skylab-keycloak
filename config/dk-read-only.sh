#!/usr/bin/env bash
# DK reads and does not write (grup-yonetimi ticket 08, decision GY1 of 2026-10-12): the one-time
# step that takes DK's write roles away. DK is Microsoft Entra's Global Reader ("can read everything
# that a Global Administrator can, but not update anything") plus Reports Reader (the audit reports):
# here core's global:read plus audit:read. core already refuses every write of a reader root's member
# whatever the token carries (core-backend #244, #247); this step brings Keycloak in line, so that the
# tokens carry no write role and the roles mode (grup-yonetimi 09) gives DK its reads from global:read.
#
# Why a step of its own: the reconciler seeds a Privileged role ONCE (skylab.seeded-group-mappings)
# and never takes a mapping away, so DK keeps the write roles it got when core's resource roles were
# seeded to ADMIN, YK and DK. Their set is ADMIN and YK now (CORE_PRIVILEGED_NAMES); DK's read roles
# come from the core-roles step (core global:read and audit:read, forms skyforms:read-all) and from
# site-editor-grants.sh (the event sites' content:read). Run the core-roles step first.
#
# For each DK root (/DK and /UYELER/DK, whichever exist: core's AUTHZ_PRIVILEGED_READER_ROOTS) it reads
# the root's direct role mappings and sorts each one:
#   write  taken away by --apply (WRITE_ROLES): core's 13 roles of the contract table but global:read
#          and url:access (the 12 write roles and url:moderator; core-backend docs/authz-roles.md;
#          media:private:read and github:activity:read only read, but DK reads them through its root in
#          the groups mode and through global:read in the both and roles modes), any client's
#          cms:access, content:write and client:admin (a Site client's editor and tenant roles: where the
#          client has content:read and the root lacks it, content:read is granted in their place),
#          SkyMail's sending and writing roles and Place's roles;
#   forms  Forms' admin roles (FORMS_ROLES: skyforms:*, skyforms:feedback:*, as core's AdminRoles):
#          kept until forms-backend reads skyforms:read-all (Fatih); --forms takes them away then;
#   read   kept (READ_ROLES): core global:read, audit:read, users:read; SkyMail's reading roles;
#          content:read of any client; forms skyforms:read-all;
#   app    kept (APP_ROLES, core's app roles bound to the holder; Yusuf 2026-10-14, Y1 and Y5): core's
#          own short link roles (url:access and url:create/get/update/delete: a DK member keeps their
#          own links) and Forms' seat and screens (skyforms:access, form:manage, response:manage,
#          feedback:manage: forms are opened only through their collaborators; Fatih may choose
#          skyforms:access for DK's /admin entry);
#   other  any other client role and every realm role: a WARNING, kept (the Java era's realm roles
#          leave in rol-temizligi F3; anything else is decided in the SKY LAB admin panel).
# A write role the root still gets through a composite role or a parent group, and a write role a
# subgroup of the root holds directly (core refuses one there from the panel; the Admin Console does
# not), are WARNINGs: only the roots' direct mappings are taken away. Each root ends with "write roles
# held: none" or their list.
#
# Safety: a root that would lose a core role but holds no core/global:read and core/audit:read (or,
# with --forms, a Forms role but no forms/skyforms:read-all) is a PROBLEM: DK would lose its reads in
# the roles mode; run the core-roles step first. A default group at or under a DK root is a PROBLEM.
# A failed read (anything but Keycloak's "not found" for a group) stops the run with exit 1. On a
# PROBLEM nothing is written.
#
# --apply names the backup file in its first line (--backup-file, default
# /tmp/dk-read-only-<realm>-<UTC time>.tsv; never overwritten) and writes it before any change: one
# "path<TAB>client<TAB>role" line per mapping taken away, and says so at once ("backup: …"), so that a
# run cut halfway leaves its backup named on the screen; then it grants content:read where planned,
# then takes the roles away. A second run changes nothing and writes no backup. --restore FILE grants a backup's mappings back (a dry run without --apply; content:read
# stays); a line that is no DK write or Forms role mapping makes the file invalid (exit 2), before a
# login.
#
# It refuses every realm but e-skylab and e-skylab-sandbox, before it logs in; KEYCLOAK_REALM has no
# default. It is not one of the reconciler's steps: it changes what the reconciler never takes away,
# once, with Yusuf's approval (runbook §28: sandbox first; dry run, approval, --apply, dry run 0).
#
# Usage (inside the Keycloak image, as an operator):
#   KEYCLOAK_REALM=<realm> dk-read-only.sh --admin-user <admin>                       # --check (default)
#   KEYCLOAK_REALM=<realm> dk-read-only.sh --kcadm-config <file> [--forms] --apply [--backup-file <file>]
#   KEYCLOAK_REALM=<realm> dk-read-only.sh --kcadm-config <file> --restore <backup> [--apply]
#
# Environment: KEYCLOAK_ADMIN_URL (default http://keycloak:8080), KEYCLOAK_REALM (required),
# KEYCLOAK_ADMIN_REALM (default master), KEYCLOAK_DK_READ_ONLY_ADMIN_USERNAME (or --admin-user).
# Output: "[dk-read-only] ..." lines (group paths and role names, never a person), then "check: N
# change(s) pending, W warning(s), P problem(s)" or "applied N change(s), ...". Exit 0 unless a
# PROBLEM or a failed read (1) or a usage error, a refused realm or an invalid backup (2).
set -Eeuo pipefail
shopt -s inherit_errexit

umask 077

KCADM=${KCADM_BIN:-/opt/keycloak/bin/kcadm.sh}
JAVA_BIN=${JAVA_BIN:-java}
KEYCLOAK_LIB_DIR=${KEYCLOAK_LIB_DIR:-/opt/keycloak/lib/lib/main}
CONFIG_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ADMIN_URL=${KEYCLOAK_ADMIN_URL:-http://keycloak:8080}
ADMIN_REALM=${KEYCLOAK_ADMIN_REALM:-master}
TARGET_REALM=${KEYCLOAK_REALM:-}
ADMIN_USER=${KEYCLOAK_DK_READ_ONLY_ADMIN_USERNAME:-}
KCADM_CONFIG=''
OWN_CONFIG=false
MODE=check
FORMS=keep
RESTORE_FILE=''
BACKUP_FILE=''

# The Privileged names whose roots read and do not write (core's AUTHZ_PRIVILEGED_READER_ROOTS
# default: /DK and /UYELER/DK).
READER_NAMES=(DK)
# The lists are read through listed's nameref.
# shellcheck disable=SC2034
# client|role ("*": any client). core's are the contract table's (core-backend internal/authz/roles.go)
# but global:read and url:access; the Site roles are inscribed's (ADR-0056); SkyMail's and Place's
# write or send.
WRITE_ROLES=(
  'core|event:manage' 'core|season:manage' 'core|ticket:manage' 'core|ticket:validate'
  'core|competitor:manage' 'core|competition:manage' 'core|media:manage' 'core|media:private:read'
  'core|certificate:manage' 'core|users:manage' 'core|groups:manage' 'core|github:activity:read'
  'core|url:moderator'
  '*|cms:access' '*|content:write' '*|client:admin'
  'skymail|skymail:announcements:send' 'skymail|skymail:templates:write' 'skymail|skymail:lists:write'
  'skymail|skymail:mails:write' 'skymail|skymail:mails:send' 'skymail|skymail:mails:approve'
  'place|place:admin' 'place|place:moderator'
)
# Forms' admin roles (core-backend role_classes.go AdminRoles): kept until --forms.
# shellcheck disable=SC2034
FORMS_ROLES=('forms|skyforms:*' 'forms|skyforms:feedback:*')
# core's app roles bound to the holder (role_classes.go AppRoles) that DK keeps (Y1, Y5).
# shellcheck disable=SC2034
APP_ROLES=(
  'core|url:access' 'core|url:create' 'core|url:get' 'core|url:update' 'core|url:delete'
  'forms|skyforms:access' 'forms|skyforms:form:manage' 'forms|skyforms:response:manage'
  'forms|skyforms:feedback:manage'
)
# shellcheck disable=SC2034
READ_ROLES=(
  'core|global:read' 'core|audit:read' 'core|users:read'
  'skymail|skymail:system-mails:read' 'skymail|skymail:access' 'skymail|skymail:templates:read'
  'skymail|skymail:lists:read' 'skymail|skymail:mails:read'
  '*|content:read'
  'forms|skyforms:read-all'
)
# The roles a root must hold before it loses core's (or, with --forms, Forms') write roles.
CORE_READS=(global:read audit:read)
FORMS_READ=skyforms:read-all
# The Site read role granted in place of a Site write role taken away.
SITE_READ_ROLE=content:read

usage() {
  printf 'usage: KEYCLOAK_REALM=(e-skylab|e-skylab-sandbox) %s (--admin-user <administrator> | --kcadm-config <file>) [--check | --apply] [--forms] [--backup-file <file>] | --restore <backup> [--check | --apply]\n' \
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
    --forms)
      FORMS=remove
      shift
      ;;
    --backup-file)
      [[ $# -ge 2 && -n $2 ]] || usage
      BACKUP_FILE=$2
      shift 2
      ;;
    --restore)
      [[ $# -ge 2 && -n $2 ]] || usage
      RESTORE_FILE=$2
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done
if [[ -n $RESTORE_FILE && ($FORMS == remove || -n $BACKUP_FILE) ]]; then
  usage
fi
if [[ -z $RESTORE_FILE && $MODE == apply && -z $BACKUP_FILE ]]; then
  BACKUP_FILE=/tmp/dk-read-only-${TARGET_REALM:-realm}-$(date -u +%Y%m%dT%H%M%SZ).tsv
fi

log() {
  printf '[dk-read-only] %s\n' "$1"
}

if [[ $TARGET_REALM != e-skylab && $TARGET_REALM != e-skylab-sandbox ]]; then
  log "refusing realm ${TARGET_REALM:-(unset)}: set KEYCLOAK_REALM to e-skylab (production) or e-skylab-sandbox; nothing was read or changed" >&2
  exit 2
fi

# reader_root PATH: true for a DK root path (/<NAME> or /UYELER/<NAME> of READER_NAMES).
reader_root() {
  local name
  for name in "${READER_NAMES[@]}"; do
    [[ $1 != "/$name" && $1 != "/UYELER/$name" ]] || return 0
  done
  return 1
}

# listed LIST CLIENT ROLE: true when the array LIST ("client|role", "*" for any client) holds the pair.
# Names compare as plain strings (skyforms:* is no pattern).
listed() {
  local -n list=$1
  local entry
  for entry in "${list[@]}"; do
    if [[ (${entry%%|*} == '*' || ${entry%%|*} == "$2") && ${entry#*|} == "$3" ]]; then
      return 0
    fi
  done
  return 1
}

# --- the backup to restore, before a login -----------------------------------------------------
RESTORE_LINES=()
if [[ -n $RESTORE_FILE ]]; then
  if [[ ! -r $RESTORE_FILE || ! -f $RESTORE_FILE ]]; then
    log "the backup $RESTORE_FILE is not readable; nothing was read or changed" >&2
    exit 2
  fi
  number=0
  while IFS= read -r line || [[ -n $line ]]; do
    number=$((number + 1))
    [[ -n $line && $line != '#'* ]] || continue
    IFS=$'\t' read -r path client role rest <<<"$line"
    if [[ -z ${path:-} || -z ${client:-} || -z ${role:-} || -n ${rest:-} ]] || ! reader_root "$path" \
      || [[ $client == realm-management ]] \
      || ! { listed WRITE_ROLES "$client" "$role" || listed FORMS_ROLES "$client" "$role"; }; then
      log "line $number of $RESTORE_FILE is not a DK write role mapping (path<TAB>client<TAB>role of a DK root and a role this step takes away): $RESTORE_FILE is not a dk-read-only backup; nothing was read or changed" >&2
      exit 2
    fi
    RESTORE_LINES+=("$path"$'\t'"$client"$'\t'"$role")
  done <"$RESTORE_FILE"
fi

WORK_DIR=$(mktemp -d /tmp/dk-read-only.XXXXXX)
if [[ -z $KCADM_CONFIG ]]; then
  if [[ -z $ADMIN_USER ]]; then
    if [[ -t 0 ]]; then
      read -r -p "Keycloak administrator username: " ADMIN_USER
    fi
    [[ -n $ADMIN_USER ]] || { rm -rf "$WORK_DIR"; usage; }
  fi
  KCADM_CONFIG=$(mktemp /tmp/dk-read-only-kcadm.XXXXXX)
  OWN_CONFIG=true
elif [[ ! -r $KCADM_CONFIG ]]; then
  rm -rf "$WORK_DIR"
  printf 'kcadm config %s is not readable\n' "$KCADM_CONFIG" >&2
  exit 2
fi

cleanup() {
  if [[ $OWN_CONFIG == true ]]; then
    rm -f "$KCADM_CONFIG"
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

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

summary() {
  if [[ $MODE == apply ]]; then
    log "applied $changes change(s), $warnings warning(s), $problems problem(s)"
  else
    log "check: $changes change(s) pending, $warnings warning(s), $problems problem(s)"
  fi
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

csv() {
  kcadm get "$1" -r "$TARGET_REALM" --fields "$2" --format csv --noquotes "${@:3}" | tr -d '\r' | sed '/^$/d'
}

# read_or_stop WHAT COMMAND...: the output of a read; a failed read stops the run (exit 1), it is never
# taken for "nothing".
read_or_stop() {
  local what=$1 out
  shift
  if ! out=$("$@"); then
    log "$what could not be read in realm $TARGET_REALM; stopped (a failed read is never taken for \"none\"; nothing was changed)" >&2
    exit 1
  fi
  printf '%s\n' "$out"
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

# mappings ID: the group's direct role mappings, "client<TAB>clientUuid<TAB>roleId<TAB>role" per line
# ("-<TAB>-<TAB>roleId<TAB>role" for a realm role).
mappings() {
  kcadm get "groups/$1/role-mappings" -r "$TARGET_REALM" | json_tool scope-mappings
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
  log "the group $1 could not be read in realm $TARGET_REALM; stopped (a failed read is never taken for \"absent\")" >&2
  exit 1
}

role_reference() { # role_reference ID NAME: {"id":…,"name":…}; role names carry no quote or backslash
  printf '{"id":"%s","name":"%s"}' "$1" "$2"
}

# write_mappings create|delete GROUP_ID CLIENT_UUID ROLE_ID|ROLE...: one call for one client's roles.
write_mappings() {
  local verb=$1 gid=$2 client_uuid=$3 body='' item
  shift 3
  for item in "$@"; do
    body="$body,$(role_reference "${item%%|*}" "${item#*|}")"
  done
  kcadm_write "$verb" "groups/$gid/role-mappings/clients/$client_uuid" -r "$TARGET_REALM" -b "[${body#,}]"
}

# --- login --------------------------------------------------------------------------------------
compile_json_tool
credential_arguments=(
  --config "$KCADM_CONFIG"
  --server "$ADMIN_URL"
  --realm "$ADMIN_REALM"
  --user "$ADMIN_USER"
)
# kcadm prompts for the password on the operator's terminal (never redirect this line).
if [[ $OWN_CONFIG == true ]]; then
  "$KCADM" config credentials "${credential_arguments[@]}"
fi
if [[ -n $RESTORE_FILE ]]; then
  log "realm=$TARGET_REALM mode=$MODE restore=$RESTORE_FILE (${#RESTORE_LINES[@]} mapping(s))"
else
  # The backup's path first: a run cut halfway still names it.
  log "realm=$TARGET_REALM mode=$MODE forms=$FORMS${BACKUP_FILE:+ backup=$BACKUP_FILE}"
fi
if ! realm_name=$(kcadm get "realms/$TARGET_REALM" --fields realm --format csv --noquotes 2>/dev/null | tr -d '\r') \
  || [[ $realm_name != "$TARGET_REALM" ]]; then
  log "realm $TARGET_REALM does not exist or cannot be read; nothing was changed" >&2
  exit 1
fi

# --- the DK roots and the default groups -----------------------------------------------------------
roots=()
declare -A gid_of=()
for name in "${READER_NAMES[@]}"; do
  for path in "/$name" "/UYELER/$name"; do
    id=$(group_id "$path")
    [[ -n $id ]] || continue
    roots+=("$path")
    gid_of[$path]=$id
  done
done
if [[ ${#roots[@]} == 0 ]]; then
  log "no DK group (neither /DK nor /UYELER/DK) in realm $TARGET_REALM; nothing to do"
  summary
  exit 0
fi
log "DK groups: ${roots[*]}"
default_groups=$(read_or_stop 'the default groups' csv default-groups path)
while IFS= read -r default; do
  [[ -n $default ]] || continue
  for path in "${roots[@]}"; do
    if [[ $default == "$path" || $default == "$path"/* ]]; then
      problem "the default group $default is at or under the DK group $path: every new user would be in DK; nothing was changed (remove it from the realm's default groups first)"
    fi
  done
done <<<"$default_groups"

# Both lookups set a global (never call them inside $(...): a subshell's globals are lost).
declare -A client_uuid_of=() role_lines_of=()
CLIENT_UUID=''
ROLE_ID=''
# lookup_client CLIENT_ID: CLIENT_UUID is the client's uuid, empty when it does not exist (read once).
lookup_client() {
  if [[ -z ${client_uuid_of[$1]+set} ]]; then
    client_uuid_of[$1]=$(read_or_stop "the client $1" uuid_by "$1")
  fi
  CLIENT_UUID=${client_uuid_of[$1]}
}
# lookup_role CLIENT_UUID ROLE: ROLE_ID is the client role's id, empty when it does not exist (a
# client's roles are read once).
lookup_role() {
  if [[ -z ${role_lines_of[$1]+set} ]]; then
    role_lines_of[$1]=$(read_or_stop 'the roles of a client' csv "clients/$1/roles" id,name -q first=0 -q max=10000)
  fi
  ROLE_ID=$(id_of "${role_lines_of[$1]}" "$2")
}

# --- restore --------------------------------------------------------------------------------------
if [[ -n $RESTORE_FILE ]]; then
  declare -A restore_of=() held_of=()
  for entry in "${RESTORE_LINES[@]}"; do
    IFS=$'\t' read -r path client role <<<"$entry"
    gid=${gid_of[$path]:-}
    if [[ -z $gid ]]; then
      warning "$path does not exist in realm $TARGET_REALM; $client/$role not restored"
      continue
    fi
    lookup_client "$client"
    uuid=$CLIENT_UUID
    if [[ -z $uuid ]]; then
      warning "the client $client does not exist in realm $TARGET_REALM; $client/$role not restored to $path"
      continue
    fi
    lookup_role "$uuid" "$role"
    rid=$ROLE_ID
    if [[ -z $rid ]]; then
      warning "the role $client/$role does not exist in realm $TARGET_REALM; not restored to $path"
      continue
    fi
    if [[ -z ${held_of[$path|$uuid]+set} ]]; then
      held_of[$path|$uuid]=$(read_or_stop "the $client roles of $path" csv "groups/$gid/role-mappings/clients/$uuid" name)
    fi
    if grep -Fxq -- "$role" <<<"${held_of[$path|$uuid]}"; then
      log "$path holds $client/$role (unchanged)"
      continue
    fi
    change "grant $client/$role to $path (restore)"
    restore_of[$path|$uuid]="${restore_of[$path|$uuid]:-} $rid|$role"
  done
  if [[ $problems != 0 ]]; then
    summary
    exit 1
  fi
  if [[ $MODE == apply ]]; then
    for key in "${!restore_of[@]}"; do
      read -r -a items <<<"${restore_of[$key]}"
      write_mappings create "${gid_of[${key%%|*}]}" "${key#*|}" "${items[@]}" \
        || { log "a write failed in realm $TARGET_REALM; stopped (run the restore again: it grants only what is missing)" >&2; exit 1; }
    done
  fi
  summary
  exit 0
fi

# --- sort each root's mappings ----------------------------------------------------------------------
removals=()   # path|client_uuid|client|role_id|role
grants=()     # path|client_uuid|client|role_id|role|in place of
for path in "${roots[@]}"; do
  gid=${gid_of[$path]}
  held=$(read_or_stop "the role mappings of $path" mappings "$gid")
  reads=() apps=() writes=() forms_kept=() others=()
  declare -A holds=() replaced_of=()
  while IFS=$'\t' read -r client uuid rid role; do
    [[ -n ${role:-} ]] || continue
    holds[$client|$role]=1
    if [[ $client == - ]]; then
      others+=("realm/$role")
    elif listed READ_ROLES "$client" "$role"; then
      reads+=("$client/$role")
    elif listed APP_ROLES "$client" "$role"; then
      apps+=("$client/$role")
    elif listed WRITE_ROLES "$client" "$role" || { [[ $FORMS == remove ]] && listed FORMS_ROLES "$client" "$role"; }; then
      writes+=("$client/$role")
      removals+=("$path|$uuid|$client|$rid|$role")
      [[ -n ${client_uuid_of[$client]+set} ]] || client_uuid_of[$client]=$uuid
      if [[ $role == cms:access || $role == content:write || $role == client:admin ]]; then
        replaced_of[$client]="${replaced_of[$client]:+${replaced_of[$client]}, }$role"
      fi
    elif listed FORMS_ROLES "$client" "$role"; then
      forms_kept+=("$client/$role")
    else
      others+=("$client/$role")
    fi
  done <<<"$held"

  # A Site write role goes, its read role comes.
  for client in "${!replaced_of[@]}"; do
    [[ -z ${holds[$client|$SITE_READ_ROLE]:-} ]] || continue
    lookup_client "$client"
    uuid=$CLIENT_UUID
    lookup_role "$uuid" "$SITE_READ_ROLE"
    rid=$ROLE_ID
    if [[ -z $rid ]]; then
      log "NOTE: $client has no $SITE_READ_ROLE role; $path gets no read role in place of ${replaced_of[$client]}"
      continue
    fi
    grants+=("$path|$uuid|$client|$rid|$SITE_READ_ROLE|${replaced_of[$client]}")
  done

  # The reads a root holds before it loses the writes they stand for.
  if [[ " ${writes[*]-} " == *" core/"* ]]; then
    for role in "${CORE_READS[@]}"; do
      [[ -n ${holds[core|$role]:-} ]] \
        || problem "$path holds no core/$role: taking core's write roles away first would leave DK without its reads in the roles mode; run the core-roles step first (KEYCLOAK_RECONCILE_ONLY=core-roles, runbook §19, §28); nothing was changed"
    done
  fi
  if [[ $FORMS == remove && " ${writes[*]-} " == *" forms/"* && -z ${holds[forms|$FORMS_READ]:-} ]]; then
    problem "$path holds no forms/$FORMS_READ: taking Forms' roles away first would leave DK without Forms; run the core-roles step first (KEYCLOAK_RECONCILE_ONLY=core-roles, runbook §28); nothing was changed"
  fi

  # Write roles that still reach the root through a composite role or a parent group. Keycloak's
  # composite answer for a group expands its composites but leaves its parents out: each parent
  # (/UYELER for /UYELER/DK) is read too, and what a parent gives stays after this step even when the
  # root holds it directly as well.
  sources=("$gid")
  ancestor=${path%/*}
  while [[ -n $ancestor ]]; do
    ancestor_id=$(group_id "$ancestor")
    if [[ -n $ancestor_id ]]; then sources+=("$ancestor_id"); fi
    ancestor=${ancestor%/*}
  done
  declare -A reached=()
  for client in core skymail place forms; do
    [[ $client != forms || $FORMS == remove ]] || continue
    lookup_client "$client"
    uuid=$CLIENT_UUID
    [[ -n $uuid ]] || continue
    for source in "${sources[@]}"; do
      effective=$(read_or_stop "the effective $client roles of $path" csv "groups/$source/role-mappings/clients/$uuid/composite" name)
      while IFS= read -r role; do
        [[ -n $role ]] || continue
        [[ $source != "$gid" || -z ${holds[$client|$role]:-} ]] || continue
        if listed WRITE_ROLES "$client" "$role" || { [[ $FORMS == remove ]] && listed FORMS_ROLES "$client" "$role"; }; then
          reached[$client/$role]=1
        fi
      done <<<"$effective"
    done
  done
  while IFS= read -r role; do
    [[ -n $role ]] || continue
    warning "$path still gets $role through a composite role or a parent group; this step takes direct mappings only (remove it where it comes from)"
  done < <(printf '%s\n' "${!reached[@]}" | sort)
  unset reached

  # Subgroups of the root (at any depth) that hold a write role directly: core refuses a role there
  # from the panel (PlacementPrivilegedSubgroup), the Admin Console does not. Reported, not taken away.
  pending=("$gid|$path")
  while [[ ${#pending[@]} -gt 0 ]]; do
    item=${pending[0]}
    pending=("${pending[@]:1}")
    children_read=$(read_or_stop "the subgroups of ${item#*|}" csv "groups/${item%%|*}/children" id,name -q first=0 -q max=1000)
    while IFS=, read -r child_id child_name; do
      [[ -n $child_id ]] || continue
      child_path="${item#*|}/$child_name"
      pending+=("$child_id|$child_path")
      child_held=$(read_or_stop "the role mappings of $child_path" mappings "$child_id")
      while IFS=$'\t' read -r client _ _ role; do
        [[ -n ${role:-} && $client != - ]] || continue
        if listed WRITE_ROLES "$client" "$role" || { [[ $FORMS == remove ]] && listed FORMS_ROLES "$client" "$role"; }; then
          warning "$child_path, a subgroup of $path, holds $client/$role directly; not taken away (remove it in the Admin Console: the SKY LAB admin panel puts no role on a Privileged root's subgroup)"
        fi
      done <<<"$child_held"
    done <<<"$children_read"
  done

  log "$path: read roles kept: $(printf '%s\n' ${reads[@]+"${reads[@]}"} | sort | paste -sd, - | sed 's/,/, /g; s/^$/none/')"
  if [[ ${#apps[@]} -gt 0 ]]; then
    log "$path: app roles kept (the holder's own, core's app roles): $(printf '%s\n' "${apps[@]}" | sort | paste -sd, - | sed 's/,/, /g')"
  fi
  if [[ ${#forms_kept[@]} -gt 0 ]]; then
    log "NOTE: $path: Forms roles kept until forms-backend reads forms/$FORMS_READ: ${forms_kept[*]} (--forms takes them away then; runbook §28)"
  fi
  for role in ${others[@]+"${others[@]}"}; do
    warning "$path holds $role, which this step does not sort; kept"
  done
  if [[ ${#writes[@]} == 0 ]]; then
    log "$path: write roles held: none${forms_kept[*]:+ (Forms roles kept: ${forms_kept[*]})}"
  else
    log "$path: write roles held: ${#writes[@]} ($(printf '%s\n' "${writes[@]}" | sort | paste -sd, - | sed 's/,/, /g'))"
  fi
  unset holds replaced_of
done

for item in ${grants[@]+"${grants[@]}"}; do
  IFS='|' read -r path _ client _ role instead <<<"$item"
  change "grant $client/$role to $path (in place of $instead)"
done
for item in ${removals[@]+"${removals[@]}"}; do
  IFS='|' read -r path _ client _ role <<<"$item"
  change "take $client/$role away from $path"
done

if [[ $problems != 0 ]]; then
  summary
  exit 1
fi
if [[ $MODE != apply ]]; then
  summary
  exit 0
fi

# --- apply: the backup, the reads, then the writes away -----------------------------------------------
if [[ ${#removals[@]} == 0 ]]; then
  log 'nothing to take away; no backup written'
else
  {
    printf '# dk-read-only backup: realm %s, %s; put back with dk-read-only.sh --restore <this file> --apply\n' \
      "$TARGET_REALM" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '# path<TAB>client<TAB>role of each mapping taken away\n'
    for item in "${removals[@]}"; do
      IFS='|' read -r path _ client _ role <<<"$item"
      printf '%s\t%s\t%s\n' "$path" "$client" "$role"
    done
    for item in ${grants[@]+"${grants[@]}"}; do
      IFS='|' read -r path _ client _ role _ <<<"$item"
      printf '# granted in place (a restore keeps it): %s\t%s\t%s\n' "$path" "$client" "$role"
    done
  } >"$WORK_DIR/backup.tsv"
  # Never over an existing file (noclobber): a backup is never lost to a later run.
  if ! (set -o noclobber; cat "$WORK_DIR/backup.tsv" >"$BACKUP_FILE") 2>/dev/null; then
    problem "the backup $BACKUP_FILE could not be written (it exists, or its directory is not writable); nothing was changed"
    summary
    exit 1
  fi
  log "backup: $BACKUP_FILE (${#removals[@]} mapping(s) to take away; put them back with --restore $BACKUP_FILE --apply)"
fi
declare -A batch=()
for item in ${grants[@]+"${grants[@]}"}; do
  IFS='|' read -r path uuid _ rid role _ <<<"$item"
  batch[$path|$uuid]="${batch[$path|$uuid]:-} $rid|$role"
done
# write_failed: a write failed halfway; the backup holds every planned removal (exit 1).
write_failed() {
  log "a write failed in realm $TARGET_REALM; stopped. ${BACKUP_FILE:+The backup $BACKUP_FILE holds every planned removal: put back what was taken with --restore $BACKUP_FILE --apply, or }run this step again" >&2
  exit 1
}
for key in "${!batch[@]}"; do
  read -r -a items <<<"${batch[$key]}"
  write_mappings create "${gid_of[${key%%|*}]}" "${key#*|}" "${items[@]}" || write_failed
done
batch=()
for item in ${removals[@]+"${removals[@]}"}; do
  IFS='|' read -r path uuid _ rid role <<<"$item"
  batch[$path|$uuid]="${batch[$path|$uuid]:-} $rid|$role"
done
for key in "${!batch[@]}"; do
  read -r -a items <<<"${batch[$key]}"
  write_mappings delete "${gid_of[${key%%|*}]}" "${key#*|}" "${items[@]}" || write_failed
done
summary
