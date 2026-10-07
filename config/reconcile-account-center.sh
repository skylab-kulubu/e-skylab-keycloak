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
# K4: the realm browser flow signs in with the SKY LAB username/password form, which also takes
# the School and Personal e-mail. KEYCLOAK_PASSWORD_FORM=auth-username-password-form puts
# Keycloak's own form back (the rollback; run it before going back to an image without the
# SKY LAB form, or every password login of the realm fails).
BROWSER_FLOW_ALIAS='browser plus passkey'
STOCK_PASSWORD_FORM=auth-username-password-form
SKY_PASSWORD_FORM=sky-username-password-form
PASSWORD_FORM=${KEYCLOAK_PASSWORD_FORM:-$SKY_PASSWORD_FORM}
# K4b: the first step of the realm's reset credentials flow ("Şifremi unuttum") finds the person by
# the same identifiers as the password form; the mail still goes to the Primary e-mail.
# KEYCLOAK_RESET_CHOOSE_USER=reset-credentials-choose-user puts Keycloak's own step back (the
# rollback; run it before going back to an image without the SKY LAB step, or every reset-password
# request of the realm fails). A realm bound to Keycloak's built-in flow moves to an editable copy.
RESET_FLOW_COPY_ALIAS='sky reset credentials'
STOCK_RESET_CHOOSE_USER=reset-credentials-choose-user
SKY_RESET_CHOOSE_USER=sky-reset-credentials-choose-user
RESET_CHOOSE_USER=${KEYCLOAK_RESET_CHOOSE_USER:-$SKY_RESET_CHOOSE_USER}
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
# Login clients whose token is narrowed to the APIs their app calls (ADR-0058, ADR-0059; see
# reconcile_login_clients). skycms-audience is the realm scope that puts inscribed's audience into
# the Site clients' tokens: the event sites' clients (site-clients.sh) and skyapp
# (skyapp-cms-editor.sh) carry it too. It has two writers: this step, which must not turn the full
# scope off without it, and site-clients.sh --shared-scope, which repairs it alone before a release.
# Both write the same attributes and the same mapper (config/skycms-audience-mappers.json is
# site-clients.sh's audience_mapper_body); tests/login-clients.sh proves that neither changes what
# the other wrote. They differ only on another mapper in the scope: this step prunes it, as in every
# scope it owns, while site-clients.sh stops on a foreign audience. SkyMail's login client is also
# SkyMail's API client (SKYMAIL_CLIENT_ID, mailer-client-contract.sh): its own scope names it as the
# audience.
SKYCMS_SCOPE_NAME=skycms-audience
SKYMAIL_SCOPE_NAME=skymail-api-audience
# The admin panel's login client (ADR-0058; see reconcile_admin_panel_client): admin, superadmin in
# the sandbox realm (as in inscribed-cms-roles.sh); KEYCLOAK_ADMIN_PANEL_CLIENT_ID names another.
if [[ $TARGET_REALM == e-skylab-sandbox ]]; then
  ADMIN_PANEL_CLIENT_ID=${KEYCLOAK_ADMIN_PANEL_CLIENT_ID:-superadmin}
else
  ADMIN_PANEL_CLIENT_ID=${KEYCLOAK_ADMIN_PANEL_CLIENT_ID:-admin}
fi
ADMIN_PANEL_SCOPE_NAME=admin-panel-api-audience
# The API clients whose every role the panel's token may carry (skycms reads the panel's own roles).
ADMIN_PANEL_API_CLIENTS=(core forms)
# An operator runs one step with a kcadm session they logged in themselves (the sandbox realm has no
# reconciler identity): KEYCLOAK_RECONCILE_KCADM_CONFIG names that session's kcadm config file, which
# is never deleted here, and KEYCLOAK_RECONCILE_ONLY the step. The whole reconciliation still runs
# only as the scoped reconciler identity, so an operator session requires KEYCLOAK_RECONCILE_ONLY.
OPERATOR_KCADM_CONFIG=${KEYCLOAK_RECONCILE_KCADM_CONFIG:-}
RECONCILE_ONLY=${KEYCLOAK_RECONCILE_ONLY:-}
# KEYCLOAK_RECONCILE_CHECK=true: a dry run of the operator's service-roles step (runbook §20); it
# prints "would ..." for each change and writes nothing. No other step has a dry run.
RECONCILE_CHECK=${KEYCLOAK_RECONCILE_CHECK:-false}
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
case $RECONCILE_ONLY in
  '' | admin-panel-client | login-clients | core-roles | service-roles) ;;
  # The step's name before core's service roles became a list (core-internal-auth ticket 03).
  media-attach) RECONCILE_ONLY=service-roles ;;
  *)
    printf 'KEYCLOAK_RECONCILE_ONLY must be empty, admin-panel-client, login-clients, core-roles or service-roles, not %s\n' "$RECONCILE_ONLY" >&2
    exit 2
    ;;
esac
case $RECONCILE_CHECK in
  false) ;;
  true)
    if [[ $RECONCILE_ONLY != service-roles || -z $OPERATOR_KCADM_CONFIG ]]; then
      printf 'KEYCLOAK_RECONCILE_CHECK=true is a dry run of the operator step KEYCLOAK_RECONCILE_ONLY=service-roles with KEYCLOAK_RECONCILE_KCADM_CONFIG only\n' >&2
      exit 2
    fi
    ;;
  *)
    printf 'KEYCLOAK_RECONCILE_CHECK must be true or false, not %s\n' "$RECONCILE_CHECK" >&2
    exit 2
    ;;
esac
if [[ -n $OPERATOR_KCADM_CONFIG ]]; then
  if [[ -z $RECONCILE_ONLY ]]; then
    printf 'KEYCLOAK_RECONCILE_KCADM_CONFIG needs KEYCLOAK_RECONCILE_ONLY: an operator session runs one step; the whole reconciliation runs as %s\n' \
      "$CONFIG_CLIENT_ID" >&2
    exit 2
  fi
  if [[ ! -r $OPERATOR_KCADM_CONFIG ]]; then
    printf 'KEYCLOAK_RECONCILE_KCADM_CONFIG is not a readable kcadm config file: %s\n' "$OPERATOR_KCADM_CONFIG" >&2
    exit 2
  fi
  KCADM_CONFIG=$OPERATOR_KCADM_CONFIG
else
  KCADM_CONFIG=$(mktemp /tmp/account-center-kcadm.XXXXXX)
fi
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
  if [[ -z $OPERATOR_KCADM_CONFIG ]]; then
    rm -f "$KCADM_CONFIG"
  fi
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

if [[ -z $OPERATOR_KCADM_CONFIG ]]; then
  require KEYCLOAK_CONFIG_CLIENT_SECRET
fi

case $PASSWORD_FORM in
  "$SKY_PASSWORD_FORM" | "$STOCK_PASSWORD_FORM") ;;
  *)
    printf 'KEYCLOAK_PASSWORD_FORM must be %s (default) or %s (rollback), not %s\n' \
      "$SKY_PASSWORD_FORM" "$STOCK_PASSWORD_FORM" "$PASSWORD_FORM" >&2
    exit 1
    ;;
esac
case $RESET_CHOOSE_USER in
  "$SKY_RESET_CHOOSE_USER" | "$STOCK_RESET_CHOOSE_USER") ;;
  *)
    printf 'KEYCLOAK_RESET_CHOOSE_USER must be %s (default) or %s (rollback), not %s\n' \
      "$SKY_RESET_CHOOSE_USER" "$STOCK_RESET_CHOOSE_USER" "$RESET_CHOOSE_USER" >&2
    exit 1
    ;;
esac

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

