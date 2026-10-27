#!/usr/bin/env bash
# The master realm's console: groups, hardening and a passkey sign-in (rol-temizligi ticket 03;
# decisions S1, S2, S3 and spec §4.4 in sky_lab_genel .scratch/rol-temizligi). Console accounts live
# in master, one per person (Microsoft Entra's separate admin account); their rights come from the
# groups under /KONSOL, not from master's realm role admin, which stays with the operator's account and
# the two emergency accounts. master is outside the reconciler (core-internal-auth 17, item 4): this
# script runs with an operator session, kcadm inside the Keycloak container, as the other operator
# scripts do.
#
# What it keeps in master (--apply writes, --check only reads):
#   - the groups: /KONSOL (no role, no member of its own) and its leaves from config/master-console.json
#     (the role-groups file shape; ReconcileJson role-groups validates it). Each leaf holds the listed
#     roles of one "<realm>-realm" client: every role of it but impersonation (excluded_roles), so its
#     members write in that realm's console and cannot act as another person. A role a leaf holds
#     beyond its list, a role of the client the file neither lists nor excludes (a role a newer
#     Keycloak adds), a role on /KONSOL itself, a subgroup under a leaf and a group under /KONSOL that
#     the file does not list are WARNINGs and are never taken away. A leaf whose client does not exist
#     (no such realm on this server) is a WARNING and is skipped. A default group at or under /KONSOL is
#     a PROBLEM and nothing is written. Membership is never touched: who is in a leaf is data
#     (rol-temizligi ticket 04, the F1 step of the wizard, or the console itself).
#   - the sign-in: the top-level flow konsol-passkey (Username Password Form, then WebAuthn
#     Authenticator, both REQUIRED; no Cookie step, so an open SSO session never stands in for the
#     two factors; no conditional-role subflow, spec §4.4: a renamed role would skip the second factor
#     silently), bound as the browser flow override of security-admin-console, account-console and
#     account. The two Account clients are bound too: a password-only session of master's Account
#     Console could otherwise delete the person's passkey (Account REST, no step-up), and the next
#     console sign-in would then let whoever holds the password register their own. A changed flow is
#     put back (an extra step or subflow removed, a step re-added, a requirement set to REQUIRED). The
#     WebAuthn (two-factor) policy of master asks for a discoverable credential with user verification
#     (a passkey), and the required action webauthn-register is enabled: an account without a passkey
#     registers one right after its password, once (the --check count below says how many have none).
#     Another master client with a browser sign-in (standard or implicit flow, redirect URIs, not
#     bearer-only) that is not bound is a WARNING with its client id.
#   - realm settings: brute force detection with e-skylab's values (the brute force fields of
#     config/account-center-realm-security.json, the reconciler's file); user and admin events on,
#     both kept 30 days (adminEventsExpiration), admin event details on (ticket 18's mail reads master's
#     LOGIN events). Listeners and enabled event types are never sent.
# Every write is made only when the live value differs, so a second --apply writes nothing and leaves
# no admin event.
#
# --check also counts, never naming a person (service accounts are left out):
#   - people holding master's realm role admin (directly, through a group or a composite); a WARNING
#     above KEYCLOAK_MASTER_ADMIN_MAX (default 3: the operator's account and the two emergency
#     accounts);
#   - the members of each leaf (directly or through a subgroup); a WARNING above
#     KEYCLOAK_CONSOLE_WRITERS_MAX (default 6: the console writers of 2026-10-13);
#   - people holding a role of a "<realm>-realm" client directly or through a group outside /KONSOL/*;
#     a WARNING when any;
#   - console people (admin holders and leaf members) without a WebAuthn credential; a WARNING when
#     any (they register one at their next sign-in, rol-temizligi F1).
# e-skylab's own side (K3: no person and no group holds a realm-management role) is counted by
# KEYCLOAK_REALM=e-skylab config/role-groups.sh --audit.
#
# --remove-override is the rollback of the sign-in: it removes the browser flow override of the three
# clients where it points to konsol-passkey (master's own browser flow applies again); the flow, the
# groups and the realm settings stay. A dry run unless --apply. It needs only an operator session
# (admin-cli's password grant does not go through the browser flow), so it works when nobody can open
# the console.
#
# A failed read stops the run with exit 1; it is never taken for "absent".
#
# Usage (inside the Keycloak image, as an operator of master):
#   master-console.sh --admin-user <admin>                      # --check (default)
#   master-console.sh --admin-user <admin> --apply              # writes
#   master-console.sh --admin-user <admin> --remove-override [--apply]
#   master-console.sh --kcadm-config <file> [--check | --apply | --remove-override [--apply]]
#
# Environment: KEYCLOAK_ADMIN_URL (default http://keycloak:8080), KEYCLOAK_MASTER_CONSOLE_ADMIN_USERNAME
# (or --admin-user), KEYCLOAK_MASTER_CONSOLE_FILE (default config/master-console.json next to this
# script), KEYCLOAK_MASTER_ADMIN_MAX (default 3), KEYCLOAK_CONSOLE_WRITERS_MAX (default 6).
# Output: "[master-console] ..." lines, then "check: N change(s) pending, W warning(s), P problem(s)" or
# "applied N change(s), ...". Exit 0 unless a PROBLEM (1) or a usage error or an invalid file (2).
set -Eeuo pipefail
shopt -s inherit_errexit

