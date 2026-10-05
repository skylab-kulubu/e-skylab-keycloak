# shellcheck shell=bash
# Sourced by run-integration.sh; uses its kcadm, fail, json_assert, v2_jwt_payload, v2_role_body,
# V2_REALM, TEST_STATE_DIR, COMPOSE and ADMIN_CONFIG, and lca_login / lca_client_uuid /
# lca_scope_uuids from login-client-audiences.sh.
#
# The admin panel's login client (admin; superadmin in the sandbox realm) and its narrowed token
# (ADR-0058, admin-token-authz ticket 02). The fixture client has production's hand-made shape:
# confidential, full scope, inscribed's flat roles mapper and a full-path groups mapper. After the
# reconciler, a real authorization code login of the panel must give exactly aud core, forms and
# skycms, no realm_access, resource_access only core, forms and the panel's own roles, while the
# panel's own roles claim and the groups stay; Standard Token Exchange must turn that token into a
# token for one of the three APIs and refuse any other audience.
#
# The fixture realm has core but not forms (core-erasure-client.sh makes forms and skycms later),
# so the first two passes map only core roles and warn about forms; the last stage runs the step
# alone with an operator session once forms exists, the way the sandbox realm is reconciled.
#
# The exchanged token must keep what each API reads (admin-token-authz K1, the gate of the panel's
# BFF): tests/admin-panel-exchanged-token.jq is that contract, checked for a Privileged person, a
# team Leader and a plain member whose roles come from groups as in production.

AP_CLIENT=admin
AP_SCOPE=admin-panel-api-audience
AP_USER=admin-panel-fixture
AP_PASSWORD=admin-panel-fixture-password-change-me
AP_REDIRECT=https://admin.yildizskylab.com/api/auth/callback
# What core-frontend asks for (src/lib/auth/oauth2.ts).
AP_PANEL_SCOPE='openid profile email'
AP_FORMS_ROLE=skyforms:form:manage
AP_APIS=(core forms skycms)
AP_EXCHANGE_CONTRACT="$SCRIPT_DIR/admin-panel-exchanged-token.jq"
# The forms role forms-backend checks (HasRoleAsync("skyforms:*", "forms")), held in production
# through groups.
AP_FORMS_CHECKED_ROLE='skyforms:*'
# The people of the exchange proof and the team groups under the fixture's /UYELER (production's
# shape: a member is in /UYELER/<unit>/<team>, its Leader also in the team's LIDERLER subgroup).
AP_PRIVILEGED_USER=admin-panel-privileged-fixture
AP_LEADER_USER=admin-panel-leader-fixture
AP_MEMBER_USER=admin-panel-member-fixture
AP_PEOPLE_PASSWORD=admin-panel-people-password-change-me
AP_TEAM_PATH=/UYELER/ARGE/WEBLAB
AP_LEADERS_PATH=/UYELER/ARGE/WEBLAB/LIDERLER
AP_UUID=''
AP_SECRET=''
AP_EXCHANGE_STATUS=''
AP_EXCHANGE_BODY=''
AP_EXCHANGED_PAYLOAD=''

ap_client_secret() {
  kcadm get "clients/$AP_UUID/client-secret" -r "$V2_REALM" -c | jq -r '.value // empty'
}

# The reconciler step alone, inside the Keycloak container with the harness administrator's kcadm
# session: the operator path the sandbox realm (no reconciler identity there) is reconciled with.
ap_operator_reconcile() {
  local client_id=$1
  shift
  "${COMPOSE[@]}" exec -T \
    -e "KEYCLOAK_REALM=$V2_REALM" \
    -e "KEYCLOAK_RECONCILE_KCADM_CONFIG=$ADMIN_CONFIG" \
    -e "KEYCLOAK_ADMIN_PANEL_CLIENT_ID=$client_id" \
    "$@" \
    keycloak /opt/keycloak/config/reconcile-account-center.sh 2>&1
}

# ap_exchange <subject access token> <audience> [<parameter>=<value>...]: Standard Token Exchange by
# the panel's client, as the panel's server will ask (no scope); leaves the HTTP status and the
# response body in AP_EXCHANGE_STATUS and AP_EXCHANGE_BODY.
ap_exchange() {
  local body="$TEST_STATE_DIR/ap-exchange.body" pair extra=()
  for pair in "${@:3}"; do extra+=(--data-urlencode "$pair"); done
  AP_EXCHANGE_STATUS=$(curl --silent --show-error \
    --output "$body" \
    --write-out '%{http_code}' \
    --user "$AP_CLIENT:$AP_SECRET" \
    --data-urlencode grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
    --data-urlencode "subject_token=$1" \
    --data-urlencode subject_token_type=urn:ietf:params:oauth:token-type:access_token \
    --data-urlencode "audience=$2" \
    ${extra[@]+"${extra[@]}"} \
    "http://localhost:18080/realms/$V2_REALM/protocol/openid-connect/token")
  AP_EXCHANGE_BODY=$(cat "$body")
  rm -f "$body"
}

