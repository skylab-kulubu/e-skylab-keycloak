#!/usr/bin/env bash
# Idempotent local-development login client of the admin panel in the SANDBOX realm only:
# admin-local in e-skylab-sandbox. core-frontend (the admin panel) is developed with `next dev` on
# http://localhost:3000 against the sandbox (its dev proxy sends /sandbox-api/* to the sandbox API).
# The sandbox panel's own client (superadmin) refuses that callback and stays so: its redirects and
# its secret belong to the deployed sandbox panel. This script makes a separate client instead:
#   - public, no secret (core-frontend signs in with PKCE S256 and sends a client secret only when
#     OAUTH2_CLIENT_SECRET is set); standard flow only, PKCE S256 required; implicit, direct
#     grants, service account, device, CIBA and token exchange off; no consent, no front-channel
#     logout;
#   - redirect URI exactly http://localhost:3000/api/auth/callback, web origin exactly
#     http://localhost:3000, post-logout redirect exactly http://localhost:3000/*. Any other URI on
#     the client is removed: the client is wholly this script's;
#   - the token of the panel's client as the reconciler narrows it (ADR-0058, admin-token-authz
#     ticket 02, reconcile_admin_panel_client), read from the panel's client in the realm (the
#     reference, superadmin; KEYCLOAK_ADMIN_PANEL_CLIENT_ID names another) and never written to it:
#       * fullScopeAllowed=false; the role scope holds every role of core and forms (as the
#         reconciler gives the panel's client) and every own role of the reference, nothing else:
#         realm roles and other clients' roles are removed;
#       * the default client scopes are the reference's plus admin-panel-api-audience (the
#         reconciler's scope: aud core, forms, skycms); the optional scopes are the reference's.
#         Other links are removed. The audience scope is the reconciler's and is never written here:
#         it must exist with audience mappers to core, forms and skycms;
#       * the mapper inscribed-roles: the reference's roles as the flat claim roles, access token and
#         introspection only (what config/inscribed-cms-roles.sh writes on the reference, whose own
#         roles inscribed reads there);
#       * groups as full paths in the access token: from a default scope, otherwise the client
#         mapper groups (Group Membership, full path, access token and introspection).
#     So the token carries the claims the panel reads (sub, profile, email, groups,
#     resource_access.core.roles) and the APIs check (aud core / forms / skycms, resource_access of
#     core and forms, the flat roles). Two differences remain, both from the client id: azp is
#     admin-local, and aud also names the reference whenever the person holds one of its roles
#     (Keycloak's audience resolve names every client with roles in the token but the token's own).
#     Anything the reference adds by a client mapper of another kind is reported as a NOTE and not
#     copied (compare the two tokens: the wizard does).
# Every PROBLEM is found before anything is written and stops the run: nothing is written, exit 1.
#
# A public client cannot use Standard Token Exchange. When the panel's server exchanges tokens
# (admin-token-authz ticket 08, the BFF), this client has to become confidential; its secret then
# goes to the developer encrypted (age to their GitHub SSH keys), never through a chat.
#
# --revoke (with --apply) deletes the client admin-local and nothing else: its sessions end and its
# tokens can no longer be refreshed (an access token already issued stays valid until it expires).
#
# It refuses the production realm e-skylab explicitly, and every realm but e-skylab-sandbox, before
# it logs in. Without the realm, the reference, core, forms or the audience scope it writes nothing
# (exit 1).
#
# Usage (inside the Keycloak image or with its kcadm, as an operator):
#   sandbox-admin-local-client.sh --admin-user <admin>                    # --check (default)
#   sandbox-admin-local-client.sh --admin-user <admin> --apply            # creates and repairs
#   sandbox-admin-local-client.sh --kcadm-config <file> [--apply]         # reuse a kcadm session
#   sandbox-admin-local-client.sh --kcadm-config <file> --revoke [--apply]
#
# The administrator password is typed into kcadm's own prompt and never passes through this
# script. --kcadm-config reuses a kcadm config file an operator (or the wizard) already logged in
# with; the script then never logs in and never deletes that file. Environment: KEYCLOAK_ADMIN_URL
# (default http://keycloak:8080), KEYCLOAK_REALM (default e-skylab-sandbox, the only one accepted),
# KEYCLOAK_ADMIN_REALM (default master), KEYCLOAK_ADMIN_PANEL_CLIENT_ID (default superadmin),
# KEYCLOAK_ADMIN_LOCAL_ADMIN_USERNAME (or --admin-user).
#
# Output: one "[admin-local] ..." line per fact, change ("would ..." in --check), NOTE, WARNING and
# PROBLEM, then "check: N change(s) pending, W warning(s), P problem(s)" or "applied N change(s),
# ...". Exit 0 unless a PROBLEM or a missing prerequisite (1) or a usage error or a refused realm
# (2). No secret or token is ever read or printed.
# Operators: ops/wizards/sandbox-admin-local-client-wizard.sh in sky_lab_genel runs it.
set -Eeuo pipefail
shopt -s inherit_errexit

umask 077

