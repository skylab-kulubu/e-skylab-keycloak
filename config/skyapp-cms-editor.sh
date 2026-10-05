#!/usr/bin/env bash
# Idempotent setup of SkyApp's CMS editing (ADR-0056, addendum of 2026-10-03; CONTEXT.md "Site
# editor"). SkyApp (public client skyapp) writes the main site's news and team pages straight to
# inscribed with the person's own token; no bridge, no inscribed change. inscribed's collections
# (news, teams) are not partitioned by tenant: any token with aud skycms and content:write in the
# flat roles claim may write them, and the collection's own rules (news: the Privileged groups;
# teams: the team's LIDERLER/KOORDINATORLER, any team with client:admin) decide per item. The
# site's pages (/cms/content) stay out of reach: skyapp is no registered inscribed client.
#
# Who may edit from SkyApp is exactly who may edit the main site: skyapp's CMS roles are never
# granted to a group or a person, they are composites of the main site's roles:
#   frontend-main/cms:access   includes skyapp/cms:access   (= skyapp/content:read + content:write)
#   frontend-main/client:admin includes skyapp/client:admin
# so a grant of frontend-main/cms:access in the SKY LAB admin panel is the one place that makes a
# Site editor, on the site and in the app. Both realms have frontend-main (the sandbox's since
# e-skylab-keycloak #65), so there is no other source: any other role that includes one of skyapp's
# four CMS roles is a PROBLEM (a link into another skyapp role is not this script's business).
#
# For skyapp it
#   1. creates the client roles content:read, content:write, cms:access (a composite of the first
#      two; SkyApp's editor buttons look for it in resource_access.skyapp.roles) and client:admin;
#   2. makes frontend-main's cms:access and client:admin include skyapp's;
#   3. attaches the realm scope skycms-audience (aud += skycms, inscribed checks it) as a default
#      client scope of skyapp;
#   4. adds the mapper inscribed-roles: skyapp's own roles, composites expanded, as the flat
#      multivalued claim roles, access token and introspection only (inscribed reads that claim);
#      another emitter of roles on skyapp or a default scope is a PROBLEM;
#   5. makes sure the access token carries groups as full paths (inscribed's teams and SkyApp read
#      them): a full-path Group Membership mapper on skyapp or a default scope is enough; a groups
#      claim of another shape is a PROBLEM (SkyApp reads it); none at all gets the client mapper
#      inscribed-groups;
#   6. reports who reaches skyapp's roles through frontend-main (groups, and the users and service
#      accounts that hold the role directly) and warns about any direct grant of skyapp's roles (to
#      a group or a person; take it away in the admin panel).
# Every PROBLEM (another emitter of roles or groups, a mapper name taken, another role that includes
# one of skyapp's CMS roles) is found before anything is written and stops the run like a missing
# prerequisite: nothing is written, exit 1. Fix it by hand (or --revoke, below) and run again.
# It never grants a role to a group or a person and never changes skyapp's flags, redirects,
# secrets or other scopes. --revoke (with --apply) takes away every link into skyapp's CMS roles from
# a role that is not one of them: frontend-main's two and any other client's or realm role's. From
# the next token refresh on nobody reaches skyapp's CMS roles through a composite (the roles and
# mappers stay, empty). A direct grant of a skyapp role is not touched and keeps working: --revoke
# reports it as a WARNING; take it away in the admin panel.
#
# It refuses every realm but e-skylab and e-skylab-sandbox before it logs in; KEYCLOAK_REALM has no
# default. Missing skyapp, skycms, skycms-audience (with an audience mapper to skycms) or
# frontend-main's cms:access/client:admin (config/inscribed-cms-roles.sh makes them) stop the run
# before anything is written (exit 1).
#
# Usage (inside the Keycloak image, as an operator):
#   KEYCLOAK_REALM=<realm> skyapp-cms-editor.sh --admin-user <admin>             # --check (default)
#   KEYCLOAK_REALM=<realm> skyapp-cms-editor.sh --admin-user <admin> --apply     # writes
#   KEYCLOAK_REALM=<realm> skyapp-cms-editor.sh --kcadm-config <file> [--apply] [--revoke]
#
# The administrator password is typed into kcadm's own prompt and never passes through this script.
# Environment: KEYCLOAK_ADMIN_URL (default http://keycloak:8080), KEYCLOAK_REALM (required),
# KEYCLOAK_ADMIN_REALM (default master), KEYCLOAK_SKYAPP_CMS_ADMIN_USERNAME (or --admin-user).
# Output: "[skyapp-cms] ..." lines, then "check: N change(s) pending, W warning(s), P problem(s)" or
# "applied N change(s), ..."; a PROBLEM or a missing prerequisite ends with "nothing was changed: ...".
# Exit 0 unless a PROBLEM or a missing prerequisite (1, nothing written) or a usage error or a
# refused realm (2). No token or secret is ever read.
set -Eeuo pipefail
shopt -s inherit_errexit