# ap_assert_exchanged <subject access token> <its payload> <audience> <who>: the exchange to one API
# succeeds with one access token (no refresh or ID token) that keeps
# tests/admin-panel-exchanged-token.jq; leaves its payload in AP_EXCHANGED_PAYLOAD.
ap_assert_exchanged() {
  local token=$1 subject=$2 audience=$3 who=$4 violations
  ap_exchange "$token" "$audience"
  [[ $AP_EXCHANGE_STATUS == 200 ]] \
    || fail "the exchange to $audience for $who was refused (HTTP $AP_EXCHANGE_STATUS, $(jq -r '.error + ": " + .error_description' <<<"$AP_EXCHANGE_BODY"))"
  json_assert "$AP_EXCHANGE_BODY" \
    '.issued_token_type == "urn:ietf:params:oauth:token-type:access_token" and (has("refresh_token") | not) and (has("id_token") | not)' \
    "the exchange to $audience for $who returned more than one access token"
  AP_EXCHANGED_PAYLOAD=$(v2_jwt_payload "$(jq -r .access_token <<<"$AP_EXCHANGE_BODY")")
  violations=$(jq -c --arg aud "$audience" --argjson subject "$subject" -f "$AP_EXCHANGE_CONTRACT" <<<"$AP_EXCHANGED_PAYLOAD")
  [[ $violations == '[]' ]] \
    || fail "the token exchanged to $audience for $who breaks the contract: $(jq -r 'join("; ")' <<<"$violations")"
}

# ap_effective_roles <user id> <clientId>: the person's effective roles of one client (direct, from
# groups and composites) as Keycloak's admin API reports them, a sorted JSON array.
ap_effective_roles() {
  kcadm get "users/$1/role-mappings/clients/$(lca_client_uuid "$2")/composite" -r "$V2_REALM" -c \
    | jq -c '[.[].name] | sort'
}

# ap_group_id <path>: the id of a group by its full path.
ap_group_id() {
  kcadm get "group-by-path$1" -r "$V2_REALM" -c | jq -r .id
}

# ap_grant_group <path> <clientId> <role>...: client roles to a group (the SKY LAB admin panel's
# grants); role names may hold * and :, so they are looked up, not put in a URL.
ap_grant_group() {
  local path=$1 client=$2 client_uuid
  shift 2
  client_uuid=$(lca_client_uuid "$client")
  kcadm create "groups/$(ap_group_id "$path")/role-mappings/clients/$client_uuid" -r "$V2_REALM" \
    -b "$(kcadm get "clients/$client_uuid/roles" -r "$V2_REALM" -c \
      | jq -c --args '[.[] | select(.name | IN($ARGS.positional[])) | {id, name}]' "$@")" >/dev/null
}

# ap_person <username> <group path>...: a person who signs in with AP_PEOPLE_PASSWORD; prints the id.
ap_person() {
  local username=$1 id path
  shift
  id=$(kcadm create users -r "$V2_REALM" -i -s "username=$username" -s enabled=true \
    -s "email=$username@example.invalid" -s emailVerified=true -s firstName=Admin -s lastName=Exchange)
  kcadm set-password -r "$V2_REALM" --userid "$id" --new-password "$AP_PEOPLE_PASSWORD" >/dev/null
  for path in "$@"; do
    kcadm update "users/$id/groups/$(ap_group_id "$path")" -r "$V2_REALM" -n -b '{}' >/dev/null
  done
  printf '%s\n' "$id"
}