KCADM=${KCADM_BIN:-/opt/keycloak/bin/kcadm.sh}
ADMIN_URL=${KEYCLOAK_ADMIN_URL:-http://keycloak:8080}
ADMIN_REALM=${KEYCLOAK_ADMIN_REALM:-master}
SANDBOX_REALM=e-skylab-sandbox
PRODUCTION_REALM=e-skylab
TARGET_REALM=${KEYCLOAK_REALM:-$SANDBOX_REALM}
ADMIN_USER=${KEYCLOAK_ADMIN_LOCAL_ADMIN_USERNAME:-}
REFERENCE_CLIENT=${KEYCLOAK_ADMIN_PANEL_CLIENT_ID:-superadmin}
KCADM_CONFIG=''
OWN_CONFIG=false
MODE=check
REVOKE=false

CLIENT_ID=admin-local
CLIENT_NAME='Admin panel: local development (localhost:3000)'
CLIENT_DESCRIPTION='core-frontend under next dev on http://localhost:3000 against the sandbox. Public, PKCE S256, localhost only. Made by config/sandbox-admin-local-client.sh; never in production'
LOCAL_ORIGIN=http://localhost:3000
REDIRECT_URI="$LOCAL_ORIGIN/api/auth/callback"
POST_LOGOUT_URI="$LOCAL_ORIGIN/*"
FLAG_FIELDS='enabled,protocol,publicClient,bearerOnly,standardFlowEnabled,implicitFlowEnabled,directAccessGrantsEnabled,serviceAccountsEnabled,fullScopeAllowed,consentRequired,frontchannelLogout,attributes(pkce.code.challenge.method,post.logout.redirect.uris,oauth2.device.authorization.grant.enabled,oidc.ciba.grant.enabled,standard.token.exchange.enabled)'
FLAG_VALUES="true,openid-connect,true,false,true,false,false,false,false,false,false,S256,$POST_LOGOUT_URI,false,false,false"
FLAG_SETTINGS=(
  -s enabled=true
  -s protocol=openid-connect
  -s publicClient=true
  -s bearerOnly=false
  -s standardFlowEnabled=true
  -s implicitFlowEnabled=false
  -s directAccessGrantsEnabled=false
  -s serviceAccountsEnabled=false
  -s fullScopeAllowed=false
  -s consentRequired=false
  -s frontchannelLogout=false
  -s 'attributes."pkce.code.challenge.method"=S256'
  -s "attributes.\"post.logout.redirect.uris\"=$POST_LOGOUT_URI"
  -s 'attributes."oauth2.device.authorization.grant.enabled"=false'
  -s 'attributes."oidc.ciba.grant.enabled"=false'
  -s 'attributes."standard.token.exchange.enabled"=false'
)
# The reconciler's admin panel contract (reconcile-account-center.sh: ADMIN_PANEL_API_CLIENTS,
# ADMIN_PANEL_SCOPE_NAME and config/admin-panel-api-audience-mappers.json).
API_CLIENTS=(core forms)
AUDIENCE_SCOPE=admin-panel-api-audience
AUDIENCES=(core forms skycms)
ROLES_CLAIM=roles
ROLES_MAPPER=inscribed-roles
GROUPS_CLAIM=groups
GROUPS_MAPPER=groups
ROLES_SCOPE=roles
# Mapper CSV: the free-text name last, so a comma in it cannot shift the other columns. The columns
# between the id and the name ("shape"): type, claim, full path, access token, ID token, userinfo,
# introspection, multivalued, JSON type, role client, role prefix, audience.
MAPPER_FIELDS='id,protocolMapper,config(claim.name,full.path,access.token.claim,id.token.claim,userinfo.token.claim,introspection.token.claim,multivalued,jsonType.label,usermodel.clientRoleMapping.clientId,usermodel.clientRoleMapping.rolePrefix,included.client.audience),name'

usage() {
  printf 'usage: %s (--admin-user <administrator> | --kcadm-config <file>) [--check | --apply] [--revoke]\n' \
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
    --revoke)
      REVOKE=true
      shift
      ;;
    *)
      usage
      ;;
  esac
done

# Before anything else, and before a login: only the sandbox realm is ever written.
if [[ $TARGET_REALM == "$PRODUCTION_REALM" ]]; then
  printf '[admin-local] refusing realm %s: that is production, and a localhost login client never goes there; this script writes only the sandbox realm %s. Nothing was read or changed\n' \
    "$TARGET_REALM" "$SANDBOX_REALM" >&2
  exit 2
fi
if [[ $TARGET_REALM != "$SANDBOX_REALM" ]]; then
  printf '[admin-local] refusing realm %s: this script writes only the sandbox realm %s; nothing was read or changed\n' \
    "${TARGET_REALM:-(empty)}" "$SANDBOX_REALM" >&2
  exit 2
