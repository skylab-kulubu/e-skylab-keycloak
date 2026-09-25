# shellcheck shell=bash
# Sourced by run-integration.sh; uses its kcadm, fail, json_assert, v2_jwt_payload, V2_REALM
# and TEST_STATE_DIR.
#
# Two login clients whose access tokens must name the API they call in aud even for a person
# who holds no role of that API: Keycloak's audience-resolve only adds a client whose roles the
# token carries. Both scopes were made by hand in production and are adopted by the reconciler:
#   skyforms      -> skyforms-forms-audience     (forms-audience, aud += forms; forms-backend
#                    RequireAudience, members got 401 without it)
#   frontend-main -> frontend-main-core-audience (core-audience, aud += core; core ADR 0019,
#                    every CMS image upload through the site got 401 without it)
# The fixture realm has skyforms but no frontend-main, like a sandbox realm without the site's
# client: the first reconciliation must skip it with a warning. skyforms gets the scope the way
# the Admin Console made it in production, so the first reconciliation must adopt it in place.

LCA_USER='audience-fixture'
LCA_PASSWORD='audience-fixture-password-change-me'
LCA_SKYFORMS_SCOPE=skyforms-forms-audience
LCA_FRONTEND_MAIN_SCOPE=frontend-main-core-audience
LCA_SKYFORMS_REDIRECT=https://forms.yildizskylab.com/api/auth/callback/keycloak
LCA_FRONTEND_MAIN_REDIRECT=https://yildizskylab.com/api/auth/callback/keycloak
LCA_HAND_MADE_SCOPE_UUID=''
LCA_HAND_MADE_MAPPER_UUID=''
LCA_ACCESS_PAYLOAD=''
LCA_ID_PAYLOAD=''

lca_client_uuid() {
  kcadm get clients -r "$V2_REALM" -q "clientId=$1" -c \
    | jq -r --arg id "$1" '.[] | select(.clientId == $id) | .id'
}

lca_scope_uuids() {
  kcadm get client-scopes -r "$V2_REALM" -c \
    | jq -r --arg name "$1" '.[] | select(.name == $name) | .id'
}

# Before the first reconciliation: production's hand-made skyforms scope, with the attributes and
# mapper config the Admin Console writes (included in the token scope, shown on the consent
# screen, lightweight and introspection flags set).
stage_login_audiences_hand_made() {
  CURRENT_STAGE='login client audiences: hand-made production scope'
  local skyforms_uuid
  [[ -z $(lca_client_uuid frontend-main) ]] \
    || fail 'the fixture realm must start without frontend-main (the sandbox case)'
  skyforms_uuid=$(lca_client_uuid skyforms)
  [[ -n $skyforms_uuid ]] || fail 'the fixture realm lacks the skyforms client'
  LCA_HAND_MADE_SCOPE_UUID=$(kcadm create client-scopes -r "$V2_REALM" -i \
    -b "{\"name\":\"$LCA_SKYFORMS_SCOPE\",\"description\":\"\",\"protocol\":\"openid-connect\",\"attributes\":{\"include.in.token.scope\":\"true\",\"display.on.consent.screen\":\"true\",\"gui.order\":\"\",\"consent.screen.text\":\"\"}}")
  kcadm create "client-scopes/$LCA_HAND_MADE_SCOPE_UUID/protocol-mappers/models" -r "$V2_REALM" \
    -b '{"name":"forms-audience","protocol":"openid-connect","protocolMapper":"oidc-audience-mapper","consentRequired":false,"config":{"included.client.audience":"forms","id.token.claim":"false","access.token.claim":"true","lightweight.claim":"false","introspection.token.claim":"true"}}' >/dev/null
  LCA_HAND_MADE_MAPPER_UUID=$(kcadm get "client-scopes/$LCA_HAND_MADE_SCOPE_UUID/protocol-mappers/models" \
    -r "$V2_REALM" -c | jq -r '.[] | select(.name == "forms-audience") | .id')
  [[ -n $LCA_HAND_MADE_MAPPER_UUID ]] || fail 'the hand-made forms-audience mapper was not created'
  kcadm update "clients/$skyforms_uuid/default-client-scopes/$LCA_HAND_MADE_SCOPE_UUID" \
    -r "$V2_REALM" -n -b '{}' >/dev/null
}