# ap_assert_person_exchanges <username> <user id>: the person's real panel login, then the exchange
# to each API. The panel's token must carry exactly the person's effective core, forms and panel
# roles and group paths (so the contract's "every claim kept" is not vacuous); each exchanged token
# keeps the contract and carries what its API reads. Prints one evidence line (claim names only).
ap_assert_person_exchanges() {
  local who=$1 id=$2 core forms panel groups token subject audience shapes=()
  core=$(ap_effective_roles "$id" core)
  forms=$(ap_effective_roles "$id" forms)
  panel=$(ap_effective_roles "$id" "$AP_CLIENT")
  groups=$(kcadm get "users/$id/groups" -r "$V2_REALM" -c | jq -c '[.[].path] | sort')
  lca_login "$AP_CLIENT" "$AP_REDIRECT" "$AP_SECRET" "$who" "$AP_PEOPLE_PASSWORD" "$AP_PANEL_SCOPE"
  token=$LCA_ACCESS_TOKEN
  subject=$LCA_ACCESS_PAYLOAD
  json_assert "$subject" \
    '(.resource_access.core.roles // [] | sort) == $core and (.resource_access.forms.roles // [] | sort) == $forms
      and (.resource_access[$client].roles // [] | sort) == $panel and (.roles // [] | sort) == $panel
      and ((.resource_access // {}) | keys - [$client, "core", "forms"]) == [] and (.groups // [] | sort) == $groups
      and (has("realm_access") | not) and (.sid | type) == "string"' \
    "the panel token of $who does not carry exactly their roles and group paths" \
    --arg client "$AP_CLIENT" --argjson core "$core" --argjson forms "$forms" --argjson panel "$panel" \
    --argjson groups "$groups"
  for audience in "${AP_APIS[@]}"; do
    ap_assert_exchanged "$token" "$subject" "$audience" "$who"
    case $audience in
      core)
        json_assert "$AP_EXCHANGED_PAYLOAD" '(.resource_access.core.roles // [] | sort) == $core and (.groups // [] | sort) == $groups' \
          "the core token of $who lost core's roles or the group paths" --argjson core "$core" --argjson groups "$groups"
        ;;
      forms)
        json_assert "$AP_EXCHANGED_PAYLOAD" '(.resource_access.forms.roles // [] | sort) == $forms' \
          "the forms token of $who lost the forms roles" --argjson forms "$forms"
        ;;
      skycms)
        json_assert "$AP_EXCHANGED_PAYLOAD" \
          '.azp == $client and (.roles // [] | sort) == $panel and (.groups // [] | sort) == $groups and ((.resource_access // {}) | length) == 0' \
          "the skycms token of $who lost the tenant, the flat roles or the group paths" \
          --arg client "$AP_CLIENT" --argjson panel "$panel" --argjson groups "$groups"
        ;;
    esac
    shapes+=("$audience$(jq -c '.resource_access // {} | keys' <<<"$AP_EXCHANGED_PAYLOAD")")
  done
  printf '    %s: %s core, %s forms, %s panel role(s), %s group path(s); resource_access %s; every exchanged token keeps %s\n' \
    "$who" "$(jq length <<<"$core")" "$(jq length <<<"$forms")" "$(jq length <<<"$panel")" "$(jq length <<<"$groups")" \
    "${shapes[*]}" "$(jq -c '[keys[] | select(IN("exp", "iat", "jti", "aud", "resource_access") | not)]' <<<"$AP_EXCHANGED_PAYLOAD")"
}

