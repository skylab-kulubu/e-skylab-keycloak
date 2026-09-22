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
FLOW_ALIAS=account-center-browser
NATIVE_FLOW_ALIAS=account-center-native-handoff
SCOPE_NAME=account-center-account-api
CORE_SCOPE_NAME=account-center-core-claims
SKYAPP_CLIENT_ID=skyapp
SKYAPP_SCOPE_NAME=skyapp-account-center-audience
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

realm_browser_flow_alias() {
  local realm_csv browser_flow
  if ! realm_csv=$(kcadm get "realms/$TARGET_REALM" \
    --fields browserFlow \
    --format csv \
    --noquotes); then
    printf 'Failed to read the active browser flow for realm %s\n' "$TARGET_REALM" >&2
    return 2
  fi
  while IFS= read -r browser_flow; do
    if [[ -n $browser_flow ]]; then
      printf '%s\n' "$browser_flow"
      return 0
    fi
  done <<<"$realm_csv"
  printf 'Realm %s does not have an active browser flow\n' "$TARGET_REALM" >&2
  return 1
}

urlencode_path_segment() {
  local input=$1 output='' character encoded index
  local LC_ALL=C
  for ((index = 0; index < ${#input}; index++)); do
    character=${input:index:1}
    case $character in
      [a-zA-Z0-9.~_-])
        output+=$character
        ;;
      *)
        printf -v encoded '%02X' "'$character"
        output+="%$encoded"
        ;;
    esac
  done
  printf '%s\n' "$output"
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

authentication_config_signature() {
  local provider_id=$1
  local config_id=$2
  local config_json

  if [[ -z $config_id ]]; then
    printf 'NONE\n'
    return 0
  fi
  if [[ $provider_id != conditional-credential ]]; then
    printf 'CONFIGURED\n'
    return 0
  fi

  if ! config_json=$(kcadm_json "authentication/config/$config_id" \
    -r "$TARGET_REALM" -c); then
    printf 'Failed to read authentication configuration %s\n' "$config_id" >&2
    return 2
  fi
  if [[ $config_json == *'"config":{"credentials":"webauthn-passwordless"}'* ]]; then
    printf 'BUILTIN_PASSWORDLESS\n'
  else
    printf 'DRIFTED\n'
  fi
}

flow_graph_signature() {
  local alias=$1
  local executions_csv encoded_alias
  local level priority requirement provider_id authentication_flow authentication_config
  local kind config_state
  encoded_alias=$(urlencode_path_segment "$alias")
  if ! executions_csv=$(kcadm get "authentication/flows/$encoded_alias/executions" \
    -r "$TARGET_REALM" \
    --fields level,priority,requirement,providerId,authenticationFlow,authenticationConfig \
    --format csv \
    --noquotes); then
    printf 'Failed to read authentication flow executions for %s\n' "$alias" >&2
    return 2
  fi
  while IFS=, read -r level priority requirement provider_id authentication_flow authentication_config; do
    [[ -n $level ]] || continue
    if [[ $authentication_flow == true ]]; then
      kind=FLOW
    else
      kind=$provider_id
    fi
    if ! config_state=$(authentication_config_signature \
      "$provider_id" "$authentication_config"); then
      printf 'Failed to read authentication configuration for %s\n' "$provider_id" >&2
      return 2
    fi
    printf '%s|%s|%s|%s|%s\n' \
      "$level" "$priority" "$requirement" "$kind" "$config_state"
  done <<<"$executions_csv"
}

account_center_source_graph_signature() {
  local alias=$1
  local executions_csv encoded_alias
  local level priority requirement display_name provider_id authentication_flow authentication_config
  local kind config_state native_flow_count=0 native_execution_count=0
  encoded_alias=$(urlencode_path_segment "$alias")
  if ! executions_csv=$(kcadm get "authentication/flows/$encoded_alias/executions" \
    -r "$TARGET_REALM" \
    --fields level,priority,requirement,displayName,providerId,authenticationFlow,authenticationConfig \
    --format csv \
    --noquotes); then
    printf 'Failed to read authentication flow executions for %s\n' "$alias" >&2
    return 2
  fi
  while IFS=, read -r level priority requirement display_name provider_id authentication_flow authentication_config; do
    [[ -n $level ]] || continue
    if [[ $authentication_flow == true && $display_name == "$NATIVE_FLOW_ALIAS" ]]; then
      native_flow_count=$((native_flow_count + 1))
      if [[ $level != 0 || $priority != 5 || $requirement != ALTERNATIVE ]]; then
        printf 'The %s subflow contract differs from desired state\n' "$NATIVE_FLOW_ALIAS" >&2
        return 1
      fi
      continue
    fi
    if [[ $authentication_flow != true && $provider_id == sky-native-handoff ]]; then
      native_execution_count=$((native_execution_count + 1))
      if [[ $level != 1 || $priority != 10 || $requirement != REQUIRED ]]; then
        printf 'The sky-native-handoff execution contract differs from desired state\n' >&2
        return 1
      fi
      continue
    fi
    if [[ $authentication_flow == true ]]; then
      kind=FLOW
    else
      kind=$provider_id
    fi
    if ! config_state=$(authentication_config_signature \
      "$provider_id" "$authentication_config"); then
      printf 'Failed to read authentication configuration for %s\n' "$provider_id" >&2
      return 2
    fi
    printf '%s|%s|%s|%s|%s\n' \
      "$level" "$priority" "$requirement" "$kind" "$config_state"
  done <<<"$executions_csv"
  if [[ $native_flow_count != 1 || $native_execution_count != 1 ]]; then
    printf 'Expected exactly one native handoff subflow and execution; observed %s and %s\n' \
      "$native_flow_count" "$native_execution_count" >&2
    return 1
  fi
}

add_native_handoff_execution() {
  local alias=$1
  local executions_csv native_flow_execution_id native_execution_id
  local id level display_name provider_id authentication_flow

  kcadm create "authentication/flows/$alias/executions/flow" \
    -r "$TARGET_REALM" \
    -b "{\"alias\":\"$NATIVE_FLOW_ALIAS\",\"type\":\"basic-flow\",\"provider\":\"basic-flow\",\"priority\":5,\"description\":\"Redeems one-time Account Center native handoff codes\"}" >/dev/null

  kcadm create "authentication/flows/$NATIVE_FLOW_ALIAS/executions/execution" \
    -r "$TARGET_REALM" \
    -b '{"provider":"sky-native-handoff","priority":10}' >/dev/null

  if ! executions_csv=$(kcadm get "authentication/flows/$alias/executions" \
    -r "$TARGET_REALM" \
    --fields id,level,displayName,providerId,authenticationFlow \
    --format csv \
    --noquotes); then
    printf 'Failed to read authentication executions after adding native handoff\n' >&2
    return 2
  fi

  native_flow_execution_id=''
  native_execution_id=''
  while IFS=, read -r id level display_name provider_id authentication_flow; do
    if [[ $level == 0 && $display_name == "$NATIVE_FLOW_ALIAS" && $authentication_flow == true ]]; then
      if [[ -n $native_flow_execution_id ]]; then
        printf 'Duplicate %s subflows were created\n' "$NATIVE_FLOW_ALIAS" >&2
        return 1
      fi
      native_flow_execution_id=$id
    fi
    if [[ $level == 1 && $provider_id == sky-native-handoff && $authentication_flow != true ]]; then
      if [[ -n $native_execution_id ]]; then
        printf 'Duplicate sky-native-handoff executions were created\n' >&2
        return 1
      fi
      native_execution_id=$id
    fi
  done <<<"$executions_csv"

  if [[ -z $native_flow_execution_id || -z $native_execution_id ]]; then
    printf 'Observed native handoff execution inventory:\n%s\n' "$executions_csv" >&2
    printf 'Native handoff subflow and execution were not created as expected\n' >&2
    return 1
  fi

  kcadm update "authentication/flows/$alias/executions" \
    -r "$TARGET_REALM" \
    -n \
    -b "{\"id\":\"$native_flow_execution_id\",\"priority\":5,\"requirement\":\"ALTERNATIVE\"}" >/dev/null

  kcadm update "authentication/flows/$NATIVE_FLOW_ALIAS/executions" \
    -r "$TARGET_REALM" \
    -n \
    -b "{\"id\":\"$native_execution_id\",\"priority\":10,\"requirement\":\"REQUIRED\"}" >/dev/null
}

ensure_browser_flow() {
  local client_id=$1
  local flow_id actual_graph source_alias source_graph current_source_graph encoded_source_alias graph_status
  if source_alias=$(realm_browser_flow_alias); then
    :
  else
    return $?
  fi
  if [[ $source_alias == "$FLOW_ALIAS" ]]; then
    printf 'The realm browser flow cannot be the Account Center client flow\n' >&2
    return 1
  fi
  if ! source_graph=$(flow_graph_signature "$source_alias"); then
    return 2
  fi
  if [[ $source_graph == *'|sky-native-handoff|'* ]]; then
    printf 'The active realm browser flow already contains the reserved sky-native-handoff provider\n' >&2
    return 1
  fi
  if flow_id=$(optional_lookup flow_id_by_alias "$FLOW_ALIAS"); then
    :
  else
    return $?
  fi

  if [[ -n $flow_id ]]; then
    if actual_graph=$(account_center_source_graph_signature "$FLOW_ALIAS"); then
      :
    else
      graph_status=$?
      if [[ $graph_status == 2 ]]; then
        return 2
      fi
      actual_graph=''
    fi
    if [[ $actual_graph != "$source_graph" ]]; then
      kcadm update "clients/$client_id" -r "$TARGET_REALM" \
        -s 'authenticationFlowBindingOverrides.browser=' >/dev/null
      kcadm delete "authentication/flows/$flow_id" -r "$TARGET_REALM" >/dev/null
      flow_id=''
    fi
  fi

  if [[ -z $flow_id ]]; then
    encoded_source_alias=$(urlencode_path_segment "$source_alias")
    kcadm create "authentication/flows/$encoded_source_alias/copy" \
      -r "$TARGET_REALM" \
      -s "newName=$FLOW_ALIAS" >/dev/null
    if flow_id=$(flow_id_by_alias "$FLOW_ALIAS"); then
      :
    else
      return $?
    fi
    add_native_handoff_execution "$FLOW_ALIAS"
  fi

  if ! current_source_graph=$(flow_graph_signature "$source_alias"); then
    return 2
  fi
  if [[ $current_source_graph != "$source_graph" ]]; then
    printf 'The active realm browser flow changed during reconciliation; retry safely\n' >&2
    return 1
  fi
  if actual_graph=$(account_center_source_graph_signature "$FLOW_ALIAS"); then
    :
  else
    graph_status=$?
    return "$graph_status"
  fi
  if [[ $actual_graph != "$source_graph" ]]; then
    printf 'Expected %s to preserve active realm flow %s:\n%s\nActual source portion:\n%s\n' \
      "$FLOW_ALIAS" "$source_alias" "$source_graph" "$actual_graph" >&2
    printf 'The %s execution graph differs from the active realm browser flow\n' "$FLOW_ALIAS" >&2
    return 1
  fi
  printf '%s\n' "$flow_id"
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
  local flow_uuid=$1
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
  },
  "authenticationFlowBindingOverrides": {
    "browser": "$flow_uuid"
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

authenticate
kcadm_json "realms/$TARGET_REALM" >/dev/null
compile_json_tool

reconcile_realm_settings
reconcile_brute_force_and_password_policy
reconcile_passkey_policy
reconcile_required_actions
reconcile_user_profile

ensure_account_center_client
flow_uuid=$(ensure_browser_flow "$ACCOUNT_CENTER_UUID")
reconcile_account_center_client "$flow_uuid"

ensure_client_scope "$SCOPE_NAME" \
  "$CONFIG_DIR/account-center-account-api-mappers.json"
scope_uuid=$ENSURED_SCOPE_ID
ensure_client_scope "$CORE_SCOPE_NAME" \
  "$CONFIG_DIR/account-center-core-claims-mappers.json"
core_scope_uuid=$ENSURED_SCOPE_ID
reconcile_skyapp_audience
reconcile_account_center_client_scopes "$scope_uuid" "$core_scope_uuid"
reconcile_account_scope_mappings
verify_mailer_client

printf 'Account Center Keycloak configuration is reconciled.\n'