# After the first reconciliation: the missing client is skipped, the hand-made scope is adopted
# (same scope and mapper ids, one scope of that name, attributes brought to the reconciled
# shape). Then the site's client appears and the skyforms scope drifts before the second pass.
stage_login_audiences_after_first_reconciliation() {
  CURRENT_STAGE='login client audiences: skip a missing client, adopt the hand-made scope'
  local log="$TEST_STATE_DIR/reconcile-first.log" skyforms_uuid scope mappers
  grep -Fq "[reconcile] WARNING: client frontend-main does not exist in realm $V2_REALM; skipped client scope $LCA_FRONTEND_MAIN_SCOPE" "$log" \
    || fail 'the first reconciliation did not report skipping the missing frontend-main client'
  [[ -z $(lca_scope_uuids "$LCA_FRONTEND_MAIN_SCOPE") ]] \
    || fail 'the reconciler created a scope for a client that does not exist'
  [[ $(lca_scope_uuids "$LCA_SKYFORMS_SCOPE") == "$LCA_HAND_MADE_SCOPE_UUID" ]] \
    || fail 'the hand-made skyforms scope was not adopted in place (recreated or duplicated)'
  if grep -Fq "client scope $LCA_SKYFORMS_SCOPE: created" "$log"; then
    fail 'the reconciler reported creating the hand-made skyforms scope'
  fi
  scope=$(kcadm get "client-scopes/$LCA_HAND_MADE_SCOPE_UUID" -r "$V2_REALM" -c)
  json_assert "$scope" \
    '.protocol == "openid-connect" and .attributes["include.in.token.scope"] == "false" and .attributes["display.on.consent.screen"] == "false"' \
    'the adopted skyforms scope attributes were not brought to the reconciled shape'
  mappers=$(kcadm get "client-scopes/$LCA_HAND_MADE_SCOPE_UUID/protocol-mappers/models" -r "$V2_REALM" -c)
  json_assert "$mappers" 'length == 1 and .[0].id == $id and .[0].name == "forms-audience"' \
    'the hand-made forms-audience mapper was not kept in place' --arg id "$LCA_HAND_MADE_MAPPER_UUID"
  skyforms_uuid=$(lca_client_uuid skyforms)
  json_assert "$(kcadm get "clients/$skyforms_uuid/default-client-scopes" -r "$V2_REALM" -c)" \
    '[.[] | select(.name == $name)] | length == 1' \
    'the adopted scope is not a default scope of skyforms exactly once' --arg name "$LCA_SKYFORMS_SCOPE"

  # The site's login client, as skylab-site signs in: public, authorization code with S256 PKCE.
  kcadm create clients -r "$V2_REALM" \
    -s clientId=frontend-main -s 'name=SKY LAB site (fixture)' -s enabled=true \
    -s protocol=openid-connect -s publicClient=true -s standardFlowEnabled=true \
    -s directAccessGrantsEnabled=false -s rootUrl=https://yildizskylab.com \
    -s "redirectUris=[\"$LCA_FRONTEND_MAIN_REDIRECT\"]" \
    -s 'attributes."pkce.code.challenge.method"=S256' >/dev/null

  # Drift on the adopted scope: moved among the optional scopes (the token would carry forms
  # only when asked for), the audience added to the ID token, a foreign mapper.
  kcadm delete "clients/$skyforms_uuid/default-client-scopes/$LCA_HAND_MADE_SCOPE_UUID" \
    -r "$V2_REALM" >/dev/null
  kcadm update "clients/$skyforms_uuid/optional-client-scopes/$LCA_HAND_MADE_SCOPE_UUID" \
    -r "$V2_REALM" -n -b '{}' >/dev/null
  kcadm update "client-scopes/$LCA_HAND_MADE_SCOPE_UUID/protocol-mappers/models/$LCA_HAND_MADE_MAPPER_UUID" \
    -r "$V2_REALM" -s 'config."id.token.claim"=true' >/dev/null
  kcadm create "client-scopes/$LCA_HAND_MADE_SCOPE_UUID/protocol-mappers/models" -r "$V2_REALM" \
    -b '{"name":"unexpected-forms-mapper","protocol":"openid-connect","protocolMapper":"oidc-audience-mapper","config":{"included.custom.audience":"unexpected","access.token.claim":"true"}}' >/dev/null
}