# The reconciled contract of the panel's client; the arguments are the API clients whose every
# role must be in its scope (forms once it exists).
ap_assert_contract() {
  local client scope_uuid mappings resource resource_uuid mapped every
  client=$(kcadm get "clients/$AP_UUID" -r "$V2_REALM" -c)
  json_assert "$client" \
    '.clientId == $client and .publicClient == false and .fullScopeAllowed == false and .attributes["standard.token.exchange.enabled"] == "true" and .redirectUris == [$redirect]' \
    'the admin client differs from the contract (confidential, no full scope, standard token exchange, redirect kept)' \
    --arg client "$AP_CLIENT" --arg redirect "$AP_REDIRECT"
  json_assert "$client" '[.protocolMappers[].name] | sort == ["groups", "inscribed-roles"]' \
    "the reconciler touched the admin client's own mappers"
  [[ $(ap_client_secret) == "$AP_SECRET" ]] || fail 'reconciliation changed the admin client secret'
  json_assert "$(kcadm get "clients/$AP_UUID/scope-mappings/realm" -r "$V2_REALM" -c)" 'length == 0' \
    'a realm role is still in the scope of the admin client'
  mappings=$(kcadm get "clients/$AP_UUID/scope-mappings" -r "$V2_REALM" -c)
  json_assert "$mappings" '(.clientMappings // {}) | keys == ($want | split(" ") | sort)' \
    'the admin client has role scope mappings of other clients than the APIs it calls' --arg want "$*"
  for resource in "$@"; do
    resource_uuid=$(lca_client_uuid "$resource")
    mapped=$(kcadm get "clients/$AP_UUID/scope-mappings/clients/$resource_uuid" -r "$V2_REALM" -c \
      | jq -c '[.[].name] | sort')
    every=$(kcadm get "clients/$resource_uuid/roles" -r "$V2_REALM" -c | jq -c '[.[].name] | sort')
    [[ $mapped == "$every" ]] || fail "the admin client's scope holds $mapped of $resource instead of every role $every"
  done
  scope_uuid=$(lca_scope_uuids "$AP_SCOPE")
  [[ -n $scope_uuid && $scope_uuid != *$'\n'* ]] || fail "client scope $AP_SCOPE is missing or duplicated"
  json_assert "$(kcadm get "client-scopes/$scope_uuid" -r "$V2_REALM" -c)" \
    '.protocol == "openid-connect" and .attributes["include.in.token.scope"] == "false" and .attributes["display.on.consent.screen"] == "false"' \
    "client scope $AP_SCOPE differs"
  json_assert "$(kcadm get "client-scopes/$scope_uuid/protocol-mappers/models" -r "$V2_REALM" -c)" \
    '(map({name, protocolMapper, aud: .config["included.client.audience"], access: .config["access.token.claim"], id: .config["id.token.claim"], introspection: .config["introspection.token.claim"]}) | sort_by(.name))
      == [{"name": "core-audience", "protocolMapper": "oidc-audience-mapper", "aud": "core", "access": "true", "id": "false", "introspection": "true"},
          {"name": "forms-audience", "protocolMapper": "oidc-audience-mapper", "aud": "forms", "access": "true", "id": "false", "introspection": "true"},
          {"name": "skycms-audience", "protocolMapper": "oidc-audience-mapper", "aud": "skycms", "access": "true", "id": "false", "introspection": "true"}]' \
    "the mappers of $AP_SCOPE differ or a foreign mapper remains"
  json_assert "$(kcadm get "clients/$AP_UUID/default-client-scopes" -r "$V2_REALM" -c)" \
    '[.[] | select(.id == $id)] | length == 1' "$AP_SCOPE is not a default scope of $AP_CLIENT" --arg id "$scope_uuid"
  json_assert "$(kcadm get "clients/$AP_UUID/optional-client-scopes" -r "$V2_REALM" -c)" \
    '[.[] | select(.id == $id)] | length == 0' "$AP_SCOPE is still an optional scope of $AP_CLIENT" --arg id "$scope_uuid"
}

# Before the first reconciliation: production's client as it is today (hand-made, confidential,
# full scope, a client secret the panel holds). The positive control shows what full scope puts in
# the panel's token for this person: roles of an unrelated client and realm roles.
stage_admin_panel_hand_made() {
  CURRENT_STAGE='admin panel client: the hand-made production client'
  AP_UUID=$(lca_client_uuid "$AP_CLIENT")
  [[ -n $AP_UUID ]] || fail 'the fixture realm lacks the admin client'
  json_assert "$(kcadm get "clients/$AP_UUID" -r "$V2_REALM" -c)" '.publicClient == false and .fullScopeAllowed == true' \
    'the fixture admin client is not shaped like production (confidential, full scope)'
  kcadm create "clients/$AP_UUID/client-secret" -r "$V2_REALM" >/dev/null 2>&1
  AP_SECRET=$(ap_client_secret)
  [[ -n $AP_SECRET ]] || fail 'the fixture admin client has no client secret'
  lca_login "$AP_CLIENT" "$AP_REDIRECT" "$AP_SECRET" "$AP_USER" "$AP_PASSWORD" "$AP_PANEL_SCOPE"
  json_assert "$LCA_ACCESS_PAYLOAD" \
    '((.aud | if type == "array" then . else [.] end) | index("skymail")) != null and ((.realm_access.roles // []) | index("offline_access")) != null and (.resource_access | has("skymail"))' \
    'the full-scope control token lacks the foreign roles of the fixture person; the narrowing assertions would prove nothing'
}

