#!/usr/bin/env bash
# One-off, idempotent operator script for three identity guardrails the steady-state reconciler
# cannot apply: its identity deliberately holds neither user permissions nor identity provider
# permissions. In this order it
#   1. ensures core's client roles certificate:template:manage, certificate:binding:manage,
#      certificate:issue and certificate:revoke exist (core no longer creates them itself);
#   2. sets sync mode FORCE on the "department mapper" of the YTÜ Microsoft identity provider
#      (alias OBS), so the department is read from Microsoft Graph on every login;
#   3. removes the realm-management role manage-clients from core's service account and keeps
#      every other role. ADR-0048 rejected manage-clients for core because it lets core rewrite
#      every client's redirect URIs and secrets; core only needed it to create the roles of
#      step 1, so this step runs only after step 1 has confirmed that all four roles exist.
# Nothing else is touched: other mappers, the identity provider itself, other roles and clients.
#
# Usage (inside the Keycloak image, as an operator):
#   identity-guardrails.sh --admin-user <admin>            # dry run (default): prints the plan
#   identity-guardrails.sh --admin-user <admin> --apply    # performs it
#   --core-client <clientId> overrides core's client id (default core, or KEYCLOAK_CORE_CLIENT_ID)
#
# The administrator password is typed into kcadm's own prompt and never passes through this
# script. Environment: KEYCLOAK_ADMIN_URL (default http://keycloak:8080), KEYCLOAK_REALM
# (default e-skylab), KEYCLOAK_ADMIN_REALM (default master). KEYCLOAK_GUARDRAILS_ADMIN_PASSWORD
# is accepted only together with SKY_HARNESS=1 (the integration harness); anywhere else the
# script refuses it, because kcadm would receive the password on its command line.
set -Eeuo pipefail
shopt -s inherit_errexit

umask 077

KCADM=${KCADM_BIN:-/opt/keycloak/bin/kcadm.sh}
ADMIN_URL=${KEYCLOAK_ADMIN_URL:-http://keycloak:8080}
ADMIN_REALM=${KEYCLOAK_ADMIN_REALM:-master}
TARGET_REALM=${KEYCLOAK_REALM:-e-skylab}
ADMIN_USER=${KEYCLOAK_GUARDRAILS_ADMIN_USERNAME:-}
CORE_CLIENT_ID=${KEYCLOAK_CORE_CLIENT_ID:-core}
YTU_IDP_ALIAS=OBS
DEPARTMENT_MAPPER_NAME='department mapper'
DEPARTMENT_MAPPER_TYPE=microsoft-department-mapper
# core creates these roles without a description; they are created the same way here.
CERTIFICATE_ROLES=(
  certificate:template:manage
  certificate:binding:manage
  certificate:issue
  certificate:revoke
)
REVOKED_CORE_ROLE=manage-clients
KCADM_CONFIG=$(mktemp /tmp/identity-guardrails-kcadm.XXXXXX)
MODE=dry-run

cleanup() {
  rm -f "$KCADM_CONFIG"
}
trap cleanup EXIT

usage() {
  printf 'usage: %s --admin-user <administrator> [--core-client <clientId>] [--apply]\n' \
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
    --core-client)
      [[ $# -ge 2 && -n $2 ]] || usage
      CORE_CLIENT_ID=$2
      shift 2
      ;;
    --apply)
      MODE=apply
      shift
      ;;
    --dry-run)
      MODE=dry-run
      shift
      ;;
    *)
      usage
      ;;
  esac
done

if [[ -z $ADMIN_USER ]]; then
  if [[ -t 0 ]]; then
    read -r -p "Keycloak administrator username: " ADMIN_USER
  fi
  [[ -n $ADMIN_USER ]] || usage
fi

log() {
  printf '[identity-guardrails] %s\n' "$1"
}

plan() {
  if [[ $MODE == apply ]]; then
    log "$1"
  else
    log "would $1"
  fi
}

kcadm() {
  local command=$1
  shift
  "$KCADM" "$command" --config "$KCADM_CONFIG" "$@"
}

kcadm_write() {
  local stderr_file status
  stderr_file=$(mktemp /tmp/identity-guardrails-stderr.XXXXXX)
  if kcadm "$@" >/dev/null 2>"$stderr_file"; then
    status=0
  else
    status=$?
    cat "$stderr_file" >&2
  fi
  rm -f "$stderr_file"
  return "$status"
}

# Prints the internal id of a client; 1 when it does not exist, 2 when clients cannot be read.
client_uuid_by_client_id() {
  local wanted=$1 clients_csv id client_id
  if ! clients_csv=$(kcadm get clients -r "$TARGET_REALM" -q "clientId=$wanted" \
    --fields id,clientId \
    --format csv \
    --noquotes); then
    printf 'Failed to read clients while looking up %s\n' "$wanted" >&2
    return 2
  fi
  while IFS=, read -r id client_id; do
    if [[ $client_id == "$wanted" ]]; then
      printf '%s\n' "$id"
      return 0
    fi
  done <<<"$clients_csv"
  return 1
}