# Kcadm path segment for a flow alias. Aliases outside this conservative set are refused
# rather than encoded, so an unexpected name can never address another resource.
flow_alias_path() {
  local alias=$1
  if [[ ! $alias =~ ^[A-Za-z0-9._\ -]+$ ]]; then
    printf 'Unsupported characters in authentication flow alias: %s\n' "$alias" >&2
    return 1
  fi
  printf '%s\n' "${alias// /%20}"
}

# Puts authenticator TO in the place of authenticator FROM in FLOW_ALIAS and logs one line
# "NOUN of flow 'FLOW_ALIAS': unchanged|updated (...)" (K4's password form, K4b's choose-user step).
# Admin REST cannot change the provider of an execution, so the new one is added under the same
# parent flow with the same priority (Keycloak orders executions by priority alone) and REQUIRED
# (the only requirement either factory offers), then the old one is deleted. For that moment the
# flow runs the step twice; there is never a moment without it. ReconcileJson (its password-form
# planner, which names no provider of its own) refuses, and nothing is written, unless the flow
# holds exactly one of the two, REQUIRED, without an authenticator config and with a priority none
# of its siblings shares. A run cut between the two writes leaves both side by side, which the next
# run finishes. The flow's other executions are never touched. Keycloak refuses any change to a
# built-in flow, so FLOW_ALIAS must name an editable one.
swap_flow_execution() {
  local flow_alias=$1 from=$2 to=$3 noun=$4
  local flow_path live_file plan_file status action execution_id parent_id priority parent_alias parent_path
  flow_path=$(flow_alias_path "$flow_alias")
  live_file=$(mktemp "$WORK_DIR/flow-execution.XXXXXX")
  plan_file=$(mktemp "$WORK_DIR/flow-execution-plan.XXXXXX")
  kcadm_json "authentication/flows/$flow_path/executions" -r "$TARGET_REALM" >"$live_file"
  if json_tool password-form "$from" "$to" <"$live_file" >"$plan_file"; then
    status=0
  else
    status=$?
  fi
  if [[ $status == 4 ]]; then
    printf "%s of flow '%s' was not changed: the step above explains why\n" "${noun^}" "$flow_alias" >&2
    return 1
  elif [[ $status != 0 ]]; then
    printf "Could not plan the %s of flow '%s' (status %s)\n" "$noun" "$flow_alias" "$status" >&2
    return 1
  fi
  IFS=$'\t' read -r action execution_id parent_id priority <"$plan_file"
  case $action in
    unchanged)
      log "$noun of flow '$flow_alias': unchanged ($to)"
      return 0
      ;;
    finish)
      kcadm delete "authentication/executions/$execution_id" -r "$TARGET_REALM" >/dev/null
      log "$noun of flow '$flow_alias': updated (finished an interrupted swap: removed $from next to $to)"
      ;;
    swap)
      if [[ $parent_id == - ]]; then
        parent_alias=$flow_alias
      else
        parent_alias=$(kcadm_json "authentication/flows/$parent_id" -r "$TARGET_REALM" | json_tool field alias)
      fi
      parent_path=$(flow_alias_path "$parent_alias")
      kcadm create "authentication/flows/$parent_path/executions/execution" -r "$TARGET_REALM" \
        -b "{\"provider\":\"$to\",\"priority\":$priority}" >/dev/null
      kcadm delete "authentication/executions/$execution_id" -r "$TARGET_REALM" >/dev/null
      log "$noun of flow '$flow_alias': updated ($from -> $to in subflow '$parent_alias', priority $priority, REQUIRED)"
      ;;
    *)
      printf "Unexpected %s plan for flow '%s': %s\n" "$noun" "$flow_alias" "$action" >&2
      return 1
      ;;
  esac
  kcadm_json "authentication/flows/$flow_path/executions" -r "$TARGET_REALM" >"$live_file"
  if ! json_tool password-form "$from" "$to" <"$live_file" >"$plan_file" \
    || [[ $(cut -f1 "$plan_file") != unchanged ]]; then
    printf "%s of flow '%s' is not in place after the swap; inspect it in the Admin Console\n" \
      "${noun^}" "$flow_alias" >&2
    return 1
  fi
}

# K4: puts PASSWORD_FORM in the place of the other username/password form in FLOW_ALIAS
# (default: the SKY LAB form replaces Keycloak's; the rollback swaps it back). The flow's other
# executions (passkey, OTP, passkey offer, organization) are never touched.
reconcile_password_form() {
  local flow_alias=$1 from
  if [[ $PASSWORD_FORM == "$SKY_PASSWORD_FORM" ]]; then
    from=$STOCK_PASSWORD_FORM
  else
    from=$SKY_PASSWORD_FORM
  fi
  swap_flow_execution "$flow_alias" "$from" "$PASSWORD_FORM" 'password form'
}