# After the first reconciliation: the hand-made client is narrowed in place (same id, same secret),
# forms is reported missing. Then the client drifts before the second pass.
stage_admin_panel_after_first_reconciliation() {
  CURRENT_STAGE='admin panel client: narrowed in place by the first reconciliation'
  local log="$TEST_STATE_DIR/reconcile-first.log" scope_uuid mapper_uuid core_uuid skymail_uuid
  grep -Fq "[reconcile] client scope $AP_SCOPE: created" "$log" \
    || fail 'the first reconciliation did not create the admin panel audience scope'
  grep -Fq "[reconcile] WARNING: client forms does not exist in realm $V2_REALM; no forms role is in the scope of $AP_CLIENT" "$log" \
    || fail 'the first reconciliation did not report the missing forms client'
  grep -Fq "[reconcile] client $AP_CLIENT (no full scope, standard token exchange): updated (fullScopeAllowed attributes)" "$log" \
    || fail 'the first reconciliation did not narrow the hand-made admin client'
  [[ $(lca_client_uuid "$AP_CLIENT") == "$AP_UUID" ]] || fail 'the admin client was replaced instead of adopted'
  ap_assert_contract core

  # Drift: full scope back on, token exchange off, a core role out of the scope, a realm role and a
  # foreign client role in it, the audience scope among the optional scopes, one audience mapper
  # into the ID token and a foreign mapper.
  core_uuid=$(lca_client_uuid core)
  skymail_uuid=$(lca_client_uuid skymail)
  scope_uuid=$(lca_scope_uuids "$AP_SCOPE")
  kcadm update "clients/$AP_UUID" -r "$V2_REALM" \
    -s fullScopeAllowed=true -s 'attributes."standard.token.exchange.enabled"=false' >/dev/null
  kcadm delete "clients/$AP_UUID/scope-mappings/clients/$core_uuid" -r "$V2_REALM" \
    -b "$(v2_role_body "$core_uuid" url:read)" >/dev/null
  kcadm create "clients/$AP_UUID/scope-mappings/clients/$skymail_uuid" -r "$V2_REALM" \
    -b "$(v2_role_body "$skymail_uuid" skymail:access)" >/dev/null
  kcadm create "clients/$AP_UUID/scope-mappings/realm" -r "$V2_REALM" \
    -b "$(kcadm get roles/offline_access -r "$V2_REALM" -c | jq -c '[{id, name}]')" >/dev/null
  kcadm delete "clients/$AP_UUID/default-client-scopes/$scope_uuid" -r "$V2_REALM" >/dev/null
  kcadm update "clients/$AP_UUID/optional-client-scopes/$scope_uuid" -r "$V2_REALM" -n -b '{}' >/dev/null
  mapper_uuid=$(kcadm get "client-scopes/$scope_uuid/protocol-mappers/models" -r "$V2_REALM" -c \
    | jq -r '.[] | select(.name == "skycms-audience") | .id')
  [[ -n $mapper_uuid ]] || fail 'the skycms-audience mapper was not created'
  kcadm update "client-scopes/$scope_uuid/protocol-mappers/models/$mapper_uuid" -r "$V2_REALM" \
    -s 'config."id.token.claim"=true' >/dev/null
  kcadm create "client-scopes/$scope_uuid/protocol-mappers/models" -r "$V2_REALM" \
    -b '{"name":"unexpected-admin-audience","protocol":"openid-connect","protocolMapper":"oidc-audience-mapper","config":{"included.custom.audience":"unexpected","access.token.claim":"true"}}' >/dev/null
}

stage_admin_panel_after_second_reconciliation() {
  CURRENT_STAGE='admin panel client: drift repaired by the second reconciliation'
  local log="$TEST_STATE_DIR/reconcile-second.log" scope_uuid expected
  scope_uuid=$(lca_scope_uuids "$AP_SCOPE")
  for expected in \
    "[reconcile] client $AP_CLIENT (no full scope, standard token exchange): updated (fullScopeAllowed attributes)" \
    "[reconcile] client $AP_CLIENT: detached optional scope $AP_SCOPE (it must be a default scope)" \
    "[reconcile] pruned protocol mappers from scope $scope_uuid: unexpected-admin-audience"; do
    grep -Fq "$expected" "$log" || fail "the second reconciliation did not log: $expected"
  done
  grep -Eq "^\[reconcile\] protocol mappers of scope $scope_uuid: updated \(.*~skycms-audience" "$log" \
    || fail 'the second reconciliation did not repair the drifted skycms-audience mapper'
  grep -E "^\[reconcile\] role scope mappings of $AP_CLIENT \(every role of core, forms\): updated \(" "$log" \
    | grep -F '+core/url:read' | grep -F -- '-realm/offline_access' | grep -Fq -- '-skymail/skymail:access' \
    || fail 'the second reconciliation did not restore the role scope mappings of the admin client'
  ap_assert_contract core
}

