#!/usr/bin/env bash
# Idempotent provisioning of inscribed's roles on the Site clients (CMS moves to inscribed,
# ADR-0056). inscribed (External mode) reads the tenant from azp, the audience skycms and the
# capabilities from ONE fixed, flat claim: roles. The old CMS read cms:access from
# resource_access[azp].roles, a path that changes with the client, so inscribed cannot read it.
#
# The script CREATES roles and composites and makes the claims. It never grants a role to a group
# or to a person: group -> client-role mappings are made in the SKY LAB admin panel (Groups ->
# client roles; CONTEXT.md "Client role"). Its only grants go to the clients' own service accounts.
# It reports, read-only, who holds each CMS role, so the panel's grants can be checked.
#
# Clients: frontend-main, frontend-arge and the admin panel's client (admin; superadmin in the realm
# e-skylab-sandbox), in this order, or the --client list. A client missing from the realm is skipped
# with a NOTE (the sandbox realm may have no frontend-*). For every client
#   1. creates the client roles content:read, content:write and schema:sync when they are missing;
#      on the site editors (frontend-main, frontend-arge and the event sites frontend-artlab,
#      frontend-yildizjam, frontend-skydays) also cms:access and client:admin:
#        - cms:access is what the sites' editor UI checks (@skylab-kulubu/inscribed-auth 0.3.1 looks
#          for it anywhere in the access token's resource_access; a site login's token carries only
#          that site's roles when the client does not allow the full scope, as frontend-arge does);
#        - client:admin lets inscribed's collections create any team page and edit any team page
#          (ClaimDerived: a departed leader's page) and lets its holder change this one tenant's
#          settings (GET/PUT /admin/clients/<client>: isActive, allowAnonymousContentRead);
#   2. makes the client's cms:access a composite of its own content:read and content:write, so a
#      group holding cms:access gets both in the roles claim. A client other than the site editors
#      keeps an existing cms:access this way and is never given one (its groups get content:*
#      directly);
#   3. adds the "User Client Role" mapper inscribed-roles: the client's own roles, composites
#      expanded, as the flat multivalued claim roles in the access token and introspection only
#      (not the ID token, not userinfo); a different mapper that already emits roles on the client
#      or one of its default scopes is reported and blocks the mapper, never overwritten;
#   4. makes sure the access token carries groups as full paths (inscribed's collections read
#      them): an existing full-path Group Membership mapper on the client or on one of its default
#      scopes is enough; otherwise the client mapper inscribed-groups is added; a groups claim
#      without full paths is reported, never changed (other consumers may read it);
#   5. gives the client's service account, when it has one, content:read and schema:sync (sites
#      read content server-side and push collection schemas with client_credentials). Service
#      accounts are never enabled here. With --post-cutover it also takes cms:access (and so
#      content:write) away from that service account; never by default: the old CMS renders the
#      site with that grant until inscribed takes over /api/cms on cutover night;
#   6. reports which groups hold cms:access, content:read, content:write, schema:sync and
#      client:admin on the client, directly or through a composite (one of the client's own or a
#      realm role); a group's grant reaches its subgroups. A grant straight to a person (service
#      accounts aside) is a WARNING: CMS roles go to groups only. A CMS role in the realm's default
#      roles, or reaching a default group, is a PROBLEM. Composites of other clients are not
#      followed.
# Nothing is ever removed except this script's own redundant inscribed-groups mapper and, with
# --post-cutover, cms:access on the service accounts.
#
# Usage (inside the Keycloak image, as an operator):
#   inscribed-cms-roles.sh --admin-user <admin>             # --check (default): state, plan, report
#   inscribed-cms-roles.sh --admin-user <admin> --apply     # creates and updates
#   inscribed-cms-roles.sh --kcadm-config <file> [--apply]  # reuse a logged-in kcadm session
#   ... [--client <clientId>]...                            # other clients than the default three
#   ... --post-cutover                                      # cutover night only, see 5.
#
# The administrator password is typed into kcadm's own prompt and never passes through this
# script. --kcadm-config reuses a kcadm config file an operator (or the wizard) already logged in
# with; the script then never logs in and never deletes that file. Environment: KEYCLOAK_ADMIN_URL
# (default http://keycloak:8080), KEYCLOAK_REALM (default e-skylab), KEYCLOAK_ADMIN_REALM (default
# master), KEYCLOAK_INSCRIBED_ADMIN_USERNAME (or --admin-user).
#
# Output: one "[inscribed-roles] ..." line per fact, change ("would ..." in --check), NOTE, WARNING
# and PROBLEM, then "check: N change(s) pending, W warning(s), P problem(s)" or "applied N
# change(s), ...". Exit 0 unless a PROBLEM (1) or a usage error (2). No token or secret is ever read.
# Operators: ops/wizards/inscribed-keycloak-roles-wizard.sh in sky_lab_genel runs it in production.
set -Eeuo pipefail
shopt -s inherit_errexit