# K4b: puts RESET_CHOOSE_USER in the place of the other choose-user step in the realm's reset
# credentials flow (default: the SKY LAB step replaces Keycloak's; the rollback swaps it back),
# with swap_flow_execution. Keycloak's built-in "reset credentials" flow cannot be edited: a realm
# still bound to a built-in flow gets an editable copy of it (RESET_FLOW_COPY_ALIAS, made once and
# reused afterwards, even by a run cut short), the swap happens in the copy, and only then is the
# realm bound to the copy, so no request ever meets a half-made flow. The rollback swaps back in
# whichever flow is bound and keeps that binding: the copy then holds exactly Keycloak's steps.
# A realm bound to a built-in flow already runs Keycloak's own step, which the rollback leaves as
# it is. Binding the copy is a realm PUT of that one field, the same kind every realm step makes.
reconcile_reset_choose_user() {
  local from bound bound_path flow_id built_in target rebound
  if [[ $RESET_CHOOSE_USER == "$SKY_RESET_CHOOSE_USER" ]]; then
    from=$STOCK_RESET_CHOOSE_USER
  else
    from=$SKY_RESET_CHOOSE_USER
  fi
  bound=$(kcadm_json "realms/$TARGET_REALM" --fields resetCredentialsFlow | json_tool field resetCredentialsFlow)
  if [[ -z $bound ]]; then
    printf 'The realm has no reset credentials flow binding; nothing was changed\n' >&2
    return 1
  fi
  if flow_id=$(optional_lookup flow_id_by_alias "$bound"); then
    :
  else
    return $?
  fi
  if [[ -z $flow_id ]]; then
    printf "The realm's reset credentials flow '%s' does not exist; nothing was changed\n" "$bound" >&2
    return 1
  fi
  built_in=$(kcadm_json "authentication/flows/$flow_id" -r "$TARGET_REALM" | json_tool field builtIn)
  target=$bound
  if [[ $built_in == true && $RESET_CHOOSE_USER == "$SKY_RESET_CHOOSE_USER" ]]; then
    target=$RESET_FLOW_COPY_ALIAS
    if flow_id=$(optional_lookup flow_id_by_alias "$target"); then
      :
    else
      return $?
    fi
    if [[ -z $flow_id ]]; then
      bound_path=$(flow_alias_path "$bound")
      kcadm create "authentication/flows/$bound_path/copy" -r "$TARGET_REALM" \
        -s "newName=$target" >/dev/null
      log "authentication flow '$target': created (an editable copy of the built-in '$bound')"
    fi
  fi
  swap_flow_execution "$target" "$from" "$RESET_CHOOSE_USER" 'choose-user step'
  if [[ $target == "$bound" ]]; then
    log "realm reset credentials flow binding: unchanged ($bound)"
    return 0
  fi
  kcadm update "realms/$TARGET_REALM" -n -b "{\"resetCredentialsFlow\":\"$target\"}" >/dev/null
  rebound=$(kcadm_json "realms/$TARGET_REALM" --fields resetCredentialsFlow | json_tool field resetCredentialsFlow)
  if [[ $rebound != "$target" ]]; then
    printf "The realm's reset credentials flow is '%s', not '%s', after binding it; inspect it in the Admin Console\n" \
      "$rebound" "$target" >&2
    return 1
  fi
  log "realm reset credentials flow binding: updated ($bound -> $target)"
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
# they drift and kept among the client's default scopes. A realm without the client skips the item
# with a warning. Today it runs for skyforms; frontend-main and frontend-arge get their core scope in
# reconcile_login_clients together with the rest of their narrowed token.
reconcile_login_client_audience() {
  local client_id=$1 scope_name=$2 mappers_file=$3
  local client_uuid
  if ! client_uuid=$(optional_lookup client_id_by_client_id "$client_id"); then
    return 2
  fi
  if [[ -z $client_uuid ]]; then
    warn "client $client_id does not exist in realm $TARGET_REALM; skipped client scope $scope_name"
    return 0
  fi
  ensure_default_audience_scope "$client_id" "$client_uuid" "$scope_name" "$mappers_file"
}

# The source-controlled audience scope of a login client, kept among its default scopes only.
ensure_default_audience_scope() {
  local client_id=$1 client_uuid=$2 scope_name=$3 mappers_file=$4
  local scope_uuid optional_scopes
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

# Login clients narrowed to the APIs their app calls (ADR-0058, ADR-0059; admin-token-authz tickets
# 16, 17 and 18). They were made by hand in production with "Full scope allowed" on, so their
# tokens carried every audience, realm role and client role of the person, most of it read by no
# service. What each app sends its token to and what that API reads was measured on the apps'
# origin/main (2026-10-05; sky_lab_genel .scratch/admin-token-authz/issues/16-18):
#   frontend-main (the main site and its CMS editor) and frontend-arge (arge) call inscribed (aud
#     skycms, tenant azp, the flat roles claim of the client's own roles, collection rules on
#     full-path groups, the teams collection among them) and core POST /v1/media for images (aud
#     core, no core role); the sites' editor gate looks for cms:access in any client of
#     resource_access, so with full scope another site's cms:access opened this site's editor;
#   skymail (the SkyMail UI) calls SkyMail only, which reads the client's own roles
#     (resource_access.skymail) and sub, name and e-mail from Keycloak's userinfo, and no groups
#     (mailing lists read groups with SkyMail's own service account).
# The contract per client: the API audiences come from hardcoded Audience mappers in default scopes
# (a person without a role of the API keeps them; audience-resolve adds nothing once the full scope
# is off, and production's skycms reached the sites' tokens only through it), no realm role and no
# other client's role in the role scope (the client's own roles always pass Keycloak's filter, so
# cms:access, content:* and the skymail:* roles stay), "Full scope allowed" off. The sites keep
# their full-path groups (inscribed reads them); SkyMail's token carries none: every default or
# optional scope writing the claim groups is detached from skymail only (the realm scope and every
# other client keep it) and a mapper of skymail itself writing it is deleted. The order keeps the
# apps working during the run: audiences first, full scope off last. The client's secret, URIs,
# flags and other mappers are not touched. A missing client is skipped with a warning (the sandbox
# realm may lack one); the operator runs this step alone there (KEYCLOAK_RECONCILE_ONLY=login-clients).
reconcile_login_clients() {
  reconcile_narrowed_login_client "$FRONTEND_MAIN_CLIENT_ID" keep-groups \
    "$FRONTEND_MAIN_SCOPE_NAME=$CONFIG_DIR/frontend-main-core-audience-mappers.json" \
    "$SKYCMS_SCOPE_NAME=$CONFIG_DIR/skycms-audience-mappers.json"
  reconcile_narrowed_login_client "$FRONTEND_ARGE_CLIENT_ID" keep-groups \
    "$FRONTEND_ARGE_SCOPE_NAME=$CONFIG_DIR/frontend-arge-core-audience-mappers.json" \
    "$SKYCMS_SCOPE_NAME=$CONFIG_DIR/skycms-audience-mappers.json"
  reconcile_narrowed_login_client "$SKYMAIL_CLIENT_ID" drop-groups \
    "$SKYMAIL_SCOPE_NAME=$CONFIG_DIR/skymail-api-audience-mappers.json"
}

# reconcile_narrowed_login_client CLIENT keep-groups|drop-groups SCOPE=MAPPERS_FILE...
reconcile_narrowed_login_client() {
  local client_id=$1 groups=$2
  shift 2
  local client_uuid spec scopes='' desired_file="$WORK_DIR/narrowed-$client_id.json"
  for spec in "$@"; do
    scopes="$scopes${scopes:+, }${spec%%=*}"
  done
  if ! client_uuid=$(optional_lookup client_id_by_client_id "$client_id"); then
    return 2
  fi
  if [[ -z $client_uuid ]]; then
    warn "client $client_id does not exist in realm $TARGET_REALM; skipped client scope $scopes and its token narrowing"
    return 0
  fi
  for spec in "$@"; do
    ensure_default_audience_scope "$client_id" "$client_uuid" "${spec%%=*}" "${spec#*=}"
  done
  reconcile_role_scope "$client_id" "$client_uuid"
  if [[ $groups == drop-groups ]]; then
    remove_groups_claim "$client_id" "$client_uuid"
  fi
  printf '{"fullScopeAllowed":false}\n' >"$desired_file"
  apply_fields_if_changed "client $client_id (no full scope)" "$desired_file" \
    "clients/$client_uuid" -r "$TARGET_REALM"
}

# writes_groups TYPE CLAIM: a mapper of TYPE writing CLAIM puts group data into a token: Keycloak's
# Group Membership mapper, SKY LAB's group overage mapper, or any mapper whose claim is groups
# (microprofile-jwt's "groups" writes the realm roles there).
writes_groups() {
  [[ $1 == oidc-group-membership-mapper || $1 == sky-group-overage-mapper || $2 == groups || $2 == groups.* ]]
}

# mappers_write_groups ENDPOINT: one of the protocol mappers at ENDPOINT writes group data.
mappers_write_groups() {
  local mappers_csv id type claim name
  mappers_csv=$(kcadm get "$1" -r "$TARGET_REALM" \
    --fields 'id,protocolMapper,config(claim.name),name' \
    --format csv \
    --noquotes)
  while IFS=, read -r id type claim name; do
    [[ -n $id ]] || continue
    if writes_groups "$type" "$claim"; then
      return 0
    fi
  done <<<"$mappers_csv"
  return 1
}

# The claim groups out of one client's tokens (ADR-0059: an app whose APIs read no groups gets none,
# Entra's "groups assigned to the application"): every default or optional scope with a mapper that
# writes group data is detached from this client only, and such a mapper of the client is deleted.
remove_groups_claim() {
  local client_id=$1 client_uuid=$2
  local kind scopes_csv scope_id scope_name mappers_csv id type claim name changed=''
  for kind in default optional; do
    scopes_csv=$(kcadm get "clients/$client_uuid/$kind-client-scopes" -r "$TARGET_REALM" \
      --fields id,name \
      --format csv \
      --noquotes)
    while IFS=, read -r scope_id scope_name; do
      [[ -n $scope_id ]] || continue
      if mappers_write_groups "client-scopes/$scope_id/protocol-mappers/models"; then
        kcadm delete "clients/$client_uuid/$kind-client-scopes/$scope_id" -r "$TARGET_REALM" >/dev/null
        changed="$changed -$kind scope $scope_name"
      fi
    done <<<"$scopes_csv"
  done
  mappers_csv=$(kcadm get "clients/$client_uuid/protocol-mappers/models" -r "$TARGET_REALM" \
    --fields 'id,protocolMapper,config(claim.name),name' \
    --format csv \
    --noquotes)
  while IFS=, read -r id type claim name; do
    [[ -n $id ]] || continue
    if writes_groups "$type" "$claim"; then
      kcadm delete "clients/$client_uuid/protocol-mappers/models/$id" -r "$TARGET_REALM" >/dev/null
      changed="$changed -mapper $name"
    fi
  done <<<"$mappers_csv"
  if [[ -z $changed ]]; then
    log "groups claim of $client_id (none): unchanged"
  else
    log "groups claim of $client_id (none): updated (${changed# })"
  fi
}

# The admin panel's login client (ADR-0058, admin-token-authz ticket 02), made by hand and
# confidential in both realms. With full scope its token carried every audience and role of the
# person (11 audiences, 12 realm roles, 3.3 KB in production). Here the token is narrowed to the APIs
# the panel calls: every role of core and forms is in the client's role scope and nothing else,
# "Full scope allowed" is off (the panel's own roles, content:* for inscribed, always pass), and
# core, forms and skycms come from hardcoded audience mappers so a person without a role of that API
# is not refused (the reason of reconcile_login_client_audience). realm_access disappears; groups and
# the client's own mappers stay. Standard Token Exchange is on, so the panel's server can trade its
# token for a token of one of the three APIs (Keycloak lets a confidential client exchange a token
# issued to itself). The order keeps the live panel working during the run: audiences and API roles
# first, full scope off last. A role made on core or forms outside the reconciler reaches the panel's
# token with the next run.
#
# A missing client is skipped with a warning. A public one fails the run before anything is written
# to it: token exchange needs a confidential client, and making it confidential changes how the panel
# signs in (it must then send the client secret), which is the panel's change (admin-token-authz
# ticket 07). The step runs last, so every other step is done by then.
reconcile_admin_panel_client() {
  local client_uuid live_file public_client desired_file="$WORK_DIR/client-$ADMIN_PANEL_CLIENT_ID.json"
  if ! client_uuid=$(optional_lookup client_id_by_client_id "$ADMIN_PANEL_CLIENT_ID"); then
    return 2
  fi
  if [[ -z $client_uuid ]]; then
    warn "client $ADMIN_PANEL_CLIENT_ID does not exist in realm $TARGET_REALM; skipped the admin panel token contract"
    return 0
  fi
  live_file=$(mktemp "$WORK_DIR/admin-panel.XXXXXX")
  kcadm_json "clients/$client_uuid" -r "$TARGET_REALM" >"$live_file"
  public_client=$(json_tool field publicClient <"$live_file")
  if [[ $public_client != true && $public_client != false ]]; then
    printf 'Client %s has no readable publicClient flag (%s); nothing was changed on it\n' \
      "$ADMIN_PANEL_CLIENT_ID" "${public_client:-empty}" >&2
    return 1
  fi
  if [[ $public_client == true ]]; then
    printf 'Client %s is public: Standard Token Exchange needs a confidential client, and making it confidential changes how the admin panel signs in (it must send the client secret; admin-token-authz ticket 07). Nothing was changed on %s; make it confidential together with the panel, then run again\n' \
      "$ADMIN_PANEL_CLIENT_ID" "$ADMIN_PANEL_CLIENT_ID" >&2
    return 1
  fi
  ensure_default_audience_scope "$ADMIN_PANEL_CLIENT_ID" "$client_uuid" "$ADMIN_PANEL_SCOPE_NAME" \
    "$CONFIG_DIR/admin-panel-api-audience-mappers.json"
  reconcile_role_scope "$ADMIN_PANEL_CLIENT_ID" "$client_uuid" "${ADMIN_PANEL_API_CLIENTS[@]}"
  printf '{"fullScopeAllowed":false,"attributes":{"standard.token.exchange.enabled":"true"}}\n' >"$desired_file"
  apply_fields_if_changed "client $ADMIN_PANEL_CLIENT_ID (no full scope, standard token exchange)" \
    "$desired_file" "clients/$client_uuid" -r "$TARGET_REALM"
}

# {"id":…,"name":…} of one role; role names are free text (a quote or backslash stays JSON).
role_reference() {
  local name=${2//\\/\\\\}
  name=${name//\"/\\\"}
  printf '{"id":"%s","name":"%s"}' "$1" "$name"
}

# The role scope of a login client whose full scope is turned off: every role of the API clients
# given after its id and uuid (the admin panel: core, forms; the sites and SkyMail: none), no other
# client role and no realm role. The client's own roles always pass Keycloak's filter and need no
# mapping. A missing API client is reported; its roles are added once it exists.
reconcile_role_scope() {
  local client_id=$1 client_uuid=$2
  shift 2
  local apis=("$@")
  local live_file mapped api api_uuid roles_csv role_id role_name body owner owner_uuid is_api
  local changed='' label
  if [[ ${#apis[@]} -gt 0 ]]; then
    label="role scope mappings of $client_id (every role of $(printf '%s, ' "${apis[@]}" | sed 's/, $//'))"
  else
    label="role scope mappings of $client_id (none: only its own roles)"
  fi
  live_file=$(mktemp "$WORK_DIR/role-scope.XXXXXX")
  kcadm_json "clients/$client_uuid/scope-mappings" -r "$TARGET_REALM" >"$live_file"
  mapped=$(json_tool scope-mappings <"$live_file")
  for api in ${apis[@]+"${apis[@]}"}; do
    if ! api_uuid=$(optional_lookup client_id_by_client_id "$api"); then
      return 2
    fi
    if [[ -z $api_uuid ]]; then
      warn "client $api does not exist in realm $TARGET_REALM; no $api role is in the scope of $client_id"
      continue
    fi
    roles_csv=$(kcadm get "clients/$api_uuid/roles" -r "$TARGET_REALM" \
      --fields id,name \
      --format csv \
      --noquotes)
    body=''
    while IFS=, read -r role_id role_name; do
      [[ -n $role_id ]] || continue
      if ! grep -Fq "$api"$'\t'"$api_uuid"$'\t'"$role_id"$'\t' <<<"$mapped"; then
        body="$body,$(role_reference "$role_id" "$role_name")"
        changed="$changed +$api/$role_name"
      fi
    done <<<"$roles_csv"
    if [[ -n $body ]]; then
      kcadm create "clients/$client_uuid/scope-mappings/clients/$api_uuid" \
        -r "$TARGET_REALM" \
        -b "[${body#,}]" >/dev/null
    fi
  done
  while IFS=$'\t' read -r owner owner_uuid role_id role_name; do
    [[ -n $owner ]] || continue
    is_api=false
    for api in ${apis[@]+"${apis[@]}"}; do
      [[ $owner == "$api" ]] && is_api=true
    done
    [[ $is_api == false ]] || continue
    body="[$(role_reference "$role_id" "$role_name")]"
    if [[ $owner == - ]]; then
      kcadm delete "clients/$client_uuid/scope-mappings/realm" -r "$TARGET_REALM" -b "$body" >/dev/null
      changed="$changed -realm/$role_name"
    else
      kcadm delete "clients/$client_uuid/scope-mappings/clients/$owner_uuid" -r "$TARGET_REALM" -b "$body" >/dev/null
      changed="$changed -$owner/$role_name"
    fi
  done <<<"$mapped"
  if [[ -z $changed ]]; then
    log "$label: unchanged"
  else
    log "$label: updated (${changed# })"
  fi
}

# core's per-resource client roles (ADR-0059, admin-token-authz ticket 03): what the Privileged
# group check of core gave, one role per resource, so that it can be granted per resource from the
# SKY LAB admin panel. The list is the contract table in sky_lab_genel
# .scratch/admin-token-authz/spec.md ("Sözleşme: core'un kaynak rolleri"); core (tickets 04/05)
# checks exactly these names. Every run creates a missing role (manage-clients). Each role is
# granted to the Privileged groups (ADMIN, YK, DK at /<NAME> and /UYELER/<NAME>, whichever exist)
# ONCE: the role attribute CORE_ROLE_SEED_ATTRIBUTE records when and to which groups, and a role
# that carries it is never granted again, so a mapping changed or removed in the admin panel stays
# that way. Nothing here ever removes a mapping or a role. A role added to the list later is seeded
# on its own first run. Granting a client role to a group needs user permissions, which the
# reconciler identity deliberately lacks (ADR-0048's reason for manage-clients): its runs create
# the roles and warn about unseeded ones; an operator seeds them by running this step alone with
# their own kcadm session (KEYCLOAK_RECONCILE_ONLY=core-roles, runbook §19).
CORE_CLIENT_ID=${KEYCLOAK_CORE_CLIENT_ID:-core}
CORE_ROLE_SEED_ATTRIBUTE=skylab.seeded-group-mappings
CORE_PRIVILEGED_NAMES=(ADMIN YK DK)
# name|description (the description is written only when the role is created)
CORE_ROLE_DEFINITIONS=(
  'event:manage|Her takımın etkinliklerini, etkinlik günlerini ve oturumlarını yönetir; kapı görevlisi atar (ADR-0059)'
  'season:manage|Sezonları oluşturur, değiştirir, siler (ADR-0059)'
  'ticket:manage|Her etkinliğin biletlerini görür ve atar (ADR-0059)'
  'ticket:validate|Her etkinlikte kapı girişi yapar (bilet doğrulama; ADR-0059)'
  'competitor:manage|Her yarışmacıyı görür ve yönetir (ADR-0059)'
  'media:manage|Medyayı listeler ve siler (ADR-0059)'
  'media:private:read|core uygulamasının özel medyasını açar (sertifika varlıkları; ADR-0059)'
  'certificate:manage|Her takımın sertifikalarını ve sertifika şablonlarını yönetir (ADR-0059)'
  'users:manage|Kullanıcıları görür ve yönetir (ADR-0059)'
  'groups:manage|Grupları görür ve yönetir (ADR-0059)'
  'github:activity:read|Kulübün GitHub etkinliğini (özel depolar dahil) görür (ADR-0059)'
  'url:moderator|Her kısa linki ve form bağlantısını görür ve yönetir'
  'url:access|Kısa link oluşturur, kendi linklerini görür ve yönetir'
)

# The Privileged groups that exist, one "path<TAB>id" per line. Only Keycloak's answer that the
# path does not exist counts as a missing group; any other failed lookup (network, permission,
# server error) fails the function, so the caller never seeds and marks a role without a group
# that is in fact there.
core_privileged_groups() {
  local name path line id stderr_file
  stderr_file=$(mktemp "$WORK_DIR/stderr.XXXXXX")
  for name in "${CORE_PRIVILEGED_NAMES[@]}"; do
    for path in "/$name" "/UYELER/$name"; do
      if line=$(kcadm get "group-by-path$path" -r "$TARGET_REALM" --fields id,path --format csv --noquotes \
        2>"$stderr_file"); then
        line=$(tr -d '\r' <<<"$line" | sed '/^$/d')
      elif grep -Eqi 'not found|does not exist' "$stderr_file"; then
        continue
      else
        cat "$stderr_file" >&2
        printf 'The Privileged group %s could not be looked up in realm %s; nothing was granted\n' \
          "$path" "$TARGET_REALM" >&2
        return 1
      fi
      id=${line%%,*}
      [[ -n $line && ${line#*,} == "$path" && -n $id ]] || continue
      printf '%s\t%s\n' "$path" "$id"
    done
  done
}

reconcile_core_roles() {
  local core_uuid roles_csv definition name description created='' roles_file seeds
  local unseeded=() role_name role_seed_value seed groups default path gid stamp granted held role_id paths
  local role_ids body defaults
  if ! core_uuid=$(optional_lookup client_id_by_client_id "$CORE_CLIENT_ID"); then
    return 2
  fi
  if [[ -z $core_uuid ]]; then
    warn "client $CORE_CLIENT_ID does not exist in realm $TARGET_REALM; skipped core's resource roles"
    return 0
  fi
  roles_csv=$(kcadm get "clients/$core_uuid/roles" -r "$TARGET_REALM" --fields name --format csv --noquotes \
    | tr -d '\r')
  for definition in "${CORE_ROLE_DEFINITIONS[@]}"; do
    name=${definition%%|*}
    description=${definition#*|}
    if ! grep -Fxq -- "$name" <<<"$roles_csv"; then
      kcadm_quiet create "clients/$core_uuid/roles" -r "$TARGET_REALM" \
        -s "name=$name" -s "description=$description"
      created="$created, $name"
    fi
  done
  if [[ -z $created ]]; then
    log "client roles of $CORE_CLIENT_ID (${#CORE_ROLE_DEFINITIONS[@]} resource roles): unchanged"
  else
    log "client roles of $CORE_CLIENT_ID (${#CORE_ROLE_DEFINITIONS[@]} resource roles): created (${created#, })"
  fi

  roles_file=$(mktemp "$WORK_DIR/core-roles.XXXXXX")
  kcadm_json "clients/$core_uuid/roles" -r "$TARGET_REALM" -q briefRepresentation=false >"$roles_file"
  seeds=$(json_tool role-attribute "$CORE_ROLE_SEED_ATTRIBUTE" <"$roles_file")
  for definition in "${CORE_ROLE_DEFINITIONS[@]}"; do
    name=${definition%%|*}
    seed=''
    while IFS=$'\t' read -r role_name role_seed_value; do
      [[ $role_name == "$name" ]] && seed=$role_seed_value
    done <<<"$seeds"
    [[ -n $seed ]] || unseeded+=("$name")
  done
  if [[ ${#unseeded[@]} == 0 ]]; then
    log "group mappings of the $CORE_CLIENT_ID resource roles: unchanged (each seeded once; the SKY LAB admin panel owns them)"
    return 0
  fi
  if [[ -z $OPERATOR_KCADM_CONFIG ]]; then
    warn "core roles not yet granted to the Privileged groups: ${unseeded[*]} (granting a role to a group needs user permissions the reconciler identity does not have); run this step alone with an operator session: KEYCLOAK_RECONCILE_ONLY=core-roles (runbook §19)"
    return 0
  fi

  # Operator session: seed. Nothing is written unless every check passes.
  if ! groups=$(core_privileged_groups); then
    return 1
  fi
  if [[ -z $groups ]]; then
    warn "no Privileged group (/ADMIN, /YK, /DK or under /UYELER) exists in realm $TARGET_REALM; nothing was granted, the roles stay unseeded"
    return 0
  fi
  # Read into a variable first: a failed read inside a process substitution would pass as "no
  # default group" and seed anyway. This check is what keeps every new user from getting the roles.
  if ! defaults=$(kcadm get "realms/$TARGET_REALM/default-groups" --fields path --format csv --noquotes); then
    printf 'The default groups of realm %s could not be read; nothing was granted (a Privileged default group would give every new user the core resource roles)\n' \
      "$TARGET_REALM" >&2
    return 1
  fi
  while IFS= read -r default; do
    default=${default%$'\r'}
    [[ -n $default ]] || continue
    while IFS=$'\t' read -r path gid; do
      if [[ $default == "$path" || $default == "$path"/* ]]; then
        printf 'The default group %s is at or under the Privileged group %s: every new user would get the core resource roles. Nothing was granted\n' \
          "$default" "$path" >&2
        return 1
      fi
    done <<<"$groups"
  done <<<"$defaults"
  for name in "${CORE_PRIVILEGED_NAMES[@]}"; do
    grep -Eq "^(/UYELER)?/$name"$'\t' <<<"$groups" \
      || warn "no Privileged group $name (neither /$name nor /UYELER/$name) in realm $TARGET_REALM; it gets no core resource role"
  done
  paths=$(cut -f1 <<<"$groups" | paste -sd, -)
  stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  role_ids=$(kcadm get "clients/$core_uuid/roles" -r "$TARGET_REALM" --fields id,name --format csv --noquotes \
    | tr -d '\r')
  declare -A granted_to=()
  # One read and at most one write per group.
  while IFS=$'\t' read -r path gid; do
    held=$(kcadm get "groups/$gid/role-mappings/clients/$core_uuid" -r "$TARGET_REALM" --fields name --format csv \
      --noquotes | tr -d '\r')
    body=''
    for name in "${unseeded[@]}"; do
      grep -Fxq -- "$name" <<<"$held" && continue
      role_id=$(sed -n "s/^\([^,]*\),$name\$/\1/p" <<<"$role_ids")
      [[ -n $role_id ]] || { printf 'core role %s could not be read back\n' "$name" >&2; return 1; }
      body="$body,$(role_reference "$role_id" "$name")"
      granted_to[$name]="${granted_to[$name]:-}, $path"
    done
    [[ -z $body ]] || kcadm_quiet create "groups/$gid/role-mappings/clients/$core_uuid" -r "$TARGET_REALM" \
      -b "[${body#,}]"
  done <<<"$groups"
  # The mark comes last: a run cut before it grants the same (idempotently) next time.
  for name in "${unseeded[@]}"; do
    kcadm_quiet update "clients/$core_uuid/roles/$name" -r "$TARGET_REALM" \
      -s "attributes.\"$CORE_ROLE_SEED_ATTRIBUTE\"=[\"$stamp $paths\"]"
    granted=${granted_to[$name]:-, none (every group already held it)}
    log "core role $name: seeded once to $paths (granted to: ${granted#, })"
  done
}

# core's service roles (runbook §20): the client roles of core that a product's service account
# (client credentials) holds and core reads from resource_access.core.roles; aud must contain core.
#   media:attach        POST/DELETE /v1/media/{id}/attachments and the anonymous form upload rule
#                       (media redesign ticket 03, ADR-0052); core also requires azp and client_id
#                       to be a client of its MEDIA_SERVICE_CLIENTS.
#   ticket:forms        POST /v1/forms/{formId}/responses: forms reports its answers and core writes
#                       the Tickets an accepted answer to an Event's form earns (core's
#                       docs/form-response-tickets.md); core accepts it only from the forms
#                       product's service account.
#   url:forms           form-bound short links, /v1/urls/forms/{formId} and GET /v1/urls/availability.
#   users:read          GET /v1/users/{id}.
# url:forms and users:read were granted to the forms service account by hand before (forms-url-role
# wizard, Java era); they are codified here with the other two.
#
# Every run creates a missing role (manage-clients; the description is written only then) and, for
# a listed client whose fullScopeAllowed is false, maps the role in the client's role scope, or it
# never reaches the token. Granting a role to a service account needs user permissions the
# reconciler identity deliberately lacks (as for core-roles), so an operator runs this step alone
# with their own kcadm session (KEYCLOAK_RECONCILE_ONLY=service-roles; media-attach, its name before
# ticket 03, still works). KEYCLOAK_RECONCILE_CHECK=true makes the operator step a dry run: it reads
# everything, prints "would ..." for each change and writes nothing. The operator step reads
# everything first and writes only when every read succeeded; a failed read is never taken for
# "absent". It then grants each role to each listed service account that lacks it, records on the
# role (attribute CORE_SERVICE_ROLE_GRANT_ATTRIBUTE) when and to which service accounts, and reports,
# never removes: another holder (a user, a group or the realm's default role) of a role meant for
# service accounts only, and a core role a listed service account holds beyond this list (a NOTE).
# aud core is not added here: Keycloak's audience resolve mapper (default scope roles) puts core in
# aud once resource_access.core is in the token; the step verifies that scope instead of adding a
# second audience mapper.
#
# name|clients (space separated)|holders|description. holders: services (only the listed clients'
# service accounts may hold it; any other holder is reported) or shared (people may hold it too:
# users:read predates the service accounts). Keep the clients of media:attach in step with core's
# MEDIA_SERVICE_CLIENTS (product:client pairs; unset it is forms:forms): a CMS client is added in
# both places together, once its service account exists. ticket:forms and url:forms are forms only.
CORE_SERVICE_ROLE_DEFINITIONS=(
  "media:attach|forms|services|Service attach API (media redesign ticket 03, ADR-0052): a product's service account links Media to its own records. Service accounts only; never a person or a group."
  "ticket:forms|forms|services|Forms reports its answers (POST /v1/forms/{formId}/responses, core docs/form-response-tickets.md); core writes the Tickets an accepted answer to an Event's form earns. Service accounts only; never a person or a group."
  "url:forms|forms|services|Forms service account: form-bound short links (/v1/urls/forms/{formId}) and GET /v1/urls/availability only. Grants nothing on the generic /v1/urls endpoints."
  "users:read|forms|shared|Reads a person's profile (GET /v1/users/{id}); held by the Forms service account."
)
CORE_SERVICE_ROLE_GRANT_ATTRIBUTE=skylab.granted-service-accounts
# Listed clients that must be service account only: no browser login (standard or implicit flow) and
# no password grant (direct access grants). core reads the product from client_id == azp, so a token
# of forms must always be its service account's; Forms signs people in through skyforms. The
# reconciler identity verifies and warns; the operator step sets the flags that are not false
# (KEYCLOAK_RECONCILE_CHECK=true: "would set ..."). No other client is touched.
CORE_SERVICE_ONLY_CLIENTS=(forms)
CORE_SERVICE_ONLY_FLAGS=(standardFlowEnabled implicitFlowEnabled directAccessGrantsEnabled)
CORE_SERVICE_ROLE_OPERATOR_STEP='run this step alone with an operator session: KEYCLOAK_RECONCILE_ONLY=service-roles (runbook §20)'
SERVICE_ROLE_CHANGES=0

# service_role_read WHAT ARGS...: a kcadm read for the service-roles step; a failure names WHAT and
# stops the step before it writes anything.
service_role_read() {
  local what=$1 result
  shift
  if ! result=$(kcadm get "$@" -r "$TARGET_REALM" --format csv --noquotes); then
    printf '%s could not be read in realm %s; nothing was granted\n' "$what" "$TARGET_REALM" >&2
    return 1
  fi
  tr -d '\r' <<<"$result" | sed '/^$/d'
}

# service_role_change TEXT: one change of the step. With KEYCLOAK_RECONCILE_CHECK=true it is logged
# as "would TEXT" and the caller writes nothing (the function then returns 1).
service_role_change() {
  SERVICE_ROLE_CHANGES=$((SERVICE_ROLE_CHANGES + 1))
  if [[ $RECONCILE_CHECK == true ]]; then
    log "would $1"
    return 1
  fi
  return 0
}

reconcile_core_service_roles() {
  local core_uuid roles_file marks role_name value definition name clients holders description
  local role_id client client_uuid flags full_scope scopes mapped sa_line sa_id sa_name held
  local stderr_file line accounts stamp label others account users groups defaults extra
  local flag flag_value open
  local operator=false
  local names=() all_clients=() plan=() sets=()
  local -A role_ids=() role_clients=() role_holders=() markers=() granted=() client_lines=() person_logins=()
  [[ -z $OPERATOR_KCADM_CONFIG ]] || operator=true
  SERVICE_ROLE_CHANGES=0
  if ! core_uuid=$(optional_lookup client_id_by_client_id "$CORE_CLIENT_ID"); then
    return 2
  fi
  if [[ -z $core_uuid ]]; then
    warn "client $CORE_CLIENT_ID does not exist in realm $TARGET_REALM; skipped its service roles"
    return 0
  fi

  # The roles: created when missing (harmless, they grant nothing), before every read.
  for definition in "${CORE_SERVICE_ROLE_DEFINITIONS[@]}"; do
    IFS='|' read -r name clients holders description <<<"$definition"
    names+=("$name")
    role_clients[$name]=$clients
    role_holders[$name]=$holders
    for client in $clients; do
      [[ " ${all_clients[*]} " == *" $client "* ]] || all_clients+=("$client")
    done
    label="client role $name of $CORE_CLIENT_ID"
    if ! role_id=$(optional_lookup client_role_id_by_name "$core_uuid" "$name"); then
      return 2
    fi
    if [[ -n $role_id ]]; then
      log "$label: unchanged"
    elif service_role_change "create $label"; then
      kcadm_quiet create "clients/$core_uuid/roles" -r "$TARGET_REALM" \
        -s "name=$name" -s "description=$description"
      role_id=$(client_role_id_by_name "$core_uuid" "$name")
      log "$label: created"
    fi
    role_ids[$name]=$role_id
  done
  roles_file=$(mktemp "$WORK_DIR/service-roles.XXXXXX")
  kcadm_json "clients/$core_uuid/roles" -r "$TARGET_REALM" -q briefRepresentation=false >"$roles_file"
  # Into a variable first: a failure inside a process substitution would pass as "no record".
  marks=$(json_tool role-attribute "$CORE_SERVICE_ROLE_GRANT_ATTRIBUTE" <"$roles_file")
  # "<timestamp> <service account>,<service account>"
  while IFS=$'\t' read -r role_name value; do
    if [[ -n $role_name ]]; then markers[$role_name]=$value; fi
  done <<<"$marks"

  # Reads: one plan line per listed client that has a service account.
  for client in "${all_clients[@]}"; do
    if ! client_uuid=$(optional_lookup client_id_by_client_id "$client"); then
      return 2
    fi
    if [[ -z $client_uuid ]]; then
      warn "client $client does not exist in realm $TARGET_REALM; its core service roles are not granted to its service account"
      continue
    fi
    flags=$(service_role_read "Client $client" "clients/$client_uuid" --fields serviceAccountsEnabled,fullScopeAllowed)
    if [[ ${flags%%,*} != true ]]; then
      warn "client $client has no service account (serviceAccountsEnabled=${flags%%,*}); its core service roles are not granted and nothing was changed on the client"
      continue
    fi
    full_scope=${flags#*,}
    if [[ " ${CORE_SERVICE_ONLY_CLIENTS[*]} " == *" $client "* ]]; then
      # One field per read: nothing depends on the order of the csv columns.
      open=''
      for flag in "${CORE_SERVICE_ONLY_FLAGS[@]}"; do
        flag_value=$(service_role_read "Client $client" "clients/$client_uuid" --fields "$flag")
        [[ $flag_value == false ]] || open+=" $flag"
      done
      person_logins[$client]=${open# }
    fi
    scopes=$(service_role_read "The default client scopes of $client" "clients/$client_uuid/default-client-scopes" --fields name)
    if grep -Fxq roles <<<"$scopes"; then
      log "default client scope roles of $client: verified (it puts resource_access and, through audience resolve, aud $CORE_CLIENT_ID in the token)"
    else
      warn "client $client has no default client scope roles: its token carries neither resource_access.$CORE_CLIENT_ID nor aud $CORE_CLIENT_ID; nothing was changed on the client, add roles back to its default client scopes"
    fi
    mapped=-
    if [[ $full_scope == false ]]; then
      mapped=$(service_role_read "The role scope of $client" "clients/$client_uuid/scope-mappings/clients/$core_uuid" --fields name)
      mapped=",$(paste -sd, - <<<"$mapped"),"
    fi
    sa_line=$(service_role_read "The service account of $client" "clients/$client_uuid/service-account-user" --fields id,username)
    sa_id=${sa_line%%,*}
    sa_name=${sa_line#*,}
    if [[ -z $sa_id || -z $sa_name || $sa_line != *,* || $sa_line == *$'\n'* ]]; then
      printf 'The service account of %s could not be resolved in realm %s; nothing was granted\n' "$client" "$TARGET_REALM" >&2
      return 1
    fi
    stderr_file=$(mktemp "$WORK_DIR/stderr.XXXXXX")
    if held=$(kcadm get "users/$sa_id/role-mappings/clients/$core_uuid/composite" -r "$TARGET_REALM" \
      --fields name --format csv --noquotes 2>"$stderr_file"); then
      held=",$(tr -d '\r' <<<"$held" | sed '/^$/d' | paste -sd, -),"
    elif [[ $operator == true ]]; then
      cat "$stderr_file" >&2
      printf 'The %s roles of %s could not be read in realm %s; nothing was granted\n' "$CORE_CLIENT_ID" "$sa_name" "$TARGET_REALM" >&2
      return 1
    else
      # The reconciler identity has no user permissions: expected, the operator step checks.
      held=-
    fi
    client_lines[$client]="$client_uuid|$full_scope|$mapped|$sa_id|$sa_name|$held"
  done

  if [[ $operator == true ]]; then
    defaults=$(service_role_read "The default role default-roles-${TARGET_REALM,,}" "roles/default-roles-${TARGET_REALM,,}/composites/clients/$core_uuid" --fields name)
    for name in "${names[@]}"; do
      [[ ${role_holders[$name]} == services && -n ${role_ids[$name]} ]] || continue
      users=$(service_role_read "The users holding $name" "clients/$core_uuid/roles/$name/users" --fields username)
      groups=$(service_role_read "The groups holding $name" "clients/$core_uuid/roles/$name/groups" --fields path)
      plan+=("$name"$'\037'"$(paste -sd, - <<<"$users")"$'\037'"$(paste -sd, - <<<"$groups")")
    done
  fi

  # Writes: the service-only clients' flags first, then role by role.
  for client in "${all_clients[@]}"; do
    [[ -n ${client_lines[$client]:-} && -n ${person_logins[$client]+set} ]] || continue
    client_uuid=${client_lines[$client]%%|*}
    open=${person_logins[$client]}
    if [[ -z $open ]]; then
      log "client $client: service account only, verified (${CORE_SERVICE_ONLY_FLAGS[*]} false)"
      continue
    fi
    if [[ $operator != true ]]; then
      warn "client $client lets a person sign in ($open not false): core reads the product from client_id == azp, so it must be service account only; nothing was changed on the client; $CORE_SERVICE_ROLE_OPERATOR_STEP"
      continue
    fi
    if service_role_change "set ${open// /=false, }=false on client $client (service account only: no browser login, no password grant)"; then
      sets=()
      for flag in $open; do sets+=(-s "$flag=false"); done
      kcadm_quiet update "clients/$client_uuid" -r "$TARGET_REALM" "${sets[@]}"
      log "client $client: updated (${open// /=false, }=false; service account only)"
    fi
  done
  for name in "${names[@]}"; do
    role_id=${role_ids[$name]}
    value=${markers[$name]:-}
    accounts=''
    for client in ${role_clients[$name]}; do
      [[ -n ${client_lines[$client]:-} ]] || continue
      IFS='|' read -r client_uuid full_scope mapped sa_id sa_name held <<<"${client_lines[$client]}"
      if [[ $mapped == - ]]; then
        log "role scope of $client: unchanged (full scope: the roles of its service account reach its token)"
      elif [[ $mapped == *",$name,"* ]]; then
        log "role scope of $client: unchanged ($CORE_CLIENT_ID/$name is mapped)"
      elif service_role_change "map $CORE_CLIENT_ID/$name in the role scope of $client (fullScopeAllowed is false)"; then
        kcadm_quiet create "clients/$client_uuid/scope-mappings/clients/$core_uuid" -r "$TARGET_REALM" \
          -b "[$(role_reference "$role_id" "$name")]"
        log "role scope of $client: updated (+$CORE_CLIENT_ID/$name; fullScopeAllowed is false)"
      fi
      if [[ $held == - ]]; then
        if [[ -n $value && ,${value#* }, == *",$sa_name,"* ]]; then
          log "service account $sa_name: $name unchanged (granted by the operator step at ${value%% *}; the reconciler identity cannot read service-account roles, the operator step re-checks them)"
        else
          warn "$name is not yet granted to service account $sa_name by the operator step (the reconciler identity cannot read or grant service-account roles); $CORE_SERVICE_ROLE_OPERATOR_STEP"
        fi
        continue
      fi
      if [[ $held == *",$name,"* ]]; then
        log "service account $sa_name: $name unchanged (held)"
      elif [[ $operator != true ]]; then
        warn "service account $sa_name lacks $name; $CORE_SERVICE_ROLE_OPERATOR_STEP"
        continue
      elif service_role_change "grant $name to service account $sa_name"; then
        kcadm_quiet create "users/$sa_id/role-mappings/clients/$core_uuid" -r "$TARGET_REALM" \
          -b "[$(role_reference "$role_id" "$name")]"
        log "service account $sa_name: $name granted"
      fi
      accounts+=",$sa_name"
    done
    [[ $operator == true ]] || continue

    accounts=$(tr ',' '\n' <<<"${accounts#,}" | sed '/^$/d' | sort | paste -sd, -)
    granted[$name]=$accounts
    if [[ -n $accounts && $accounts != "${value#* }" ]]; then
      stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      if service_role_change "record the grant of $name ($CORE_SERVICE_ROLE_GRANT_ATTRIBUTE=<now> $accounts)"; then
        kcadm_quiet update "clients/$core_uuid/roles/$name" -r "$TARGET_REALM" \
          -s "attributes.\"$CORE_SERVICE_ROLE_GRANT_ATTRIBUTE\"=[\"$stamp $accounts\"]"
        log "client role $name of $CORE_CLIENT_ID: grant recorded ($CORE_SERVICE_ROLE_GRANT_ATTRIBUTE=$stamp $accounts)"
      fi
    fi
  done
  [[ $operator == true ]] || return 0

  # Reports: nothing is removed.
  for line in ${plan[@]+"${plan[@]}"}; do
    IFS=$'\037' read -r name users groups <<<"$line"
    others=''
    for account in ${users//,/ }; do
      [[ ,${granted[$name]}, == *",$account,"* ]] || others+=", $account"
    done
    [[ -z $others ]] \
      || warn "$name is also held by the users ${others#, } (nothing was removed; it is for the service accounts of ${role_clients[$name]} only, remove it in the Admin Console)"
    [[ -z $groups ]] \
      || warn "$name is held by the groups $groups (nothing was removed; every member holds it, remove it in the Admin Console)"
    ! grep -Fxq -- "$name" <<<"$defaults" \
      || warn "$name is in the default role default-roles-${TARGET_REALM,,} (nothing was removed; every user holds it, remove it in the Admin Console)"
  done
  for client in "${all_clients[@]}"; do
    [[ -n ${client_lines[$client]:-} ]] || continue
    IFS='|' read -r client_uuid full_scope mapped sa_id sa_name held <<<"${client_lines[$client]}"
    extra=''
    for role_name in ${held//,/ }; do
      for name in "${names[@]}"; do
        [[ $role_name != "$name" || " ${role_clients[$name]} " != *" $client "* ]] || continue 2
      done
      extra+=", $role_name"
    done
    [[ -z $extra ]] \
      || log "NOTE: service account $sa_name also holds the $CORE_CLIENT_ID roles ${extra#, }, which this step does not manage (nothing was removed)"
  done
  if [[ $RECONCILE_CHECK == true ]]; then
    log "check: $SERVICE_ROLE_CHANGES change(s) pending; nothing was written"
  else
    log "applied $SERVICE_ROLE_CHANGES change(s)"
  fi
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

if [[ -z $OPERATOR_KCADM_CONFIG ]]; then
  authenticate
fi
kcadm_json "realms/$TARGET_REALM" >/dev/null
compile_json_tool

if [[ $RECONCILE_ONLY == admin-panel-client ]]; then
  reconcile_admin_panel_client
  printf 'Admin panel client configuration is reconciled.\n'
  exit 0
fi
if [[ $RECONCILE_ONLY == login-clients ]]; then
  reconcile_login_clients
  printf 'Login client configuration is reconciled.\n'
  exit 0
fi
if [[ $RECONCILE_ONLY == core-roles ]]; then
  reconcile_core_roles
  printf 'Core resource roles are reconciled.\n'
  exit 0
fi
if [[ $RECONCILE_ONLY == service-roles ]]; then
  reconcile_core_service_roles
  if [[ $RECONCILE_CHECK == true ]]; then
    printf 'Core service roles are checked; nothing was written.\n'
  else
    printf 'Core service roles are reconciled.\n'
  fi
  exit 0
fi

reconcile_realm_settings
reconcile_brute_force_and_password_policy
reconcile_event_retention
reconcile_passkey_policy
reconcile_required_actions
reconcile_user_profile

ensure_account_center_client
retire_account_center_browser_flow
# account-center-browser, the other flow that held a username/password form, is retired and
# deleted just above; the realm browser flow is the only one left to swap.
reconcile_password_form "$BROWSER_FLOW_ALIAS"
reconcile_reset_choose_user
reconcile_account_center_client

ensure_client_scope "$SCOPE_NAME" \
  "$CONFIG_DIR/account-center-account-api-mappers.json"
scope_uuid=$ENSURED_SCOPE_ID
ensure_client_scope "$CORE_SCOPE_NAME" \
  "$CONFIG_DIR/account-center-core-claims-mappers.json"
core_scope_uuid=$ENSURED_SCOPE_ID
reconcile_skyapp_audience
# frontend-main and frontend-arge get their core audience scopes here as well (the scopes of
# reconcile_login_client_audience), together with the narrowing.
reconcile_login_clients
reconcile_login_client_audience "$SKYFORMS_CLIENT_ID" "$SKYFORMS_SCOPE_NAME" \
  "$CONFIG_DIR/skyforms-forms-audience-mappers.json"
reconcile_account_center_client_scopes "$scope_uuid" "$core_scope_uuid"
reconcile_account_scope_mappings
verify_mailer_client
verify_erasure_client
# Before the admin panel's step, so that a core role created here enters its scope in this run.
reconcile_core_roles
# Also before the admin panel's step: a core service role created here enters its scope in this run.
reconcile_core_service_roles
# Last: a public admin panel client stops the run, and every other step is done by then; core and
# forms roles made by earlier steps are already in place to enter the panel's scope.
reconcile_admin_panel_client

printf 'Account Center Keycloak configuration is reconciled.\n'