# After core-erasure-client.sh made forms and skycms: the step alone with an operator session (the
# sandbox path) refuses what it must refuse, maps the new forms role, and the panel's real login
# gives the narrowed token that Standard Token Exchange turns into one-API tokens.
stage_admin_panel_tokens() {
  CURRENT_STAGE='admin panel client: the step alone with an operator session'
  local output skyforms_uuid skyforms_before forms_uuid token payload audience
  local refused="$TEST_STATE_DIR/ap-operator-refused.log"
  output=$(ap_operator_reconcile superadmin -e KEYCLOAK_RECONCILE_ONLY=admin-panel-client) \
    || { printf '%s\n' "$output" >&2; fail 'the step failed on a realm without the client'; }
  grep -Fq "[reconcile] WARNING: client superadmin does not exist in realm $V2_REALM; skipped the admin panel token contract" <<<"$output" \
    || { printf '%s\n' "$output" >&2; fail 'the step did not report the missing client'; }
  [[ $(grep -c '^\[reconcile\]' <<<"$output") == 1 ]] \
    || { printf '%s\n' "$output" >&2; fail 'the step did more than skip a missing client'; }
  grep -Fq 'Admin panel client configuration is reconciled.' <<<"$output" \
    || fail 'the step alone did not report completion'

  # A public client cannot use Standard Token Exchange, and making it confidential changes how the
  # panel signs in: the step refuses it and writes nothing (skyforms is public in the fixture).
  skyforms_uuid=$(lca_client_uuid skyforms)
  skyforms_before=$(kcadm get "clients/$skyforms_uuid" -r "$V2_REALM" -c | jq -S -c .)
  # Expected failures run as plain if-conditions: in a command substitution the harness ERR trap
  # would report them.
  if ap_operator_reconcile skyforms -e KEYCLOAK_RECONCILE_ONLY=admin-panel-client >"$refused"; then
    fail 'the step accepted a public client'
  fi
  grep -Fq 'Client skyforms is public' "$refused" \
    || { cat "$refused" >&2; fail 'the step did not say why it refused the public client'; }
  [[ $(kcadm get "clients/$skyforms_uuid" -r "$V2_REALM" -c | jq -S -c .) == "$skyforms_before" ]] \
    || fail 'the refused step changed the public client'

  # The whole reconciliation runs only with the scoped reconciler identity.
  if ap_operator_reconcile "$AP_CLIENT" >"$refused"; then
    fail 'an operator session ran the whole reconciliation'
  fi
  grep -Fq 'KEYCLOAK_RECONCILE_KCADM_CONFIG needs KEYCLOAK_RECONCILE_ONLY' "$refused" \
    || { cat "$refused" >&2; fail 'the refused operator run did not say why'; }

  forms_uuid=$(lca_client_uuid forms)
  [[ -n $forms_uuid ]] || fail 'core-erasure-client.sh did not leave the forms client'
  kcadm create "clients/$forms_uuid/roles" -r "$V2_REALM" -s "name=$AP_FORMS_ROLE" >/dev/null
  kcadm add-roles -r "$V2_REALM" --uusername "$AP_USER" --cclientid forms --rolename "$AP_FORMS_ROLE" >/dev/null
  output=$(ap_operator_reconcile "$AP_CLIENT" -e KEYCLOAK_RECONCILE_ONLY=admin-panel-client) \
    || { printf '%s\n' "$output" >&2; fail 'the step alone failed'; }
  grep -E "^\[reconcile\] role scope mappings of $AP_CLIENT \(every role of core, forms\): updated \(" <<<"$output" \
    | grep -Fq "+forms/$AP_FORMS_ROLE" \
    || { printf '%s\n' "$output" >&2; fail 'the step did not put the new forms role in the scope of the admin client'; }
  ap_assert_contract core forms

  CURRENT_STAGE='admin panel client: the narrowed token of a real login'
  lca_login "$AP_CLIENT" "$AP_REDIRECT" "$AP_SECRET" "$AP_USER" "$AP_PASSWORD" "$AP_PANEL_SCOPE"
  token=$LCA_ACCESS_TOKEN
  payload=$LCA_ACCESS_PAYLOAD
  json_assert "$payload" '.azp == $client and (.sid | type) == "string" and (.sid | length) > 0' \
    'the panel token lost azp admin or a live sid (the sky-handoff admin API needs both)' --arg client "$AP_CLIENT"
  json_assert "$payload" '((.aud | if type == "array" then . else [.] end) | sort) == ["core", "forms", "skycms"]' \
    "the panel token's aud is not exactly core, forms and skycms"
  json_assert "$payload" 'has("realm_access") | not' 'the panel token carries realm roles'
  json_assert "$payload" \
    '.resource_access == {($client): {"roles": ["content:read"]}, "core": {"roles": ["url:create"]}, "forms": {"roles": [$forms_role]}}' \
    'resource_access of the panel token is not exactly the roles of core, forms and the panel itself' \
    --arg client "$AP_CLIENT" --arg forms_role "$AP_FORMS_ROLE"
  json_assert "$payload" '.roles == ["content:read"] and .groups == ["/UYELER/YK"]' \
    "the panel token lost inscribed's flat roles claim or the group paths"
  # A person without a role of any API still gets all three audiences: they come from the hardcoded
  # mappers, not from audience-resolve (the reason members got 401 on SkyForms).
  lca_login "$AP_CLIENT" "$AP_REDIRECT" "$AP_SECRET" "$LCA_USER" "$LCA_PASSWORD" "$AP_PANEL_SCOPE"
  json_assert "$LCA_ACCESS_PAYLOAD" \
    '((.aud | if type == "array" then . else [.] end) | sort) == ["core", "forms", "skycms"] and ((.resource_access // {}) | length) == 0' \
    'the panel token of a person without API roles lacks one of the three audiences'

  CURRENT_STAGE='admin panel client: Standard Token Exchange to one API'
  for audience in "${AP_APIS[@]}"; do
    ap_assert_exchanged "$token" "$payload" "$audience" "$AP_USER"
  done
  # skymail is a client the person holds a role of: a full-scope token would name it, this one must not.
  ap_exchange "$token" skymail
  [[ $AP_EXCHANGE_STATUS == 400 && $(jq -r .error <<<"$AP_EXCHANGE_BODY") == invalid_request ]] \
    || fail "an exchange to an audience outside the panel token was not refused (HTTP $AP_EXCHANGE_STATUS)"
  # The exchange gives no refresh token: the server keeps only the panel's own session.
  ap_exchange "$token" core requested_token_type=urn:ietf:params:oauth:token-type:refresh_token
  [[ $AP_EXCHANGE_STATUS == 400 && $(jq -r .error <<<"$AP_EXCHANGE_BODY") == invalid_request ]] \
    || fail "an exchange for a refresh token was not refused (HTTP $AP_EXCHANGE_STATUS)"
}

