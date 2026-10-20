# shellcheck shell=bash
# Sourced by run-integration.sh; uses its kcadm, fail, json_assert, v2_jwt_payload, V2_REALM,
# TEST_STATE_DIR, SCRIPT_DIR, COMPOSE and ADMIN_CONFIG, lca_client_uuid / LCA_USER from
# login-client-audiences.sh and cr_group_id from core-roles.sh.
#
# core's service roles (runbook §20): media:attach (media redesign ticket 03, ADR-0052),
# ticket:forms (core's form response Tickets, docs/form-response-tickets.md), url:forms and users:read. The reconciler
# creates them on core; the forms service account holds them. The reconciler identity has no user
# permissions, so it reports and an operator grants with the step alone
# (KEYCLOAK_RECONCILE_ONLY=service-roles; media-attach is the old name of the step), first as a dry
# run (KEYCLOAK_RECONCILE_CHECK=true). Proven with a real client-credentials token of forms: azp and
# client_id forms, aud core, resource_access.core.roles holding all four. The fixture realm gets
# forms (confidential, service account, full scope, the realm's default scopes, the standard flow on
# as in production on 2026-10-07) from core-erasure-client.sh. The operator step also makes forms
# service account only (standard flow, implicit flow and direct access grants off; core reads the
# product from client_id == azp); the reconciler identity only reports it.
# The same step grants audience:read (core #242, who a News send goes to) to SkyMail's service
# account (client skymail-backend, a fixture client) and SkyMail's roles skymail:access,
# skymail:mails:send, skymail:lists:read and skymail:lists:write to core's own service account
# (duyuru-haber ticket 04). SkyMail's roles are never created by the step: the fixture has
# skymail:access and the two list roles, skymail:mails:send comes from the mailer stage, and
# core-erasure-client.sh grants core skymail:access and skymail:mails:send by hand (production's
# state), so the step grants the two list roles.
# Mail tracking (iletisim-servisi ticket 17): communication-preferences:read (core #256, whom SkyMail
# may track) to SkyMail's service account, and skymail:tracking:withdraw (skymail-backend #75, core
# withdraws a person's tracking) to core's. The latter is the one SkyMail role the step creates (its
# line has a description). Both are service accounts' only (review condition B2 of skymail-backend
# #75): after the step each is held by its one service account and by no other user, no group, no
# composite role and not the default role; a composite holding the withdraw role is reported.
# SkyMail's service account also holds realm-management view-users and view-clients (granted by hand
# in production on 2026-09-23, codified for skymail-backend #85): it reads people through the Admin
# REST API (GET /users?email=…&exact=true, group members, its roles' holders). The fixture grants
# view-users by hand (production's shape), the step reports it held and grants view-clients; the
# real skymail-backend token then reads users and clients from the Admin REST API.

CSR_ROLES=(media:attach ticket:forms url:forms users:read)
CSR_NEW_ROLE=ticket:forms
# Held by hand before the operator step (as production's forms service account held it).
CSR_HAND_ROLE=users:read
CSR_SORTED='["media:attach","ticket:forms","url:forms","users:read"]'
CSR_ATTRIBUTE=skylab.granted-service-accounts
CSR_CLIENT=forms
CSR_ACCOUNT=service-account-forms
declare -A CSR_DESCRIPTION=(
  [media:attach]="Service attach API (media redesign ticket 03, ADR-0052): a product's service account links Media to its own records. Service accounts only; never a person or a group."
  [ticket:forms]="Forms reports its answers (POST /v1/forms/{formId}/responses, core docs/form-response-tickets.md); core writes the Tickets an accepted answer to an Event's form earns. Service accounts only; never a person or a group."
  [url:forms]="Forms service account: form-bound short links (/v1/urls/forms/{formId}) and GET /v1/urls/availability only. Grants nothing on the generic /v1/urls endpoints."
  [users:read]="Reads a person's profile (GET /v1/users/{id}); held by the Forms service account."
)
CSR_PAYLOAD=''
CSR_TOKEN=''
CSR_AUDIENCE_ROLE=audience:read
CSR_AUDIENCE_CLIENT=skymail-backend
CSR_AUDIENCE_ACCOUNT=service-account-skymail-backend
CSR_CORE_ACCOUNT=service-account-core
CSR_TRACKING_ROLE=communication-preferences:read
CSR_WITHDRAW_ROLE=skymail:tracking:withdraw
# A realm role the stage makes composite over the withdraw role, to see it reported.
CSR_WITHDRAW_PARENT=csr-withdraw-parent
# SkyMail's roles of core's service account; core-erasure-client.sh grants the first two by hand.
CSR_SKYMAIL_ROLES=(skymail:access skymail:mails:send skymail:lists:read skymail:lists:write "$CSR_WITHDRAW_ROLE")
CSR_SKYMAIL_HAND=(skymail:access skymail:mails:send)
CSR_SKYMAIL_SORTED='["skymail:access","skymail:lists:read","skymail:lists:write","skymail:mails:send","skymail:tracking:withdraw"]'
# realm-management roles of SkyMail's service account; the first is granted by hand before the step.
CSR_ADMIN_ROLES=(view-users view-clients)
CSR_ADMIN_HAND=view-users
CSR_ADMIN_SORTED='["view-clients","view-users"]'
CSR_FLAGS_OFF='.standardFlowEnabled == false and .implicitFlowEnabled == false and .directAccessGrantsEnabled == false'
CSR_FLAGS_PRODUCTION='.standardFlowEnabled == true and .implicitFlowEnabled == false and .directAccessGrantsEnabled == false'

# The step alone with the harness administrator's kcadm session (the operator path). Arguments are
# extra `exec` options (environment).
csr_operator() {
  "${COMPOSE[@]}" exec -T \
    -e "KEYCLOAK_REALM=$V2_REALM" \
    -e "KEYCLOAK_RECONCILE_KCADM_CONFIG=$ADMIN_CONFIG" \
    -e KEYCLOAK_RECONCILE_ONLY=service-roles \
    "$@" \
    keycloak /opt/keycloak/config/reconcile-account-center.sh 2>&1
}

# The step alone as the reconciler identity (account-center-config: manage-clients, no user
# permissions), the way the full reconciliation runs it. $1: the step name (default service-roles).
csr_reconciler() {
  "${COMPOSE[@]}" run --rm --no-deps -e "KEYCLOAK_RECONCILE_ONLY=${1:-service-roles}" "${@:2}" keycloak-config 2>&1
}

csr_newest_event() {
  kcadm get admin-events -r "$V2_REALM" -q max=1 -c | jq -r '.[0].time // 0'
}

csr_events_since() {
  kcadm get admin-events -r "$V2_REALM" -q max=200 -c | jq --argjson since "$1" '[.[] | select(.time > $since)] | length'
}

csr_forms_client() {
  kcadm get "clients/$(lca_client_uuid "$CSR_CLIENT")" -r "$V2_REALM" -c
}