# Runs a lookup that returns 1 for "absent": prints its result (empty when absent) and fails
# only on a real error.
optional_lookup() {
  local result status
  if result=$("$@"); then
    printf '%s\n' "$result"
    return 0
  else
    status=$?
  fi
  if [[ $status == 1 ]]; then
    return 0
  fi
  return "$status"
}

# Prints the names of core's client roles, one per line.
core_role_names() {
  kcadm get "clients/$1/roles" -r "$TARGET_REALM" \
    --fields name \
    --format csv \
    --noquotes
}

missing_certificate_roles() {
  local names=$1 role
  for role in "${CERTIFICATE_ROLES[@]}"; do
    grep -Fxq -- "$role" <<<"$names" || printf '%s\n' "$role"
  done
}

credential_arguments=(
  --config "$KCADM_CONFIG"
  --server "$ADMIN_URL"
  --realm "$ADMIN_REALM"
  --user "$ADMIN_USER"
)
if [[ -n ${KEYCLOAK_GUARDRAILS_ADMIN_PASSWORD:-} ]]; then
  if [[ ${SKY_HARNESS:-} != 1 ]]; then
    printf 'KEYCLOAK_GUARDRAILS_ADMIN_PASSWORD is accepted only by the test harness (SKY_HARNESS=1); unset it and type the password into the kcadm prompt\n' >&2
    exit 2
  fi
  credential_arguments+=(--password "$KEYCLOAK_GUARDRAILS_ADMIN_PASSWORD")
fi
# No redirection: kcadm asks for the password only when stdout is a terminal ("Console is not
# active" otherwise). Its "Logging into" line goes to stderr, so stdout stays clean either way.
"$KCADM" config credentials "${credential_arguments[@]}"
log "realm=$TARGET_REALM coreClient=$CORE_CLIENT_ID identityProvider=$YTU_IDP_ALIAS mode=$MODE"

changes=0
problems=0
certificate_roles_confirmed=false

# --- 1. core's certificate client roles --------------------------------------------------------
core_uuid=$(optional_lookup client_uuid_by_client_id "$CORE_CLIENT_ID")
if [[ -z $core_uuid ]]; then
  log "WARNING: client $CORE_CLIENT_ID does not exist in realm $TARGET_REALM; certificate roles and the $REVOKED_CORE_ROLE removal were skipped"
else
  role_names=$(core_role_names "$core_uuid")
  missing=$(missing_certificate_roles "$role_names")
  if [[ -z $missing ]]; then
    log "client $CORE_CLIENT_ID: certificate roles unchanged (${CERTIFICATE_ROLES[*]})"
  else
    while IFS= read -r role; do
      plan "create client role $role on $CORE_CLIENT_ID"
      changes=$((changes + 1))
      if [[ $MODE == apply ]]; then
        kcadm_write create "clients/$core_uuid/roles" -r "$TARGET_REALM" -s "name=$role"
      fi
    done <<<"$missing"
  fi
  if [[ $MODE == apply ]]; then
    # Read back: the manage-clients removal below depends on these roles existing.
    role_names=$(core_role_names "$core_uuid")
    missing=$(missing_certificate_roles "$role_names")
    if [[ -n $missing ]]; then
      printf 'Client %s still lacks the roles %s; %s was left in place\n' \
        "$CORE_CLIENT_ID" "$(tr '\n' ' ' <<<"$missing" | sed 's/ $//')" "$REVOKED_CORE_ROLE" >&2
      exit 1
    fi
  fi
  [[ -n $missing ]] || certificate_roles_confirmed=true
fi

# --- 2. OBS department mapper sync mode ---------------------------------------------------------
idp_aliases=$(kcadm get identity-provider/instances -r "$TARGET_REALM" \
  --fields alias \
  --format csv \
  --noquotes)
if ! grep -Fxq -- "$YTU_IDP_ALIAS" <<<"$idp_aliases"; then
  log "identity provider $YTU_IDP_ALIAS does not exist in realm $TARGET_REALM; department mapper sync mode skipped"