umask 077

KCADM=${KCADM_BIN:-/opt/keycloak/bin/kcadm.sh}
JAVA_BIN=${JAVA_BIN:-java}
KEYCLOAK_LIB_DIR=${KEYCLOAK_LIB_DIR:-/opt/keycloak/lib/lib/main}
CONFIG_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG_FILE=${KEYCLOAK_MASTER_CONSOLE_FILE:-$CONFIG_DIR/master-console.json}
SECURITY_FILE=$CONFIG_DIR/account-center-realm-security.json
ADMIN_URL=${KEYCLOAK_ADMIN_URL:-http://keycloak:8080}
REALM=master
ADMIN_USER=${KEYCLOAK_MASTER_CONSOLE_ADMIN_USERNAME:-}
ADMIN_MAX=${KEYCLOAK_MASTER_ADMIN_MAX:-3}
WRITERS_MAX=${KEYCLOAK_CONSOLE_WRITERS_MAX:-6}
KCADM_CONFIG=''
OWN_CONFIG=false
MODE=check
ACTION=reconcile

FLOW_ALIAS=konsol-passkey
FLOW_DESCRIPTION='Konsol: parola, ardından passkey (WebAuthn); Cookie adımı yok (rol-temizligi 03)'
# The steps of the flow, in order, all REQUIRED.
FLOW_STEPS=(auth-username-password-form webauthn-authenticator)
BOUND_CLIENTS=(security-admin-console account-console account)
REGISTER_ACTION=webauthn-register
BRUTE_FORCE_FIELDS=(bruteForceProtected permanentLockout failureFactor waitIncrementSeconds maxFailureWaitSeconds
  maxDeltaTimeSeconds quickLoginCheckMilliSeconds minimumQuickLoginWaitSeconds)
# The two-factor WebAuthn policy as e-skylab's passkey policy asks: a discoverable credential with user
# verification. Keycloak writes this policy whole and only from a PUT that carries its rpEntityName
# (the other fields absent go back to their defaults), so it is sent with the whole live realm.
WEBAUTHN_POLICY='{"webAuthnPolicyResidentKey":"required","webAuthnPolicyUserVerificationRequirement":"required"}'
# The reconciler's event retention (config/reconcile-account-center.sh EVENT_RETENTION_*).
EVENT_RETENTION_SECONDS=2592000
EVENT_RETENTION_SETTINGS="{\"eventsEnabled\":true,\"eventsExpiration\":$EVENT_RETENTION_SECONDS,\"adminEventsEnabled\":true,\"adminEventsDetailsEnabled\":true}"
ADMIN_EVENTS_EXPIRATION_ATTRIBUTE=adminEventsExpiration

usage() {
  printf 'usage: %s (--admin-user <administrator> | --kcadm-config <file>) [--check | --apply | --remove-override [--apply]]\n' \
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
    --remove-override)
      ACTION=remove-override
      shift
      ;;
    *)
      usage
      ;;
  esac
done

for limit in "$ADMIN_MAX" "$WRITERS_MAX"; do
  [[ $limit =~ ^[0-9]{1,4}$ ]] || {
    printf '[master-console] KEYCLOAK_MASTER_ADMIN_MAX and KEYCLOAK_CONSOLE_WRITERS_MAX must be whole numbers; nothing was read or changed\n' >&2
    exit 2
  }
done

WORK_DIR=$(mktemp -d /tmp/master-console.XXXXXX)
if [[ -z $KCADM_CONFIG ]]; then
  if [[ -z $ADMIN_USER ]]; then
    if [[ -t 0 ]]; then
      read -r -p "Keycloak administrator username (master): " ADMIN_USER
    fi
    [[ -n $ADMIN_USER ]] || { rm -rf "$WORK_DIR"; usage; }
  fi
  KCADM_CONFIG=$(mktemp /tmp/master-console-kcadm.XXXXXX)
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