umask 077

KCADM=${KCADM_BIN:-/opt/keycloak/bin/kcadm.sh}
ADMIN_URL=${KEYCLOAK_ADMIN_URL:-http://keycloak:8080}
ADMIN_REALM=${KEYCLOAK_ADMIN_REALM:-master}
TARGET_REALM=${KEYCLOAK_REALM:-e-skylab}
ADMIN_USER=${KEYCLOAK_INSCRIBED_ADMIN_USERNAME:-}
KCADM_CONFIG=''
OWN_CONFIG=false
MODE=check
POST_CUTOVER=false
CLIENTS=()

# The admin panel logs in through admin in production and through superadmin in the sandbox.
if [[ $TARGET_REALM == e-skylab-sandbox ]]; then
  ADMIN_PANEL_CLIENT='superadmin'
else
  ADMIN_PANEL_CLIENT='admin'
fi
DEFAULT_CLIENTS=(frontend-main frontend-arge "$ADMIN_PANEL_CLIENT")
# The sites whose editor UI opens on cms:access (the event sites since 2026-10-03, ADR-0056 addendum).
SITE_EDITOR_CLIENTS=(frontend-main frontend-arge frontend-artlab frontend-yildizjam frontend-skydays)
LEGACY_ROLE=cms:access
ADMIN_ROLE=client:admin
CAPABILITY_ROLES=(content:read content:write schema:sync)
EDITOR_ROLES=(content:read content:write)
SERVICE_ROLES=(content:read schema:sync)
REPORT_ROLES=(cms:access content:read content:write schema:sync client:admin)
declare -A ROLE_DESCRIPTION=(
  [content:read]='inscribed: read this site client'"'"'s pages and collections (ADR-0056)'
  [content:write]='inscribed: edit this site client'"'"'s pages and collections (ADR-0056); cms:access includes it'
  [schema:sync]='inscribed: push collection schemas (cms-sync) for this site client (ADR-0056)'
  [cms:access]='Opens this site'"'"'s CMS editor; includes content:read + content:write (ADR-0056). Groups only, granted in the SKY LAB admin panel'
  [client:admin]='inscribed: create and fix any team page, this tenant'"'"'s settings (ADR-0056). People only, through groups granted in the SKY LAB admin panel'
)
ROLES_CLAIM=roles
ROLES_MAPPER=inscribed-roles
GROUPS_CLAIM=groups
GROUPS_MAPPER=inscribed-groups
# Mapper CSV: the free-text name last, so a comma in it cannot shift the other columns.
MAPPER_FIELDS='id,protocolMapper,config(claim.name,full.path,access.token.claim,id.token.claim,userinfo.token.claim,introspection.token.claim,multivalued,jsonType.label,usermodel.clientRoleMapping.clientId,usermodel.clientRoleMapping.rolePrefix),name'

usage() {
  printf 'usage: %s (--admin-user <administrator> | --kcadm-config <file>) [--check | --apply] [--client <clientId>]... [--post-cutover]\n' \
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
    --client)
      [[ $# -ge 2 && -n $2 ]] || usage
      CLIENTS+=("$2")
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
    --post-cutover)
      POST_CUTOVER=true
      shift
      ;;
    *)
      usage
      ;;
  esac
done
[[ ${#CLIENTS[@]} -gt 0 ]] || CLIENTS=("${DEFAULT_CLIENTS[@]}")

if [[ -z $KCADM_CONFIG ]]; then
  if [[ -z $ADMIN_USER ]]; then
    if [[ -t 0 ]]; then
      read -r -p "Keycloak administrator username: " ADMIN_USER
    fi
    [[ -n $ADMIN_USER ]] || usage
  fi
  KCADM_CONFIG=$(mktemp /tmp/inscribed-roles-kcadm.XXXXXX)
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
  printf '[inscribed-roles] %s\n' "$1"
}

declare -A role_ids=() planned=()
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

kcadm() {
  local command=$1
  shift
  "$KCADM" "$command" --config "$KCADM_CONFIG" "$@"
}

kcadm_write() {
  local stderr_file status
  stderr_file=$(mktemp /tmp/inscribed-roles-stderr.XXXXXX)
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

role_body() {
  printf '[{"id":"%s","name":"%s"}]' "$1" "$2"
}

is_site_editor() {
  local candidate
  for candidate in "${SITE_EDITOR_CLIENTS[@]}"; do
    [[ $candidate != "$1" ]] || return 0
  done
  return 1
}

# expected_mapper_line KIND CLIENT: the CSV columns after id (protocolMapper and config) that the
# mapper this script owns must have; the same order as MAPPER_FIELDS.
expected_mapper_line() {
  case $1 in
    roles)
      printf 'oidc-usermodel-client-role-mapper,%s,,true,false,false,true,true,String,%s,' "$ROLES_CLAIM" "$2"
      ;;
    groups)
      printf 'oidc-group-membership-mapper,%s,true,true,false,false,true,true,,,' "$GROUPS_CLAIM"
      ;;
  esac
}

mapper_body() {
  local kind=$1 client=$2 id=${3:-} id_field=''
  [[ -z $id ]] || id_field="\"id\":\"$id\","
  case $kind in
    roles)
      printf '{%s"name":"%s","protocol":"openid-connect","protocolMapper":"oidc-usermodel-client-role-mapper","consentRequired":false,"config":{"usermodel.clientRoleMapping.clientId":"%s","usermodel.clientRoleMapping.rolePrefix":"","claim.name":"%s","jsonType.label":"String","multivalued":"true","access.token.claim":"true","id.token.claim":"false","userinfo.token.claim":"false","introspection.token.claim":"true","lightweight.claim":"false"}}' \
        "$id_field" "$ROLES_MAPPER" "$client" "$ROLES_CLAIM"
      ;;
    groups)
      printf '{%s"name":"%s","protocol":"openid-connect","protocolMapper":"oidc-group-membership-mapper","consentRequired":false,"config":{"claim.name":"%s","full.path":"true","multivalued":"true","access.token.claim":"true","id.token.claim":"false","userinfo.token.claim":"false","introspection.token.claim":"true","lightweight.claim":"false"}}' \
        "$id_field" "$GROUPS_MAPPER" "$GROUPS_CLAIM"
      ;;
  esac
}