# admin-token-authz K1, the gate of the panel's BFF: after the exchange each API still finds what it
# reads, for the three kinds of people the panel serves, with their roles coming from groups as in
# production (the SKY LAB admin panel's grants):
#   - a Privileged person in /UYELER/YK: core's resource roles as the operator seeded them (the
#     core-roles stage ran before), the panel's content:read and content:write (inscribed) and the
#     forms role skyforms:* that forms-backend checks;
#   - a team Leader in the team group and its LIDERLER subgroup: content:read and content:write for
#     the team page; core and inscribed decide from the group paths;
#   - a plain member of the team: no role of any API, only the group path.
# The panel's token must carry exactly each person's effective roles and group paths, and every
# exchange to core, forms and skycms must keep tests/admin-panel-exchanged-token.jq. Keycloak's
# Evaluate with an audience (what an operator can run against a live realm without anyone's
# password) must give the same token as the exchange. Runs before the no-op reconciliation, which
# then proves the new forms role is already in the panel's scope.
stage_admin_panel_exchange_claims() {
  CURRENT_STAGE='admin panel client: groups and people of the exchange proof'
  local output parent name client person privileged leader member audience evaluated exchanged
  local normalize='del(.exp, .iat, .jti, .sid, .iss, .auth_time) | if has("scope") then .scope |= (split(" ") | sort | join(" ")) else . end'
  # The role forms-backend checks; the step alone puts it in the panel's scope, as the next
  # reconciliation would.
  output=$(kcadm get "clients/$(lca_client_uuid forms)/roles" -r "$V2_REALM" -c)
  if ! jq -e --arg role "$AP_FORMS_CHECKED_ROLE" 'any(.[]; .name == $role)' <<<"$output" >/dev/null; then
    kcadm create "clients/$(lca_client_uuid forms)/roles" -r "$V2_REALM" -s "name=$AP_FORMS_CHECKED_ROLE" >/dev/null
  fi
  output=$(ap_operator_reconcile "$AP_CLIENT" -e KEYCLOAK_RECONCILE_ONLY=admin-panel-client) \
    || { printf '%s\n' "$output" >&2; fail 'the step alone failed'; }
  ap_assert_contract core forms
  parent=/UYELER
  for name in ARGE WEBLAB LIDERLER; do
    kcadm create "groups/$(ap_group_id "$parent")/children" -r "$V2_REALM" -s "name=$name" >/dev/null
    parent="$parent/$name"
  done
  [[ $parent == "$AP_LEADERS_PATH" ]] || fail "the team groups are not $AP_LEADERS_PATH"
  ap_grant_group /UYELER/YK "$AP_CLIENT" content:read content:write
  ap_grant_group /UYELER/YK forms "$AP_FORMS_CHECKED_ROLE"
  ap_grant_group "$AP_LEADERS_PATH" "$AP_CLIENT" content:read content:write
  privileged=$(ap_person "$AP_PRIVILEGED_USER" /UYELER/YK)
  leader=$(ap_person "$AP_LEADER_USER" "$AP_TEAM_PATH" "$AP_LEADERS_PATH")
  member=$(ap_person "$AP_MEMBER_USER" "$AP_TEAM_PATH")
  # The people are what they stand for, or the proof below would be vacuous.
  json_assert "$(ap_effective_roles "$privileged" core)" 'length > 0' 'the Privileged person holds no core role'
  [[ $(ap_effective_roles "$privileged" forms) == "[\"$AP_FORMS_CHECKED_ROLE\"]" ]] \
    || fail "the Privileged person does not hold exactly $AP_FORMS_CHECKED_ROLE of forms"
  for person in "$privileged" "$leader"; do
    [[ $(ap_effective_roles "$person" "$AP_CLIENT") == '["content:read","content:write"]' ]] \
      || fail 'a Privileged person or Leader does not hold exactly content:read and content:write'
  done
  for client in core forms; do
    [[ $(ap_effective_roles "$leader" "$client") == '[]' ]] || fail "the Leader holds a role of $client"
  done
  for client in core forms "$AP_CLIENT"; do
    [[ $(ap_effective_roles "$member" "$client") == '[]' ]] || fail "the plain member holds a role of $client"
  done

  CURRENT_STAGE='admin panel client: exchanged tokens of a Privileged person, a Leader and a member'
  ap_assert_person_exchanges "$AP_PRIVILEGED_USER" "$privileged"
  ap_assert_person_exchanges "$AP_LEADER_USER" "$leader"
  ap_assert_person_exchanges "$AP_MEMBER_USER" "$member"

  CURRENT_STAGE='admin panel client: Evaluate with an audience is the exchange'
  lca_login "$AP_CLIENT" "$AP_REDIRECT" "$AP_SECRET" "$AP_PRIVILEGED_USER" "$AP_PEOPLE_PASSWORD" "$AP_PANEL_SCOPE"
  for audience in "${AP_APIS[@]}"; do
    ap_assert_exchanged "$LCA_ACCESS_TOKEN" "$LCA_ACCESS_PAYLOAD" "$audience" "$AP_PRIVILEGED_USER"
    # Evaluate makes its own session and reaches Keycloak by another address: sid and iss differ.
    evaluated=$(kcadm get "clients/$AP_UUID/evaluate-scopes/generate-example-access-token" -r "$V2_REALM" \
      -q "userId=$privileged" -q "audience=$audience" -q scope=openid -c | jq -S -c "$normalize")
    exchanged=$(jq -S -c "$normalize" <<<"$AP_EXCHANGED_PAYLOAD")
    [[ $evaluated == "$exchanged" ]] \
      || fail "Evaluate with audience $audience differs from the exchange in $(jq -n -c --argjson a "$evaluated" --argjson b "$exchanged" '[($a + $b) | keys[] | select($a[.] != $b[.])]')"
  done
  printf '    Evaluate (userId, audience, scope=openid) gives the exchanged token for core, forms and skycms\n'
}

# Part of v2_state_snapshot: what the no-op reconciliation must leave byte for byte.
ap_state_snapshot() {
  local scope_uuid
  scope_uuid=$(lca_scope_uuids "$AP_SCOPE")
  kcadm get "clients/$AP_UUID" -r "$V2_REALM" -c
  kcadm get "clients/$AP_UUID/scope-mappings" -r "$V2_REALM" -c | jq -c '{realmMappings: ((.realmMappings // []) | sort_by(.id)), clientMappings: ((.clientMappings // {}) | map_values(.mappings | sort_by(.id)))}'
  kcadm get "clients/$AP_UUID/default-client-scopes" -r "$V2_REALM" -c | jq -c 'sort_by(.id)'
  kcadm get "clients/$AP_UUID/optional-client-scopes" -r "$V2_REALM" -c | jq -c 'sort_by(.id)'
  kcadm get "client-scopes/$scope_uuid" -r "$V2_REALM" -c
  kcadm get "client-scopes/$scope_uuid/protocol-mappers/models" -r "$V2_REALM" -c | jq -c 'sort_by(.id)'
}
