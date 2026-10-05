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

AP_CLIENT=admin
AP_SCOPE=admin-panel-api-audience
AP_USER=admin-panel-fixture
AP_PASSWORD=admin-panel-fixture-password-change-me
AP_REDIRECT=https://admin.yildizskylab.com/api/auth/callback
# What core-frontend asks for (src/lib/auth/oauth2.ts).
AP_PANEL_SCOPE='openid profile email'
AP_FORMS_ROLE=skyforms:form:manage
AP_UUID=''
AP_SECRET=''
AP_EXCHANGE_STATUS=''
AP_EXCHANGE_BODY=''

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

# ap_exchange <subject access token> <audience>: Standard Token Exchange by the panel's client;
# leaves the HTTP status and the response body in AP_EXCHANGE_STATUS and AP_EXCHANGE_BODY.
ap_exchange() {
  local body="$TEST_STATE_DIR/ap-exchange.body"
  AP_EXCHANGE_STATUS=$(curl --silent --show-error \
    --output "$body" \
    --write-out '%{http_code}' \
    --user "$AP_CLIENT:$AP_SECRET" \
    --data-urlencode grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
    --data-urlencode "subject_token=$1" \
    --data-urlencode subject_token_type=urn:ietf:params:oauth:token-type:access_token \
    --data-urlencode "audience=$2" \
    "http://localhost:18080/realms/$V2_REALM/protocol/openid-connect/token")
  AP_EXCHANGE_BODY=$(cat "$body")
  rm -f "$body"
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
  for audience in core forms skycms; do
    ap_exchange "$token" "$audience"
    [[ $AP_EXCHANGE_STATUS == 200 ]] \
      || fail "the exchange to $audience was refused (HTTP $AP_EXCHANGE_STATUS, $(jq -r '.error + ": " + .error_description' <<<"$AP_EXCHANGE_BODY"))"
    payload=$(v2_jwt_payload "$(jq -r .access_token <<<"$AP_EXCHANGE_BODY")")
    json_assert "$payload" '(.aud | if type == "array" then . else [.] end) == [$aud] and .azp == $client' \
      "the exchanged token for $audience does not carry that one audience" --arg aud "$audience" --arg client "$AP_CLIENT"
  done
  # skymail is a client the person holds a role of: a full-scope token would name it, this one must not.
  ap_exchange "$token" skymail
  [[ $AP_EXCHANGE_STATUS == 400 && $(jq -r .error <<<"$AP_EXCHANGE_BODY") == invalid_request ]] \
    || fail "an exchange to an audience outside the panel token was not refused (HTTP $AP_EXCHANGE_STATUS)"
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