# The resource paths of the CLIENT admin events (client updates) after $1, sorted JSON array.
csr_client_updates_since() {
  kcadm get admin-events -r "$V2_REALM" -q max=200 -c \
    | jq -c --argjson since "$1" '[.[] | select(.time > $since and .resourceType == "CLIENT") | .resourcePath] | unique'
}

csr_role_body() {
  kcadm get "clients/$(lca_client_uuid core)/roles/$1" -r "$V2_REALM" -c | jq -c '[{id, name}]'
}

# The core roles service-account-forms holds directly, sorted JSON array.
csr_account_roles() {
  local account_id
  account_id=$(kcadm get "clients/$(lca_client_uuid "$CSR_CLIENT")/service-account-user" -r "$V2_REALM" -c | jq -r .id)
  kcadm get "users/$account_id/role-mappings/clients/$(lca_client_uuid core)" -r "$V2_REALM" -c | jq -c '[.[].name] | sort'
}

csr_account_id() {
  kcadm get "clients/$(lca_client_uuid "$CSR_CLIENT")/service-account-user" -r "$V2_REALM" -c | jq -r .id
}

# The roles a client's service account holds directly on a resource client, sorted JSON array.
# $1: client, $2: resource client.
csr_account_roles_of() {
  local account_id
  account_id=$(kcadm get "clients/$(lca_client_uuid "$1")/service-account-user" -r "$V2_REALM" -c | jq -r .id)
  kcadm get "users/$account_id/role-mappings/clients/$(lca_client_uuid "$2")" -r "$V2_REALM" -c | jq -c '[.[].name] | sort'
}

# The grant record of a role ("" when absent). $1: resource client, $2: role.
csr_marker_of() {
  kcadm get "clients/$(lca_client_uuid "$1")/roles/$2" -r "$V2_REALM" -c \
    | jq -r --arg a "$CSR_ATTRIBUTE" '(.attributes // {})[$a][0] // ""'
}

# The grant records of the four roles, one "role=record" per line.
csr_markers() {
  local role
  for role in "${CSR_ROLES[@]}"; do
    printf '%s=%s\n' "$role" "$(kcadm get "clients/$(lca_client_uuid core)/roles/$role" -r "$V2_REALM" -c \
      | jq -r --arg a "$CSR_ATTRIBUTE" '(.attributes // {})[$a][0] // ""')"
  done
}

# A real client-credentials grant of CLIENT (default forms); leaves the decoded access token in
# CSR_PAYLOAD.
csr_service_token() {
  local client=${1:-$CSR_CLIENT} secret token
  secret=$(kcadm get "clients/$(lca_client_uuid "$client")/client-secret" -r "$V2_REALM" -c | jq -r '.value // empty')
  [[ -n $secret ]] || fail "client $client has no secret"
  token=$(curl --fail --silent --show-error --user "$client:$secret" \
    --data-urlencode grant_type=client_credentials \
    "http://localhost:18080/realms/$V2_REALM/protocol/openid-connect/token" | jq -r '.access_token // empty')
  [[ -n $token ]] || fail "client $client got no client-credentials access token"
  CSR_TOKEN=$token
  CSR_PAYLOAD=$(v2_jwt_payload "$token")
}

# The core roles of the token in CSR_PAYLOAD that are service roles, sorted JSON array.
csr_token_service_roles() {
  jq -c --argjson want "$CSR_SORTED" '[(.resource_access.core.roles // [])[] | select(. as $r | $want | index($r) != null)] | sort' <<<"$CSR_PAYLOAD"
}

csr_token_has_core_audience() {
  jq -e '(.aud // []) | (if type == "array" then . else [.] end) | index("core") != null' <<<"$CSR_PAYLOAD" >/dev/null
}