umask 077

KCADM=${KCADM_BIN:-/opt/keycloak/bin/kcadm.sh}
ADMIN_URL=${KEYCLOAK_ADMIN_URL:-http://keycloak:8080}
ADMIN_REALM=${KEYCLOAK_ADMIN_REALM:-master}
TARGET_REALM=${KEYCLOAK_REALM:-}
ADMIN_USER=${KEYCLOAK_SKYAPP_CMS_ADMIN_USERNAME:-}
KCADM_CONFIG=''
OWN_CONFIG=false
MODE=check
REVOKE=false
SOURCE_CLIENT=frontend-main

APP_CLIENT=skyapp
RESOURCE_CLIENT=skycms
AUDIENCE_SCOPE=skycms-audience
EDITOR_ROLE=cms:access
CAPABILITY_ROLES=(content:read content:write)
APP_ROLES=(content:read content:write cms:access client:admin)
LINKED_ROLES=(cms:access client:admin)
declare -A ROLE_DESCRIPTION=(
  [content:read]='inscribed: read collections from SkyApp (ADR-0056 addendum 2026-10-03). Never granted: reached through the main site'"'"'s cms:access'
  [content:write]='inscribed: write news and team pages from SkyApp (ADR-0056 addendum 2026-10-03). Never granted: reached through the main site'"'"'s cms:access'
  [cms:access]='Opens SkyApp'"'"'s CMS editing; includes content:read + content:write. Never granted: the main site'"'"'s cms:access includes it (ADR-0056 addendum 2026-10-03)'
  [client:admin]='inscribed: create and fix any team page from SkyApp. Never granted: the main site'"'"'s client:admin includes it (ADR-0056 addendum 2026-10-03)'
)
ROLES_CLAIM=roles
ROLES_MAPPER=inscribed-roles
GROUPS_CLAIM=groups
GROUPS_MAPPER=inscribed-groups
# Mapper CSV: the free-text name last, so a comma in it cannot shift the other columns.
MAPPER_FIELDS='id,protocolMapper,config(claim.name,full.path,access.token.claim,id.token.claim,userinfo.token.claim,introspection.token.claim,multivalued,jsonType.label,usermodel.clientRoleMapping.clientId,usermodel.clientRoleMapping.rolePrefix,included.client.audience),name'

usage() {
  printf 'usage: KEYCLOAK_REALM=(e-skylab|e-skylab-sandbox) %s (--admin-user <administrator> | --kcadm-config <file>) [--check | --apply] [--revoke]\n' \
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

if [[ $TARGET_REALM != e-skylab && $TARGET_REALM != e-skylab-sandbox ]]; then
  printf '[skyapp-cms] refusing realm %s: set KEYCLOAK_REALM to e-skylab (production) or e-skylab-sandbox; nothing was read or changed\n' \
    "${TARGET_REALM:-(unset)}" >&2
  exit 2
fi

if [[ -z $KCADM_CONFIG ]]; then
  if [[ -z $ADMIN_USER ]]; then
    if [[ -t 0 ]]; then
      read -r -p "Keycloak administrator username: " ADMIN_USER
    fi
    [[ -n $ADMIN_USER ]] || usage
  fi
  KCADM_CONFIG=$(mktemp /tmp/skyapp-cms-kcadm.XXXXXX)
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
  printf '[skyapp-cms] %s\n' "$1"
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

missing() {
  missing=$((missing + 1))
  log "MISSING: $1"
}

kcadm() {
  local command=$1
  shift
  "$KCADM" "$command" --config "$KCADM_CONFIG" "$@"
}

kcadm_write() {
  local stderr_file status
  stderr_file=$(mktemp /tmp/skyapp-cms-stderr.XXXXXX)
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

uuid_by() {
  csv clients id,clientId -q "clientId=$1" | while IFS=, read -r id client_id; do
    if [[ $client_id == "$1" ]]; then printf '%s\n' "$id"; fi
  done
}

role_body() {
  printf '[{"id":"%s","name":"%s"}]' "$1" "$2"
}

# role_id CLIENT_UUID ROLE: the id of the client role (empty when absent).
role_id() {
  csv "clients/$1/roles" id,name | sed -n "s/^\([^,]*\),$2\$/\1/p"
}

# includes PARENT_ROLE_ID CHILD_ROLE_ID: whether the composite PARENT includes CHILD directly.
includes() {
  csv "roles-by-id/$1/composites" id | grep -Fx "$2" >/dev/null
}

claims_into() {
  [[ $1 == "$2" || $1 == "$2".* ]]
}

mapper_body() {
  local kind=$1 id=${2:-} id_field=''
  [[ -z $id ]] || id_field="\"id\":\"$id\","
  case $kind in
    roles)
      printf '{%s"name":"%s","protocol":"openid-connect","protocolMapper":"oidc-usermodel-client-role-mapper","consentRequired":false,"config":{"usermodel.clientRoleMapping.clientId":"%s","usermodel.clientRoleMapping.rolePrefix":"","claim.name":"%s","jsonType.label":"String","multivalued":"true","access.token.claim":"true","id.token.claim":"false","userinfo.token.claim":"false","introspection.token.claim":"true","lightweight.claim":"false"}}' \
        "$id_field" "$ROLES_MAPPER" "$APP_CLIENT" "$ROLES_CLAIM"
      ;;
    groups)
      printf '{%s"name":"%s","protocol":"openid-connect","protocolMapper":"oidc-group-membership-mapper","consentRequired":false,"config":{"claim.name":"%s","full.path":"true","multivalued":"true","access.token.claim":"true","id.token.claim":"false","userinfo.token.claim":"false","introspection.token.claim":"true","lightweight.claim":"false"}}' \
        "$id_field" "$GROUPS_MAPPER" "$GROUPS_CLAIM"
      ;;
  esac
}

# expected_mapper_line KIND: the CSV columns after id that the mapper this script owns must have (the
# order of MAPPER_FIELDS, name excluded).
expected_mapper_line() {
  case $1 in
    roles) printf 'oidc-usermodel-client-role-mapper,%s,,true,false,false,true,true,String,%s,,' "$ROLES_CLAIM" "$APP_CLIENT" ;;
    groups) printf 'oidc-group-membership-mapper,%s,true,true,false,false,true,true,,,,' "$GROUPS_CLAIM" ;;
  esac
}

