#!/usr/bin/env bash
# Idempotent grant of SkyMail's send permission to Forms' service account (realms e-skylab and
# e-skylab-sandbox). forms-backend sends one mail at a time through SkyMail's
# POST /v1/mail_tasks/single with a client-credentials token of its client forms. SkyMail reads the
# caller's roles from resource_access.skymail.roles and requires skymail:access for /v1 and
# skymail:mails:send or skymail:mails:write for that route. Until now the grant was made by hand:
# production had it, the sandbox realm did not, so every sandbox Forms mail was refused with
# 403 server.forbidden.
# The script makes sure that service-account-forms holds, directly or through a composite role:
#   - skymail:access;
#   - skymail:mails:send, unless it already holds skymail:mails:write (which also allows the route;
#     it is broader than sending one mail needs, so it is reported as a NOTE and left as is);
#   - when the client forms has fullScopeAllowed=false, the same roles in its scope mappings for the
#     client skymail (otherwise the token would not carry them).
# It never creates a SkyMail role (SkyMail's roles are made with the client skymail) and never
# removes a role, a mapping or anything else. A missing client forms or skymail, a disabled service
# account or a missing role skymail:access is a PROBLEM (exit 1); so is a missing
# skymail:mails:send when the account does not hold skymail:mails:write. A client forms without the
# default client scope roles is a WARNING: its tokens carry no resource_access at all.
#
# It refuses every realm but e-skylab and e-skylab-sandbox, before it logs in.
#
# Usage (inside the Keycloak image, as an operator):
#   forms-skymail-grants.sh --admin-user <admin>             # --check (default): state and plan
#   forms-skymail-grants.sh --admin-user <admin> --apply     # grants what is missing
#   forms-skymail-grants.sh --kcadm-config <file> [--apply]  # reuse a logged-in kcadm session
#   --forms-client <clientId> overrides Forms' client id (default forms, or KEYCLOAK_FORMS_CLIENT_ID)
#
# The administrator password is typed into kcadm's own prompt and never passes through this
# script. Environment: KEYCLOAK_ADMIN_URL (default http://keycloak:8080), KEYCLOAK_REALM (default
# e-skylab), KEYCLOAK_ADMIN_REALM (default master), KEYCLOAK_FORMS_GRANTS_ADMIN_USERNAME (or
# --admin-user).
#
# Output: one "[forms-skymail-grants] ..." line per fact, change ("would ..." in --check), NOTE,
# WARNING and PROBLEM, then "check: N change(s) pending, W warning(s), P problem(s)" or "applied N
# change(s), ...". Exit 0 unless a PROBLEM or a missing realm (1) or a usage error or a refused
# realm (2). No secret or token is read or printed.
# Operators: ops/wizards/forms-mail-templates-wizard.sh --sandbox-send-fix in sky_lab_genel made the
# sandbox grant by hand on 2026-10-05; this script is the codified form for both realms.
set -Eeuo pipefail
shopt -s inherit_errexit

umask 077