# Authorization code with PKCE and Keycloak's own login form, like v2_login_account_center but for
# a public client without PAR; leaves both token payloads in LCA_ACCESS_PAYLOAD and LCA_ID_PAYLOAD.
lca_login() {
  local client_id=$1 redirect_uri=$2
  local verifier challenge page login_action status location code response token
  local cookies="$TEST_STATE_DIR/lca-$client_id.cookies" headers="$TEST_STATE_DIR/lca-$client_id.headers"
  verifier="lca-$client_id-verifier-0123456789abcdefghijklmnopqrstuvwxyz"
  challenge=$(printf '%s' "$verifier" | openssl dgst -binary -sha256 | openssl base64 -A | tr '+/' '-_' | tr -d '=')
  page=$(curl --fail --silent --show-error --location \
    --cookie-jar "$cookies" --cookie "$cookies" \
    --get \
    --data-urlencode "client_id=$client_id" \
    --data-urlencode response_type=code \
    --data-urlencode scope=openid \
    --data-urlencode "redirect_uri=$redirect_uri" \
    --data-urlencode "code_challenge=$challenge" \
    --data-urlencode code_challenge_method=S256 \
    --data-urlencode "state=lca-$client_id" \
    --data-urlencode "nonce=lca-$client_id-nonce" \
    "http://localhost:18080/realms/$V2_REALM/protocol/openid-connect/auth")
  login_action=$(grep -Eo '"loginAction"[[:space:]]*:[[:space:]]*"[^"]*"' <<<"$page" \
    | head -n 1 | sed -E 's/^"loginAction"[[:space:]]*:[[:space:]]*//' | jq -r . || true)
  [[ -n $login_action ]] || fail "$client_id login: the login page exposed no login action"
  status=$(curl --silent --show-error \
    --output /dev/null \
    --dump-header "$headers" \
    --write-out '%{http_code}' \
    --cookie-jar "$cookies" --cookie "$cookies" \
    --data-urlencode "username=$LCA_USER" \
    --data-urlencode "password=$LCA_PASSWORD" \
    --data-urlencode credentialId= \
    "$login_action")
  [[ $status == 302 ]] || fail "$client_id login: credential submission did not redirect (HTTP $status)"
  location=$(awk '
    tolower($1) == "location:" {
      sub(/^[^:]*:[[:space:]]*/, "")
      sub(/\r$/, "")
      print
    }
  ' "$headers")
  code=$(sed -n 's/.*[?&]code=\([^&]*\).*/\1/p' <<<"$location")
  [[ -n $code ]] || fail "$client_id login: the authorization redirect lacks a code"
  response=$(curl --fail --silent --show-error \
    --data-urlencode grant_type=authorization_code \
    --data-urlencode "client_id=$client_id" \
    --data-urlencode "code=$code" \
    --data-urlencode "redirect_uri=$redirect_uri" \
    --data-urlencode "code_verifier=$verifier" \
    "http://localhost:18080/realms/$V2_REALM/protocol/openid-connect/token")
  token=$(jq -r .access_token <<<"$response")
  [[ -n $token && $token != null ]] || fail "$client_id login: no access token was issued"
  LCA_ACCESS_PAYLOAD=$(v2_jwt_payload "$token")
  token=$(jq -r .id_token <<<"$response")
  [[ -n $token && $token != null ]] || fail "$client_id login: no ID token was issued"
  LCA_ID_PAYLOAD=$(v2_jwt_payload "$token")
}

# One login client after the second reconciliation: the reconciled scope, its one mapper, the
# default attachment, then a real login of a person without any role of the API.
lca_assert_client() {
  local client_id=$1 scope_name=$2 mapper_name=$3 audience=$4 redirect_uri=$5
  local client_uuid scope_uuid scope mappers
  client_uuid=$(lca_client_uuid "$client_id")
  scope_uuid=$(lca_scope_uuids "$scope_name")
  [[ -n $scope_uuid && $scope_uuid != *$'\n'* ]] || fail "client scope $scope_name is missing or duplicated"
  scope=$(kcadm get "client-scopes/$scope_uuid" -r "$V2_REALM" -c)
  json_assert "$scope" '.protocol == "openid-connect" and .attributes["include.in.token.scope"] == "false"' \
    "client scope $scope_name differs"
  mappers=$(kcadm get "client-scopes/$scope_uuid/protocol-mappers/models" -r "$V2_REALM" -c)
  json_assert "$mappers" \
    'length == 1 and .[0].name == $name and .[0].protocolMapper == "oidc-audience-mapper" and .[0].config["included.client.audience"] == $aud and .[0].config["access.token.claim"] == "true" and .[0].config["id.token.claim"] == "false" and .[0].config["introspection.token.claim"] == "true"' \
    "the mapper of $scope_name differs or a foreign mapper remains" --arg name "$mapper_name" --arg aud "$audience"
  json_assert "$(kcadm get "clients/$client_uuid/default-client-scopes" -r "$V2_REALM" -c)" \
    '[.[] | select(.id == $id)] | length == 1' \
    "$scope_name is not a default scope of $client_id" --arg id "$scope_uuid"
  json_assert "$(kcadm get "clients/$client_uuid/optional-client-scopes" -r "$V2_REALM" -c)" \
    '[.[] | select(.id == $id)] | length == 0' \
    "$scope_name is still an optional scope of $client_id" --arg id "$scope_uuid"

  lca_login "$client_id" "$redirect_uri"
  json_assert "$LCA_ACCESS_PAYLOAD" \
    '.azp == $client and ((.aud | if type == "array" then . else [.] end) | index($aud)) != null' \
    "the $client_id access token lacks aud $audience" --arg client "$client_id" --arg aud "$audience"
  # The person holds no role of the API: the audience comes from the scope, not audience-resolve.
  json_assert "$LCA_ACCESS_PAYLOAD" '(.resource_access // {}) | has($aud) | not' \
    "the audience fixture person unexpectedly holds a role of $audience" --arg aud "$audience"
  json_assert "$LCA_ID_PAYLOAD" \
    '((.aud | if type == "array" then . else [.] end) | index($aud)) == null' \
    "the $client_id ID token carries aud $audience" --arg aud "$audience"
}

stage_login_audiences_after_second_reconciliation() {
  CURRENT_STAGE='login client audiences: reconciled scopes and tokens'
  local log="$TEST_STATE_DIR/reconcile-second.log"
  grep -Fq "[reconcile] client scope $LCA_FRONTEND_MAIN_SCOPE: created" "$log" \
    || fail 'the second reconciliation did not create the scope of the new frontend-main client'
  grep -Eq "^\[reconcile\] protocol mappers of scope $LCA_HAND_MADE_SCOPE_UUID: updated \(.*~forms-audience" "$log" \
    || fail 'the second reconciliation did not repair the drifted forms-audience mapper'
  grep -Fq "[reconcile] client skyforms: detached optional scope $LCA_SKYFORMS_SCOPE" "$log" \
    || fail 'the second reconciliation did not take the skyforms scope out of the optional scopes'
  [[ $(lca_scope_uuids "$LCA_SKYFORMS_SCOPE") == "$LCA_HAND_MADE_SCOPE_UUID" ]] \
    || fail 'repairing the skyforms scope replaced it instead of repairing it in place'
  lca_assert_client skyforms "$LCA_SKYFORMS_SCOPE" forms-audience forms "$LCA_SKYFORMS_REDIRECT"
  lca_assert_client frontend-main "$LCA_FRONTEND_MAIN_SCOPE" core-audience core "$LCA_FRONTEND_MAIN_REDIRECT"
}

# Part of v2_state_snapshot: what the no-op reconciliation must leave byte for byte.
lca_state_snapshot() {
  local client_id scope_name client_uuid scope_uuid
  for client_id in skyforms frontend-main; do
    client_uuid=$(lca_client_uuid "$client_id")
    kcadm get "clients/$client_uuid/default-client-scopes" -r "$V2_REALM" -c
    kcadm get "clients/$client_uuid/optional-client-scopes" -r "$V2_REALM" -c
  done
  for scope_name in "$LCA_SKYFORMS_SCOPE" "$LCA_FRONTEND_MAIN_SCOPE"; do
    scope_uuid=$(lca_scope_uuids "$scope_name")
    kcadm get "client-scopes/$scope_uuid" -r "$V2_REALM" -c
    kcadm get "client-scopes/$scope_uuid/protocol-mappers/models" -r "$V2_REALM" -c
  done
}