log() {
  printf '[master-console] %s\n' "$1"
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
  kcadm get "$1" -r "$REALM" --fields "$2" --format csv --noquotes "${@:3}" | tr -d '\r' | sed '/^$/d'
}

json() {
  kcadm get "$1" -r "$REALM" "${@:2}"
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
  if out=$(kcadm get "group-by-path$1" -r "$REALM" --fields id,path --format csv --noquotes 2>"$err"); then
    out=$(tr -d '\r' <<<"$out" | sed '/^$/d')
    if [[ ${out#*,} == "$1" && -n ${out%%,*} ]]; then printf '%s\n' "${out%%,*}"; fi
    return 0
  fi
  if grep -Eqi 'not found|does not exist|could not find' "$err"; then
    return 0
  fi
  cat "$err" >&2
  printf '[master-console] the group %s could not be read in realm %s; stopped (a failed read is never taken for "absent")\n' \
    "$1" "$REALM" >&2
  exit 1
}

# children ID: the direct subgroups of the group, one "id,name" per line.
children() {
  csv "groups/$1/children" id,name -q first=0 -q max=1000
}

# attribute ID NAME: the first value of the group's attribute NAME (empty when absent).
attribute() {
  local group
  group=$(json "groups/$1")
  printf '[%s]' "$group" | json_tool role-attribute "$2" | cut -f2-
}

# mappings ENDPOINT: the role mappings read from ENDPOINT (groups/ID/role-mappings or
# users/ID/role-mappings), one "client<TAB>role" per line ("-" for a realm role).
mappings() {
  json "$1" | json_tool scope-mappings | cut -f1,4
}

# attribute_options DISPLAY DESCRIPTION: kcadm -s options that write both attributes. The texts
# carry no double quote and no backslash (ReconcileJson role-groups refuses them).
attribute_options() {
  ATTRIBUTE_OPTIONS=(-s "attributes.display_name_tr=[\"$1\"]" -s "attributes.description_tr=[\"$2\"]")
}

# browser_override UUID: the flow id of the client's browser flow override (empty when none).
browser_override() {
  local live
  live=$(json "clients/$1" --fields 'authenticationFlowBindingOverrides(*)')
  if [[ $live =~ \"browser\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  fi
  return 0
}

# flow_id ALIAS: the id of the top-level flow ALIAS (empty when absent).
flow_id() {
  local flows
  flows=$(csv authentication/flows id,alias)
  id_of "$flows" "$1"
}

# --- the file, before a login ---------------------------------------------------------------------
compile_json_tool
if ! parsed=$(json_tool role-groups "$CONFIG_FILE" 2>"$WORK_DIR/parse.err"); then
  cat "$WORK_DIR/parse.err" >&2
  printf '[master-console] %s is not a valid console group file; nothing was read or changed\n' "$CONFIG_FILE" >&2
  exit 2
fi
IFS=$'\t' read -r _ ROOT ROOT_DISPLAY ROOT_DESCRIPTION <<<"$(head -n 1 <<<"$parsed")"
LEAVES=()
while IFS= read -r line; do
  if [[ $line == group$'\t'* ]]; then LEAVES+=("${line#group$'\t'}"); fi
done <<<"$parsed"
excluded=$(json_tool field excluded_roles <"$CONFIG_FILE")
if [[ ! $excluded =~ ^\[(\"[a-z-]+\"(,\"[a-z-]+\")*)?\]$ ]]; then
  printf '[master-console] excluded_roles of %s must be a list of role names; nothing was read or changed\n' "$CONFIG_FILE" >&2
  exit 2
fi
excluded=${excluded//[\[\]\"]/}
EXCLUDED_ROLES=()
[[ -z $excluded ]] || IFS=',' read -r -a EXCLUDED_ROLES <<<"$excluded"
for leaf in "${LEAVES[@]}"; do
  IFS=$'\t' read -r name client roles _ <<<"$leaf"
  if [[ $client != *-realm ]]; then
    printf '[master-console] %s: the client %s is not a realm client (<realm>-realm); nothing was read or changed\n' "$name" "$client" >&2
    exit 2
  fi
  for role in ${EXCLUDED_ROLES[@]+"${EXCLUDED_ROLES[@]}"}; do
    if [[ " $roles " == *" $role "* ]]; then
      printf '[master-console] %s lists the excluded role %s; nothing was read or changed\n' "$name" "$role" >&2
      exit 2
    fi
  done
done

# The brute force values of e-skylab (the reconciler's file), only the brute force fields.
desired_brute_force=''
for field in "${BRUTE_FORCE_FIELDS[@]}"; do
  value=$(json_tool field "$field" <"$SECURITY_FILE")
  if [[ ! $value =~ ^(true|false|[0-9]{1,9})$ ]]; then
    printf '[master-console] %s of %s is not a boolean or a whole number; nothing was read or changed\n' "$field" "$SECURITY_FILE" >&2
    exit 2
  fi
  desired_brute_force+=",\"$field\":$value"
done
printf '{%s}\n' "${desired_brute_force#,}" >"$WORK_DIR/brute-force.json"

credential_arguments=(
  --config "$KCADM_CONFIG"
  --server "$ADMIN_URL"
  --realm "$REALM"
  --user "$ADMIN_USER"
)
if [[ $OWN_CONFIG == true ]]; then
  "$KCADM" config credentials "${credential_arguments[@]}"
fi
log "realm=$REALM mode=$MODE action=$ACTION flow=$FLOW_ALIAS root=/$ROOT leaves=${#LEAVES[@]}"

if ! realm_name=$(kcadm get "realms/$REALM" --fields realm --format csv --noquotes 2>/dev/null | tr -d '\r') \
  || [[ $realm_name != "$REALM" ]]; then
  printf '[master-console] realm %s cannot be read with this session; nothing was changed\n' "$REALM" >&2
  exit 1
fi

# --- the rollback: --remove-override ---------------------------------------------------------------
if [[ $ACTION == remove-override ]]; then
  flow=$(flow_id "$FLOW_ALIAS")
  for client in "${BOUND_CLIENTS[@]}"; do
    uuid=$(uuid_by "$client")
    if [[ -z $uuid ]]; then
      log "$client: absent in $REALM; nothing to remove"
      continue
    fi
    bound=$(browser_override "$uuid")
    if [[ -z $bound || -z $flow || $bound != "$flow" ]]; then
      log "$client: no browser flow override to $FLOW_ALIAS; unchanged"
      continue
    fi
    change "remove the browser flow override of $client ($FLOW_ALIAS; master's own browser flow applies again)"
    if [[ $MODE == apply ]]; then
      kcadm_write update "clients/$uuid" -r "$REALM" -s 'authenticationFlowBindingOverrides.browser='
    fi
  done
  log "the flow $FLOW_ALIAS, the groups and the realm settings stay; --apply without --remove-override binds it again"
  summary
  exit 0
fi

# --- default groups: a default group at or under /KONSOL would give every new account its roles ----
default_groups=$(csv default-groups path)
while IFS= read -r default; do
  [[ -n $default ]] || continue
  if [[ $default == "/$ROOT" || $default == "/$ROOT"/* ]]; then
    problem "the default group $default is at or under /$ROOT: every new account would get its roles; nothing was changed (remove it from master's default groups first)"
  fi
done <<<"$default_groups"
if [[ $problems != 0 ]]; then
  summary
  exit 1
fi

# --- realm settings ---------------------------------------------------------------------------------
# apply_fields LABEL DESIRED_FILE [whole]: writes the fields of DESIRED_FILE to the realm only when one
# of them differs (objects compare as subsets, arrays as multisets); with "whole" kcadm sends them on
# the whole live realm (read, merged, written back) instead of alone.
apply_fields() {
  local label=$1 desired=$2 changed merge=-n
  json "realms/$REALM" >"$WORK_DIR/realm-live.json"
  changed=$(json_tool diff-fields "$desired" <"$WORK_DIR/realm-live.json")
  if [[ -z $changed ]]; then
    log "$label: unchanged"
    return 0
  fi
  change "set $label ($(tr '\n' ' ' <<<"$changed" | sed 's/ $//'))"
  if [[ $MODE == apply ]]; then
    [[ ${3:-} != whole ]] || merge=--merge
    kcadm_write update "realms/$REALM" "$merge" -f "$desired"
  fi
}

apply_fields 'brute force detection (the values of e-skylab)' "$WORK_DIR/brute-force.json"
printf '%s\n' "$WEBAUTHN_POLICY" >"$WORK_DIR/webauthn-policy.json"
apply_fields 'WebAuthn policy (a discoverable credential with user verification: a passkey)' "$WORK_DIR/webauthn-policy.json" whole

# User and admin event retention, as the reconciler keeps e-skylab's: the four settings are realm
# fields, the admin event expiration a realm attribute sent with the complete live attribute map
# (Keycloak drops every attribute a PUT with "attributes" leaves out); one PUT, only when one differs.
event_label="user and admin events (kept ${EVENT_RETENTION_SECONDS} s, admin event details on)"
printf '%s\n' "$EVENT_RETENTION_SETTINGS" >"$WORK_DIR/events.json"
printf '{"attributes":{"%s":"%s"}}\n' "$ADMIN_EVENTS_EXPIRATION_ATTRIBUTE" "$EVENT_RETENTION_SECONDS" >"$WORK_DIR/events-attribute.json"
json "realms/$REALM" >"$WORK_DIR/realm-live.json"
event_changed=$(json_tool diff-fields "$WORK_DIR/events.json" <"$WORK_DIR/realm-live.json")
if [[ -n $(json_tool diff-fields "$WORK_DIR/events-attribute.json" <"$WORK_DIR/realm-live.json") ]]; then
  json_tool realm-attribute "$ADMIN_EVENTS_EXPIRATION_ATTRIBUTE" "$EVENT_RETENTION_SECONDS" \
    <"$WORK_DIR/realm-live.json" >"$WORK_DIR/events-attribute.json"
  json_tool merge "$WORK_DIR/events.json" "$WORK_DIR/events-attribute.json" >"$WORK_DIR/events-write.json"
  event_changed=$(printf '%s\nattributes.%s' "$event_changed" "$ADMIN_EVENTS_EXPIRATION_ATTRIBUTE")
elif [[ -n $event_changed ]]; then
  cp "$WORK_DIR/events.json" "$WORK_DIR/events-write.json"
fi
if [[ -z $event_changed ]]; then
  log "$event_label: unchanged"
else
  change "set $event_label ($(sed '/^$/d' <<<"$event_changed" | tr '\n' ' ' | sed 's/ $//'))"
  if [[ $MODE == apply ]]; then
    kcadm_write update "realms/$REALM" -n -f "$WORK_DIR/events-write.json"
  fi
fi

# --- the passkey registration ----------------------------------------------------------------------
register=$(csv authentication/required-actions alias,enabled | grep "^$REGISTER_ACTION," || true)
case $register in
  "$REGISTER_ACTION,true")
    log "required action $REGISTER_ACTION: unchanged (enabled)"
    ;;
  "$REGISTER_ACTION,false")
    change "enable the required action $REGISTER_ACTION (an account without a passkey registers one right after its password)"
    if [[ $MODE == apply ]]; then
      kcadm_write update "authentication/required-actions/$REGISTER_ACTION" -r "$REALM" -s enabled=true
    fi
    ;;
  *)
    problem "the required action $REGISTER_ACTION is not registered in $REALM: an account without a passkey could not sign in to the console; register it in the console (Authentication, Required actions) and run again"
    ;;
esac

# --- the flow ---------------------------------------------------------------------------------------
# add_step PROVIDER: appends the step to the flow and makes it REQUIRED.
add_step() {
  local added
  added=$(kcadm create "authentication/flows/$FLOW_ALIAS/executions/execution" -r "$REALM" -i -b "{\"provider\":\"$1\"}")
  kcadm_write update "authentication/flows/$FLOW_ALIAS/executions" -r "$REALM" -n \
    -b "{\"id\":\"$added\",\"requirement\":\"REQUIRED\"}"
}

changes_before_flow=$changes
flow=$(flow_id "$FLOW_ALIAS")
if [[ -z $flow ]]; then
  change "create the flow $FLOW_ALIAS (${FLOW_STEPS[*]}, each REQUIRED; no Cookie step)"
  if [[ $MODE == apply ]]; then
    kcadm_write create authentication/flows -r "$REALM" -s "alias=$FLOW_ALIAS" -s providerId=basic-flow \
      -s topLevel=true -s builtIn=false -s "description=$FLOW_DESCRIPTION"
    for step in "${FLOW_STEPS[@]}"; do add_step "$step"; done
    flow=$(flow_id "$FLOW_ALIAS")
    [[ -n $flow ]] || { problem "the flow $FLOW_ALIAS could not be read back after it was created"; summary; exit 1; }
  fi
else
  executions=$(csv "authentication/flows/$FLOW_ALIAS/executions" id,providerId,requirement,level,authenticationFlow)
  kept_ids=()
  kept_steps=()
  kept_requirements=()
  while IFS=, read -r id provider requirement level subflow; do
    [[ -n $id ]] || continue
    if [[ $level == 0 && $subflow != true && " ${FLOW_STEPS[*]} " == *" $provider "* && " ${kept_steps[*]} " != *" $provider "* ]]; then
      kept_ids+=("$id")
      kept_steps+=("$provider")
      kept_requirements+=("$requirement")
      continue
    fi
    [[ $subflow != true ]] || provider='a subflow'
    change "remove ${provider:-an execution} (level $level, $requirement) from the flow $FLOW_ALIAS"
    if [[ $MODE == apply ]]; then
      kcadm_write delete "authentication/executions/$id" -r "$REALM"
    fi
  done <<<"$executions"
  if [[ "${kept_steps[*]}" == "${FLOW_STEPS[*]}" ]]; then
    for index in "${!kept_ids[@]}"; do
      [[ ${kept_requirements[$index]} != REQUIRED ]] || continue
      change "set ${kept_steps[$index]} of the flow $FLOW_ALIAS to REQUIRED (was ${kept_requirements[$index]})"
      if [[ $MODE == apply ]]; then
        kcadm_write update "authentication/flows/$FLOW_ALIAS/executions" -r "$REALM" -n \
          -b "{\"id\":\"${kept_ids[$index]}\",\"requirement\":\"REQUIRED\"}"
      fi
    done
  else
    change "rebuild the steps of the flow $FLOW_ALIAS as ${FLOW_STEPS[*]}, each REQUIRED (found: ${kept_steps[*]:-none})"
    if [[ $MODE == apply ]]; then
      for id in ${kept_ids[@]+"${kept_ids[@]}"}; do kcadm_write delete "authentication/executions/$id" -r "$REALM"; done
      for step in "${FLOW_STEPS[@]}"; do add_step "$step"; done
    fi
  fi
fi
[[ $changes != "$changes_before_flow" ]] || log "flow $FLOW_ALIAS: unchanged (${FLOW_STEPS[*]}, each REQUIRED)"

# --- the clients ------------------------------------------------------------------------------------
for client in "${BOUND_CLIENTS[@]}"; do
  uuid=$(uuid_by "$client")
  if [[ -z $uuid ]]; then
    log "$client: absent in $REALM; nothing to bind"
    continue
  fi
  bound=''
  bound=$(browser_override "$uuid")
  if [[ -n $flow && $bound == "$flow" ]]; then
    log "$client: browser flow override unchanged ($FLOW_ALIAS)"
    continue
  fi
  change "bind the browser sign-in of $client to $FLOW_ALIAS (client flow override)"
  if [[ $MODE == apply ]]; then
    kcadm_write update "clients/$uuid" -r "$REALM" -s "authenticationFlowBindingOverrides.browser=$flow"
  fi
done

# Another client with a browser sign-in signs in through master's own browser flow (password only).
clients_read=$(csv clients id,clientId,standardFlowEnabled,implicitFlowEnabled,bearerOnly -q first=0 -q max=10000)
unbound=''
while IFS=, read -r uuid client standard implicit bearer; do
  [[ -n $uuid && $bearer != true && ($standard == true || $implicit == true) ]] || continue
  [[ " ${BOUND_CLIENTS[*]} " != *" $client "* ]] || continue
  redirects=$(json "clients/$uuid" --fields redirectUris)
  [[ ! $redirects =~ \"redirectUris\"[[:space:]]*:[[:space:]]*\[[[:space:]]*\] ]] || continue
  [[ $redirects == *redirectUris* ]] || continue
  bound=$(browser_override "$uuid")
  if [[ -z $flow || $bound != "$flow" ]]; then unbound+=", $client"; fi
done <<<"$clients_read"
[[ -z $unbound ]] || warning "client(s) of $REALM with a browser sign-in that is not $FLOW_ALIAS: ${unbound#, } (a password-only session there; bind them or turn their browser flows off)"

# --- the groups -------------------------------------------------------------------------------------
root_id=$(group_id "/$ROOT")
if [[ -z $root_id ]]; then
  change "create the group /$ROOT (no role, no member)"
  if [[ $MODE == apply ]]; then
    attribute_options "$ROOT_DISPLAY" "$ROOT_DESCRIPTION"
    kcadm_write create groups -r "$REALM" -s "name=$ROOT" "${ATTRIBUTE_OPTIONS[@]}"
    root_id=$(group_id "/$ROOT")
    [[ -n $root_id ]] || { problem "/$ROOT could not be read back after it was created"; summary; exit 1; }
  fi
else
  if [[ $(attribute "$root_id" display_name_tr) != "$ROOT_DISPLAY" || $(attribute "$root_id" description_tr) != "$ROOT_DESCRIPTION" ]]; then
    change "write display_name_tr and description_tr of /$ROOT"
    if [[ $MODE == apply ]]; then
      attribute_options "$ROOT_DISPLAY" "$ROOT_DESCRIPTION"
      kcadm_write update "groups/$root_id" -r "$REALM" "${ATTRIBUTE_OPTIONS[@]}"
    fi
  else
    log "/$ROOT: unchanged"
  fi
  root_roles=$(mappings "groups/$root_id/role-mappings" | tr '\t' '/' | sed 's|^-/|realm/|' | paste -sd, -)
  [[ -z $root_roles ]] || warning "/$ROOT itself holds roles ($root_roles): every member of every console group gets them; not taken away"
fi

declare -A existing=() client_uuids=()
if [[ -n $root_id ]]; then
  leaves_read=$(children "$root_id")
  while IFS=, read -r id name; do
    if [[ -n $id ]]; then existing[$name]=$id; fi
  done <<<"$leaves_read"
fi
managed=()
declare -A leaf_ids=()
for leaf in "${LEAVES[@]}"; do
  IFS=$'\t' read -r name client roles display description <<<"$leaf"
  managed+=("$name")
  path="/$ROOT/$name"
  if [[ -z ${client_uuids[$client]+set} ]]; then
    client_uuids[$client]=$(uuid_by "$client")
  fi
  uuid=${client_uuids[$client]}
  if [[ -z $uuid ]]; then
    warning "$path: the client $client does not exist in $REALM (no realm ${client%-realm} on this server); skipped (not created)"
    continue
  fi
  role_lines=$(csv "clients/$uuid/roles" id,name -q first=0 -q max=10000)
  bodies=()
  read -r -a role_list <<<"$roles"
  for role in "${role_list[@]}"; do
    role_id=$(id_of "$role_lines" "$role")
    if [[ -z $role_id ]]; then
      warning "$path: the role $client/$role does not exist in $REALM; skipped (not created)"
      continue 2
    fi
    bodies+=("$role|{\"id\":\"$role_id\",\"name\":\"$role\"}")
  done
  # A role of the client the file neither lists nor excludes: a role a newer Keycloak added.
  unlisted=''
  while IFS=, read -r _ role; do
    [[ -n $role && " $roles " != *" $role "* && " ${EXCLUDED_ROLES[*]-} " != *" $role "* ]] || continue
    unlisted+=", $role"
  done <<<"$role_lines"
  [[ -z $unlisted ]] || warning "$client has role(s) ${unlisted#, } that ${CONFIG_FILE##*/} neither lists for $path nor excludes; decide and add them to one of the two lists"

  id=${existing[$name]:-}
  if [[ -z $id ]]; then
    change "create the console group $path ($client: every role but ${EXCLUDED_ROLES[*]-nothing}; no member)"
    if [[ $MODE == apply ]]; then
      attribute_options "$display" "$description"
      kcadm_write create "groups/$root_id/children" -r "$REALM" -s "name=$name" "${ATTRIBUTE_OPTIONS[@]}"
      id=$(group_id "$path")
      [[ -n $id ]] || { problem "$path could not be read back after it was created"; continue; }
    fi
  elif [[ $(attribute "$id" display_name_tr) != "$display" || $(attribute "$id" description_tr) != "$description" ]]; then
    change "write display_name_tr and description_tr of $path"
    if [[ $MODE == apply ]]; then
      attribute_options "$display" "$description"
      kcadm_write update "groups/$id" -r "$REALM" "${ATTRIBUTE_OPTIONS[@]}"
    fi
  fi
  [[ -z $id ]] || leaf_ids[$path]=$id

  held=''
  if [[ -n $id ]]; then
    held=$(mappings "groups/$id/role-mappings")
  fi
  missing=()
  for body in "${bodies[@]}"; do
    role=${body%%|*}
    if grep -Fxq -- "$client"$'\t'"$role" <<<"$held"; then
      continue
    fi
    missing+=("${body#*|}")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    change "map ${#missing[@]} role(s) of $client to $path"
    if [[ $MODE == apply ]]; then
      body=$(IFS=,; printf '[%s]' "${missing[*]}")
      kcadm_write create "groups/$id/role-mappings/clients/$uuid" -r "$REALM" -b "$body"
    fi
  elif [[ -n ${existing[$name]:-} ]]; then
    log "$path: roles unchanged ($client: ${#bodies[@]} role(s))"
  fi

  if [[ -n ${existing[$name]:-} ]]; then
    extra=''
    while IFS=$'\t' read -r held_client held_role; do
      [[ -n $held_role ]] || continue
      [[ $held_client == "$client" && " $roles " == *" $held_role "* ]] && continue
      [[ $held_client == - ]] && held_client=realm
      extra+=", $held_client/$held_role"
    done <<<"$held"
    [[ -z $extra ]] || warning "$path also holds ${extra#, } (a console group holds its listed roles only; impersonation never); not taken away"
    subgroups=$(children "$id")
    subgroups=$(sed '/^$/d' <<<"$subgroups" | wc -l | tr -d ' ')
    [[ $subgroups == 0 ]] || warning "$path has $subgroups subgroup(s): a console group is a leaf (its roles reach them); not removed"
  fi
done

for name in "${!existing[@]}"; do
  [[ " ${managed[*]} " == *" $name "* ]] || warning "/$ROOT/$name is not in ${CONFIG_FILE##*/}; left as it is"
done

# --- the counts (read only; never a name) ----------------------------------------------------------
# For every person: master's admin (effective: directly, a group or a composite), the groups (with
# their parents: a mapping reaches the subgroups) and the "<realm>-realm" roles held outside /KONSOL/*.
declare -A group_path=() group_parent=() group_roles=() leaf_members=()
# group_chain ID: CHAIN becomes the ids of the group and its parents (each group read once; not in a
# subshell, so the reads stay cached).
group_chain() {
  local gid=$1 line path parent
  CHAIN=()
  while [[ -n $gid ]]; do
    if [[ -z ${group_path[$gid]+set} ]]; then
      line=$(csv "groups/$gid" id,path,parentId)
      IFS=, read -r _ path parent <<<"$line"
      [[ -n $path ]] || { printf '[master-console] the group %s could not be read; stopped\n' "$gid" >&2; exit 1; }
      group_path[$gid]=$path
      group_parent[$gid]=$parent
      group_roles[$gid]=$(mappings "groups/$gid/role-mappings")
    fi
    CHAIN+=("$gid")
    gid=${group_parent[$gid]}
  done
}

people=$(csv users id,username -q briefRepresentation=true -q first=0 -q max=100000)
admin_people=0
outside_people=0
console_people=0
without_passkey=0
while IFS=, read -r user_id username; do
  [[ -n $user_id && $username != service-account-* ]] || continue
  effective=$(csv "users/$user_id/role-mappings/realm/composite" name)
  holds_admin=false
  if grep -Fxq admin <<<"$effective"; then holds_admin=true; fi
  outside=false
  direct=$(mappings "users/$user_id/role-mappings")
  if grep -Eq $'^[^\t]+-realm\t' <<<"$direct"; then outside=true; fi
  in_leaf=false
  user_groups=$(csv "users/$user_id/groups" id -q first=0 -q max=1000)
  declare -A seen_leaf=()
  while IFS= read -r gid; do
    [[ -n $gid ]] || continue
    group_chain "$gid"
    for cid in "${CHAIN[@]}"; do
      path=${group_path[$cid]}
      if [[ -n ${leaf_ids[$path]:-} ]]; then
        in_leaf=true
        if [[ -z ${seen_leaf[$path]:-} ]]; then
          seen_leaf[$path]=1
          leaf_members[$path]=$((${leaf_members[$path]:-0} + 1))
        fi
      fi
      if [[ $path != "/$ROOT" && $path != "/$ROOT"/* ]] && grep -Eq $'^[^\t]+-realm\t' <<<"${group_roles[$cid]}"; then
        outside=true
      fi
    done
  done <<<"$user_groups"
  unset seen_leaf
  [[ $holds_admin == false ]] || admin_people=$((admin_people + 1))
  [[ $outside == false ]] || outside_people=$((outside_people + 1))
  if [[ $holds_admin == true || $in_leaf == true ]]; then
    console_people=$((console_people + 1))
    credential_types=$(csv "users/$user_id/credentials" type)
    if ! grep -Fxq webauthn <<<"$credential_types"; then
      without_passkey=$((without_passkey + 1))
    fi
  fi
done <<<"$people"

log "count: $admin_people person(s) hold $REALM's realm role admin (at most $ADMIN_MAX: the operator's account and two emergency accounts)"
[[ $admin_people -le $ADMIN_MAX ]] || warning "$admin_people person(s) hold $REALM's admin, more than $ADMIN_MAX (KEYCLOAK_MASTER_ADMIN_MAX); rol-temizligi F1 takes it from the console writers"
for path in "${!leaf_ids[@]}"; do
  count=${leaf_members[$path]:-0}
  log "count: $path has $count member(s) (at most $WRITERS_MAX)"
  [[ $count -le $WRITERS_MAX ]] || warning "$path has $count member(s), more than $WRITERS_MAX (KEYCLOAK_CONSOLE_WRITERS_MAX)"
done
log "count: $outside_people person(s) hold a <realm>-realm role directly or through a group outside /$ROOT/*"
[[ $outside_people == 0 ]] || warning "$outside_people person(s) hold a <realm>-realm role outside /$ROOT/* (directly or through another group); move them to a console group (rol-temizligi F1)"
log "count: $console_people console person(s) (admin or a console group), $without_passkey of them without a passkey"
[[ $without_passkey == 0 ]] || warning "$without_passkey console person(s) have no passkey yet: each registers one right after the password at the next console sign-in (rol-temizligi F1: confirm that the person did it)"

summary
if [[ $problems != 0 ]]; then
  exit 1
fi