# The composite roles that hold role $1 of client $2 directly, "<container>/<name>" per line
# (container: realm or a clientId), the default role included; empty when none. Lists first, then
# loops: kcadm runs through `compose exec`, which would read a loop's stdin.
csr_composite_parents() {
  local role_id line listed container parent_id parent_name client_uuid client_id
  local clients=() parents=()
  role_id=$(kcadm get "clients/$(lca_client_uuid "$2")/roles/$1" -r "$V2_REALM" -c | jq -r .id)
  listed=$(kcadm get clients -r "$V2_REALM" -c | jq -r '.[] | "\(.id)\t\(.clientId)"')
  mapfile -t clients <<<"$listed"
  listed=$(kcadm get roles -r "$V2_REALM" -c | jq -r '.[] | select(.composite) | "realm\t\(.id)\t\(.name)"')
  for line in "${clients[@]}"; do
    IFS=$'\t' read -r client_uuid client_id <<<"$line"
    listed+=$'\n'$(kcadm get "clients/$client_uuid/roles" -r "$V2_REALM" -c \
      | jq -r --arg c "$client_id" '.[] | select(.composite) | "\($c)\t\(.id)\t\(.name)"')
  done
  mapfile -t parents < <(sed '/^$/d' <<<"$listed")
  # Positive control: the realm's default role is a composite, so the scan saw at least one.
  [[ ${#parents[@]} -gt 0 && ${#clients[@]} -gt 1 ]] || fail 'the composite scan read no composite role or no client'
  for line in "${parents[@]}"; do
    IFS=$'\t' read -r container parent_id parent_name <<<"$line"
    if kcadm get "roles-by-id/$parent_id/composites" -r "$V2_REALM" -c | jq -e --arg id "$role_id" 'any(.[]; .id == $id)' >/dev/null; then
      printf '%s/%s\n' "$container" "$parent_name"
    fi
  done
}

# B2: role $1 of client $2 is held by the user $3 (a service account) alone: no other user, no
# group, no composite role, not the default role.
csr_held_by_service_account_only() {
  local role=$1 resource=$2 account=$3 resource_uuid parents
  resource_uuid=$(lca_client_uuid "$resource")
  json_assert "$(kcadm get "clients/$resource_uuid/roles/$role/users" -r "$V2_REALM" -c)" \
    '[.[].username] == [$a]' "a user other than $account holds $role" --arg a "$account"
  json_assert "$(kcadm get "clients/$resource_uuid/roles/$role/groups" -r "$V2_REALM" -c)" 'length == 0' \
    "a group holds $role"
  json_assert "$(kcadm get "clients/$resource_uuid/roles/$role" -r "$V2_REALM" -c)" '.composite == false' \
    "$role is a composite"
  parents=$(csr_composite_parents "$role" "$resource")
  [[ -z $parents ]] || fail "$role is in the composite roles (the default role included): $(paste -sd, - <<<"$parents")"
}

# expect_lines OUTPUT WHO LINE...: every LINE is in OUTPUT.
csr_expect_lines() {
  local output=$1 who=$2 expected
  shift 2
  for expected in "$@"; do
    grep -Fq -- "$expected" <<<"$output" || { printf '%s\n' "$output" >&2; fail "$who did not print: $expected"; }
  done
}

# The operator step with one kcadm read failing for another reason than "not found" (KCADM_BIN
# injection): it must stop and write nothing. $1: the failing read, $2: the expected message.
csr_injected_failure_refuses() {
  local log="$TEST_STATE_DIR/service-roles-injected-failure.log" before
  before=$(csr_newest_event)
  if csr_operator -e KCADM_BIN=/tmp/kcadm-core-roles-failure.sh -e "KCADM_INJECT_FAIL=$1" >"$log"; then
    cat "$log" >&2
    fail "the service-roles step succeeded although reading $1 failed"
  fi
  grep -Fq "$2" "$log" || { cat "$log" >&2; fail "the service-roles step did not say why it stopped when reading $1 failed"; }
  [[ $(csr_events_since "$before") == 0 ]] || fail "the service-roles step wrote something after reading $1 failed"
  [[ $(csr_account_roles) == '[]' ]] || fail "the service-roles step granted a role after reading $1 failed"
}

# First reconciliation (the reconciler identity): the four roles exist with their descriptions,
# forms does not exist yet, nobody holds them.
stage_core_service_roles_after_first_reconciliation() {
  CURRENT_STAGE='core service roles: created by the first reconciliation, held by nobody'
  local log="$TEST_STATE_DIR/reconcile-first.log" core_uuid role
  core_uuid=$(lca_client_uuid core)
  for role in "${CSR_ROLES[@]}"; do
    grep -Fq "[reconcile] client role $role of core: created" "$log" \
      || fail "the first reconciliation did not create $role"
    json_assert "$(kcadm get "clients/$core_uuid/roles/$role" -r "$V2_REALM" -c)" '.description == $d and .composite == false' \
      "$role was created without its description or as a composite" --arg d "${CSR_DESCRIPTION[$role]}"
    json_assert "$(kcadm get "clients/$core_uuid/roles/$role/users" -r "$V2_REALM" -c)" 'length == 0' \
      "a user holds $role after the first reconciliation"
    json_assert "$(kcadm get "clients/$core_uuid/roles/$role/groups" -r "$V2_REALM" -c)" 'length == 0' \
      "a group holds $role after the first reconciliation"
  done
  grep -Fq "[reconcile] WARNING: client $CSR_CLIENT does not exist in realm $V2_REALM; its core service roles are not granted to its service account" "$log" \
    || fail 'the first reconciliation did not report the missing forms client'
  # audience:read: created, held by nobody, reported for SkyMail's service account.
  grep -Fq "[reconcile] client role $CSR_AUDIENCE_ROLE of core: created" "$log" \
    || fail "the first reconciliation did not create $CSR_AUDIENCE_ROLE"
  json_assert "$(kcadm get "clients/$core_uuid/roles/$CSR_AUDIENCE_ROLE" -r "$V2_REALM" -c)" '.composite == false and (.description | startswith("SkyMail asks who a News send goes to"))' \
    "$CSR_AUDIENCE_ROLE was created without its description or as a composite"
  json_assert "$(kcadm get "clients/$core_uuid/roles/$CSR_AUDIENCE_ROLE/users" -r "$V2_REALM" -c)" 'length == 0' \
    "a user holds $CSR_AUDIENCE_ROLE after the first reconciliation"
  grep -Fq "[reconcile] WARNING: $CSR_AUDIENCE_ROLE is not yet granted to service account $CSR_AUDIENCE_ACCOUNT by the operator step" "$log" \
    || fail "the first reconciliation did not report $CSR_AUDIENCE_ROLE for $CSR_AUDIENCE_ACCOUNT"
  # Mail tracking (ticket 17): communication-preferences:read on core, skymail:tracking:withdraw on
  # skymail (the one SkyMail role the step makes), both created, held by nobody, reported.
  grep -Fq "[reconcile] client role $CSR_TRACKING_ROLE of core: created" "$log" \
    || fail "the first reconciliation did not create $CSR_TRACKING_ROLE"
  json_assert "$(kcadm get "clients/$core_uuid/roles/$CSR_TRACKING_ROLE" -r "$V2_REALM" -c)" '.composite == false and (.description | startswith("SkyMail asks whom it may track"))' \
    "$CSR_TRACKING_ROLE was created without its description or as a composite"
  grep -Fq "[reconcile] client role $CSR_WITHDRAW_ROLE of skymail: created" "$log" \
    || fail "the first reconciliation did not create $CSR_WITHDRAW_ROLE"
  json_assert "$(kcadm get "clients/$(lca_client_uuid skymail)/roles/$CSR_WITHDRAW_ROLE" -r "$V2_REALM" -c)" '.composite == false and (.description | startswith("core withdraws a person'"'"'s mail tracking"))' \
    "$CSR_WITHDRAW_ROLE was created without its description or as a composite"
  for role in "$CSR_TRACKING_ROLE|core" "$CSR_WITHDRAW_ROLE|skymail"; do
    json_assert "$(kcadm get "clients/$(lca_client_uuid "${role#*|}")/roles/${role%%|*}/users" -r "$V2_REALM" -c)" 'length == 0' \
      "a user holds ${role%%|*} after the first reconciliation"
    json_assert "$(kcadm get "clients/$(lca_client_uuid "${role#*|}")/roles/${role%%|*}/groups" -r "$V2_REALM" -c)" 'length == 0' \
      "a group holds ${role%%|*} after the first reconciliation"
  done
  grep -Fq "[reconcile] WARNING: $CSR_TRACKING_ROLE is not yet granted to service account $CSR_AUDIENCE_ACCOUNT by the operator step" "$log" \
    || fail "the first reconciliation did not report $CSR_TRACKING_ROLE for $CSR_AUDIENCE_ACCOUNT"
  grep -Fq "[reconcile] WARNING: $CSR_WITHDRAW_ROLE is not yet granted to service account $CSR_CORE_ACCOUNT by the operator step" "$log" \
    || fail "the first reconciliation did not report $CSR_WITHDRAW_ROLE for $CSR_CORE_ACCOUNT"
  # SkyMail's roles of core: a missing one is reported, never created.
  grep -Fq "[reconcile] WARNING: client role skymail:mails:send of skymail does not exist in realm $V2_REALM (it is made with the client skymail, not here); it is not granted to core" "$log" \
    || fail 'the first reconciliation did not report the missing skymail:mails:send'
  # (that it did not create it is proven by stage_v2_after_first_reconciliation, which finds no
  # skymail:mails:send after the first reconciliation and creates it.)
  grep -Fq "[reconcile] WARNING: skymail:lists:write is not yet granted to service account $CSR_CORE_ACCOUNT by the operator step" "$log" \
    || fail "the first reconciliation did not report the SkyMail roles of $CSR_CORE_ACCOUNT"
}

# After core-erasure-client.sh made forms and core-roles seeded the groups, before the no-op
# reconciliation (which then proves the steady state writes nothing).
stage_core_service_roles_granted_by_operator() {
  CURRENT_STAGE='core service roles: the reconciler identity reports, it does not grant'
  local roles_scope_id audience_uuid output core_uuid forms_uuid account_id user_id admin_id new_body hand_body extra_body before markers role
  local realm_management_uuid audience_account_id
  local reconciler_lines=() operator_lines=()
  core_uuid=$(lca_client_uuid core)
  forms_uuid=$(lca_client_uuid "$CSR_CLIENT")
  [[ -n $forms_uuid ]] || fail 'core-erasure-client.sh did not leave the forms client'
  json_assert "$(kcadm get "clients/$forms_uuid" -r "$V2_REALM" -c)" '.serviceAccountsEnabled == true and .fullScopeAllowed == true' \
    'the forms fixture is not a full-scope service-account client (production shape)'
  # Production's shape on 2026-10-07: the standard flow on. core reads the product from
  # client_id == azp, so the operator step below turns it off.
  json_assert "$(csr_forms_client)" "$CSR_FLAGS_PRODUCTION" \
    'the forms fixture is not in production shape (standard flow on, implicit flow and direct access grants off)'
  csr_service_token
  [[ $(csr_token_service_roles) == '[]' ]] || fail 'the forms service token carries a core service role before any grant'

  # skymail-backend without the default client scope roles: its token would carry neither
  # resource_access.core nor aud core, so the step attaches it (client configuration, both identities).
  roles_scope_id=$(kcadm get client-scopes -r "$V2_REALM" -c | jq -r '.[] | select(.name == "roles") | .id')
  audience_uuid=$(lca_client_uuid "$CSR_AUDIENCE_CLIENT")
  kcadm delete "clients/$audience_uuid/default-client-scopes/$roles_scope_id" -r "$V2_REALM" >/dev/null
  # The step's old name still runs it.
  output=$(csr_reconciler media-attach) || { printf '%s\n' "$output" >&2; fail 'the reconciler identity failed on the service-roles step'; }
  reconciler_lines=('Core service roles are reconciled.'
    "[reconcile] default client scope roles of $CSR_CLIENT: verified"
    "[reconcile] role scope of $CSR_CLIENT: unchanged (full scope"
    "[reconcile] WARNING: client $CSR_CLIENT lets a person sign in (standardFlowEnabled not false): core reads the product from client_id == azp, so it must be service account only; nothing was changed on the client"
    'KEYCLOAK_RECONCILE_ONLY=service-roles')
  for role in "${CSR_ROLES[@]}"; do
    reconciler_lines+=("[reconcile] client role $role of core: unchanged"
      "[reconcile] WARNING: $role is not yet granted to service account $CSR_ACCOUNT by the operator step")
  done
  reconciler_lines+=("[reconcile] client role $CSR_AUDIENCE_ROLE of core: unchanged"
    "[reconcile] default client scope roles of $CSR_AUDIENCE_CLIENT: added (it puts resource_access and, through audience resolve, aud core in the token)"
    "[reconcile] WARNING: $CSR_AUDIENCE_ROLE is not yet granted to service account $CSR_AUDIENCE_ACCOUNT by the operator step"
    "[reconcile] client role $CSR_TRACKING_ROLE of core: unchanged"
    "[reconcile] WARNING: $CSR_TRACKING_ROLE is not yet granted to service account $CSR_AUDIENCE_ACCOUNT by the operator step"
    '[reconcile] default client scope roles of core: verified (it puts resource_access and, through audience resolve, aud skymail in the token)')
  for role in "${CSR_SKYMAIL_ROLES[@]}"; do
    reconciler_lines+=("[reconcile] client role $role of skymail: unchanged"
      "[reconcile] WARNING: $role is not yet granted to service account $CSR_CORE_ACCOUNT by the operator step")
  done
  for role in "${CSR_ADMIN_ROLES[@]}"; do
    reconciler_lines+=("[reconcile] client role $role of realm-management: unchanged"
      "[reconcile] WARNING: $role is not yet granted to service account $CSR_AUDIENCE_ACCOUNT by the operator step")
  done
  csr_expect_lines "$output" 'the reconciler identity' "${reconciler_lines[@]}"
  [[ $(csr_account_roles_of "$CSR_AUDIENCE_CLIENT" core) == '[]' ]] || fail "the reconciler identity granted $CSR_AUDIENCE_ROLE"
  json_assert "$(kcadm get "clients/$audience_uuid/default-client-scopes" -r "$V2_REALM" -c)" '[.[].name] | index("roles") != null' \
    "the step did not attach the default client scope roles to $CSR_AUDIENCE_CLIENT"
  [[ $(csr_account_roles) == '[]' ]] || fail 'the reconciler identity granted a core service role'
  json_assert "$(csr_forms_client)" "$CSR_FLAGS_PRODUCTION" 'the reconciler identity changed the login flags of forms'
  ! csr_markers | grep -q '=.' || fail 'the reconciler identity recorded a grant'
  # The dry run is the operator's only.
  if output=$(csr_reconciler service-roles -e KEYCLOAK_RECONCILE_CHECK=true); then
    printf '%s\n' "$output" >&2
    fail 'the reconciler identity accepted KEYCLOAK_RECONCILE_CHECK=true'
  fi
  grep -Fq 'KEYCLOAK_RECONCILE_CHECK=true is a dry run of the operator step' <<<"$output" \
    || { printf '%s\n' "$output" >&2; fail 'the refused dry run did not say why'; }

  CURRENT_STAGE='core service roles: the operator step fails closed'
  "${COMPOSE[@]}" exec -T keycloak bash -c \
    'cat >/tmp/kcadm-core-roles-failure.sh && chmod 755 /tmp/kcadm-core-roles-failure.sh' \
    <"$SCRIPT_DIR/kcadm-core-roles-failure.sh"
  csr_injected_failure_refuses "clients/$forms_uuid/default-client-scopes" \
    "The default client scopes of $CSR_CLIENT could not be read in realm $V2_REALM; nothing was granted"
  csr_injected_failure_refuses /role-mappings/clients/ \
    "The core roles of $CSR_ACCOUNT could not be read in realm $V2_REALM; nothing was granted"
  csr_injected_failure_refuses "roles/$CSR_NEW_ROLE/users" \
    "The users holding $CSR_NEW_ROLE could not be read in realm $V2_REALM; nothing was granted"
  csr_injected_failure_refuses composites/clients/ \
    "The default role default-roles-$V2_REALM could not be read in realm $V2_REALM; nothing was granted"
  # The composite scan (B2) reads every composite role's children by id; only it uses roles-by-id.
  csr_injected_failure_refuses roles-by-id/ 'The composites of '

  CURRENT_STAGE='core service roles: the dry run plans only what is missing and writes nothing'
  # Production's shape before the step: users:read granted to forms by hand. A person and a group
  # got the new role by hand, the person also users:read (people may hold it), and forms holds a
  # core role the step does not manage.
  account_id=$(csr_account_id)
  user_id=$(kcadm get users -r "$V2_REALM" -q "username=$LCA_USER" -q exact=true -c | jq -r '.[0].id')
  admin_id=$(cr_group_id /ADMIN)
  new_body=$(csr_role_body "$CSR_NEW_ROLE")
  hand_body=$(csr_role_body "$CSR_HAND_ROLE")
  extra_body=$(csr_role_body url:create)
  kcadm create "users/$account_id/role-mappings/clients/$core_uuid" -r "$V2_REALM" -b "$hand_body" >/dev/null
  kcadm create "users/$account_id/role-mappings/clients/$core_uuid" -r "$V2_REALM" -b "$extra_body" >/dev/null
  kcadm create "users/$user_id/role-mappings/clients/$core_uuid" -r "$V2_REALM" -b "$new_body" >/dev/null
  kcadm create "users/$user_id/role-mappings/clients/$core_uuid" -r "$V2_REALM" -b "$hand_body" >/dev/null
  kcadm create "groups/$admin_id/role-mappings/clients/$core_uuid" -r "$V2_REALM" -b "$new_body" >/dev/null
  # Production's shape: SkyMail's service account got realm-management roles by hand (2026-09-23).
  # Here only view-users: the step reports it held and grants view-clients. Positive control with
  # the real skymail-backend token: it reads users (view-users) but not clients (no view-clients).
  realm_management_uuid=$(lca_client_uuid realm-management)
  audience_account_id=$(kcadm get "clients/$audience_uuid/service-account-user" -r "$V2_REALM" -c | jq -r .id)
  kcadm create "users/$audience_account_id/role-mappings/clients/$realm_management_uuid" -r "$V2_REALM" \
    -b "$(kcadm get "clients/$realm_management_uuid/roles/$CSR_ADMIN_HAND" -r "$V2_REALM" -c | jq -c '[{id, name}]')" >/dev/null
  kcadm create "clients/$audience_uuid/client-secret" -r "$V2_REALM" >/dev/null 2>&1
  csr_service_token "$CSR_AUDIENCE_CLIENT"
  [[ $(v2_admin_rest_status "$CSR_TOKEN" 'users?email=audience-fixture%40example.invalid&exact=true&max=2&briefRepresentation=true') == 200 ]] \
    || fail "positive control: the $CSR_AUDIENCE_CLIENT token with $CSR_ADMIN_HAND cannot search users by e-mail"
  [[ $(v2_admin_rest_status "$CSR_TOKEN" 'clients?clientId=skymail') == 403 ]] \
    || fail "positive control: the $CSR_AUDIENCE_CLIENT token reads clients without view-clients"
  # B2: a realm role made composite over the withdraw role gives it to everyone who holds that role;
  # the step reports it and removes nothing.
  kcadm create roles -r "$V2_REALM" -s "name=$CSR_WITHDRAW_PARENT" >/dev/null
  kcadm add-roles -r "$V2_REALM" --rname "$CSR_WITHDRAW_PARENT" --cclientid skymail --rolename "$CSR_WITHDRAW_ROLE" >/dev/null
  [[ $(csr_composite_parents "$CSR_WITHDRAW_ROLE" skymail) == "realm/$CSR_WITHDRAW_PARENT" ]] \
    || fail "positive control: the composite scan does not see $CSR_WITHDRAW_ROLE in realm/$CSR_WITHDRAW_PARENT"
  before=$(csr_newest_event)
  output=$(csr_operator -e KEYCLOAK_RECONCILE_CHECK=true) || { printf '%s\n' "$output" >&2; fail 'the dry run failed'; }
  operator_lines=('Core service roles are checked; nothing was written.'
    '[reconcile] check: 23 change(s) pending; nothing was written'
    "[reconcile] would grant $CSR_AUDIENCE_ROLE to service account $CSR_AUDIENCE_ACCOUNT"
    "[reconcile] would record the grant of $CSR_AUDIENCE_ROLE ($CSR_ATTRIBUTE=<now> $CSR_AUDIENCE_ACCOUNT)"
    "[reconcile] would grant $CSR_TRACKING_ROLE to service account $CSR_AUDIENCE_ACCOUNT"
    "[reconcile] would record the grant of $CSR_TRACKING_ROLE ($CSR_ATTRIBUTE=<now> $CSR_AUDIENCE_ACCOUNT)"
    "[reconcile] would grant skymail:lists:read to service account $CSR_CORE_ACCOUNT"
    "[reconcile] would grant skymail:lists:write to service account $CSR_CORE_ACCOUNT"
    "[reconcile] would grant $CSR_WITHDRAW_ROLE to service account $CSR_CORE_ACCOUNT"
    "[reconcile] WARNING: $CSR_WITHDRAW_ROLE is in the composite roles realm/$CSR_WITHDRAW_PARENT (nothing was removed"
    "[reconcile] would set standardFlowEnabled=false on client $CSR_CLIENT (service account only: no browser login, no password grant)"
    "[reconcile] service account $CSR_ACCOUNT: $CSR_HAND_ROLE unchanged (held)"
    "[reconcile] WARNING: $CSR_NEW_ROLE is also held by the users $LCA_USER (nothing was removed"
    "[reconcile] WARNING: $CSR_NEW_ROLE is held by the groups /ADMIN (nothing was removed"
    "[reconcile] NOTE: service account $CSR_ACCOUNT also holds the core roles url:create, which this step does not manage (nothing was removed)"
    "[reconcile] service account $CSR_AUDIENCE_ACCOUNT: $CSR_ADMIN_HAND unchanged (held)"
    "[reconcile] would grant view-clients to service account $CSR_AUDIENCE_ACCOUNT")
  for role in "${CSR_ADMIN_ROLES[@]}"; do
    operator_lines+=("[reconcile] would record the grant of $role ($CSR_ATTRIBUTE=<now> $CSR_AUDIENCE_ACCOUNT)")
  done
  for role in "${CSR_ROLES[@]}"; do
    operator_lines+=("[reconcile] would record the grant of $role ($CSR_ATTRIBUTE=<now> $CSR_ACCOUNT)")
    [[ $role == "$CSR_HAND_ROLE" ]] || operator_lines+=("[reconcile] would grant $role to service account $CSR_ACCOUNT")
  done
  for role in "${CSR_SKYMAIL_ROLES[@]}"; do
    operator_lines+=("[reconcile] would record the grant of $role ($CSR_ATTRIBUTE=<now> $CSR_CORE_ACCOUNT)")
  done
  for role in "${CSR_SKYMAIL_HAND[@]}"; do
    operator_lines+=("[reconcile] service account $CSR_CORE_ACCOUNT: $role unchanged (held)")
  done
  csr_expect_lines "$output" 'the dry run' "${operator_lines[@]}"
  [[ $(csr_account_roles_of "$CSR_AUDIENCE_CLIENT" core) == '[]' ]] || fail "the dry run granted $CSR_AUDIENCE_ROLE"
  [[ $(csr_account_roles_of core skymail) == '["skymail:access","skymail:mails:send"]' ]] \
    || fail "the dry run changed the SkyMail roles of $CSR_CORE_ACCOUNT: $(csr_account_roles_of core skymail)"
  ! grep -Fq "would grant $CSR_HAND_ROLE" <<<"$output" || { printf '%s\n' "$output" >&2; fail 'the dry run planned a grant forms already holds'; }
  ! grep -Fq "would grant $CSR_ADMIN_HAND" <<<"$output" || { printf '%s\n' "$output" >&2; fail "the dry run planned a grant $CSR_AUDIENCE_ACCOUNT already holds"; }
  ! grep -Fq 'also holds the realm-management roles' <<<"$output" || { printf '%s\n' "$output" >&2; fail 'the dry run noted the composite children of the realm-management roles'; }
  [[ $(csr_account_roles_of "$CSR_AUDIENCE_CLIENT" realm-management) == "[\"$CSR_ADMIN_HAND\"]" ]] \
    || fail "the dry run changed the realm-management roles of $CSR_AUDIENCE_ACCOUNT: $(csr_account_roles_of "$CSR_AUDIENCE_CLIENT" realm-management)"
  ! grep -Fq "$CSR_HAND_ROLE is also held" <<<"$output" || { printf '%s\n' "$output" >&2; fail 'the dry run reported a person holding users:read (people may)'; }
  ! grep -Eq '\] (service account .* granted|client role .* grant recorded)' <<<"$output" \
    || { printf '%s\n' "$output" >&2; fail 'the dry run said it wrote something'; }
  ! grep -Eq 'would set (implicitFlowEnabled|directAccessGrantsEnabled)' <<<"$output" \
    || { printf '%s\n' "$output" >&2; fail 'the dry run planned to set a flag that is already off'; }
  [[ $(csr_events_since "$before") == 0 ]] || fail 'the dry run wrote something'
  json_assert "$(csr_forms_client)" "$CSR_FLAGS_PRODUCTION" 'the dry run changed the login flags of forms'
  [[ $(csr_account_roles) == "[\"url:create\",\"$CSR_HAND_ROLE\"]" ]] || fail "the dry run changed the roles of $CSR_ACCOUNT: $(csr_account_roles)"

  CURRENT_STAGE='core service roles: granted by the operator step, other holders reported and kept'
  output=$(csr_operator) || { printf '%s\n' "$output" >&2; fail 'the service-roles operator step failed'; }
  operator_lines=('Core service roles are reconciled.'
    '[reconcile] applied 23 change(s)'
    "[reconcile] service account $CSR_AUDIENCE_ACCOUNT: $CSR_ADMIN_HAND unchanged (held)"
    "[reconcile] service account $CSR_AUDIENCE_ACCOUNT: view-clients granted"
    "[reconcile] service account $CSR_AUDIENCE_ACCOUNT: $CSR_AUDIENCE_ROLE granted"
    "[reconcile] client role $CSR_AUDIENCE_ROLE of core: grant recorded ($CSR_ATTRIBUTE="
    "[reconcile] service account $CSR_AUDIENCE_ACCOUNT: $CSR_TRACKING_ROLE granted"
    "[reconcile] client role $CSR_TRACKING_ROLE of core: grant recorded ($CSR_ATTRIBUTE="
    "[reconcile] service account $CSR_CORE_ACCOUNT: skymail:lists:read granted"
    "[reconcile] service account $CSR_CORE_ACCOUNT: skymail:lists:write granted"
    "[reconcile] service account $CSR_CORE_ACCOUNT: $CSR_WITHDRAW_ROLE granted"
    "[reconcile] client role $CSR_WITHDRAW_ROLE of skymail: grant recorded ($CSR_ATTRIBUTE="
    "[reconcile] WARNING: $CSR_WITHDRAW_ROLE is in the composite roles realm/$CSR_WITHDRAW_PARENT (nothing was removed"
    "[reconcile] client role skymail:access of skymail: grant recorded ($CSR_ATTRIBUTE="
    "[reconcile] client $CSR_CLIENT: updated (standardFlowEnabled=false; service account only)"
    "[reconcile] service account $CSR_ACCOUNT: $CSR_HAND_ROLE unchanged (held)"
    "[reconcile] WARNING: $CSR_NEW_ROLE is also held by the users $LCA_USER (nothing was removed"
    "[reconcile] WARNING: $CSR_NEW_ROLE is held by the groups /ADMIN (nothing was removed"
    "[reconcile] NOTE: service account $CSR_ACCOUNT also holds the core roles url:create")
  for role in "${CSR_ROLES[@]}"; do
    operator_lines+=("[reconcile] client role $role of core: grant recorded ($CSR_ATTRIBUTE=")
    [[ $role == "$CSR_HAND_ROLE" ]] || operator_lines+=("[reconcile] service account $CSR_ACCOUNT: $role granted")
  done
  csr_expect_lines "$output" 'the operator step' "${operator_lines[@]}"
  json_assert "$(csr_forms_client)" "$CSR_FLAGS_OFF and .serviceAccountsEnabled == true and .fullScopeAllowed == true and .publicClient == false" \
    'the operator step did not make forms service account only (or changed another of its settings)'
  # forms is the only client the step updated.
  [[ $(csr_client_updates_since "$before") == "[\"clients/$forms_uuid\"]" ]] \
    || fail "the operator step updated another client than forms: $(csr_client_updates_since "$before")"
  [[ $(csr_account_roles) == '["media:attach","ticket:forms","url:create","url:forms","users:read"]' ]] \
    || fail "$CSR_ACCOUNT does not hold exactly the four core service roles and the hand-made url:create: $(csr_account_roles)"
  markers=$(csr_markers)
  for role in "${CSR_ROLES[@]}"; do
    grep -Eq "^$role=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z $CSR_ACCOUNT\$" <<<"$markers" \
      || fail "the grant record of $role is not '<UTC time> $CSR_ACCOUNT': $markers"
  done
  [[ $(csr_account_roles_of "$CSR_AUDIENCE_CLIENT" core) == "[\"$CSR_AUDIENCE_ROLE\",\"$CSR_TRACKING_ROLE\"]" ]] \
    || fail "$CSR_AUDIENCE_ACCOUNT does not hold exactly $CSR_AUDIENCE_ROLE and $CSR_TRACKING_ROLE: $(csr_account_roles_of "$CSR_AUDIENCE_CLIENT" core)"
  for role in "$CSR_AUDIENCE_ROLE" "$CSR_TRACKING_ROLE"; do
    [[ $(csr_marker_of core "$role") =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\ $CSR_AUDIENCE_ACCOUNT$ ]] \
      || fail "the grant record of $role is wrong: $(csr_marker_of core "$role")"
  done
  [[ $(csr_account_roles_of core skymail) == "$CSR_SKYMAIL_SORTED" ]] \
    || fail "$CSR_CORE_ACCOUNT does not hold exactly SkyMail's five roles: $(csr_account_roles_of core skymail)"
  [[ $(csr_account_roles_of "$CSR_AUDIENCE_CLIENT" realm-management) == "$CSR_ADMIN_SORTED" ]] \
    || fail "$CSR_AUDIENCE_ACCOUNT does not hold exactly view-users and view-clients: $(csr_account_roles_of "$CSR_AUDIENCE_CLIENT" realm-management)"
  for role in "${CSR_ADMIN_ROLES[@]}"; do
    csr_expect_lines "$output" 'the operator step' "[reconcile] client role $role of realm-management: grant recorded ($CSR_ATTRIBUTE="
    [[ $(csr_marker_of realm-management "$role") =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\ $CSR_AUDIENCE_ACCOUNT$ ]] \
      || fail "the grant record of $role is wrong: $(csr_marker_of realm-management "$role")"
  done
  for role in "${CSR_SKYMAIL_ROLES[@]}"; do
    [[ $(csr_marker_of skymail "$role") =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\ $CSR_CORE_ACCOUNT$ ]] \
      || fail "the grant record of $role is wrong: $(csr_marker_of skymail "$role")"
  done
  json_assert "$(kcadm get "users/$user_id/role-mappings/clients/$core_uuid" -r "$V2_REALM" -c)" \
    '[.[].name] | index($r) != null' "the operator step removed $CSR_NEW_ROLE from a person" --arg r "$CSR_NEW_ROLE"
  json_assert "$(kcadm get "groups/$admin_id/role-mappings/clients/$core_uuid" -r "$V2_REALM" -c)" \
    '[.[].name] | index($r) != null' "the operator step removed $CSR_NEW_ROLE from a group" --arg r "$CSR_NEW_ROLE"
  kcadm delete "users/$user_id/role-mappings/clients/$core_uuid" -r "$V2_REALM" -b "$new_body" >/dev/null
  kcadm delete "users/$user_id/role-mappings/clients/$core_uuid" -r "$V2_REALM" -b "$hand_body" >/dev/null
  kcadm delete "groups/$admin_id/role-mappings/clients/$core_uuid" -r "$V2_REALM" -b "$new_body" >/dev/null
  kcadm delete "users/$account_id/role-mappings/clients/$core_uuid" -r "$V2_REALM" -b "$extra_body" >/dev/null
  [[ $(csr_account_roles) == "$CSR_SORTED" ]] || fail "$CSR_ACCOUNT does not hold exactly the four core service roles"
  json_assert "$(kcadm get "roles/$CSR_WITHDRAW_PARENT/composites/clients/$(lca_client_uuid skymail)" -r "$V2_REALM" -c)" \
    '[.[].name] == [$r]' "the operator step removed $CSR_WITHDRAW_ROLE from the composite realm/$CSR_WITHDRAW_PARENT" --arg r "$CSR_WITHDRAW_ROLE"
  kcadm delete "roles/$CSR_WITHDRAW_PARENT" -r "$V2_REALM" >/dev/null

  CURRENT_STAGE='core service roles: in the forms client-credentials token, and nowhere else'
  # The client-credentials grant still works with the standard flow off, with the same roles.
  csr_service_token
  json_assert "$CSR_PAYLOAD" '.azp == "forms" and .client_id == "forms"' \
    'the forms service token does not name forms in azp and client_id'
  csr_token_has_core_audience || fail 'the forms service token does not carry aud core'
  [[ $(csr_token_service_roles) == "$CSR_SORTED" ]] \
    || fail "the forms service token lacks a core service role: $(csr_token_service_roles)"
  # No other service account gets the new role: the only user holding it is forms' service
  # account, no group holds it, and core-erasure's real token lacks it.
  json_assert "$(kcadm get "clients/$core_uuid/roles/$CSR_NEW_ROLE/users" -r "$V2_REALM" -c)" \
    '[.[].username] == [$a]' "a user other than $CSR_ACCOUNT holds $CSR_NEW_ROLE" --arg a "$CSR_ACCOUNT"
  json_assert "$(kcadm get "clients/$core_uuid/roles/$CSR_NEW_ROLE/groups" -r "$V2_REALM" -c)" 'length == 0' \
    "a group holds $CSR_NEW_ROLE"
  csr_service_token core-erasure
  [[ $(csr_token_service_roles) == '[]' ]] || fail "the core-erasure service token carries a core service role: $(csr_token_service_roles)"
  json_assert "$CSR_PAYLOAD" '(.resource_access.core.roles // []) | index($r) == null' \
    "the core-erasure service token carries $CSR_AUDIENCE_ROLE" --arg r "$CSR_AUDIENCE_ROLE"

  CURRENT_STAGE='core service roles: audience:read in the SkyMail service token, SkyMail roles in the core token'
  kcadm create "clients/$(lca_client_uuid "$CSR_AUDIENCE_CLIENT")/client-secret" -r "$V2_REALM" >/dev/null 2>&1
  csr_service_token "$CSR_AUDIENCE_CLIENT"
  json_assert "$CSR_PAYLOAD" '.azp == $c and ((.resource_access.core.roles // []) | index($r) != null)' \
    "the $CSR_AUDIENCE_CLIENT service token lacks $CSR_AUDIENCE_ROLE" --arg c "$CSR_AUDIENCE_CLIENT" --arg r "$CSR_AUDIENCE_ROLE"
  csr_token_has_core_audience || fail "the $CSR_AUDIENCE_CLIENT service token does not carry aud core"
  [[ $(csr_token_service_roles) == '[]' ]] || fail "the $CSR_AUDIENCE_CLIENT service token carries a forms service role"
  json_assert "$(kcadm get "clients/$core_uuid/roles/$CSR_AUDIENCE_ROLE/users" -r "$V2_REALM" -c)" \
    '[.[].username] == [$a]' "a user other than $CSR_AUDIENCE_ACCOUNT holds $CSR_AUDIENCE_ROLE" --arg a "$CSR_AUDIENCE_ACCOUNT"
  csr_service_token core
  json_assert "$CSR_PAYLOAD" '((.resource_access.skymail.roles // []) | sort) == $want' \
    "the core service token does not carry SkyMail's five roles" --argjson want "$CSR_SKYMAIL_SORTED"

  CURRENT_STAGE='core service roles: mail tracking roles in their service tokens only (B2)'
  # SkyMail's tracking:resolve call: azp skymail-backend, aud core, communication-preferences:read.
  csr_service_token "$CSR_AUDIENCE_CLIENT"
  json_assert "$CSR_PAYLOAD" '.azp == $c and ((.resource_access.core.roles // []) | index($r) != null)' \
    "the $CSR_AUDIENCE_CLIENT service token lacks $CSR_TRACKING_ROLE" --arg c "$CSR_AUDIENCE_CLIENT" --arg r "$CSR_TRACKING_ROLE"
  csr_token_has_core_audience || fail "the $CSR_AUDIENCE_CLIENT service token does not carry aud core"
  # core's withdrawal: azp core, aud skymail, skymail:tracking:withdraw.
  csr_service_token core
  json_assert "$CSR_PAYLOAD" '.azp == "core" and ((.aud // []) | (if type == "array" then . else [.] end) | index("skymail") != null) and ((.resource_access.skymail.roles // []) | index($r) != null)' \
    "the core service token lacks aud skymail or $CSR_WITHDRAW_ROLE" --arg r "$CSR_WITHDRAW_ROLE"
  # The erasure client is another core client: its token must not withdraw (ticket 17).
  csr_service_token core-erasure
  json_assert "$CSR_PAYLOAD" '(.resource_access.skymail.roles // []) | index($r) == null' \
    "the core-erasure service token carries $CSR_WITHDRAW_ROLE" --arg r "$CSR_WITHDRAW_ROLE"
  json_assert "$CSR_PAYLOAD" '(.resource_access.core.roles // []) | index($r) == null' \
    "the core-erasure service token carries $CSR_TRACKING_ROLE" --arg r "$CSR_TRACKING_ROLE"
  # Each held by its one service account: no other user, no group, no composite, not the default role.
  csr_held_by_service_account_only "$CSR_WITHDRAW_ROLE" skymail "$CSR_CORE_ACCOUNT"
  csr_held_by_service_account_only "$CSR_TRACKING_ROLE" core "$CSR_AUDIENCE_ACCOUNT"

  CURRENT_STAGE='core service roles: the SkyMail service token reads users and clients (realm-management)'
  csr_service_token "$CSR_AUDIENCE_CLIENT"
  [[ $(v2_admin_rest_status "$CSR_TOKEN" 'users?email=audience-fixture%40example.invalid&exact=true&max=2&briefRepresentation=true') == 200 ]] \
    || fail "the $CSR_AUDIENCE_CLIENT token cannot search users by e-mail after the step"
  [[ $(v2_admin_rest_status "$CSR_TOKEN" 'clients?clientId=skymail') == 200 ]] \
    || fail "the $CSR_AUDIENCE_CLIENT token cannot read clients after the step"

  CURRENT_STAGE='core service roles: a second operator step writes nothing'
  before=$(csr_newest_event)
  output=$(csr_operator) || { printf '%s\n' "$output" >&2; fail 'the second service-roles operator step failed'; }
  operator_lines=('[reconcile] applied 0 change(s)'
    "[reconcile] client $CSR_CLIENT: service account only, verified (standardFlowEnabled implicitFlowEnabled directAccessGrantsEnabled false)")
  for role in "${CSR_ROLES[@]}"; do
    operator_lines+=("[reconcile] service account $CSR_ACCOUNT: $role unchanged (held)")
  done
  operator_lines+=("[reconcile] service account $CSR_AUDIENCE_ACCOUNT: $CSR_AUDIENCE_ROLE unchanged (held)"
    "[reconcile] service account $CSR_AUDIENCE_ACCOUNT: $CSR_TRACKING_ROLE unchanged (held)")
  for role in "${CSR_ADMIN_ROLES[@]}"; do
    operator_lines+=("[reconcile] service account $CSR_AUDIENCE_ACCOUNT: $role unchanged (held)")
  done
  for role in "${CSR_SKYMAIL_ROLES[@]}"; do
    operator_lines+=("[reconcile] service account $CSR_CORE_ACCOUNT: $role unchanged (held)")
  done
  csr_expect_lines "$output" 'the second operator step' "${operator_lines[@]}"
  ! grep -Eq 'granted$|grant recorded|WARNING|NOTE' <<<"$output" || { printf '%s\n' "$output" >&2; fail 'the second operator step changed or reported something'; }
  [[ $(csr_events_since "$before") == 0 ]] || fail 'the second operator step wrote something'
  [[ $(csr_markers) == "$markers" ]] || fail 'the second operator step rewrote a grant record'
  output=$(csr_operator -e KEYCLOAK_RECONCILE_CHECK=true) || { printf '%s\n' "$output" >&2; fail 'the dry run after the grant failed'; }
  csr_expect_lines "$output" 'the dry run after the grant' '[reconcile] check: 0 change(s) pending; nothing was written'
  ! grep -Fq '] would ' <<<"$output" || { printf '%s\n' "$output" >&2; fail 'the dry run after the grant planned a change'; }

  CURRENT_STAGE='core service roles: without full scope the roles are mapped into the forms token'
  kcadm update "clients/$forms_uuid" -r "$V2_REALM" -s fullScopeAllowed=false >/dev/null
  csr_service_token
  [[ $(csr_token_service_roles) == '[]' ]] || fail 'positive control: without full scope and a mapping a role still reached the token'
  output=$(csr_reconciler) || { printf '%s\n' "$output" >&2; fail 'the reconciler identity failed on a forms client without full scope'; }
  reconciler_lines=()
  for role in "${CSR_ROLES[@]}"; do
    reconciler_lines+=("[reconcile] role scope of $CSR_CLIENT: updated (+core/$role; fullScopeAllowed is false)"
      "[reconcile] service account $CSR_ACCOUNT: $role unchanged (granted by the operator step at ")
  done
  csr_expect_lines "$output" 'the reconciler identity' "${reconciler_lines[@]}"
  ! grep -Fq WARNING <<<"$output" || { printf '%s\n' "$output" >&2; fail 'the reconciler identity warned after the grant'; }
  csr_service_token
  [[ $(csr_token_service_roles) == "$CSR_SORTED" ]] \
    || fail "the mapped roles did not reach the forms token without full scope: $(csr_token_service_roles)"
  csr_token_has_core_audience || fail 'the forms service token without full scope does not carry aud core'
  # Back to production's shape; the mappings stay (harmless with full scope).
  kcadm update "clients/$forms_uuid" -r "$V2_REALM" -s fullScopeAllowed=true >/dev/null
}

# Part of v2_state_snapshot: the forms client's flags (login flags included), role scope and service-account roles of core.
csr_state_snapshot() {
  local forms_uuid
  forms_uuid=$(lca_client_uuid "$CSR_CLIENT")
  kcadm get "clients/$forms_uuid" -r "$V2_REALM" -c \
    | jq -c '{fullScopeAllowed, serviceAccountsEnabled, standardFlowEnabled, implicitFlowEnabled, directAccessGrantsEnabled}'
  kcadm get "clients/$forms_uuid/scope-mappings/clients/$(lca_client_uuid core)" -r "$V2_REALM" -c | jq -c '[.[].name] | sort'
  csr_account_roles
  csr_markers | jq -R -c .
}