describe_mapper() {
  case $1 in
    roles) printf 'User Client Role: own client roles, composites expanded, flat multivalued claim %s, access token and introspection only' "$ROLES_CLAIM" ;;
    groups) printf 'Group Membership: claim %s, full path, access token and introspection only' "$GROUPS_CLAIM" ;;
  esac
}

ensure_own_mapper() {
  local kind=$1 live=$2 name expected mapper_id
  name=$ROLES_MAPPER
  [[ $kind == groups ]] && name=$GROUPS_MAPPER
  expected=$(expected_mapper_line "$kind")
  if [[ -z $live ]]; then
    change "add mapper $name to $APP_CLIENT ($(describe_mapper "$kind"))"
    if [[ $MODE == apply ]]; then
      kcadm_write create "clients/$app_uuid/protocol-mappers/models" -r "$TARGET_REALM" -b "$(mapper_body "$kind")"
    fi
    return 0
  fi
  mapper_id=${live%%,*}
  if [[ ${live#*,} == "$expected" ]]; then
    log "$APP_CLIENT: mapper $name unchanged"
    return 0
  fi
  change "repair mapper $name on $APP_CLIENT (${live#*,} -> $expected)"
  if [[ $MODE == apply ]]; then
    kcadm_write update "clients/$app_uuid/protocol-mappers/models/$mapper_id" -r "$TARGET_REALM" \
      -b "$(mapper_body "$kind" "$mapper_id")"
  fi
}

credential_arguments=(
  --config "$KCADM_CONFIG"
  --server "$ADMIN_URL"
  --realm "$ADMIN_REALM"
  --user "$ADMIN_USER"
)
if [[ $OWN_CONFIG == true ]]; then
  # No redirection: kcadm asks for the password only when stdout is a terminal.
  "$KCADM" config credentials "${credential_arguments[@]}"
fi
revoke_note=''
[[ $REVOKE != true ]] || revoke_note=' revoke'
log "realm=$TARGET_REALM mode=$MODE$revoke_note editors=$SOURCE_CLIENT"

if ! realm_name=$(kcadm get "realms/$TARGET_REALM" --fields realm --format csv --noquotes 2>/dev/null | tr -d '\r') \
  || [[ $realm_name != "$TARGET_REALM" ]]; then
  printf '[skyapp-cms] realm %s does not exist or cannot be read; nothing was changed\n' "$TARGET_REALM" >&2
  exit 1
fi

# --- 0. prerequisites, all read before anything is written ---------------------------------------
app_uuid=$(uuid_by "$APP_CLIENT")
source_uuid=$(uuid_by "$SOURCE_CLIENT")
[[ -n $app_uuid ]] || missing "client $APP_CLIENT does not exist in realm $TARGET_REALM"
[[ -n $(uuid_by "$RESOURCE_CLIENT") ]] || missing "client $RESOURCE_CLIENT (inscribed's audience) does not exist in realm $TARGET_REALM"
declare -A source_role=()
if [[ -z $source_uuid ]]; then
  missing "client $SOURCE_CLIENT (the editors' source) does not exist in realm $TARGET_REALM"
else
  for role in "${LINKED_ROLES[@]}"; do
    source_role[$role]=$(role_id "$source_uuid" "$role")
    [[ -n ${source_role[$role]} ]] \
      || missing "$SOURCE_CLIENT has no $role role; run inscribed-cms-roles.sh --client $SOURCE_CLIENT first"
  done
fi
audience_scope=''
while IFS=, read -r scope_id scope_name; do
  [[ $scope_name == "$AUDIENCE_SCOPE" ]] && audience_scope=$scope_id
done < <(csv client-scopes id,name)
if [[ -z $audience_scope ]]; then
  missing "client scope $AUDIENCE_SCOPE does not exist in realm $TARGET_REALM (site-clients.sh makes it)"
else
  audience_ok=false
  while IFS=, read -r _ m_type _ _ m_access _ _ _ _ _ _ _ m_audience _; do
    [[ $m_type == oidc-audience-mapper && $m_access == true && $m_audience == "$RESOURCE_CLIENT" ]] && audience_ok=true
  done < <(csv "client-scopes/$audience_scope/protocol-mappers/models" "$MAPPER_FIELDS")
  [[ $audience_ok == true ]] \
    || missing "client scope $AUDIENCE_SCOPE has no audience mapper that puts $RESOURCE_CLIENT into the access token"
fi
if [[ $missing != 0 ]]; then
  log "nothing was changed: $missing prerequisite(s) missing"
  exit 1
fi
IFS=, read -r public_client full_scope < <(csv "clients/$app_uuid" publicClient,fullScopeAllowed)
log "$APP_CLIENT: publicClient=$public_client fullScopeAllowed=$full_scope (left as is)"

# --- 1. read: skyapp's roles and every role that includes one of them -----------------------------
declare -A app_role=()
app_role_ids=' '
for role in "${APP_ROLES[@]}"; do
  app_role[$role]=$(role_id "$app_uuid" "$role")
  if [[ -n ${app_role[$role]} ]]; then
    log "$APP_CLIENT: role $role exists"
    app_role_ids+="${app_role[$role]} "
  fi
done

# composite_roles: "ID,LABEL" of every composite role of the realm (its realm roles and every
# client's roles); LABEL is "realm role NAME" or "CLIENT/NAME".
composite_roles() {
  local listing roles client_id client_name id composite name
  listing=$(csv roles id,composite,name -q max=100000)
  while IFS=, read -r id composite name; do
    if [[ $composite == true ]]; then printf '%s,realm role %s\n' "$id" "$name"; fi
  done <<<"$listing"
  listing=$(csv clients id,clientId -q max=100000)
  while IFS=, read -r client_id client_name; do
    [[ -n $client_id ]] || continue
    roles=$(csv "clients/$client_id/roles" id,composite,name -q max=100000)
    while IFS=, read -r id composite name; do
      if [[ $composite == true ]]; then printf '%s,%s/%s\n' "$id" "$client_name" "$name"; fi
    done <<<"$roles"
  done <<<"$listing"
}

# links: "PARENT_ID,CHILD_ID,CHILD_ROLE,PARENT_LABEL" for every role that directly includes one of
# skyapp's CMS roles (skyapp's own cms:access too). A link into another skyapp role is not this
# script's business: it is neither a PROBLEM nor taken away by --revoke. A failed read stops the run
# before any write.
links=()
if [[ $app_role_ids != ' ' ]]; then
  composites=$(composite_roles)
  while IFS=, read -r parent_id parent_label; do
    [[ -n $parent_id ]] || continue
    children=$(csv "roles-by-id/$parent_id/composites/clients/$app_uuid" id,name)
    while IFS=, read -r child_id child_name; do
      [[ -n $child_id && $app_role_ids == *" $child_id "* ]] || continue
      links+=("$parent_id,$child_id,$child_name,$parent_label")
    done <<<"$children"
  done <<<"$composites"
fi

# expected_link PARENT_ID CHILD_ROLE: whether PARENT including skyapp's CHILD_ROLE is a link this
# script makes (skyapp's cms:access includes content:*, frontend-main's two roles skyapp's).
expected_link() {
  case $2 in
    content:read | content:write) [[ $1 == "${app_role[$EDITOR_ROLE]:-}" ]] ;;
    *) [[ $1 == "${source_role[$2]:-}" ]] ;;
  esac
}

# link PARENT_ID PARENT_LABEL CHILD_ROLE: makes the composite PARENT include skyapp's CHILD_ROLE.
link() {
  local parent=$1 label=$2 child=$3
  if [[ -n ${app_role[$child]:-} ]] && includes "$parent" "${app_role[$child]}"; then
    log "$label includes $APP_CLIENT/$child"
    return 0
  fi
  change "make $label include $APP_CLIENT/$child"
  if [[ $MODE == apply ]]; then
    kcadm_write create "roles-by-id/$parent/composites" -r "$TARGET_REALM" -b "$(role_body "${app_role[$child]}" "$child")"
  fi
}

if [[ $REVOKE == true ]]; then
  # --- --revoke: every link into skyapp's CMS roles from a role that is not one of them goes -------
  taken=0
  for entry in "${links[@]}"; do
    IFS=, read -r parent_id child_id child_name parent_label <<<"$entry"
    [[ $app_role_ids != *" $parent_id "* ]] || continue
    taken=$((taken + 1))
    change "take $APP_CLIENT/$child_name out of $parent_label (nobody reaches it through $parent_label from the next token refresh on)"
    if [[ $MODE == apply ]]; then
      kcadm_write delete "roles-by-id/$parent_id/composites" -r "$TARGET_REALM" -b "$(role_body "$child_id" "$child_name")"
    fi
  done
  [[ $taken != 0 ]] || log "no other role includes one of $APP_CLIENT's CMS roles; nothing to take away"
else
  # --- PROBLEM checks: everything below is read before anything is written ------------------------
  for entry in "${links[@]}"; do
    IFS=, read -r parent_id _ child_name parent_label <<<"$entry"
    expected_link "$parent_id" "$child_name" \
      || problem "$parent_label includes $APP_CLIENT/$child_name: only $SOURCE_CLIENT/cms:access and $SOURCE_CLIENT/client:admin may lead to $APP_CLIENT's roles. Take the link away by hand, or run --revoke --apply (it takes away every such link, $SOURCE_CLIENT's two too) and then --apply"
  done

  # 4 and 5: who emits roles and groups (skycms-audience counted as the default scope it becomes).
  own_roles_line=''
  own_groups_line=''
  foreign_roles=()
  good_groups=()
  bad_groups=()
  optional_notes=()
  # scan WHERE TYPE CLAIM FULL_PATH ACCESS
  scan() {
    local where=$1 type=$2 claim=$3 full=$4 access=$5
    claims_into "$claim" "$ROLES_CLAIM" || claims_into "$claim" "$GROUPS_CLAIM" || return 0
    [[ $access == true ]] || return 0
    if claims_into "$claim" "$ROLES_CLAIM"; then
      foreign_roles+=("$where ($type)")
    elif [[ $type == oidc-group-membership-mapper && $claim == "$GROUPS_CLAIM" && $full == true ]]; then
      good_groups+=("$where")
    else
      bad_groups+=("$where ($type, claim $claim, full.path=${full:-unset})")
    fi
  }
  while IFS=, read -r m_id m_type m_claim m_full m_access m_idt m_userinfo m_introspection m_multi m_json m_client m_prefix m_audience m_name; do
    [[ -n $m_id ]] || continue
    line="$m_id,$m_type,$m_claim,$m_full,$m_access,$m_idt,$m_userinfo,$m_introspection,$m_multi,$m_json,$m_client,$m_prefix,$m_audience"
    if [[ $m_name == "$ROLES_MAPPER" || $m_name == "$GROUPS_MAPPER" ]]; then
      if [[ $m_name == "$ROLES_MAPPER" && $m_type == oidc-usermodel-client-role-mapper ]]; then
        own_roles_line=$line
      elif [[ $m_name == "$GROUPS_MAPPER" && $m_type == oidc-group-membership-mapper ]]; then
        own_groups_line=$line
      else
        problem "$APP_CLIENT has a mapper named $m_name of type $m_type; rename or remove it by hand"
      fi
      continue
    fi
    scan "client mapper $m_name" "$m_type" "$m_claim" "$m_full" "$m_access"
  done < <(csv "clients/$app_uuid/protocol-mappers/models" "$MAPPER_FIELDS")
  default_scopes=$(csv "clients/$app_uuid/default-client-scopes" id,name)
  audience_default=false
  if grep -Fx "$audience_scope,$AUDIENCE_SCOPE" <<<"$default_scopes" >/dev/null; then
    audience_default=true
  else
    default_scopes+=$'\n'"$audience_scope,$AUDIENCE_SCOPE"
  fi
  while IFS=, read -r scope_id scope_name; do
    [[ -n $scope_id ]] || continue
    while IFS=, read -r m_id m_type m_claim m_full m_access _ _ _ _ _ _ _ _ m_name; do
      [[ -n $m_id ]] || continue
      scan "default scope $scope_name mapper $m_name" "$m_type" "$m_claim" "$m_full" "$m_access"
    done < <(csv "client-scopes/$scope_id/protocol-mappers/models" "$MAPPER_FIELDS")
  done <<<"$default_scopes"
  while IFS=, read -r scope_id scope_name; do
    [[ -n $scope_id ]] || continue
    while IFS=, read -r m_id _ m_claim _; do
      [[ -n $m_id ]] || continue
      if claims_into "$m_claim" "$ROLES_CLAIM" || claims_into "$m_claim" "$GROUPS_CLAIM"; then
        optional_notes+=("$scope_name (claim $m_claim)")
      fi
    done < <(csv "client-scopes/$scope_id/protocol-mappers/models" "$MAPPER_FIELDS")
  done < <(csv "clients/$app_uuid/optional-client-scopes" id,name)
  [[ ${#optional_notes[@]} -eq 0 ]] \
    || log "NOTE: $APP_CLIENT: optional scope(s) ${optional_notes[*]} overwrite these claims when SkyApp requests them; SkyApp must not request them"
  [[ ${#foreign_roles[@]} -eq 0 ]] \
    || problem "$APP_CLIENT: something else already emits the claim $ROLES_CLAIM (${foreign_roles[*]}); decide by hand which one inscribed should read"
  [[ ${#bad_groups[@]} -eq 0 ]] \
    || problem "$APP_CLIENT: the claim $GROUPS_CLAIM is emitted differently from what inscribed and SkyApp read (${bad_groups[*]}); fix it by hand"
  if [[ $problems != 0 ]]; then
    log "nothing was changed: $problems problem(s); fix them by hand and run again"
    exit 1
  fi

  # --- 1. skyapp's roles -------------------------------------------------------------------------
  for role in "${APP_ROLES[@]}"; do
    [[ -z ${app_role[$role]} ]] || continue
    change "create client role $role on $APP_CLIENT"
    if [[ $MODE == apply ]]; then
      kcadm_write create "clients/$app_uuid/roles" -r "$TARGET_REALM" \
        -s "name=$role" -s "description=${ROLE_DESCRIPTION[$role]}"
      app_role[$role]=$(role_id "$app_uuid" "$role")
      [[ -n ${app_role[$role]} ]] || { printf 'role %s on %s was not created\n' "$role" "$APP_CLIENT" >&2; exit 1; }
    fi
  done

  # --- 2. composites: skyapp's cms:access, and frontend-main's roles include skyapp's -------------
  if [[ -n ${app_role[$EDITOR_ROLE]:-} ]]; then
    for role in "${CAPABILITY_ROLES[@]}"; do link "${app_role[$EDITOR_ROLE]}" "$APP_CLIENT/$EDITOR_ROLE" "$role"; done
  else
    for role in "${CAPABILITY_ROLES[@]}"; do change "make $APP_CLIENT/$EDITOR_ROLE include $APP_CLIENT/$role"; done
  fi
  for role in "${LINKED_ROLES[@]}"; do link "${source_role[$role]}" "$SOURCE_CLIENT/$role" "$role"; done

  # --- 3. aud skycms -------------------------------------------------------------------------------
  if [[ $audience_default == true ]]; then
    log "$APP_CLIENT: $AUDIENCE_SCOPE is a default scope (aud += $RESOURCE_CLIENT)"
  else
    if csv "clients/$app_uuid/optional-client-scopes" name | grep -Fx "$AUDIENCE_SCOPE" >/dev/null; then
      change "detach the optional scope $AUDIENCE_SCOPE from $APP_CLIENT (it becomes a default scope)"
      if [[ $MODE == apply ]]; then
        kcadm_write delete "clients/$app_uuid/optional-client-scopes/$audience_scope" -r "$TARGET_REALM"
      fi
    fi
    change "attach $AUDIENCE_SCOPE as a default scope of $APP_CLIENT (aud += $RESOURCE_CLIENT in every skyapp access token)"
    if [[ $MODE == apply ]]; then
      kcadm_write update "clients/$app_uuid/default-client-scopes/$audience_scope" -r "$TARGET_REALM" -n -b '{}'
    fi
  fi

  # --- 4 and 5. the mappers ------------------------------------------------------------------------
  ensure_own_mapper roles "$own_roles_line"
  if [[ ${#good_groups[@]} -gt 0 ]]; then
    log "$APP_CLIENT: $GROUPS_CLAIM (full path) comes from ${good_groups[*]}"
    if [[ -n $own_groups_line ]]; then
      change "remove the redundant mapper $GROUPS_MAPPER from $APP_CLIENT"
      if [[ $MODE == apply ]]; then
        kcadm_write delete "clients/$app_uuid/protocol-mappers/models/${own_groups_line%%,*}" -r "$TARGET_REALM"
      fi
    fi
  else
    ensure_own_mapper groups "$own_groups_line"
  fi
fi

# --- 6. report (read-only) -------------------------------------------------------------------------
# is_service_account USER_ID USERNAME: whether the user is the service-account user of the client its
# name points to (the name alone proves nothing).
is_service_account() {
  local owner account
  [[ $2 == service-account-* ]] || return 1
  owner=$(uuid_by "${2#service-account-}")
  [[ -n $owner ]] || return 1
  account=$(csv "clients/$owner/service-account-user" id 2>/dev/null) || return 1
  [[ $account == "$1" ]]
}

for role in "${APP_ROLES[@]}"; do
  [[ -n ${app_role[$role]:-} ]] || continue
  holders=$(csv "clients/$app_uuid/roles/$role/groups" path -q max=100000 | sort | paste -sd ' ' -)
  people=$(csv "clients/$app_uuid/roles/$role/users" username -q max=100000 | paste -sd ' ' -)
  if [[ $REVOKE == true ]]; then
    [[ -z $holders ]] || warning "$APP_CLIENT/$role is still granted directly to the group(s) $holders: --revoke does not take a direct grant away, they keep $APP_CLIENT/$role; take it away in the SKY LAB admin panel"
    [[ -z $people ]] || warning "$APP_CLIENT/$role is still granted directly to user(s) $people: --revoke does not take a direct grant away, they keep $APP_CLIENT/$role; take it away in the SKY LAB admin panel"
  else
    [[ -z $holders ]] || warning "$APP_CLIENT/$role is granted directly to the group(s) $holders: grant $SOURCE_CLIENT/${role/content:*/cms:access} instead and take this grant away in the SKY LAB admin panel"
    [[ -z $people ]] || warning "$APP_CLIENT/$role is granted directly to user(s) $people: take it away; SkyApp editors come from $SOURCE_CLIENT/cms:access"
  fi
done
for role in "${LINKED_ROLES[@]}"; do
  reach="(and so $APP_CLIENT/$role)"
  [[ $REVOKE != true ]] || reach="(no longer reaches $APP_CLIENT)"
  holders=$(csv "clients/$source_uuid/roles/$role/groups" path -q max=100000 | sort | paste -sd ' ' -)
  log "$SOURCE_CLIENT/$role <- ${holders:-no group} $reach"
  direct=$(csv "clients/$source_uuid/roles/$role/users" id,username -q max=100000 | sort -t, -k2)
  direct_people=()
  direct_accounts=()
  while IFS=, read -r user_id username; do
    [[ -n $user_id ]] || continue
    if is_service_account "$user_id" "$username"; then direct_accounts+=("$username"); else direct_people+=("$username"); fi
  done <<<"$direct"
  log "$SOURCE_CLIENT/$role <- directly ${#direct_people[@]} user(s)${direct_people[*]:+ (${direct_people[*]})}, ${#direct_accounts[@]} service account(s)${direct_accounts[*]:+ (${direct_accounts[*]})} $reach"
done

if [[ $MODE == apply ]]; then
  log "applied $changes change(s), $warnings warning(s), $problems problem(s)"
else
  log "check: $changes change(s) pending, $warnings warning(s), $problems problem(s)"
fi
if [[ $problems != 0 ]]; then
  exit 1
fi