else
  mappers_csv=$(kcadm get "identity-provider/instances/$YTU_IDP_ALIAS/mappers" -r "$TARGET_REALM" \
    --fields 'id,name,identityProviderMapper,config(syncMode)' \
    --format csv \
    --noquotes)
  mapper_matches=0
  mapper_id=''
  mapper_type=''
  mapper_sync_mode=''
  while IFS=, read -r id name type sync_mode; do
    [[ -n $id && $name == "$DEPARTMENT_MAPPER_NAME" ]] || continue
    mapper_matches=$((mapper_matches + 1))
    mapper_id=$id
    mapper_type=$type
    mapper_sync_mode=$sync_mode
  done <<<"$mappers_csv"
  if [[ $mapper_matches == 0 ]]; then
    log "WARNING: identity provider $YTU_IDP_ALIAS has no mapper named '$DEPARTMENT_MAPPER_NAME'; nothing was changed"
  elif [[ $mapper_matches != 1 ]]; then
    printf 'Identity provider %s has %s mappers named %s; resolve them by hand, nothing was changed\n' \
      "$YTU_IDP_ALIAS" "$mapper_matches" "'$DEPARTMENT_MAPPER_NAME'" >&2
    problems=$((problems + 1))
  elif [[ $mapper_type != "$DEPARTMENT_MAPPER_TYPE" ]]; then
    printf 'Mapper %s of identity provider %s has type %s instead of %s; nothing was changed\n' \
      "'$DEPARTMENT_MAPPER_NAME'" "$YTU_IDP_ALIAS" "${mapper_type:-(none)}" "$DEPARTMENT_MAPPER_TYPE" >&2
    problems=$((problems + 1))
  elif [[ $mapper_sync_mode == FORCE ]]; then
    log "identity provider $YTU_IDP_ALIAS mapper '$DEPARTMENT_MAPPER_NAME': sync mode FORCE unchanged"
  else
    plan "set sync mode of identity provider $YTU_IDP_ALIAS mapper '$DEPARTMENT_MAPPER_NAME' from ${mapper_sync_mode:-(unset, LEGACY)} to FORCE"
    changes=$((changes + 1))
    if [[ $MODE == apply ]]; then
      # kcadm update reads the mapper, changes this one config key and writes the whole mapper
      # back, so its other fields stay as they are.
      kcadm_write update "identity-provider/instances/$YTU_IDP_ALIAS/mappers/$mapper_id" \
        -r "$TARGET_REALM" -s config.syncMode=FORCE
    fi
  fi
fi

# --- 3. manage-clients off core's service account -----------------------------------------------
if [[ -n $core_uuid ]]; then
  service_account_enabled=$(kcadm get "clients/$core_uuid" -r "$TARGET_REALM" \
    --fields serviceAccountsEnabled \
    --format csv \
    --noquotes)
  if [[ $service_account_enabled != true ]]; then
    log "client $CORE_CLIENT_ID has no service account; $REVOKED_CORE_ROLE removal skipped"
  else
    service_user_id=$(kcadm get "clients/$core_uuid/service-account-user" -r "$TARGET_REALM" \
      --fields id \
      --format csv \
      --noquotes)
    [[ -n $service_user_id && $service_user_id != *,* ]] || {
      printf 'The %s service-account user could not be resolved exactly\n' "$CORE_CLIENT_ID" >&2
      exit 1
    }
    realm_management_uuid=$(optional_lookup client_uuid_by_client_id realm-management)
    [[ -n $realm_management_uuid ]] || {
      printf 'Client realm-management was not found in realm %s\n' "$TARGET_REALM" >&2
      exit 1
    }
    mappings="users/$service_user_id/role-mappings/clients/$realm_management_uuid"
    direct_csv=$(kcadm get "$mappings" -r "$TARGET_REALM" --fields id,name --format csv --noquotes)
    revoked_role_id=''
    kept=''
    while IFS=, read -r role_id role_name; do
      [[ -n $role_id ]] || continue
      if [[ $role_name == "$REVOKED_CORE_ROLE" ]]; then
        revoked_role_id=$role_id
      else
        kept="$kept $role_name"
      fi
    done <<<"$direct_csv"
    if [[ -n $revoked_role_id ]]; then
      if [[ $certificate_roles_confirmed == true ]]; then
        plan "remove realm-management role $REVOKED_CORE_ROLE from service-account-$CORE_CLIENT_ID"
      else
        plan "remove realm-management role $REVOKED_CORE_ROLE from service-account-$CORE_CLIENT_ID once the certificate roles above exist"
      fi
      changes=$((changes + 1))
      if [[ $MODE == apply ]]; then
        kcadm_write delete "$mappings" -r "$TARGET_REALM" \
          -b "[{\"id\":\"$revoked_role_id\",\"name\":\"$REVOKED_CORE_ROLE\"}]"
      fi
    else
      log "service-account-$CORE_CLIENT_ID: realm-management role $REVOKED_CORE_ROLE absent (unchanged)"
    fi
    log "service-account-$CORE_CLIENT_ID keeps its other realm-management roles:${kept:- none}"
    # A composite role (realm-admin, for example) or a group can still carry the role; this
    # script removes only the direct mapping and reports the rest for a manual decision.
    if [[ $MODE == apply || -z $revoked_role_id ]]; then
      effective_csv=$(kcadm get "$mappings/composite" -r "$TARGET_REALM" \
        --fields name --format csv --noquotes)
      if grep -Fxq -- "$REVOKED_CORE_ROLE" <<<"$effective_csv"; then
        printf 'service-account-%s still holds %s through a composite role or a group; remove that grant by hand\n' \
          "$CORE_CLIENT_ID" "$REVOKED_CORE_ROLE" >&2
        problems=$((problems + 1))
      fi
    fi
  fi
fi

if [[ $MODE == apply ]]; then
  log "applied $changes change(s)"
else
  log "dry run: $changes change(s) pending; rerun with --apply to execute them"
fi
if [[ $problems != 0 ]]; then
  log "$problems problem(s) need a manual decision (see above)"
  exit 1
fi
