#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s inherit_errexit

umask 077

KCADM=${KCADM_BIN:-/opt/keycloak/bin/kcadm.sh}
JAVA_BIN=${JAVA_BIN:-java}
KEYCLOAK_LIB_DIR=${KEYCLOAK_LIB_DIR:-/opt/keycloak/lib/lib/main}
CONFIG_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ADMIN_URL=${KEYCLOAK_ADMIN_URL:-http://keycloak:8080}
TARGET_REALM=${KEYCLOAK_REALM:-e-skylab}
BASE_URL=${ACCOUNT_CENTER_BASE_URL:-https://my.yildizskylab.com}
REQUIRE_PRODUCTION_HOST=${ACCOUNT_CENTER_REQUIRE_PRODUCTION_HOST:-false}
CONFIG_CLIENT_ID=${KEYCLOAK_CONFIG_CLIENT_ID:-account-center-config}
PASSKEY_RP_ID=${KEYCLOAK_PASSKEY_RP_ID:-yildizskylab.com}
PASSKEY_EXTRA_ORIGINS=${KEYCLOAK_PASSKEY_EXTRA_ORIGINS:-https://my.yildizskylab.com}
# Realm attribute that records (ISO-8601 UTC) when the passwordless relying party id last
# changed; cleanup-legacy-passkeys.sh uses it as the cutover and refuses a later one.
PASSKEY_SWITCH_ATTRIBUTE=skylab.passkeyRpIdSwitchedAt
CLIENT_ID=account-center
# The retired client-specific browser flow of the native handoff (ADR-0048); removed on sight.
LEGACY_FLOW_ALIAS=account-center-browser
SCOPE_NAME=account-center-account-api
CORE_SCOPE_NAME=account-center-core-claims
SKYAPP_CLIENT_ID=skyapp
SKYAPP_SCOPE_NAME=skyapp-account-center-audience
# Login clients whose access token must name the API they call in aud (made by hand in
# production first, adopted here by name; see reconcile_login_client_audience).
FRONTEND_MAIN_CLIENT_ID=frontend-main
FRONTEND_MAIN_SCOPE_NAME=frontend-main-core-audience
FRONTEND_ARGE_CLIENT_ID=frontend-arge
FRONTEND_ARGE_SCOPE_NAME=frontend-arge-core-audience
SKYFORMS_CLIENT_ID=skyforms
SKYFORMS_SCOPE_NAME=skyforms-forms-audience
# Event retention (account erasure ticket 09). Keycloak deletes no event with the person core's
# erasure saga removes: CREATE and UPDATE admin events hold the whole user representation
# (e-mail, names, school and personal e-mail), DELETE holds the username, LOGIN and LOGIN_ERROR
# user events hold the typed address, and admin events without an expiration are kept forever.
# Both stores therefore expire after 30 days, the period KVKK (Law 6698, art. 13) gives for
# concluding an erasure request. Admin event details stay on: they are the audit trail of who
# changed what (Yusuf's choice, 2026-09-26). Listeners and enabled event types are not managed.
EVENT_RETENTION_SECONDS=2592000
EVENT_RETENTION_SETTINGS="{\"eventsEnabled\":true,\"eventsExpiration\":$EVENT_RETENTION_SECONDS,\"adminEventsEnabled\":true,\"adminEventsDetailsEnabled\":true}"
# The admin event expiration is a realm attribute (seconds), read by Keycloak's scheduled task.
ADMIN_EVENTS_EXPIRATION_ATTRIBUTE=adminEventsExpiration
ACCOUNT_ROLE_ALLOWLIST=(manage-account view-profile manage-account-links)
KCADM_CONFIG=$(mktemp /tmp/account-center-kcadm.XXXXXX)
WORK_DIR=$(mktemp -d /tmp/account-center-reconcile.XXXXXX)
JSON_TOOL_CLASSPATH=''
ENSURED_SCOPE_ID=''
ACCOUNT_CENTER_UUID=''
PASSKEY_EXTRA_ORIGIN_LIST=()

# shellcheck source=account-center-origin.sh
source "$CONFIG_DIR/account-center-origin.sh"
# shellcheck source=mailer-client-contract.sh
source "$CONFIG_DIR/mailer-client-contract.sh"
# shellcheck source=erasure-client-contract.sh
source "$CONFIG_DIR/erasure-client-contract.sh"

cleanup() {
  rm -f "$KCADM_CONFIG"
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

log() {
  printf '[reconcile] %s\n' "$1"
}

warn() {
  printf '[reconcile] WARNING: %s\n' "$1" >&2
}

require() {
  local variable_name=$1
  if [[ -z ${!variable_name:-} ]]; then
    printf 'Missing required environment variable: %s\n' "$variable_name" >&2
    exit 1
  fi
}

require KEYCLOAK_CONFIG_CLIENT_SECRET

BASE_URL=$(normalize_account_center_base_url \
  "$BASE_URL" \
  "$REQUIRE_PRODUCTION_HOST")

kcadm() {
  local command=$1
  shift
  "$KCADM" "$command" --config "$KCADM_CONFIG" "$@"
}

authenticate() {
  local attempt
  for attempt in $(seq 1 60); do
    if "$KCADM" config credentials \
      --config "$KCADM_CONFIG" \
      --server "$ADMIN_URL" \
      --realm "$TARGET_REALM" \
      --client "$CONFIG_CLIENT_ID" \
      --secret "$KEYCLOAK_CONFIG_CLIENT_SECRET" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  printf 'Keycloak did not become ready for reconciliation\n' >&2
  return 1
}

# The Keycloak image has no jq. ReconcileJson.java is compiled once per run with the JDK
# that ships in the image and gives every comparison real JSON semantics.
compile_json_tool() {
  local jackson_jars=("$KEYCLOAK_LIB_DIR"/com.fasterxml.jackson.core.jackson-*.jar)
  local classpath jar
  if [[ ! -f ${jackson_jars[0]} ]]; then
    printf 'Jackson libraries were not found under %s\n' "$KEYCLOAK_LIB_DIR" >&2
    return 1
  fi
  classpath=''
  for jar in "${jackson_jars[@]}"; do
    classpath="$classpath$jar:"
  done
  mkdir -p "$WORK_DIR/classes"
  "$JAVA_BIN" -XX:TieredStopAtLevel=1 -XX:+UseSerialGC \
    -m jdk.compiler/com.sun.tools.javac.Main \
    -d "$WORK_DIR/classes" \
    -cp "$classpath" \
    "$CONFIG_DIR/ReconcileJson.java" >/dev/null
  JSON_TOOL_CLASSPATH="$WORK_DIR/classes:$classpath"
}

json_tool() {
  "$JAVA_BIN" -XX:TieredStopAtLevel=1 -XX:+UseSerialGC \
    -cp "$JSON_TOOL_CLASSPATH" ReconcileJson "$@"
}

# kcadm prints informational lines on stderr ("Created new model with id ...", an empty line
# for every JSON read). Keep the reconcile log to its own lines while still surfacing the
# diagnostics of a failed call.
kcadm_quiet() {
  local stderr_file status
  stderr_file=$(mktemp "$WORK_DIR/stderr.XXXXXX")
  if kcadm "$@" 2>"$stderr_file" >/dev/null; then
    status=0
  else
    status=$?
  fi
  if [[ $status != 0 ]]; then
    cat "$stderr_file" >&2
  fi
  rm -f "$stderr_file"
  return "$status"
}

kcadm_json() {
  local stderr_file status
  stderr_file=$(mktemp "$WORK_DIR/stderr.XXXXXX")
  if kcadm get "$@" 2>"$stderr_file"; then
    status=0
  else
    status=$?
  fi
  if [[ $status != 0 ]]; then
    cat "$stderr_file" >&2
  fi
  rm -f "$stderr_file"
  return "$status"
}

client_id_by_client_id() {
  local wanted=$1
  local clients_csv id client_id
  if ! clients_csv=$(kcadm get clients -r "$TARGET_REALM" \
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

flow_id_by_alias() {
  local wanted=$1
  local flows_csv id alias
  if ! flows_csv=$(kcadm get authentication/flows -r "$TARGET_REALM" \
    --fields id,alias \
    --format csv \
    --noquotes); then
    printf 'Failed to read authentication flows while looking up %s\n' "$wanted" >&2
    return 2
  fi
  while IFS=, read -r id alias; do
    if [[ $alias == "$wanted" ]]; then
      printf '%s\n' "$id"
      return 0
    fi
  done <<<"$flows_csv"
  return 1
}

client_scope_id_by_name() {
  local wanted=$1
  local scopes_csv id name
  if ! scopes_csv=$(kcadm get client-scopes -r "$TARGET_REALM" \
    --fields id,name \
    --format csv \
    --noquotes); then
    printf 'Failed to read client scopes while looking up %s\n' "$wanted" >&2
    return 2
  fi
  while IFS=, read -r id name; do
    if [[ $name == "$wanted" ]]; then
      printf '%s\n' "$id"
      return 0
    fi
  done <<<"$scopes_csv"
  return 1
}

client_role_id_by_name() {
  local client_id=$1
  local wanted=$2
  local roles_csv id name
  if ! roles_csv=$(kcadm get "clients/$client_id/roles" -r "$TARGET_REALM" \
    --fields id,name \
    --format csv \
    --noquotes); then
    printf 'Failed to read client roles while looking up %s\n' "$wanted" >&2
    return 2
  fi
  while IFS=, read -r id name; do
    if [[ $name == "$wanted" ]]; then
      printf '%s\n' "$id"
      return 0
    fi
  done <<<"$roles_csv"
  return 1
}

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

# account-center signs in through the realm's own browser flow. The retired native handoff
# needed a client-specific copy of it (account-center-browser, with the sky-native-handoff
# subflow) bound to the client; the Web handoff (ADR-0048) does not. An older deployment is
# brought back here: the client's browser binding is removed, then that flow is deleted
# together with its subflows. Both steps are no-ops once done. Keycloak does not refuse to
# delete a flow that something still points to, so a realm flow binding or another client
# that still uses it stops the run instead.
retire_account_center_browser_flow() {
  local live_file overrides flow_id realm_bindings clients_json
  live_file=$(mktemp "$WORK_DIR/client-flow.XXXXXX")
  kcadm_json "clients/$ACCOUNT_CENTER_UUID" -r "$TARGET_REALM" >"$live_file"
  overrides=$(json_tool field authenticationFlowBindingOverrides <"$live_file")
  if [[ $overrides =~ \"browser\"[[:space:]]*:[[:space:]]*\"[^\"]+\" ]]; then
    kcadm update "clients/$ACCOUNT_CENTER_UUID" -r "$TARGET_REALM" \
      -s 'authenticationFlowBindingOverrides.browser=' >/dev/null
    log "client $CLIENT_ID browser flow binding: updated (removed; the realm browser flow applies)"
  else
    log "client $CLIENT_ID browser flow binding: unchanged (the realm browser flow applies)"
  fi

  if flow_id=$(optional_lookup flow_id_by_alias "$LEGACY_FLOW_ALIAS"); then
    :
  else
    return $?
  fi
  if [[ -z $flow_id ]]; then
    log "authentication flow $LEGACY_FLOW_ALIAS: unchanged (absent)"
    return 0
  fi
  realm_bindings=$(kcadm_json "realms/$TARGET_REALM" -c \
    --fields browserFlow,registrationFlow,directGrantFlow,resetCredentialsFlow,clientAuthenticationFlow,dockerAuthenticationFlow,firstBrokerLoginFlow)
  if [[ $realm_bindings == *"\"$LEGACY_FLOW_ALIAS\""* ]]; then
    printf 'A realm flow binding still uses %s; bind the realm to its own flows before this flow can be retired\n' \
      "$LEGACY_FLOW_ALIAS" >&2
    return 1
  fi
  clients_json=$(kcadm_json clients -r "$TARGET_REALM" --fields clientId,authenticationFlowBindingOverrides -c)
  if [[ $clients_json == *"$flow_id"* ]]; then
    printf 'Another client is still bound to %s; unbind it before this flow can be retired\n' \
      "$LEGACY_FLOW_ALIAS" >&2
    return 1
  fi
  kcadm delete "authentication/flows/$flow_id" -r "$TARGET_REALM" >/dev/null
  log "authentication flow $LEGACY_FLOW_ALIAS: deleted (with its retired native handoff subflow)"
}

# Reads ENDPOINT, compares the desired fields against it and writes only when at least one
# differs. Objects compare as subsets and arrays as multisets, so an unchanged realm, client
# or client scope produces no admin event. Extra arguments (for example "-r realm") are
# passed to both kcadm calls.
apply_fields_if_changed() {
  local label=$1
  local desired_file=$2
  local endpoint=$3
  shift 3
  local live_file changed
  live_file=$(mktemp "$WORK_DIR/live.XXXXXX")
  kcadm_json "$endpoint" "$@" >"$live_file"
  changed=$(json_tool diff-fields "$desired_file" <"$live_file")
  if [[ -z $changed ]]; then
    log "$label: unchanged"
    return 0
  fi
  kcadm update "$endpoint" "$@" -n -f "$desired_file" >/dev/null
  log "$label: updated ($(tr '\n' ' ' <<<"$changed" | sed 's/ $//'))"
}

reconcile_realm_settings() {
  apply_fields_if_changed 'realm session, login and theme settings' \
    "$CONFIG_DIR/account-center-realm.json" "realms/$TARGET_REALM"
}

reconcile_brute_force_and_password_policy() {
  local login_csv
  apply_fields_if_changed 'brute force protection and password policy' \
    "$CONFIG_DIR/account-center-realm-security.json" "realms/$TARGET_REALM"
  # Username changes go through the sky-account extension; Account REST must not be able to
  # edit the username, and both e-mail addresses of a person sign in through the SKY LAB
  # authenticator, which requires unique e-mails.
  login_csv=$(kcadm get "realms/$TARGET_REALM" \
    --fields editUsernameAllowed,loginWithEmailAllowed,duplicateEmailsAllowed \
    --format csv \
    --noquotes)
  if [[ $login_csv != 'false,true,false' ]]; then
    printf 'Realm login settings differ from editUsernameAllowed=false, loginWithEmailAllowed=true, duplicateEmailsAllowed=false: %s\n' "$login_csv" >&2
    return 1
  fi
  log 'login settings asserted: editUsernameAllowed=false loginWithEmailAllowed=true duplicateEmailsAllowed=false'
}

# User and admin event retention (EVENT_RETENTION_* above). The four settings are fields of the
# realm; the admin event expiration is a realm attribute and is sent with the complete live
# attribute map (Keycloak drops every attribute a PUT with "attributes" leaves out). Both go in one
# PUT, and only when one of them differs, so an unchanged realm produces no admin event. The
# realm PUT needs manage-realm, which the reconciler identity holds; Keycloak's events/config
# endpoint (manage-events) is not used. Listeners and enabled event types are never sent.
reconcile_event_retention() {
  local desired_file="$WORK_DIR/event-retention.json" live_file="$WORK_DIR/event-retention-live.json"
  local attribute_file="$WORK_DIR/event-retention-attribute.json" write_file="$WORK_DIR/event-retention-write.json"
  local label="realm event retention (user and admin events ${EVENT_RETENTION_SECONDS} s, admin event details on)"
  local changed
  printf '%s\n' "$EVENT_RETENTION_SETTINGS" >"$desired_file"
  printf '{"attributes":{"%s":"%s"}}\n' "$ADMIN_EVENTS_EXPIRATION_ATTRIBUTE" "$EVENT_RETENTION_SECONDS" \
    >"$attribute_file"
  kcadm_json "realms/$TARGET_REALM" >"$live_file"
  changed=$(json_tool diff-fields "$desired_file" <"$live_file")
  if [[ -n $(json_tool diff-fields "$attribute_file" <"$live_file") ]]; then
    json_tool realm-attribute "$ADMIN_EVENTS_EXPIRATION_ATTRIBUTE" "$EVENT_RETENTION_SECONDS" \
      <"$live_file" >"$attribute_file"
    json_tool merge "$desired_file" "$attribute_file" >"$write_file"
    changed=$(printf '%s\nattributes.%s' "$changed" "$ADMIN_EVENTS_EXPIRATION_ATTRIBUTE")
  elif [[ -n $changed ]]; then
    cp "$desired_file" "$write_file"
  else
    log "$label: unchanged"
    return 0
  fi
  kcadm update "realms/$TARGET_REALM" -n -f "$write_file" >/dev/null
  log "$label: updated ($(sed '/^$/d' <<<"$changed" | tr '\n' ' ' | sed 's/ $//'))"
}

validate_passkey_policy_inputs() {
  local origin host configured_origins
  if [[ ! $PASSKEY_RP_ID =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$ ]]; then
    printf 'KEYCLOAK_PASSKEY_RP_ID must be a lowercase DNS name without scheme, port or path\n' >&2
    return 1
  fi
  if [[ $REQUIRE_PRODUCTION_HOST == true && $PASSKEY_RP_ID != yildizskylab.com ]]; then
    printf 'Production KEYCLOAK_PASSKEY_RP_ID must be exactly yildizskylab.com\n' >&2
    return 1
  fi
  PASSKEY_EXTRA_ORIGIN_LIST=()
  IFS=',' read -ra configured_origins <<<"$PASSKEY_EXTRA_ORIGINS"
  for origin in ${configured_origins[@]+"${configured_origins[@]}"}; do
    origin=${origin//[[:space:]]/}
    [[ -n $origin ]] || continue
    if [[ ! $origin =~ ^(https?)://([a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*)(:[0-9]{1,5})?$ ]]; then
      printf 'KEYCLOAK_PASSKEY_EXTRA_ORIGINS entries must be plain origins (scheme://host[:port]): %s\n' "$origin" >&2
      return 1
    fi
    host=${BASH_REMATCH[2]}
    if [[ $host != "$PASSKEY_RP_ID" && $host != *".$PASSKEY_RP_ID" ]]; then
      printf 'Passkey extra origin %s is not within the relying party id %s\n' "$origin" "$PASSKEY_RP_ID" >&2
      return 1
    fi
    if [[ $REQUIRE_PRODUCTION_HOST == true && ${BASH_REMATCH[1]} != https ]]; then
      printf 'Production passkey extra origins must use https: %s\n' "$origin" >&2
      return 1
    fi
    PASSKEY_EXTRA_ORIGIN_LIST+=("$origin")
  done
  if [[ ${#PASSKEY_EXTRA_ORIGIN_LIST[@]} == 0 ]]; then
    printf 'KEYCLOAK_PASSKEY_EXTRA_ORIGINS must name at least the Account Center origin\n' >&2
    return 1
  fi
}

# The relying party id makes one passkey valid on every SKY LAB origin (e., my., WebViews);
# the extra origins let Account Center run WebAuthn ceremonies against this realm policy.
# Keycloak rebuilds the whole passwordless policy from one realm update (defaults for every
# field the update leaves out), so the complete policy is declared in one document:
# account-center-passkey-policy.json plus the environment-derived rpId and extra origins.
# The two-factor WebAuthn policy (webAuthnPolicy*) is deliberately left unmanaged. Realm PUTs
# that carry no "attributes" map (this one and the realm settings above) make Keycloak reset
# the CIBA and PAR lifespans to their defaults; SKY LAB uses neither beyond the defaults.
#
# Every passkey registered before a relying party id change stops verifying, so the moment of
# a change is recorded in the realm attribute skylab.passkeyRpIdSwitchedAt before the policy
# is written: cleanup-legacy-passkeys.sh takes it as the cutover and refuses a later one. The
# attribute is written through the complete live "attributes" map because Keycloak drops every
# realm attribute that a PUT with "attributes" leaves out. Writing it first keeps a failed run
# repairable: the next run still sees the old relying party id and records the moment again.
reconcile_passkey_policy() {
  local desired_file="$WORK_DIR/passkey-policy.json" extra_file="$WORK_DIR/passkey-extra.json"
  local live_file="$WORK_DIR/passkey-live.json" switch_file="$WORK_DIR/passkey-switch.json"
  local origins_json='' origin live_rp_id switched_at
  validate_passkey_policy_inputs
  for origin in "${PASSKEY_EXTRA_ORIGIN_LIST[@]}"; do
    origins_json="$origins_json,\"$origin\""
  done
  origins_json="[${origins_json#,}]"
  printf '{"webAuthnPolicyPasswordlessRpId":"%s","webAuthnPolicyPasswordlessExtraOrigins":%s}\n' \
    "$PASSKEY_RP_ID" "$origins_json" >"$extra_file"
  json_tool merge "$CONFIG_DIR/account-center-passkey-policy.json" "$extra_file" >"$desired_file"
  kcadm_json "realms/$TARGET_REALM" >"$live_file"
  live_rp_id=$(json_tool field webAuthnPolicyPasswordlessRpId <"$live_file")
  if [[ $live_rp_id != "$PASSKEY_RP_ID" ]]; then
    switched_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    json_tool realm-attribute "$PASSKEY_SWITCH_ATTRIBUTE" "$switched_at" <"$live_file" >"$switch_file"
    kcadm update "realms/$TARGET_REALM" -n -f "$switch_file" >/dev/null
    log "passkey relying party id switches from '${live_rp_id:-(empty)}' to '$PASSKEY_RP_ID': realm attribute $PASSKEY_SWITCH_ATTRIBUTE=$switched_at recorded; passkeys registered before it stop verifying (cleanup-legacy-passkeys.sh)"
  fi
  apply_fields_if_changed "passwordless passkey policy (rpId=$PASSKEY_RP_ID extraOrigins=$origins_json)" \
    "$desired_file" "realms/$TARGET_REALM"
}

reconcile_required_actions() {
  local actions_csv alias enabled default_action updated=''
  actions_csv=$(kcadm get authentication/required-actions -r "$TARGET_REALM" \
    --fields alias,enabled,defaultAction \
    --format csv \
    --noquotes)
  while IFS='|' read -r alias enabled default_action; do
    [[ -n $alias ]] || continue
    if grep -Fxq "$alias,$enabled,$default_action" <<<"$actions_csv"; then
      continue
    fi
    kcadm update "authentication/required-actions/$alias" \
      -r "$TARGET_REALM" \
      -s "enabled=$enabled" \
      -s "defaultAction=$default_action" >/dev/null
    updated="$updated $alias"
  done <"$CONFIG_DIR/account-center-required-actions.tsv"
  if [[ -z $updated ]]; then
    log 'required actions: unchanged'
  else
    log "required actions: updated (${updated# })"
  fi
}

# The User Profile keeps its live shape (groups, annotations, requirements, message keys).
# It only gains the SKY LAB attributes the sky-account extension writes at model level, makes
# firstName, lastName and email user:view-only and never leaves unmanaged attributes
# editable by the person.
reconcile_user_profile() {
  local live_file="$WORK_DIR/user-profile.json" desired_file="$WORK_DIR/user-profile.desired.json"
  local status policy
  kcadm_json users/profile -r "$TARGET_REALM" >"$live_file"
  if json_tool user-profile "$CONFIG_DIR/account-center-user-profile.json" \
    <"$live_file" >"$desired_file"; then
    log 'user profile: unchanged'
  else
    status=$?
    if [[ $status != 3 ]]; then
      printf 'User Profile merge failed with status %s\n' "$status" >&2
      return 1
    fi
    kcadm update users/profile -r "$TARGET_REALM" -n -f "$desired_file" >/dev/null
    log 'user profile: updated (SKY LAB attributes, user:view-only identity fields, unmanagedAttributePolicy=ADMIN_VIEW)'
  fi
  policy=$(kcadm get users/profile -r "$TARGET_REALM" \
    --fields unmanagedAttributePolicy \
    --format csv \
    --noquotes)
  if [[ $policy != ADMIN_VIEW ]]; then
    printf 'User Profile unmanagedAttributePolicy is %s instead of ADMIN_VIEW\n' "${policy:-unset}" >&2
    return 1
  fi
}

prune_protocol_mappers() {
  local scope_id=$1
  shift
  local mappers_csv id name allowed_name
  local seen_names='|'
  local keep pruned=''
  if ! mappers_csv=$(kcadm get "client-scopes/$scope_id/protocol-mappers/models" \
    -r "$TARGET_REALM" \
    --fields id,name \
    --format csv \
    --noquotes); then
    printf 'Failed to read protocol mappers for client scope %s\n' "$scope_id" >&2
    return 2
  fi
  while IFS=, read -r id name; do
    [[ -n $id ]] || continue
    keep=false
    for allowed_name in "$@"; do
      if [[ $name == "$allowed_name" && $seen_names != *"|$name|"* ]]; then
        seen_names="$seen_names$name|"
        keep=true
        break
      fi
    done
    if [[ $keep == true ]]; then
      continue
    fi
    kcadm delete "client-scopes/$scope_id/protocol-mappers/models/$id" \
      -r "$TARGET_REALM" >/dev/null
    pruned="$pruned $name"
  done <<<"$mappers_csv"
  if [[ -n $pruned ]]; then
    log "pruned protocol mappers from scope $scope_id:${pruned}"
  fi
}

# Creates missing mappers and rewrites drifted ones; mappers that already match the desired
# body are left alone so an unchanged scope produces no admin event.
ensure_protocol_mappers() {
  local scope_id=$1
  local desired_file=$2
  local live_file="$WORK_DIR/mappers-$scope_id.json" plan action mapper_id name body changed=''
  if ! kcadm_json "client-scopes/$scope_id/protocol-mappers/models" \
    -r "$TARGET_REALM" >"$live_file"; then
    printf 'Failed to read protocol mappers for client scope %s\n' "$scope_id" >&2
    return 2
  fi
  plan=$(json_tool mapper-diff "$desired_file" <"$live_file")
  [[ -n $plan ]] || return 0
  while IFS=$'\t' read -r action mapper_id name body; do
    [[ -n $action ]] || continue
    case $action in
      create)
        kcadm_quiet create "client-scopes/$scope_id/protocol-mappers/models" \
          -r "$TARGET_REALM" \
          -b "$body"
        changed="$changed +$name"
        ;;
      update)
        kcadm_quiet update "client-scopes/$scope_id/protocol-mappers/models/$mapper_id" \
          -r "$TARGET_REALM" \
          -n \
          -b "$body"
        changed="$changed ~$name"
        ;;
      *)
        printf 'Unexpected mapper plan entry: %s\n' "$action" >&2
        return 1
        ;;
    esac
  done <<<"$plan"
  log "protocol mappers of scope $scope_id: updated (${changed# })"
}

# Ensures one source-controlled client scope: attributes, allowlisted mappers, nothing else.
# Leaves the scope id in ENSURED_SCOPE_ID (stdout carries the log lines).
ensure_client_scope() {
  local scope_name=$1
  local mappers_file=$2
  local scope_id desired_file="$WORK_DIR/scope-$scope_name.json" allowed_names
  printf '{"name":"%s","protocol":"openid-connect","attributes":{"include.in.token.scope":"false","display.on.consent.screen":"false"}}\n' \
    "$scope_name" >"$desired_file"
  scope_id=$(optional_lookup client_scope_id_by_name "$scope_name")
  if [[ -z $scope_id ]]; then
    scope_id=$(kcadm create client-scopes -r "$TARGET_REALM" -i -f "$desired_file")
    log "client scope $scope_name: created"
  fi
  apply_fields_if_changed "client scope $scope_name" "$desired_file" \
    "client-scopes/$scope_id" -r "$TARGET_REALM"
  allowed_names=$(json_tool names <"$mappers_file")
  [[ -n $allowed_names ]] || {
    printf 'No protocol mappers are declared in %s\n' "$mappers_file" >&2
    return 1
  }
  # shellcheck disable=SC2086
  prune_protocol_mappers "$scope_id" $allowed_names
  ensure_protocol_mappers "$scope_id" "$mappers_file"
  ENSURED_SCOPE_ID=$scope_id
}

ensure_default_client_scope() {
  local client_uuid=$1
  local scope_id=$2
  local scope_name=$3
  local default_scopes
  default_scopes=$(kcadm get "clients/$client_uuid/default-client-scopes" \
    -r "$TARGET_REALM" \
    --fields id,name \
    --format csv \
    --noquotes)
  if ! grep -Eq "^$scope_id," <<<"$default_scopes"; then
    kcadm update "clients/$client_uuid/default-client-scopes/$scope_id" \
      -r "$TARGET_REALM" \
      -n \
      -b '{}' >/dev/null
    log "default client scope $scope_name attached to client $client_uuid"
  fi
}

ensure_account_center_client() {
  ACCOUNT_CENTER_UUID=$(optional_lookup client_id_by_client_id "$CLIENT_ID")
  if [[ -z $ACCOUNT_CENTER_UUID ]]; then
    ACCOUNT_CENTER_UUID=$(kcadm create clients -r "$TARGET_REALM" -i \
      -s "clientId=$CLIENT_ID" \
      -s name='SKY LAB Account Center' \
      -s enabled=true \
      -s protocol=openid-connect \
      -s publicClient=false \
      -s bearerOnly=false)
    log "client $CLIENT_ID: created"
  fi
}

# fullScopeAllowed stays false: Keycloak Admin REST authorizes a bearer token through
# AdminAuth.hasAppRole = user.hasRole(role) && client.hasScope(role), and client.hasScope is
# true for every role once full scope is on, so a my. token of a person holding
# realm-management roles would be a valid Admin REST credential. The sky_authorization
# permissions view is therefore produced by the sky-authorization-mapper of the SPI, which
# reads the person's effective client roles itself instead of going through the client scope.
# The integration harness proves that a token of a view-users holder gets 403 from Admin REST.
reconcile_account_center_client() {
  local desired_file="$WORK_DIR/client-$CLIENT_ID.json"
  local callback_uri="$BASE_URL/api/auth/callback"
  local logout_uri="$BASE_URL/api/auth/logout/callback"
  local backchannel_logout_uri="$BASE_URL/api/auth/backchannel-logout"
  cat >"$desired_file" <<EOF
{
  "clientId": "$CLIENT_ID",
  "name": "SKY LAB Account Center",
  "enabled": true,
  "protocol": "openid-connect",
  "clientAuthenticatorType": "client-secret",
  "publicClient": false,
  "bearerOnly": false,
  "standardFlowEnabled": true,
  "implicitFlowEnabled": false,
  "directAccessGrantsEnabled": false,
  "serviceAccountsEnabled": false,
  "authorizationServicesEnabled": false,
  "consentRequired": false,
  "frontchannelLogout": false,
  "fullScopeAllowed": false,
  "rootUrl": "$BASE_URL",
  "baseUrl": "$BASE_URL/",
  "adminUrl": "$BASE_URL",
  "redirectUris": ["$callback_uri"],
  "webOrigins": [],
  "attributes": {
    "pkce.code.challenge.method": "S256",
    "require.pushed.authorization.requests": "true",
    "backchannel.logout.url": "$backchannel_logout_uri",
    "backchannel.logout.session.required": "true",
    "backchannel.logout.revoke.offline.tokens": "true",
    "post.logout.redirect.uris": "$logout_uri"
  }
}
EOF
  apply_fields_if_changed "client $CLIENT_ID" "$desired_file" \
    "clients/$ACCOUNT_CENTER_UUID" -r "$TARGET_REALM"
}

reconcile_account_center_client_scopes() {
  local scope_uuid=$1
  local core_scope_uuid=$2
  local default_scopes optional_scopes default_scope_id default_scope_name
  local optional_scope_id optional_scope_name required_default_scope_id
  default_scopes=$(kcadm get "clients/$ACCOUNT_CENTER_UUID/default-client-scopes" \
    -r "$TARGET_REALM" \
    --fields id,name \
    --format csv \
    --noquotes)
  while IFS=, read -r default_scope_id default_scope_name; do
    [[ -n $default_scope_id ]] || continue
    if [[ $default_scope_id != "$scope_uuid" && $default_scope_id != "$core_scope_uuid" ]]; then
      kcadm delete "clients/$ACCOUNT_CENTER_UUID/default-client-scopes/$default_scope_id" \
        -r "$TARGET_REALM" >/dev/null
      log "client $CLIENT_ID: detached default scope $default_scope_name"
    fi
  done <<<"$default_scopes"
  for required_default_scope_id in "$scope_uuid" "$core_scope_uuid"; do
    if ! grep -Eq "^$required_default_scope_id," <<<"$default_scopes"; then
      kcadm update "clients/$ACCOUNT_CENTER_UUID/default-client-scopes/$required_default_scope_id" \
        -r "$TARGET_REALM" \
        -n \
        -b '{}' >/dev/null
      log "client $CLIENT_ID: attached default scope $required_default_scope_id"
    fi
  done

  optional_scopes=$(kcadm get "clients/$ACCOUNT_CENTER_UUID/optional-client-scopes" \
    -r "$TARGET_REALM" \
    --fields id,name \
    --format csv \
    --noquotes)
  while IFS=, read -r optional_scope_id optional_scope_name; do
    [[ -n $optional_scope_id ]] || continue
    kcadm delete "clients/$ACCOUNT_CENTER_UUID/optional-client-scopes/$optional_scope_id" \
      -r "$TARGET_REALM" >/dev/null
    log "client $CLIENT_ID: detached optional scope $optional_scope_name"
  done <<<"$optional_scopes"
}

# Client scope mappings for the built-in account client. manage-account-links is required
# because the idp_link application-initiated action checks client.hasScope() in addition to
# the token roles; the hardcoded role mapper alone does not satisfy that check.
reconcile_account_scope_mappings() {
  local account_client_uuid assigned_account_roles assigned_role_id assigned_role_name
  local role_name role_uuid keep allowed changed=''
  account_client_uuid=$(optional_lookup client_id_by_client_id account)
  if [[ -z $account_client_uuid ]]; then
    printf 'Built-in account client was not found\n' >&2
    exit 1
  fi
  assigned_account_roles=$(kcadm get \
    "clients/$ACCOUNT_CENTER_UUID/scope-mappings/clients/$account_client_uuid" \
    -r "$TARGET_REALM" \
    --fields id,name \
    --format csv \
    --noquotes)
  while IFS=, read -r assigned_role_id assigned_role_name; do
    [[ -n $assigned_role_id ]] || continue
    keep=false
    for allowed in "${ACCOUNT_ROLE_ALLOWLIST[@]}"; do
      [[ $assigned_role_name == "$allowed" ]] && keep=true
    done
    if [[ $keep == false ]]; then
      kcadm delete "clients/$ACCOUNT_CENTER_UUID/scope-mappings/clients/$account_client_uuid" \
        -r "$TARGET_REALM" \
        -b "[{\"id\":\"$assigned_role_id\",\"name\":\"$assigned_role_name\"}]" >/dev/null
      changed="$changed -$assigned_role_name"
    fi
  done <<<"$assigned_account_roles"
  for role_name in "${ACCOUNT_ROLE_ALLOWLIST[@]}"; do
    role_uuid=$(optional_lookup client_role_id_by_name "$account_client_uuid" "$role_name")
    if [[ -z $role_uuid ]]; then
      printf 'Built-in account role was not found: %s\n' "$role_name" >&2
      exit 1
    fi
    if ! grep -Eq "^[^,]+,$role_name$" <<<"$assigned_account_roles"; then
      kcadm create "clients/$ACCOUNT_CENTER_UUID/scope-mappings/clients/$account_client_uuid" \
        -r "$TARGET_REALM" \
        -b "[{\"id\":\"$role_uuid\",\"name\":\"$role_name\"}]" >/dev/null
      changed="$changed +$role_name"
    fi
  done
  if [[ -z $changed ]]; then
    log "account role scope mappings of $CLIENT_ID: unchanged (${ACCOUNT_ROLE_ALLOWLIST[*]})"
  else
    log "account role scope mappings of $CLIENT_ID: updated (${changed# })"
  fi
}

reconcile_skyapp_audience() {
  local skyapp_client_uuid skyapp_scope_uuid
  skyapp_client_uuid=$(optional_lookup client_id_by_client_id "$SKYAPP_CLIENT_ID")
  if [[ -z $skyapp_client_uuid ]]; then
    printf 'Required client was not found: %s\n' "$SKYAPP_CLIENT_ID" >&2
    exit 1
  fi
  ensure_client_scope "$SKYAPP_SCOPE_NAME" \
    "$CONFIG_DIR/skyapp-account-center-audience-mappers.json"
  skyapp_scope_uuid=$ENSURED_SCOPE_ID
  ensure_default_client_scope "$skyapp_client_uuid" "$skyapp_scope_uuid" "$SKYAPP_SCOPE_NAME"
}

# A login client whose access token must carry the audience of the API it calls, for every
# person: Keycloak's audience-resolve adds an API only when the token carries that API's roles,
# and most people hold none. frontend-main (the site) needs core (core requires it on every
# Bearer, ADR 0019: the site's upload bridge forwards the editor's token to core /v1/media, and
# without it every CMS image upload is 401); frontend-arge (arge) needs core for the same reason
# once its CMS uploads go through core with the move to inscribed (ADR-0056); skyforms needs forms
# (forms-backend requires it: without it members get 401). The scopes were made by hand in
# production with these exact names, so they are adopted by name (never recreated), repaired when
# they drift and kept among the client's default scopes. A realm without the client (the sandbox
# has neither site client) skips the item with a warning.
reconcile_login_client_audience() {
  local client_id=$1 scope_name=$2 mappers_file=$3
  local client_uuid scope_uuid optional_scopes
  if ! client_uuid=$(optional_lookup client_id_by_client_id "$client_id"); then
    return 2
  fi
  if [[ -z $client_uuid ]]; then
    warn "client $client_id does not exist in realm $TARGET_REALM; skipped client scope $scope_name"
    return 0
  fi
  ensure_client_scope "$scope_name" "$mappers_file"
  scope_uuid=$ENSURED_SCOPE_ID
  # Keycloak keeps one link per client and scope, so an optional link would block the default one.
  optional_scopes=$(kcadm get "clients/$client_uuid/optional-client-scopes" \
    -r "$TARGET_REALM" \
    --fields id,name \
    --format csv \
    --noquotes)
  if grep -Eq "^$scope_uuid," <<<"$optional_scopes"; then
    kcadm delete "clients/$client_uuid/optional-client-scopes/$scope_uuid" \
      -r "$TARGET_REALM" >/dev/null
    log "client $client_id: detached optional scope $scope_name (it must be a default scope)"
  fi
  ensure_default_client_scope "$client_uuid" "$scope_uuid" "$scope_name"
}

# The keycloak-mailer service-account client (K5) is provisioned by the operator with
# create-mailer-client.sh because assigning its SkyMail roles needs user permissions the
# reconciler identity deliberately lacks. Here the client is verified only: a missing client
# or roles the reconciler cannot read produce a warning with the command to run, wrong flags
# or a missing roles scope fail the run (the fix is the same command).
verify_mailer_client() {
  local mailer_uuid live_flags skymail_uuid service_user_id assigned expected scope_roles
  if ! mailer_uuid=$(optional_lookup client_id_by_client_id "$MAILER_CLIENT_ID"); then
    return 2
  fi
  if [[ -z $mailer_uuid ]]; then
    warn "client $MAILER_CLIENT_ID does not exist; run: $MAILER_CREATE_COMMAND"
    return 0
  fi
  live_flags=$(mailer_client_flags "$mailer_uuid")
  if [[ $live_flags != "$MAILER_FLAG_VALUES" ]]; then
    printf 'Client %s drifted (%s: %s, expected %s); run: %s\n' \
      "$MAILER_CLIENT_ID" "$MAILER_FLAG_FIELDS" "$live_flags" "$MAILER_FLAG_VALUES" \
      "$MAILER_CREATE_COMMAND" >&2
    return 1
  fi
  if [[ -z $(mailer_roles_scope_attached "$mailer_uuid") ]]; then
    printf 'Client %s lacks the roles default scope; run: %s\n' \
      "$MAILER_CLIENT_ID" "$MAILER_CREATE_COMMAND" >&2
    return 1
  fi
  log "client $MAILER_CLIENT_ID: verified (confidential service account, $MAILER_FLAG_FIELDS=$MAILER_FLAG_VALUES, roles scope attached)"
  skymail_uuid=$(optional_lookup client_id_by_client_id "$SKYMAIL_CLIENT_ID")
  if [[ -z $skymail_uuid ]]; then
    warn "client $SKYMAIL_CLIENT_ID does not exist; $MAILER_CLIENT_ID cannot hold SkyMail roles yet; run after SkyMail exists: $MAILER_CREATE_COMMAND"
    return 0
  fi
  expected=$(mailer_expected_roles)
  scope_roles=$(mailer_scope_mapping_roles "$mailer_uuid" "$skymail_uuid")
  if [[ $scope_roles != "$expected" ]]; then
    warn "scope mappings of $MAILER_CLIENT_ID are '${scope_roles:-none}' instead of '$expected'; run: $MAILER_CREATE_COMMAND"
  fi
  service_user_id=$(kcadm get "clients/$mailer_uuid/service-account-user" \
    -r "$TARGET_REALM" \
    --fields id \
    --format csv \
    --noquotes)
  if [[ -z $service_user_id || $service_user_id == *,* ]]; then
    warn "the $MAILER_CLIENT_ID service-account user could not be resolved; run: $MAILER_CREATE_COMMAND"
    return 0
  fi
  if ! assigned=$(mailer_service_account_roles "$service_user_id" "$skymail_uuid" 2>/dev/null); then
    warn "service-account roles of $MAILER_CLIENT_ID are not readable with the reconciler identity (no user permissions); expected '$expected', verify with an administrator: $MAILER_CREATE_COMMAND"
    return 0
  fi
  if [[ $assigned == "$expected" ]]; then
    log "service-account roles of $MAILER_CLIENT_ID: verified ($expected)"
  else
    warn "service-account roles of $MAILER_CLIENT_ID are '${assigned:-none}' instead of '$expected'; run: $MAILER_CREATE_COMMAND"
  fi
}

# The core-erasure service-account client (account erasure, ADR-0051) is provisioned by the
# operator with create-erasure-client.sh, for the same reason as keycloak-mailer: its service
# account holds the erase roles, and assigning them needs user permissions. Here it is verified
# only, and everything that keeps one service's erase role out of another service's token is
# security state: wrong flags, a scope list other than the contract, a direct scope mapping, an
# erase scope with another mapper or another role, or a missing resource client fail the run
# (the fix is the operator command). A missing client and roles the reconciler cannot read are
# warnings.
verify_erasure_client() {
  local client_uuid live expected drift='' i scope_uuid resource_uuid service_user_id assigned
  local resource_arguments=() mismatched=''
  if ! client_uuid=$(optional_lookup erasure_client_uuid "$ERASURE_CLIENT_ID"); then
    return 2
  fi
  if [[ -z $client_uuid ]]; then
    warn "client $ERASURE_CLIENT_ID does not exist; run: $ERASURE_CREATE_COMMAND"
    return 0
  fi
  live=$(erasure_client_flags "$client_uuid")
  [[ $live == "$ERASURE_FLAG_VALUES" ]] \
    || drift+="; $ERASURE_FLAG_FIELDS: $live, expected $ERASURE_FLAG_VALUES"
  live=$(erasure_client_scopes "$client_uuid" default)
  expected=$(erasure_expected_default_scopes)
  [[ $live == "$expected" ]] || drift+="; default scopes: ${live:-none}, expected $expected"
  live=$(erasure_client_scopes "$client_uuid" optional)
  expected=$(erasure_expected_optional_scopes)
  [[ $live == "$expected" ]] || drift+="; optional scopes: ${live:-none}, expected $expected"
  for i in "${!ERASURE_SERVICES[@]}"; do
    if ! resource_uuid=$(optional_lookup erasure_client_uuid "${ERASURE_RESOURCE_CLIENTS[$i]}"); then
      return 2
    fi
    if [[ -z $resource_uuid ]]; then
      drift+="; resource client ${ERASURE_RESOURCE_CLIENTS[$i]} does not exist"
      continue
    fi
    resource_arguments+=("$resource_uuid" "${ERASURE_RESOURCE_CLIENTS[$i]}")
  done
  live=$(erasure_role_mappings "clients/$client_uuid/scope-mappings" "${resource_arguments[@]}")
  [[ -z $live ]] || drift+="; direct scope mappings $(paste -sd, - <<<"$live") (every token would carry them)"
  for i in "${!ERASURE_SERVICES[@]}"; do
    if ! scope_uuid=$(optional_lookup erasure_scope_uuid "${ERASURE_SCOPES[$i]}"); then
      return 2
    fi
    if [[ -z $scope_uuid ]]; then
      drift+="; scope ${ERASURE_SCOPES[$i]} does not exist"
      continue
    fi
    [[ $(erasure_scope_protocol "$scope_uuid") == openid-connect ]] \
      || drift+="; scope ${ERASURE_SCOPES[$i]} is not openid-connect"
    live=$(erasure_scope_mappers "$scope_uuid")
    [[ $live == "$(erasure_expected_mapper "$i")" ]] \
      || drift+="; mappers of ${ERASURE_SCOPES[$i]}: $(paste -sd' ' - <<<"${live:-none}"), expected $(erasure_expected_mapper "$i")"
    live=$(erasure_role_mappings "client-scopes/$scope_uuid/scope-mappings" "${resource_arguments[@]}")
    expected="${ERASURE_RESOURCE_CLIENTS[$i]}:${ERASURE_ROLES[$i]}"
    [[ $live == "$expected" ]] \
      || drift+="; roles of ${ERASURE_SCOPES[$i]}: $(paste -sd, - <<<"${live:-none}"), expected $expected"
  done
  if [[ -n $drift ]]; then
    printf 'Client %s drifted (%s); run: %s\n' "$ERASURE_CLIENT_ID" "${drift#; }" "$ERASURE_CREATE_COMMAND" >&2
    return 1
  fi
  log "client $ERASURE_CLIENT_ID: verified (confidential service account, $ERASURE_FLAG_FIELDS=$ERASURE_FLAG_VALUES, default scopes $(erasure_expected_default_scopes), optional scopes $(erasure_expected_optional_scopes), no direct scope mappings)"
  for i in "${!ERASURE_SERVICES[@]}"; do
    log "erase scope ${ERASURE_SCOPES[$i]}: verified (aud ${ERASURE_RESOURCE_CLIENTS[$i]}, role ${ERASURE_RESOURCE_CLIENTS[$i]}/${ERASURE_ROLES[$i]})"
  done
  service_user_id=$(kcadm get "clients/$client_uuid/service-account-user" \
    -r "$TARGET_REALM" \
    --fields id \
    --format csv \
    --noquotes)
  if [[ -z $service_user_id || $service_user_id == *,* ]]; then
    warn "the $ERASURE_CLIENT_ID service-account user could not be resolved; run: $ERASURE_CREATE_COMMAND"
    return 0
  fi
  for i in "${!ERASURE_SERVICES[@]}"; do
    resource_uuid=${resource_arguments[$((i * 2))]}
    if ! assigned=$(kcadm get "users/$service_user_id/role-mappings/clients/$resource_uuid" \
      -r "$TARGET_REALM" --fields name --format csv --noquotes 2>/dev/null); then
      warn "service-account roles of $ERASURE_CLIENT_ID are not readable with the reconciler identity (no user permissions); expected exactly one erase role per resource client, verify with an administrator: $ERASURE_CREATE_COMMAND (without --apply)"
      return 0
    fi
    [[ $(sed '/^$/d' <<<"$assigned" | paste -sd, -) == "${ERASURE_ROLES[$i]}" ]] \
      || mismatched+=" ${ERASURE_RESOURCE_CLIENTS[$i]}"
  done
  if [[ -z $mismatched ]]; then
    log "service-account roles of $ERASURE_CLIENT_ID: verified (one erase role per resource client)"
  else
    warn "service-account roles of $ERASURE_CLIENT_ID differ on${mismatched}; run: $ERASURE_CREATE_COMMAND"
  fi
}

authenticate
kcadm_json "realms/$TARGET_REALM" >/dev/null
compile_json_tool

reconcile_realm_settings
reconcile_brute_force_and_password_policy
reconcile_event_retention
reconcile_passkey_policy
reconcile_required_actions
reconcile_user_profile

ensure_account_center_client
retire_account_center_browser_flow
reconcile_account_center_client

ensure_client_scope "$SCOPE_NAME" \
  "$CONFIG_DIR/account-center-account-api-mappers.json"
scope_uuid=$ENSURED_SCOPE_ID
ensure_client_scope "$CORE_SCOPE_NAME" \
  "$CONFIG_DIR/account-center-core-claims-mappers.json"
core_scope_uuid=$ENSURED_SCOPE_ID
reconcile_skyapp_audience
reconcile_login_client_audience "$FRONTEND_MAIN_CLIENT_ID" "$FRONTEND_MAIN_SCOPE_NAME" \
  "$CONFIG_DIR/frontend-main-core-audience-mappers.json"
reconcile_login_client_audience "$FRONTEND_ARGE_CLIENT_ID" "$FRONTEND_ARGE_SCOPE_NAME" \
  "$CONFIG_DIR/frontend-arge-core-audience-mappers.json"
reconcile_login_client_audience "$SKYFORMS_CLIENT_ID" "$SKYFORMS_SCOPE_NAME" \
  "$CONFIG_DIR/skyforms-forms-audience-mappers.json"
reconcile_account_center_client_scopes "$scope_uuid" "$core_scope_uuid"
reconcile_account_scope_mappings
verify_mailer_client
verify_erasure_client

printf 'Account Center Keycloak configuration is reconciled.\n'