fi
if [[ -z $REFERENCE_CLIENT || $REFERENCE_CLIENT == "$CLIENT_ID" || $REFERENCE_CLIENT == *[,\"\\]* ]]; then
  printf '[admin-local] KEYCLOAK_ADMIN_PANEL_CLIENT_ID must name the sandbox panel'"'"'s client (default superadmin), not %s\n' \
    "${REFERENCE_CLIENT:-(empty)}" >&2
  exit 2
fi

if [[ -z $KCADM_CONFIG ]]; then
  if [[ -z $ADMIN_USER ]]; then
    if [[ -t 0 ]]; then
      read -r -p "Keycloak administrator username: " ADMIN_USER
    fi
    [[ -n $ADMIN_USER ]] || usage
  fi
  KCADM_CONFIG=$(mktemp /tmp/admin-local-kcadm.XXXXXX)
  OWN_CONFIG=true
elif [[ ! -r $KCADM_CONFIG ]]; then
  printf 'kcadm config %s is not readable\n' "$KCADM_CONFIG" >&2
  exit 2
fi

# shellcheck disable=SC2329  # run by the EXIT trap below
cleanup() {
  if [[ $OWN_CONFIG == true ]]; then
    rm -f "$KCADM_CONFIG"
  fi
}
trap cleanup EXIT

log() {
  printf '[admin-local] %s\n' "$1"
}

changes=0
warnings=0
problems=0

# change "what": counts one change and prints it; --check prints "would what".
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

finish() {
  if [[ $MODE == apply ]]; then
    log "applied $changes change(s), $warnings warning(s), $problems problem(s)"
  else
    log "check: $changes change(s) pending, $warnings warning(s), $problems problem(s)"
  fi
  [[ $problems == 0 ]] || exit 1
  exit 0
}

kcadm() {
  local command=$1
  shift
  "$KCADM" "$command" --config "$KCADM_CONFIG" "$@"
}

kcadm_write() {
  local stderr_file status
  stderr_file=$(mktemp /tmp/admin-local-stderr.XXXXXX)
  if kcadm "$@" >/dev/null 2>"$stderr_file"; then
    status=0
  else
    status=$?
    cat "$stderr_file" >&2
  fi
  rm -f "$stderr_file"
  return "$status"
}

# csv PATH FIELDS [kcadm arguments]: the CSV lines of a GET in the target realm (no quotes,
# empty lines dropped).
csv() {
  kcadm get "$1" -r "$TARGET_REALM" --fields "$2" --format csv --noquotes "${@:3}" | tr -d '\r' | sed '/^$/d'
}

# json_strings ITEM...: a JSON array of plain strings (URIs; a quote or backslash is refused).
json_strings() {
  local out='' item
  for item in "$@"; do
    [[ $item != *[\"\\]* ]] || { printf 'refusing to write the value %s\n' "$item" >&2; exit 1; }
    out+="${out:+,}\"$item\""
  done
  printf '[%s]' "$out"
}

# uuid_by CLIENT_ID: the id of the client with exactly this clientId (empty when absent).
uuid_by() {
  csv clients id,clientId -q "clientId=$1" | while IFS=, read -r id client_id; do
    if [[ $client_id == "$1" ]]; then printf '%s\n' "$id"; fi
  done
}

# scope_ids NAME: the ids of the client scopes with exactly this name, one per line.
scope_ids() {
  csv client-scopes id,name | while IFS=, read -r id name; do
    if [[ $name == "$1" ]]; then printf '%s\n' "$id"; fi
  done
}

# list_items PATH FIELD: the entries of a client's list field (redirectUris, webOrigins), one per
# line (kcadm joins them with commas; a URI with a comma would split, none of ours has one).
list_items() {
  csv "$1" "$2" | tr ',' '\n' | sed '/^$/d'
}

# {"id":…,"name":…} of one role; role names are free text (a quote or backslash stays JSON).
role_reference() {
  local name=${2//\\/\\\\}
  name=${name//\"/\\\"}
  printf '{"id":"%s","name":"%s"}' "$1" "$name"
}

# role_body LINES: a JSON array of role references from "id,name" lines.
role_body() {
  local body='' id name
  while IFS=, read -r id name; do
    [[ -n $id ]] || continue
    body+="${body:+,}$(role_reference "$id" "$name")"
  done <<<"$1"
  printf '[%s]' "$body"
}

# names_of LINES: the names of "id,name" lines, sorted, space separated.
names_of() {
  cut -d, -f2- <<<"$1" | sed '/^$/d' | LC_ALL=C sort | paste -sd' ' -
}

# shape LINE: the columns of a mapper CSV line between its id and its name.
shape() {
  local rest=${1#*,}
  printf '%s' "${rest%,*}"
}
# is_audience_to SHAPE AUDIENCE: the mapper puts AUDIENCE into the access token's aud.
is_audience_to() {
  local type access audience
  IFS=, read -r type _ _ access _ _ _ _ _ _ _ audience <<<"$1"
  [[ $type == oidc-audience-mapper && $audience == "$2" && $access == true ]]
}
# groups_kind SHAPE: none (does not write groups into the access token), good (full path) or bad.
groups_kind() {
  local type claim full access rest
  IFS=, read -r type claim full access rest <<<"$1"
  if [[ $claim != "$GROUPS_CLAIM" && $claim != "$GROUPS_CLAIM".* ]] || [[ $access != true ]]; then
    printf 'none'
  elif [[ $type == oidc-group-membership-mapper && $claim == "$GROUPS_CLAIM" && $full == true ]]; then
    printf 'good'
  else
    printf 'bad'
  fi
}
# writes_roles SHAPE: the mapper writes the flat claim roles into the access token.
writes_roles() {
  local type claim full access rest
  IFS=, read -r type claim full access rest <<<"$1"
  [[ ($claim == "$ROLES_CLAIM" || $claim == "$ROLES_CLAIM".*) && $access == true ]]
}
# reference_roles_mapper SHAPE: a User Client Role mapper of the reference's roles as the flat roles.
reference_roles_mapper() {
  local type claim access role_client
  IFS=, read -r type claim _ access _ _ _ _ _ role_client _ <<<"$1"
  [[ $type == oidc-usermodel-client-role-mapper && $claim == "$ROLES_CLAIM" && $access == true && $role_client == "$REFERENCE_CLIENT" ]]
}

# The mappers this script writes on admin-local, by name: their exact shape and their body.
ROLES_SHAPE="oidc-usermodel-client-role-mapper,$ROLES_CLAIM,,true,false,false,true,true,String,$REFERENCE_CLIENT,,"
GROUPS_SHAPE="oidc-group-membership-mapper,$GROUPS_CLAIM,true,true,false,false,true,true,,,,"
mapper_body() { # mapper_body NAME [ID]
  local id_field=''
  [[ -z ${2:-} ]] || id_field="\"id\":\"$2\","
  case $1 in
    "$ROLES_MAPPER")
      printf '{%s"name":"%s","protocol":"openid-connect","protocolMapper":"oidc-usermodel-client-role-mapper","consentRequired":false,"config":{"usermodel.clientRoleMapping.clientId":"%s","usermodel.clientRoleMapping.rolePrefix":"","claim.name":"%s","jsonType.label":"String","multivalued":"true","access.token.claim":"true","id.token.claim":"false","userinfo.token.claim":"false","introspection.token.claim":"true","lightweight.claim":"false"}}' \
        "$id_field" "$ROLES_MAPPER" "$REFERENCE_CLIENT" "$ROLES_CLAIM"
      ;;
    "$GROUPS_MAPPER")
      printf '{%s"name":"%s","protocol":"openid-connect","protocolMapper":"oidc-group-membership-mapper","consentRequired":false,"config":{"claim.name":"%s","full.path":"true","multivalued":"true","access.token.claim":"true","id.token.claim":"false","userinfo.token.claim":"false","introspection.token.claim":"true","lightweight.claim":"false"}}' \
        "$id_field" "$GROUPS_MAPPER" "$GROUPS_CLAIM"
      ;;
  esac
}
mapper_description() { # mapper_description NAME
  case $1 in
    "$ROLES_MAPPER") printf 'User Client Role: the roles of %s as the flat claim %s, access token and introspection' "$REFERENCE_CLIENT" "$ROLES_CLAIM" ;;
    "$GROUPS_MAPPER") printf 'Group Membership: claim %s, full path, access token and introspection' "$GROUPS_CLAIM" ;;
  esac
}

# scope_mapping_owners CLIENT_UUID: the clientIds with roles in the client's scope mappings, one
# per line (the keys of "clientMappings" in kcadm's pretty JSON; every one is resolved again below).
# kcadm ends pretty JSON with a newline on stderr; that empty line is dropped, errors are kept.
scope_mapping_owners() {
  kcadm get "clients/$1/scope-mappings" -r "$TARGET_REALM" 2> >(sed '/^$/d' >&2) | tr -d '\r' \
    | sed -n '/^  "clientMappings" : {$/,/^  }/p' | sed -n 's/^    "\(.*\)" : {$/\1/p'
}

# by_name SCOPE_ID...: the scope ids sorted by their names (scope_name_of), one per line.
by_name() {
  local id
  for id in "$@"; do printf '%s\t%s\n' "${scope_name_of[$id]}" "$id"; done | LC_ALL=C sort | cut -f2
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
if [[ $REVOKE == true ]]; then
  log "realm=$TARGET_REALM mode=$MODE revoke client=$CLIENT_ID"
else
  log "realm=$TARGET_REALM mode=$MODE client=$CLIENT_ID reference=$REFERENCE_CLIENT"
fi

if ! realm_name=$(kcadm get "realms/$TARGET_REALM" --fields realm --format csv --noquotes 2>/dev/null | tr -d '\r') \
  || [[ $realm_name != "$TARGET_REALM" ]]; then
  log "realm $TARGET_REALM does not exist or cannot be read; nothing was changed"
  exit 1
fi
client_uuid=$(uuid_by "$CLIENT_ID")

# --- --revoke: the client goes, nothing else ------------------------------------------------------
if [[ $REVOKE == true ]]; then
  if [[ -z $client_uuid ]]; then
    log "client $CLIENT_ID does not exist in realm $TARGET_REALM; nothing to revoke"
  else
    change "delete client $CLIENT_ID (its sessions end and its tokens can no longer be refreshed; an access token already issued stays valid until it expires)"
    if [[ $MODE == apply ]]; then
      kcadm_write delete "clients/$client_uuid" -r "$TARGET_REALM"
      [[ -z $(uuid_by "$CLIENT_ID") ]] || problem "client $CLIENT_ID still exists after the delete"
    fi
  fi
  finish
fi

# --- prerequisites: read everything, write nothing unless they hold -------------------------------
reference_uuid=$(uuid_by "$REFERENCE_CLIENT")
[[ -n $reference_uuid ]] || problem "the reference client $REFERENCE_CLIENT (the sandbox admin panel's) does not exist in realm $TARGET_REALM; there is nothing to mirror"
declare -A api_uuid=()
for api in "${API_CLIENTS[@]}"; do
  api_uuid[$api]=$(uuid_by "$api")
  [[ -n ${api_uuid[$api]} ]] || problem "client $api does not exist in realm $TARGET_REALM; the panel's token needs its roles"
done
audience_scope_list=$(scope_ids "$AUDIENCE_SCOPE")
audience_scope_uuid=''
case $(sed '/^$/d' <<<"$audience_scope_list" | wc -l | tr -d ' ') in
  0) problem "client scope $AUDIENCE_SCOPE does not exist in realm $TARGET_REALM; the reconciler makes it: run its step for this realm first (KEYCLOAK_RECONCILE_ONLY=admin-panel-client, ops/wizards/admin-panel-keycloak-sandbox-wizard.sh)" ;;
  1) audience_scope_uuid=$audience_scope_list ;;
  *) problem "several client scopes are named $AUDIENCE_SCOPE; keep the reconciler's one by hand (Admin Console -> Client scopes)" ;;
esac
if [[ -n $audience_scope_uuid ]]; then
  audience_mappers=$(csv "client-scopes/$audience_scope_uuid/protocol-mappers/models" "$MAPPER_FIELDS")
  for audience in "${AUDIENCES[@]}"; do
    found=false
    while IFS= read -r line; do
      [[ -n $line ]] || continue
      if is_audience_to "$(shape "$line")" "$audience"; then found=true; fi
    done <<<"$audience_mappers"
    [[ $found == true ]] \
      || problem "client scope $AUDIENCE_SCOPE puts no $audience into the access token's aud; it is the reconciler's scope (config/admin-panel-api-audience-mappers.json): run its admin-panel-client step for this realm, this script never writes it"
  done
fi
[[ $problems == 0 ]] || {
  log "nothing was changed: the prerequisites above are missing"
  finish
}

# The reference: read only.
IFS=, read -r reference_public reference_full_scope < <(csv "clients/$reference_uuid" publicClient,fullScopeAllowed)
declare -A want_default=() want_optional=() scope_name_of=()
while IFS=, read -r scope_id scope_name; do
  [[ -n $scope_id ]] || continue
  want_default[$scope_id]=1
  scope_name_of[$scope_id]=$scope_name
done < <(csv "clients/$reference_uuid/default-client-scopes" id,name)
if [[ -z ${want_default[$audience_scope_uuid]:-} || $reference_full_scope != false ]]; then
  warning "the reference $REFERENCE_CLIENT is not narrowed yet (fullScopeAllowed=$reference_full_scope, $AUDIENCE_SCOPE $([[ -n ${want_default[$audience_scope_uuid]:-} ]] && printf 'attached' || printf 'not attached')): $CLIENT_ID follows the reconciler's narrow contract anyway; narrow the reference with the reconciler's admin-panel-client step"
fi
log "reference $REFERENCE_CLIENT: publicClient=$reference_public fullScopeAllowed=$reference_full_scope (read only, never written)"
want_default[$audience_scope_uuid]=1
scope_name_of[$audience_scope_uuid]=$AUDIENCE_SCOPE
while IFS=, read -r scope_id scope_name; do
  [[ -n $scope_id ]] || continue
  scope_name_of[$scope_id]=$scope_name
  [[ -n ${want_default[$scope_id]:-} ]] || want_optional[$scope_id]=1
done < <(csv "clients/$reference_uuid/optional-client-scopes" id,name)

# The reference's own mappers: which ones the contract above covers; the rest is reported.
while IFS= read -r line; do
  [[ -n $line ]] || continue
  name=${line##*,}
  line_shape=$(shape "$line")
  covered=false
  if reference_roles_mapper "$line_shape"; then
    log "reference mapper $name (flat $ROLES_CLAIM of $REFERENCE_CLIENT): mirrored by $ROLES_MAPPER"
    covered=true
  elif [[ $(groups_kind "$line_shape") == good ]]; then
    log "reference mapper $name (full-path $GROUPS_CLAIM): $CLIENT_ID gets full-path $GROUPS_CLAIM too"
    covered=true
  else
    for audience in "${AUDIENCES[@]}"; do
      if is_audience_to "$line_shape" "$audience"; then
        log "reference mapper $name (aud $audience): $CLIENT_ID gets it from $AUDIENCE_SCOPE"
        covered=true
      fi
    done
  fi
  [[ $covered == true ]] \
    || log "NOTE: the reference's mapper $name (${line_shape%%,*}) is not copied to $CLIENT_ID; compare a token of each client if the panel reads its claim"
done < <(csv "clients/$reference_uuid/protocol-mappers/models" "$MAPPER_FIELDS")

# The default scopes $CLIENT_ID will have: what reaches its access token from them.
good_groups=()
bad_groups=()
roles_emitters=()
roles_scope_attached=false
for scope_id in "${!want_default[@]}"; do
  [[ ${scope_name_of[$scope_id]} != "$ROLES_SCOPE" ]] || roles_scope_attached=true
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    line_shape=$(shape "$line")
    case $(groups_kind "$line_shape") in
      good) good_groups+=("${scope_name_of[$scope_id]}/${line##*,}") ;;
      bad) bad_groups+=("${scope_name_of[$scope_id]}/${line##*,}") ;;
    esac
    if writes_roles "$line_shape"; then roles_emitters+=("${scope_name_of[$scope_id]}/${line##*,}"); fi
  done < <(csv "client-scopes/$scope_id/protocol-mappers/models" "$MAPPER_FIELDS")
done
[[ ${#bad_groups[@]} -eq 0 ]] \
  || problem "the default scope mapper(s) ${bad_groups[*]} write $GROUPS_CLAIM differently from full paths; the panel and inscribed read full paths. Fix the scope by hand (the reference has it too)"
[[ ${#roles_emitters[@]} -eq 0 ]] \
  || problem "the default scope mapper(s) ${roles_emitters[*]} write the flat claim $ROLES_CLAIM that inscribed reads; $ROLES_MAPPER must be its only source. Fix the scope by hand"
[[ $roles_scope_attached == true ]] \
  || warning "the reference has no default scope $ROLES_SCOPE: neither token carries resource_access, so core and forms see no role"
declare -A want_mapper=([$ROLES_MAPPER]=$ROLES_SHAPE)
if [[ ${#good_groups[@]} -gt 0 ]]; then
  log "$CLIENT_ID: full-path $GROUPS_CLAIM comes from the default scope mapper(s) ${good_groups[*]}"
else
  want_mapper[$GROUPS_MAPPER]=$GROUPS_SHAPE
fi

# The role scope it will have: every role of core and forms, and the reference's own roles.
declare -A want_roles=()
for api in "${API_CLIENTS[@]}" "$REFERENCE_CLIENT"; do
  if [[ $api == "$REFERENCE_CLIENT" ]]; then owner_uuid=$reference_uuid; else owner_uuid=${api_uuid[$api]}; fi
  want_roles[$api]=$(csv "clients/$owner_uuid/roles" id,name | LC_ALL=C sort)
done

[[ $problems == 0 ]] || {
  log "nothing was changed: fix the PROBLEM(s) above by hand and run again"
  finish
}

# --- 1. the client: flags and URIs ----------------------------------------------------------------
created=false
if [[ -z $client_uuid ]]; then
  change "create public client $CLIENT_ID (standard flow only, PKCE S256, fullScopeAllowed=false, no secret; redirect $REDIRECT_URI, web origin $LOCAL_ORIGIN, post-logout $POST_LOGOUT_URI)"
  if [[ $MODE == apply ]]; then
    client_uuid=$(kcadm create clients -r "$TARGET_REALM" -i \
      -s "clientId=$CLIENT_ID" \
      -s "name=$CLIENT_NAME" \
      -s "description=$CLIENT_DESCRIPTION" \
      "${FLAG_SETTINGS[@]}" \
      -s "redirectUris=$(json_strings "$REDIRECT_URI")" \
      -s "webOrigins=$(json_strings "$LOCAL_ORIGIN")" | tr -d '\r')
    [[ -n $client_uuid ]] || { printf 'client %s was not created\n' "$CLIENT_ID" >&2; exit 1; }
    created=true
  fi
else
  live_flags=$(csv "clients/$client_uuid" "$FLAG_FIELDS")
  if [[ $live_flags == "$FLAG_VALUES" ]]; then
    log "$CLIENT_ID: flags unchanged ($FLAG_FIELDS=$live_flags)"
  else
    change "update $CLIENT_ID flags ($FLAG_FIELDS: $live_flags -> $FLAG_VALUES)"
    if [[ $MODE == apply ]]; then
      kcadm_write update "clients/$client_uuid" -r "$TARGET_REALM" "${FLAG_SETTINGS[@]}"
    fi
  fi
  redirects=$(list_items "clients/$client_uuid" redirectUris)
  if [[ $redirects == "$REDIRECT_URI" ]]; then
    log "$CLIENT_ID: redirect URI exactly $REDIRECT_URI"
  else
    others=$(grep -Fxv -- "$REDIRECT_URI" <<<"$redirects" | paste -sd' ' - || true)
    change "set the redirect URIs of $CLIENT_ID to exactly $REDIRECT_URI${others:+ (removing $others)}"
    if [[ $MODE == apply ]]; then
      kcadm_write update "clients/$client_uuid" -r "$TARGET_REALM" -s "redirectUris=$(json_strings "$REDIRECT_URI")"
    fi
  fi
  origins=$(list_items "clients/$client_uuid" webOrigins)
  if [[ $origins == "$LOCAL_ORIGIN" ]]; then
    log "$CLIENT_ID: web origin exactly $LOCAL_ORIGIN"
  else
    others=$(grep -Fxv -- "$LOCAL_ORIGIN" <<<"$origins" | paste -sd' ' - || true)
    change "set the web origins of $CLIENT_ID to exactly $LOCAL_ORIGIN${others:+ (removing $others)}"
    if [[ $MODE == apply ]]; then
      kcadm_write update "clients/$client_uuid" -r "$TARGET_REALM" -s "webOrigins=$(json_strings "$LOCAL_ORIGIN")"
    fi
  fi
fi

# --- 2. client scopes: the reference's, plus the audience scope -----------------------------------
# A client still to be made (--check) would get the realm's default and optional OpenID Connect
# scopes; Keycloak attaches them on creation.
declare -A live_default=() live_optional=()
if [[ -n $client_uuid ]]; then
  while IFS=, read -r scope_id scope_name; do
    [[ -z $scope_id ]] || { live_default[$scope_id]=1; scope_name_of[$scope_id]=$scope_name; }
  done < <(csv "clients/$client_uuid/default-client-scopes" id,name)
  while IFS=, read -r scope_id scope_name; do
    [[ -z $scope_id ]] || { live_optional[$scope_id]=1; scope_name_of[$scope_id]=$scope_name; }
  done < <(csv "clients/$client_uuid/optional-client-scopes" id,name)
else
  while IFS=, read -r scope_id scope_name scope_protocol; do
    [[ -n $scope_id && $scope_protocol == openid-connect ]] || continue
    live_default[$scope_id]=1
    scope_name_of[$scope_id]=$scope_name
  done < <(csv default-default-client-scopes id,name,protocol)
  while IFS=, read -r scope_id scope_name scope_protocol; do
    [[ -n $scope_id && $scope_protocol == openid-connect ]] || continue
    live_optional[$scope_id]=1
    scope_name_of[$scope_id]=$scope_name
  done < <(csv default-optional-client-scopes id,name,protocol)
fi
# Detach first: Keycloak keeps one link per client and scope, so a link of the other kind would
# block the attachment below.
for scope_id in $(by_name "${!live_default[@]}"); do
  [[ -z ${want_default[$scope_id]:-} ]] || continue
  change "detach the default scope ${scope_name_of[$scope_id]} from $CLIENT_ID (the reference does not have it)"
  [[ $MODE != apply ]] || kcadm_write delete "clients/$client_uuid/default-client-scopes/$scope_id" -r "$TARGET_REALM"
done
for scope_id in $(by_name "${!live_optional[@]}"); do
  [[ -z ${want_optional[$scope_id]:-} ]] || continue
  change "detach the optional scope ${scope_name_of[$scope_id]} from $CLIENT_ID (the reference does not have it as optional)"
  [[ $MODE != apply ]] || kcadm_write delete "clients/$client_uuid/optional-client-scopes/$scope_id" -r "$TARGET_REALM"
done
for scope_id in $(by_name "${!want_default[@]}"); do
  if [[ -n ${live_default[$scope_id]:-} ]]; then
    log "$CLIENT_ID: default scope ${scope_name_of[$scope_id]} attached"
    continue
  fi
  change "attach the default scope ${scope_name_of[$scope_id]} to $CLIENT_ID"
  [[ $MODE != apply ]] || kcadm_write update "clients/$client_uuid/default-client-scopes/$scope_id" -r "$TARGET_REALM" -n -b '{}'
done
for scope_id in $(by_name "${!want_optional[@]}"); do
  if [[ -n ${live_optional[$scope_id]:-} ]]; then
    log "$CLIENT_ID: optional scope ${scope_name_of[$scope_id]} attached"
    continue
  fi
  change "attach the optional scope ${scope_name_of[$scope_id]} to $CLIENT_ID"
  [[ $MODE != apply ]] || kcadm_write update "clients/$client_uuid/optional-client-scopes/$scope_id" -r "$TARGET_REALM" -n -b '{}'
done

# --- 3. the role scope: every role of core and forms, the reference's own roles, nothing else -----
declare -A live_owner_uuid=()
live_realm_roles=''
if [[ -n $client_uuid ]]; then
  live_realm_roles=$(csv "clients/$client_uuid/scope-mappings/realm" id,name)
  while IFS= read -r owner; do
    [[ -n $owner ]] || continue
    live_owner_uuid[$owner]=$(uuid_by "$owner")
  done < <(scope_mapping_owners "$client_uuid")
fi
if [[ -n $live_realm_roles ]]; then
  change "remove the realm roles $(names_of "$live_realm_roles") from the role scope of $CLIENT_ID"
  [[ $MODE != apply ]] || kcadm_write delete "clients/$client_uuid/scope-mappings/realm" -r "$TARGET_REALM" -b "$(role_body "$live_realm_roles")"
fi
for owner in $(printf '%s\n' "${!live_owner_uuid[@]}" | sort); do
  [[ -z ${want_roles[$owner]+set} ]] || continue
  owner_uuid=${live_owner_uuid[$owner]}
  [[ -n $owner_uuid ]] || continue
  extra=$(csv "clients/$client_uuid/scope-mappings/clients/$owner_uuid" id,name)
  [[ -n $extra ]] || continue
  change "remove the $owner roles $(names_of "$extra") from the role scope of $CLIENT_ID"
  [[ $MODE != apply ]] || kcadm_write delete "clients/$client_uuid/scope-mappings/clients/$owner_uuid" -r "$TARGET_REALM" -b "$(role_body "$extra")"
done
for owner in "${API_CLIENTS[@]}" "$REFERENCE_CLIENT"; do
  if [[ $owner == "$REFERENCE_CLIENT" ]]; then owner_uuid=$reference_uuid; else owner_uuid=${api_uuid[$owner]}; fi
  live=''
  [[ -z ${live_owner_uuid[$owner]+set} ]] || live=$(csv "clients/$client_uuid/scope-mappings/clients/$owner_uuid" id,name | LC_ALL=C sort)
  missing=$(LC_ALL=C comm -13 <(printf '%s\n' "$live" | sed '/^$/d') <(printf '%s\n' "${want_roles[$owner]}" | sed '/^$/d'))
  if [[ -z $missing ]]; then
    log "$CLIENT_ID: role scope holds every $owner role ($(names_of "${want_roles[$owner]}" | sed 's/^$/none/'))"
    continue
  fi
  change "add the $owner roles $(names_of "$missing") to the role scope of $CLIENT_ID"
  [[ $MODE != apply ]] || kcadm_write create "clients/$client_uuid/scope-mappings/clients/$owner_uuid" -r "$TARGET_REALM" -b "$(role_body "$missing")"
done

# --- 4. the client's own mappers: inscribed-roles, and groups when no default scope writes it -----
declare -A have_mapper=()
if [[ -n $client_uuid ]]; then
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    name=${line##*,}
    mapper_id=${line%%,*}
    line_shape=$(shape "$line")
    if [[ -n ${want_mapper[$name]:-} && -z ${have_mapper[$name]:-} ]]; then
      have_mapper[$name]=1
      if [[ $line_shape == "${want_mapper[$name]}" ]]; then
        log "$CLIENT_ID: mapper $name unchanged ($(mapper_description "$name"))"
      elif [[ ${line_shape%%,*} == "${want_mapper[$name]%%,*}" ]]; then
        change "repair mapper $name on $CLIENT_ID ($line_shape -> $(mapper_description "$name"))"
        [[ $MODE != apply ]] || kcadm_write update "clients/$client_uuid/protocol-mappers/models/$mapper_id" -r "$TARGET_REALM" \
          -b "$(mapper_body "$name" "$mapper_id")"
      else
        change "replace mapper $name on $CLIENT_ID (type ${line_shape%%,*} -> $(mapper_description "$name"))"
        if [[ $MODE == apply ]]; then
          kcadm_write delete "clients/$client_uuid/protocol-mappers/models/$mapper_id" -r "$TARGET_REALM"
          kcadm_write create "clients/$client_uuid/protocol-mappers/models" -r "$TARGET_REALM" -b "$(mapper_body "$name")"
        fi
      fi
      continue
    fi
    change "remove mapper $name (${line_shape%%,*}) from $CLIENT_ID (not part of the contract)"
    [[ $MODE != apply ]] || kcadm_write delete "clients/$client_uuid/protocol-mappers/models/$mapper_id" -r "$TARGET_REALM"
  done < <(csv "clients/$client_uuid/protocol-mappers/models" "$MAPPER_FIELDS")
fi
for name in $(printf '%s\n' "${!want_mapper[@]}" | sort); do
  [[ -z ${have_mapper[$name]:-} ]] || continue
  change "add mapper $name to $CLIENT_ID ($(mapper_description "$name"))"
  [[ $MODE != apply ]] || kcadm_write create "clients/$client_uuid/protocol-mappers/models" -r "$TARGET_REALM" -b "$(mapper_body "$name")"
done

# --- 5. read back ---------------------------------------------------------------------------------
if [[ $MODE == apply ]]; then
  [[ $(csv "clients/$client_uuid" "$FLAG_FIELDS") == "$FLAG_VALUES" ]] || problem "the flags of $CLIENT_ID are not the contract after the run"
  [[ $(list_items "clients/$client_uuid" redirectUris) == "$REDIRECT_URI" ]] || problem "the redirect URIs of $CLIENT_ID are not exactly $REDIRECT_URI after the run"
  [[ $(list_items "clients/$client_uuid" webOrigins) == "$LOCAL_ORIGIN" ]] || problem "the web origins of $CLIENT_ID are not exactly $LOCAL_ORIGIN after the run"
  [[ $(csv "clients/$client_uuid/default-client-scopes" id | sort) == "$(printf '%s\n' "${!want_default[@]}" | sort)" ]] \
    || problem "the default scopes of $CLIENT_ID are not the reference's plus $AUDIENCE_SCOPE after the run"
  [[ $(csv "clients/$client_uuid/optional-client-scopes" id | sort) == "$(printf '%s\n' "${!want_optional[@]}" | sed '/^$/d' | sort)" ]] \
    || problem "the optional scopes of $CLIENT_ID are not the reference's after the run"
  [[ -z $(csv "clients/$client_uuid/scope-mappings/realm" id) ]] || problem "$CLIENT_ID still has realm roles in its role scope after the run"
  [[ $(scope_mapping_owners "$client_uuid" | sort) == "$(for owner in "${!want_roles[@]}"; do [[ -z ${want_roles[$owner]} ]] || printf '%s\n' "$owner"; done | sort)" ]] \
    || problem "the role scope of $CLIENT_ID holds other clients' roles than core, forms and $REFERENCE_CLIENT after the run"
  [[ $(csv "clients/$client_uuid/protocol-mappers/models" name | sort) == "$(printf '%s\n' "${!want_mapper[@]}" | sort)" ]] \
    || problem "the mappers of $CLIENT_ID are not exactly $(printf '%s ' "${!want_mapper[@]}")after the run"
  [[ $created == false ]] || log "$CLIENT_ID: created (id $client_uuid; public, so there is no secret to hand over)"
fi

log "next: core-frontend .env.local: OAUTH2_ISSUER=<Keycloak>/realms/$TARGET_REALM OAUTH2_CLIENT_ID=$CLIENT_ID OAUTH2_REDIRECT_URI=$REDIRECT_URI APP_URL=$LOCAL_ORIGIN, no OAUTH2_CLIENT_SECRET"
finish