# Claim names are compared as written in the mapper: "roles" itself or anything nested under it
# ("roles.x") lands in the same top-level claim.
claims_into() {
  [[ $1 == "$2" || $1 == "$2".* ]]
}

# ensure_own_mapper CLIENT UUID KIND LIVE_LINE: creates or repairs the mapper this script owns.
# LIVE_LINE is the mapper's CSV line (without the name) or empty when it does not exist.
ensure_own_mapper() {
  local client=$1 uuid=$2 kind=$3 live=$4 name expected mapper_id
  name=$ROLES_MAPPER
  [[ $kind == groups ]] && name=$GROUPS_MAPPER
  expected=$(expected_mapper_line "$kind" "$client")
  if [[ -z $live ]]; then
    change "add mapper $name to $client ($(describe_mapper "$kind"))"
    if [[ $MODE == apply ]]; then
      kcadm_write create "clients/$uuid/protocol-mappers/models" -r "$TARGET_REALM" \
        -b "$(mapper_body "$kind" "$client")"
    fi
    return 0
  fi
  mapper_id=${live%%,*}
  if [[ ${live#*,} == "$expected" ]]; then
    log "$client: mapper $name unchanged"
    return 0
  fi
  change "repair mapper $name on $client (${live#*,} -> $expected)"
  if [[ $MODE == apply ]]; then
    kcadm_write update "clients/$uuid/protocol-mappers/models/$mapper_id" -r "$TARGET_REALM" \
      -b "$(mapper_body "$kind" "$client" "$mapper_id")"
  fi
}

describe_mapper() {
  case $1 in
    roles) printf 'User Client Role: own client roles, composites expanded, flat multivalued claim %s, access token and introspection only' "$ROLES_CLAIM" ;;
    groups) printf 'Group Membership: claim %s, full path, access token and introspection only' "$GROUPS_CLAIM" ;;
  esac
}

# scan_mapper WHERE TYPE CLAIM FULL_PATH ACCESS: sorts one mapper that reaches the client's tokens
# into foreign_roles (writes roles), good_groups / bad_groups (writes groups) or other_token (writes
# one of the two claims, but not into the access token).
scan_mapper() {
  local where=$1 protocol_mapper=$2 claim=$3 full_path=$4 access=$5
  if ! claims_into "$claim" "$ROLES_CLAIM" && ! claims_into "$claim" "$GROUPS_CLAIM"; then
    return 0
  fi
  if [[ $access != true ]]; then
    other_token+=("$where (claim $claim)")
    return 0
  fi
  if claims_into "$claim" "$ROLES_CLAIM"; then
    foreign_roles+=("$where ($protocol_mapper)")
  elif [[ $protocol_mapper == oidc-group-membership-mapper && $claim == "$GROUPS_CLAIM" && $full_path == true ]]; then
    good_groups+=("$where")
  else
    bad_groups+=("$where ($protocol_mapper, claim $claim, full.path=${full_path:-unset})")
  fi
}

# load_scope_mappers SCOPE_ID: reads a client scope's mappers (MAPPER_FIELDS) once per run into
# scope_mapper_lines; the clients share most scopes and this script never changes a scope.
declare -A scope_mapper_lines=()
load_scope_mappers() {
  [[ -n ${scope_mapper_lines[$1]+set} ]] || scope_mapper_lines[$1]=$(csv "client-scopes/$1/protocol-mappers/models" "$MAPPER_FIELDS")
}

# --- holders (step 6) ------------------------------------------------------------------------------
# Role graph: realm_parents / client_parents[child role id] = the ids of the composite roles that
# include it directly, from the realm's composite roles (read once) and the current client's (read
# per client).
declare -A realm_parents=() client_parents=() realm_role_name=() client_role_name=()
declare -A held_groups=() held_users=() warned_direct=() warned_default_group=()
declare -A client_uuid=() client_sa=() client_by_lower=() sa_user_of=()
default_role_id=''
default_role_name=''
default_groups=''

# ancestors ID: every role id that includes ID through composites, one per line.
ancestors() {
  local -A seen=()
  local queue=("$1") current parent
  seen[$1]=1
  while [[ ${#queue[@]} -gt 0 ]]; do
    current=${queue[0]}
    queue=("${queue[@]:1}")
    for parent in ${realm_parents[$current]:-} ${client_parents[$current]:-}; do
      [[ -z ${seen[$parent]:-} ]] || continue
      seen[$parent]=1
      queue+=("$parent")
      printf '%s\n' "$parent"
    done
  done
}

# is_service_account USER_ID USERNAME: whether the user is a client's service-account user (its
# name alone proves nothing: a person may be called service-account-x).
is_service_account() {
  local user_id=$1 username=$2 owner
  [[ $username == service-account-* ]] || return 1
  owner=${client_by_lower[${username#service-account-}]:-}
  [[ -n $owner && ${client_sa[$owner]:-} == true ]] || return 1
  if [[ -z ${sa_user_of[$owner]+set} ]]; then
    sa_user_of[$owner]=$(csv "clients/$owner/service-account-user" id)
  fi
  [[ ${sa_user_of[$owner]} == "$user_id" ]]
}

# fetch_holders ROLE_ID CLIENT_UUID: caches the groups (paths) and users ("id,username") that hold
# the role directly: a role of the current client or a composite realm role.
fetch_holders() {
  local id=$1 base
  [[ -z ${held_groups[$id]+set} ]] || return 0
  if [[ -n ${client_role_name[$id]:-} ]]; then
    base="clients/$2/roles/${client_role_name[$id]}"
  else
    base="roles/${realm_role_name[$id]:-$id}"
  fi
  held_groups[$id]=$(csv "$base/groups" path -q max=100000)
  held_users[$id]=$(csv "$base/users" id,username -q max=100000)
}

# report_holders CLIENT UUID: step 6, from the realm as it is now (after --apply's writes).
report_holders() {
  local client=$1 uuid=$2 role role_id role_name composite child carrier via path default_group
  local groups_line sa_line people user_id username in_default=''
  local -A ids_by_name=()
  client_parents=()
  client_role_name=()
  while IFS=, read -r role_id role_name composite; do
    [[ -n $role_id ]] || continue
    ids_by_name[$role_name]=$role_id
    client_role_name[$role_id]=$role_name
    [[ $composite == true ]] || continue
    while IFS=, read -r child _; do
      [[ -n $child ]] || continue
      client_parents[$child]+=" $role_id"
    done < <(csv "roles-by-id/$role_id/composites" id)
  done < <(csv "clients/$uuid/roles" id,name,composite)

  log "$client: who holds its CMS roles now (a group's grant reaches its subgroups; the SKY LAB admin panel grants them, this script never does):"
  for role in "${REPORT_ROLES[@]}"; do
    role_id=${ids_by_name[$role]:-}
    if [[ -z $role_id ]]; then
      [[ -z ${planned[$role]:-} ]] || log "$client:   $role <- no group (the role does not exist yet)"
      continue
    fi
    groups_line=''
    sa_line=''
    while IFS= read -r carrier; do
      [[ -n $carrier ]] || continue
      if [[ $carrier == "$role_id" ]]; then
        via=''
      elif [[ -n ${client_role_name[$carrier]:-} ]]; then
        via=" (via ${client_role_name[$carrier]})"
      else
        via=" (via realm role ${realm_role_name[$carrier]:-$carrier})"
      fi
      if [[ $carrier == "$default_role_id" ]]; then
        in_default+="${in_default:+, }$role"
        continue
      fi
      fetch_holders "$carrier" "$uuid"
      while IFS= read -r path; do
        [[ -n $path ]] || continue
        groups_line+="${groups_line:+, }$path$via"
        while IFS= read -r default_group; do
          [[ -n $default_group ]] || continue
          [[ $default_group == "$path" || $default_group == "$path"/* ]] || continue
          [[ -z ${warned_default_group[$carrier|$default_group]:-} ]] || continue
          warned_default_group[$carrier|$default_group]=1
          problem "$client: the default group $default_group gets ${client_role_name[$carrier]:-realm role ${realm_role_name[$carrier]:-}} (held by $path): every new user gets it. Take $default_group out of the default groups or the role off $path"
        done <<<"$default_groups"
      done <<<"${held_groups[$carrier]}"
      people=''
      while IFS=, read -r user_id username; do
        [[ -n $user_id ]] || continue
        if is_service_account "$user_id" "$username"; then
          sa_line+="${sa_line:+, }$username$via"
        else
          people+="${people:+, }$username"
        fi
      done <<<"${held_users[$carrier]}"
      if [[ -n $people && -z ${warned_direct[$carrier]:-} ]]; then
        warned_direct[$carrier]=1
        if [[ -n ${client_role_name[$carrier]:-} ]]; then
          warning "$client/${client_role_name[$carrier]} is granted directly to user(s) $people, not through a group: grant it to a group in the SKY LAB admin panel and take the direct grant away"
        else
          warning "realm role ${realm_role_name[$carrier]:-$carrier} (it includes $client/$role) is granted directly to user(s) $people, not through a group"
        fi
      fi
    done < <(printf '%s\n' "$role_id"; ancestors "$role_id")
    log "$client:   $role <- ${groups_line:+group(s): }${groups_line:-no group}"
    [[ -z $sa_line ]] || log "$client:   $role <- service account(s): $sa_line"
  done
  if [[ -n $in_default ]]; then
    problem "$client: the realm's default roles ($default_role_name) include $in_default: every new user gets them. Take them out of the default roles"
  fi
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
post_cutover_note=''
[[ $POST_CUTOVER != true ]] || post_cutover_note=' post-cutover'
log "realm=$TARGET_REALM mode=$MODE clients=${CLIENTS[*]}$post_cutover_note"

# --- the realm: clients, default roles and groups, composite realm roles --------------------------
while IFS=, read -r id client_id sa_enabled; do
  [[ -n $id ]] || continue
  client_uuid[$client_id]=$id
  client_by_lower[${client_id,,}]=$id
  client_sa[$id]=$sa_enabled
done < <(csv clients id,clientId,serviceAccountsEnabled)
IFS=, read -r default_role_id default_role_name < <(
  kcadm get "realms/$TARGET_REALM" --fields 'defaultRole(id,name)' --format csv --noquotes | tr -d '\r'
) || true
default_groups=$(csv default-groups path)
while IFS=, read -r role_id role_name composite; do
  [[ -n $role_id && $composite == true ]] || continue
  realm_role_name[$role_id]=$role_name
  while IFS=, read -r child _; do
    [[ -n $child ]] || continue
    realm_parents[$child]+=" $role_id"
  done < <(csv "roles-by-id/$role_id/composites" id)
done < <(csv roles id,name,composite)

for client in "${CLIENTS[@]}"; do
  uuid=${client_uuid[$client]:-}
  if [[ -z $uuid ]]; then
    log "NOTE: client $client does not exist in realm $TARGET_REALM; skipped (nothing is made for it)"
    continue
  fi
  IFS=, read -r full_scope service_accounts < <(csv "clients/$uuid" fullScopeAllowed,serviceAccountsEnabled)
  log "$client: fullScopeAllowed=$full_scope serviceAccountsEnabled=$service_accounts"

  # --- 1. the roles -------------------------------------------------------------------------------
  role_ids=()
  planned=()
  while IFS=, read -r role_id role_name; do
    role_ids[$role_name]=$role_id
  done < <(csv "clients/$uuid/roles" id,name)
  wanted=("${CAPABILITY_ROLES[@]}")
  site_editor=false
  if is_site_editor "$client"; then
    site_editor=true
    wanted+=("$LEGACY_ROLE" "$ADMIN_ROLE")
  fi
  for role in "${wanted[@]}"; do
    if [[ -n ${role_ids[$role]:-} ]]; then
      log "$client: role $role exists"
      continue
    fi
    change "create client role $role on $client"
    if [[ $MODE == apply ]]; then
      kcadm_write create "clients/$uuid/roles" -r "$TARGET_REALM" \
        -s "name=$role" -s "description=${ROLE_DESCRIPTION[$role]}"
      role_ids[$role]=$(csv "clients/$uuid/roles" id,name | sed -n "s/^\([^,]*\),$role\$/\1/p")
      [[ -n ${role_ids[$role]} ]] || { printf 'role %s on %s was not created\n' "$role" "$client" >&2; exit 1; }
    else
      planned[$role]=1
    fi
  done

  # --- 2. cms:access includes content:read and content:write ------------------------------------
  legacy_id=${role_ids[$LEGACY_ROLE]:-}
  if [[ -z $legacy_id && -z ${planned[$LEGACY_ROLE]:-} ]]; then
    log "$client: no $LEGACY_ROLE role; none is made here (groups get content:read/content:write on $client directly)"
  else
    composites=''
    [[ -z $legacy_id ]] || composites=$(csv "roles-by-id/$legacy_id/composites" id,containerId,name)
    others=''
    while IFS=, read -r composite_id container_id composite_name; do
      [[ -n $composite_id ]] || continue
      if [[ $container_id == "$uuid" ]] && [[ $composite_name == content:read || $composite_name == content:write ]]; then
        continue
      fi
      others+="${others:+ }$composite_name"
    done <<<"$composites"
    [[ -z $others ]] || log "$client: $LEGACY_ROLE also includes (left as is): $others"
    for role in "${EDITOR_ROLES[@]}"; do
      if [[ -n $legacy_id && -n ${role_ids[$role]:-} ]] && grep -Eq "^${role_ids[$role]},$uuid," <<<"$composites"; then
        log "$client: $LEGACY_ROLE includes $role"
        continue
      fi
      change "make $client/$LEGACY_ROLE include $client/$role"
      if [[ $MODE == apply ]]; then
        kcadm_write create "roles-by-id/$legacy_id/composites" -r "$TARGET_REALM" \
          -b "$(role_body "${role_ids[$role]}" "$role")"
      fi
    done
  fi
  [[ $site_editor == true ]] || log "$client: no $ADMIN_ROLE here (team pages are not edited through $client)"

  # --- 3 and 4. who emits roles and groups ------------------------------------------------------
  # Every mapper that reaches this client's access tokens without a scope parameter: the client's
  # own and those of its default client scopes. Optional scopes only emit when a token requests
  # them; they are reported, not blocking. A mapper that does not write the access token cannot
  # collide with the claims inscribed reads and is only listed.
  own_roles_line=''
  own_groups_line=''
  own_name_clash=false
  foreign_roles=()
  good_groups=()
  bad_groups=()
  other_token=()
  optional_roles=()
  while IFS=, read -r m_id m_type m_claim m_full m_access m_idt m_userinfo m_introspection m_multi m_json m_client m_prefix m_name; do
    [[ -n $m_id ]] || continue
    line="$m_id,$m_type,$m_claim,$m_full,$m_access,$m_idt,$m_userinfo,$m_introspection,$m_multi,$m_json,$m_client,$m_prefix"
    if [[ $m_name == "$ROLES_MAPPER" || $m_name == "$GROUPS_MAPPER" ]]; then
      if [[ $m_name == "$ROLES_MAPPER" && $m_type == oidc-usermodel-client-role-mapper ]]; then
        own_roles_line=$line
      elif [[ $m_name == "$GROUPS_MAPPER" && $m_type == oidc-group-membership-mapper ]]; then
        own_groups_line=$line
      else
        problem "$client has a mapper named $m_name of type $m_type; rename or remove it by hand"
        own_name_clash=true
      fi
      continue
    fi
    scan_mapper "client mapper $m_name" "$m_type" "$m_claim" "$m_full" "$m_access"
  done < <(csv "clients/$uuid/protocol-mappers/models" "$MAPPER_FIELDS")
  while IFS=, read -r scope_id scope_name; do
    [[ -n $scope_id ]] || continue
    load_scope_mappers "$scope_id"
    while IFS=, read -r m_id m_type m_claim m_full m_access m_idt m_userinfo m_introspection m_multi m_json m_client m_prefix m_name; do
      [[ -n $m_id ]] || continue
      scan_mapper "default scope $scope_name mapper $m_name" "$m_type" "$m_claim" "$m_full" "$m_access"
    done <<<"${scope_mapper_lines[$scope_id]}"
  done < <(csv "clients/$uuid/default-client-scopes" id,name)
  while IFS=, read -r scope_id scope_name; do
    [[ -n $scope_id ]] || continue
    load_scope_mappers "$scope_id"
    while IFS=, read -r m_id m_type m_claim _; do
      [[ -n $m_id ]] || continue
      if claims_into "$m_claim" "$ROLES_CLAIM"; then
        optional_roles+=("$scope_name")
      fi
    done <<<"${scope_mapper_lines[$scope_id]}"
  done < <(csv "clients/$uuid/optional-client-scopes" id,name)
  [[ ${#other_token[@]} -eq 0 ]] || log "$client: not in the access token, left as is: ${other_token[*]}"

  # roles: only this script's mapper may write the claim.
  if [[ ${#foreign_roles[@]} -gt 0 ]]; then
    problem "$client: something else already emits the claim $ROLES_CLAIM (${foreign_roles[*]}); mapper $ROLES_MAPPER not added. Decide by hand which one inscribed should read"
  elif [[ $own_name_clash == false ]]; then
    [[ -n $own_roles_line ]] || log "$client: no mapper emits $ROLES_CLAIM"
    ensure_own_mapper "$client" "$uuid" roles "$own_roles_line"
  fi
  if [[ ${#optional_roles[@]} -gt 0 ]]; then
    warning "$client: optional scope(s) ${optional_roles[*]} also emit $ROLES_CLAIM when a token requests them"
  fi

  # groups: a full-path Group Membership mapper that reaches the access token is enough.
  if [[ ${#bad_groups[@]} -gt 0 ]]; then
    problem "$client: the claim $GROUPS_CLAIM is emitted differently from what inscribed reads (${bad_groups[*]}); not changed, other consumers may read it. Fix it by hand"
  elif [[ ${#good_groups[@]} -gt 0 ]]; then
    log "$client: $GROUPS_CLAIM (full path) comes from ${good_groups[*]}"
    if [[ -n $own_groups_line ]]; then
      change "remove the redundant mapper $GROUPS_MAPPER from $client"
      if [[ $MODE == apply ]]; then
        kcadm_write delete "clients/$uuid/protocol-mappers/models/${own_groups_line%%,*}" -r "$TARGET_REALM"
      fi
    fi
  elif [[ $own_name_clash == false ]]; then
    [[ -n $own_groups_line ]] || log "$client: no mapper emits $GROUPS_CLAIM in the access token"
    ensure_own_mapper "$client" "$uuid" groups "$own_groups_line"
  fi

  # --- 5. the service account ---------------------------------------------------------------------
  if [[ $service_accounts != true ]]; then
    log "$client: no service account (left disabled)"
  else
    IFS=, read -r sa_id sa_name < <(csv "clients/$uuid/service-account-user" id,username)
    [[ -n $sa_id ]] || { printf 'the service-account user of %s could not be resolved\n' "$client" >&2; exit 1; }
    direct=$(csv "users/$sa_id/role-mappings/clients/$uuid" id,name)
    effective=$(csv "users/$sa_id/role-mappings/clients/$uuid/composite" name | sort | paste -sd ' ' -)
    direct_names=$(cut -d, -f2 <<<"$direct" | sed '/^$/d' | sort | paste -sd ' ' -)
    log "$client: service account $sa_name holds (direct): ${direct_names:-none}"
    log "$client: service account $sa_name holds (effective): ${effective:-none}"
    sa_pending=false
    for role in "${SERVICE_ROLES[@]}"; do
      if grep -Eq "^[^,]+,$role\$" <<<"$direct"; then
        continue
      fi
      change "assign $client/$role to $sa_name"
      sa_pending=true
      if [[ $MODE == apply ]]; then
        kcadm_write create "users/$sa_id/role-mappings/clients/$uuid" -r "$TARGET_REALM" \
          -b "$(role_body "${role_ids[$role]}" "$role")"
      fi
    done
    legacy_direct_id=$(sed -n "s/^\([^,]*\),$LEGACY_ROLE\$/\1/p" <<<"$direct")
    if [[ -n $legacy_direct_id && $POST_CUTOVER == true ]]; then
      change "take $client/$LEGACY_ROLE (and so content:write) away from $sa_name (--post-cutover: inscribed serves /api/cms now)"
      sa_pending=true
      if [[ $MODE == apply ]]; then
        kcadm_write delete "users/$sa_id/role-mappings/clients/$uuid" -r "$TARGET_REALM" \
          -b "$(role_body "$legacy_direct_id" "$LEGACY_ROLE")"
      fi
    elif [[ -n $legacy_direct_id ]]; then
      log "$client: $sa_name holds $LEGACY_ROLE, so content:write through it: the old CMS renders the site with it until the cutover. On cutover night, after inscribed took over /api/cms, --post-cutover takes it away"
    fi
    if [[ $POST_CUTOVER == true ]]; then
      extras=''
      while IFS=, read -r _ direct_name; do
        [[ -n $direct_name && $direct_name != "$LEGACY_ROLE" && " ${SERVICE_ROLES[*]} " != *" $direct_name "* ]] || continue
        extras+="${extras:+ }$direct_name"
      done <<<"$direct"
      [[ -z $extras ]] || warning "$client: $sa_name also holds $extras directly; inscribed wants only ${SERVICE_ROLES[*]} on it. Take it away by hand"
      if [[ $MODE == apply || $sa_pending == false ]]; then
        effective=$(csv "users/$sa_id/role-mappings/clients/$uuid/composite" name | sort | paste -sd ' ' -)
        if [[ $effective == "${SERVICE_ROLES[*]}" ]]; then
          log "$client: service account $sa_name holds exactly: $effective"
        else
          warning "$client: service account $sa_name ends up with ${effective:-nothing} on $client, not exactly ${SERVICE_ROLES[*]}"
        fi
      fi
    fi
  fi

  # --- 6. who holds the CMS roles (read-only) -----------------------------------------------------
  report_holders "$client" "$uuid"
done

if [[ $MODE == apply ]]; then
  log "applied $changes change(s), $warnings warning(s), $problems problem(s)"
else
  log "check: $changes change(s) pending, $warnings warning(s), $problems problem(s)"
fi
if [[ $problems != 0 ]]; then
  log "$problems problem(s) need a manual decision (see PROBLEM lines above)"
  exit 1
fi