KCADM=${KCADM_BIN:-/opt/keycloak/bin/kcadm.sh}
ADMIN_URL=${KEYCLOAK_ADMIN_URL:-http://keycloak:8080}
ADMIN_REALM=${KEYCLOAK_ADMIN_REALM:-master}
TARGET_REALM=${KEYCLOAK_REALM:-e-skylab}
ALLOWED_REALMS=(e-skylab e-skylab-sandbox)
ADMIN_USER=${KEYCLOAK_FORMS_GRANTS_ADMIN_USERNAME:-}
FORMS_CLIENT_ID=${KEYCLOAK_FORMS_CLIENT_ID:-forms}
SKYMAIL_CLIENT_ID=skymail
ACCESS_ROLE=skymail:access
SEND_ROLE=skymail:mails:send
BROADER_SEND_ROLE=skymail:mails:write
ROLES_SCOPE=roles
KCADM_CONFIG=''
OWN_CONFIG=false
MODE=check

usage() {
  printf 'usage: %s (--admin-user <administrator> | --kcadm-config <file>) [--forms-client <clientId>] [--check | --apply]\n' \
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
    --forms-client)
      [[ $# -ge 2 && -n $2 ]] || usage
      FORMS_CLIENT_ID=$2
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

allowed=false
for realm in "${ALLOWED_REALMS[@]}"; do
  [[ $TARGET_REALM == "$realm" ]] && allowed=true
done
if [[ $allowed != true ]]; then
  printf '[forms-skymail-grants] refusing realm %s: Forms runs in %s only; nothing was read or changed\n' \
    "$TARGET_REALM" "${ALLOWED_REALMS[*]}" >&2
  exit 2
fi

if [[ -z $KCADM_CONFIG ]]; then
  if [[ -z $ADMIN_USER ]]; then
    if [[ -t 0 ]]; then
      read -r -p "Keycloak administrator username: " ADMIN_USER
    fi
    [[ -n $ADMIN_USER ]] || usage
  fi
  KCADM_CONFIG=$(mktemp /tmp/forms-skymail-grants-kcadm.XXXXXX)
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
  printf '[forms-skymail-grants] %s\n' "$1"
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
  stderr_file=$(mktemp /tmp/forms-skymail-grants-stderr.XXXXXX)
  if kcadm "$@" >/dev/null 2>"$stderr_file"; then
    status=0
  else
    status=$?
    cat "$stderr_file" >&2
  fi
  rm -f "$stderr_file"
  return "$status"
}

# csv PATH FIELDS [kcadm arguments]: the CSV lines of a GET in the target realm (no quotes, empty
# lines dropped).
csv() {
  kcadm get "$1" -r "$TARGET_REALM" --fields "$2" --format csv --noquotes "${@:3}" | tr -d '\r' | sed '/^$/d'
}

# uuid_by CLIENT_ID: the id of the client with exactly this clientId (empty when absent).
uuid_by() {
  csv clients id,clientId -q "clientId=$1" | while IFS=, read -r id client_id; do
    if [[ $client_id == "$1" ]]; then printf '%s\n' "$id"; fi
  done
}

has_line() { # has_line LIST NAME
  grep -Fxq -- "$2" <<<"$1"
}

finish() {
  if [[ $MODE == apply ]]; then
    log "applied $changes change(s), $warnings warning(s), $problems problem(s)"
  else
    log "check: $changes change(s) pending, $warnings warning(s), $problems problem(s)"
  fi
  [[ $problems == 0 ]] || exit 1
  exit 0
}

credential_arguments=(
  --config "$KCADM_CONFIG"
  --server "$ADMIN_URL"
  --realm "$ADMIN_REALM"
  --user "$ADMIN_USER"
)
if [[ $OWN_CONFIG == true ]]; then
  # No redirection: kcadm asks for the password only when stdout is a terminal ("Console is not
  # active" otherwise). Its "Logging into" line goes to stderr, so stdout stays clean either way.
  "$KCADM" config credentials "${credential_arguments[@]}"
fi
log "realm=$TARGET_REALM mode=$MODE formsClient=$FORMS_CLIENT_ID"

# --- prerequisites: nothing is written unless they hold --------------------------------------------
if ! realm_name=$(kcadm get "realms/$TARGET_REALM" --fields realm --format csv --noquotes 2>/dev/null | tr -d '\r') \
  || [[ $realm_name != "$TARGET_REALM" ]]; then
  log "realm $TARGET_REALM does not exist or cannot be read; nothing was changed"
  exit 1
fi

forms_uuid=$(uuid_by "$FORMS_CLIENT_ID")
skymail_uuid=$(uuid_by "$SKYMAIL_CLIENT_ID")
[[ -n $forms_uuid ]] || problem "client $FORMS_CLIENT_ID does not exist in realm $TARGET_REALM"
[[ -n $skymail_uuid ]] || problem "client $SKYMAIL_CLIENT_ID does not exist in realm $TARGET_REALM"
[[ $problems == 0 ]] || finish

IFS=, read -r service_accounts full_scope < <(csv "clients/$forms_uuid" serviceAccountsEnabled,fullScopeAllowed)
if [[ $service_accounts != true ]]; then
  problem "client $FORMS_CLIENT_ID has no service account; it cannot call SkyMail"
  finish
fi
skymail_roles=$(csv "clients/$skymail_uuid/roles" name)
if ! has_line "$skymail_roles" "$ACCESS_ROLE"; then
  problem "client $SKYMAIL_CLIENT_ID has no role $ACCESS_ROLE (made with SkyMail's client, never here)"
  finish
fi
service_user_id=$(csv "clients/$forms_uuid/service-account-user" id)
[[ -n $service_user_id && $service_user_id != *,* ]] || {
  problem "the service-account user of $FORMS_CLIENT_ID could not be resolved exactly"
  finish
}
mappings="users/$service_user_id/role-mappings/clients/$skymail_uuid"
effective=$(csv "$mappings/composite" name)
log "service-account-$FORMS_CLIENT_ID holds the skymail roles: $(tr '\n' ' ' <<<"${effective:-}" | sed 's/ *$//; s/^$/none/')"

# --- the roles it needs ----------------------------------------------------------------------------
wanted=("$ACCESS_ROLE")
if has_line "$effective" "$BROADER_SEND_ROLE"; then
  wanted+=("$BROADER_SEND_ROLE")
  log "NOTE: service-account-$FORMS_CLIENT_ID holds $BROADER_SEND_ROLE, broader than sending one mail needs ($SEND_ROLE); left as is"
  has_line "$effective" "$SEND_ROLE" && wanted+=("$SEND_ROLE")
elif has_line "$skymail_roles" "$SEND_ROLE"; then
  wanted+=("$SEND_ROLE")
else
  problem "client $SKYMAIL_CLIENT_ID has no role $SEND_ROLE and service-account-$FORMS_CLIENT_ID does not hold $BROADER_SEND_ROLE"
  finish
fi

for role in "${wanted[@]}"; do
  if has_line "$effective" "$role"; then
    log "service-account-$FORMS_CLIENT_ID: $SKYMAIL_CLIENT_ID role $role unchanged"
    continue
  fi
  change "assign $SKYMAIL_CLIENT_ID role $role to service-account-$FORMS_CLIENT_ID"
  if [[ $MODE == apply ]]; then
    kcadm_write add-roles -r "$TARGET_REALM" --uid "$service_user_id" --cid "$skymail_uuid" --rolename "$role"
  fi
done

if [[ $full_scope == true ]]; then
  log "client $FORMS_CLIENT_ID: fullScopeAllowed=true, its tokens carry every role it holds (no scope mapping needed)"
else
  scope_roles=$(csv "clients/$forms_uuid/scope-mappings/clients/$skymail_uuid" name)
  for role in "${wanted[@]}"; do
    if has_line "$scope_roles" "$role"; then
      log "client $FORMS_CLIENT_ID: scope mapping $SKYMAIL_CLIENT_ID/$role unchanged"
      continue
    fi
    change "add scope mapping $SKYMAIL_CLIENT_ID/$role to $FORMS_CLIENT_ID (fullScopeAllowed=false)"
    if [[ $MODE == apply ]]; then
      role_id=$(csv "clients/$skymail_uuid/roles/$role" id)
      kcadm_write create "clients/$forms_uuid/scope-mappings/clients/$skymail_uuid" -r "$TARGET_REALM" \
        -b "[{\"id\":\"$role_id\",\"name\":\"$role\"}]"
    fi
  done
fi

if ! has_line "$(csv "clients/$forms_uuid/default-client-scopes" name)" "$ROLES_SCOPE"; then
  warning "client $FORMS_CLIENT_ID lacks the default client scope $ROLES_SCOPE; its tokens carry no resource_access, so SkyMail refuses them"
fi

# --- read back -------------------------------------------------------------------------------------
if [[ $MODE == apply ]]; then
  effective=$(csv "$mappings/composite" name)
  for role in "${wanted[@]}"; do
    has_line "$effective" "$role" || problem "service-account-$FORMS_CLIENT_ID still lacks $SKYMAIL_CLIENT_ID role $role after the run"
  done
fi
finish
