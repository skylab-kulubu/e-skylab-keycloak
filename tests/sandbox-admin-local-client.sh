#!/usr/bin/env bash
# Real-Keycloak contract for config/sandbox-admin-local-client.sh (the admin panel's local-development
# client admin-local, sandbox realm only). Stand-alone: starts the stock Keycloak image this
# repository builds on (the Dockerfile's KEYCLOAK_IMAGE) in dev mode with docker run --rm and no
# volume, runs the script inside that container the way the wizard does and reads real tokens.
#
# Fixtures: realm e-skylab (production; must stay untouched) and realm e-skylab-sandbox with clients
# core (roles event:manage, url:moderator), forms (forms:manage), skycms, skymail (skymail:access)
# and the panel's client superadmin shaped as the reconciler and inscribed-cms-roles.sh leave it:
# confidential, fullScopeAllowed=false, every core and forms role in its role scope, the default
# scopes admin-panel-api-audience (made from config/admin-panel-api-audience-mappers.json) and groups
# (a realm scope writing full paths, not a realm default), the optional scopes address and phone
# detached, own roles content:read, content:write, schema:sync, the mapper inscribed-roles (its roles
# as the flat roles) and a hand-made hardcoded-claim mapper panel. Groups /ADMIN (core event:manage,
# forms forms:manage, superadmin content:read and content:write) and /UYELER/YK (core url:moderator);
# kaan-fixture is in both, uye-fixture only in /UYELER.
#
# What it proves:
#   - e-skylab is refused by name, every realm but e-skylab-sandbox is refused, before a login
#     (exit 2), and so is the reference admin-local itself; a missing sandbox realm is exit 1;
#     without the audience scope it is a PROBLEM (exit 1) and nothing is written;
#   - --check writes nothing (admin events); --apply makes a public client with standard flow only,
#     PKCE S256, fullScopeAllowed=false, redirect URI, web origin and post-logout redirect exactly on
#     http://localhost:3000; its default and optional scopes are the reference's (plus the audience
#     scope), its role scope every core, forms and superadmin role, its only mapper inscribed-roles;
#     the panel's hand-made mapper is a NOTE; superadmin is unchanged (its representation, scopes,
#     role scope, mappers and secret);
#   - a real authorization code flow with PKCE and no secret, back to
#     http://localhost:3000/api/auth/callback, gives kaan-fixture a token equal to superadmin's
#     except azp, aud (plus superadmin), session ids, allowed-origins and the unmirrored claim: aud
#     core, forms, skycms, superadmin; no realm_access; resource_access core, forms, superadmin;
#     the flat roles; full-path groups; the refresh grant works without a secret; uye-fixture gets
#     only aud core, forms, skycms and /UYELER;
#   - Keycloak refuses another redirect URI (the sandbox panel's, localhost:3001, 127.0.0.1:3000), a
#     request without PKCE or with the plain method, the password and client_credentials grants;
#     superadmin still refuses the localhost callback;
#   - a second --check and --apply change nothing; drift (URIs, flags, scopes, realm and foreign
#     roles in the role scope, a missing core role, a stray mapper, a changed inscribed-roles) is
#     planned without a write and repaired; a reference that is not narrowed is a WARNING; a default
#     scope writing groups without full paths is a PROBLEM (exit 1, nothing written); when the
#     reference writes groups with its own mapper (inscribed-groups), admin-local gets the mapper
#     groups and the two tokens still match;
#   - --revoke --check writes nothing; --revoke --apply deletes admin-local only; a second
#     --revoke has nothing to do; no output carries superadmin's secret.
# Requirements on the host: docker, curl, jq, openssl, base64. SANDBOX_ADMIN_LOCAL_TEST_PORT
# (default 18095), SANDBOX_ADMIN_LOCAL_TEST_CONTAINER (default sandbox-admin-local-test-<pid>).
# The jq programs name jq variables, not shell ones:
# shellcheck disable=SC2016
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPOSITORY_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
OPERATOR_SCRIPT="$REPOSITORY_ROOT/config/sandbox-admin-local-client.sh"
AUDIENCE_MAPPERS_FILE="$REPOSITORY_ROOT/config/admin-panel-api-audience-mappers.json"
IMAGE=$(sed -n 's/^ARG KEYCLOAK_IMAGE=//p' "$REPOSITORY_ROOT/Dockerfile")
PORT=${SANDBOX_ADMIN_LOCAL_TEST_PORT:-18095}
BASE_URL="http://127.0.0.1:$PORT"
REALM=e-skylab-sandbox
CLIENT=admin-local
REFERENCE=superadmin
CALLBACK=http://localhost:3000/api/auth/callback
PANEL_CALLBACK=https://sandbox-admin.yildizskylab.com/api/auth/callback
CONTAINER=${SANDBOX_ADMIN_LOCAL_TEST_CONTAINER:-sandbox-admin-local-test-$$}
ADMIN_PASSWORD=harness-admin-password
PERSON_PASSWORD=harness-person-password
KCADM_CONFIG=/tmp/harness-kcadm.config
IN_CONTAINER_SCRIPT=/tmp/sandbox-admin-local-client.sh
OUTPUTS=$(mktemp "${TMPDIR:-/tmp}/sandbox-admin-local-outputs.XXXXXX")
CURRENT_STAGE=startup

fail() {
  printf 'sandbox-admin-local-client failure during %s: %s\n' "$CURRENT_STAGE" "$1" >&2
  exit 1
}
cleanup() {
  docker rm -fv "$CONTAINER" >/dev/null 2>&1 || true
  rm -f "$OUTPUTS"
}
trap 'status=$?; trap - EXIT; cleanup; exit "$status"' EXIT
on_error() {
  local status=$?
  printf 'sandbox-admin-local-client command failed during %s (line %s)\n' "$CURRENT_STAGE" "$1" >&2
  exit "$status"
}
trap 'on_error "$LINENO"' ERR

# kcadm's "Created new ..." notices (and blank lines) go to stderr; they are dropped, errors are kept.
kcadm() {
  local command=$1
  shift
  docker exec -i "$CONTAINER" /opt/keycloak/bin/kcadm.sh "$command" --config "$KCADM_CONFIG" "$@" \
    2> >(grep -v -e '^Created new ' -e '^$' >&2 || true)
}

# run_script ARGS...: the operator script inside the Keycloak container, reusing the harness's kcadm
# session (the wizard does the same). Prints the output (also kept in OUTPUTS for the secret check);
# returns the script's status. RUN_REALM sets KEYCLOAK_REALM, RUN_REFERENCE KEYCLOAK_ADMIN_PANEL_CLIENT_ID.
run_script() {
  local output status=0
  output=$(docker exec -e KEYCLOAK_ADMIN_URL=http://localhost:8080 -e KEYCLOAK_REALM="${RUN_REALM:-$REALM}" \
    -e KEYCLOAK_ADMIN_PANEL_CLIENT_ID="${RUN_REFERENCE:-$REFERENCE}" "$CONTAINER" \
    bash "$IN_CONTAINER_SCRIPT" --kcadm-config "$KCADM_CONFIG" "$@" 2>&1) || status=$?
  printf '%s\n' "$output" >>"$OUTPUTS"
  printf '%s\n' "$output"
  return "$status"
}

# run_expecting STATUS ARGS...: run_script for a run that must exit STATUS; prints the output.
run_expecting() {
  local wanted=$1 output status=0
  shift
  trap - ERR
  output=$(run_script "$@") || status=$?
  trap 'on_error "$LINENO"' ERR
  [[ $status == "$wanted" ]] || { printf '%s\n' "$output" >&2; fail "the run did not exit $wanted (exit $status)"; }
  printf '%s\n' "$output"
}

expect_line() {
  grep -Fq -- "$2" <<<"$1" || { printf '%s\n' "$1" >&2; fail "$3: $2"; }
}

reject_line() {
  if grep -Fq -- "$2" <<<"$1"; then
    printf '%s\n' "$1" >&2
    fail "$3: $2"
  fi
}

json_assert() {
  local json=$1 expression=$2 message=$3
  shift 3
  jq -e "$@" "$expression" <<<"$json" >/dev/null || { printf '%s\n' "$json" >&2; fail "$message"; }
}

client_uuid() { # client_uuid CLIENT_ID [REALM]
  kcadm get clients -r "${2:-$REALM}" -q "clientId=$1" | jq -r --arg id "$1" '.[] | select(.clientId == $id) | .id'
}

scope_uuid() {
  kcadm get client-scopes -r "$REALM" | jq -r --arg name "$1" '.[] | select(.name == $name) | .id'
}

role_ref() { # role_ref CLIENT_ID ROLE: [{"id","name"}] of one client role
  kcadm get "clients/$(client_uuid "$1")/roles/$2" -r "$REALM" | jq -c '[{id, name}]'
}

newest_admin_event() {
  kcadm get admin-events -r "$REALM" -q max=1 | jq -r '.[0].time // 0'
}

# reference_secret: superadmin's secret from the admin API, without a newline (never printed).
reference_secret() {
  kcadm get "clients/$(client_uuid "$REFERENCE")/client-secret" -r "$REALM" | jq -j .value
}

# reference_snapshot: everything about superadmin the script could change, secret aside (compared
# by digest), as one canonical JSON document.
reference_snapshot() {
  local id
  id=$(client_uuid "$REFERENCE")
  jq -S -n \
    --argjson client "$(kcadm get "clients/$id" -r "$REALM" | jq 'del(.secret)')" \
    --argjson scopes "$(kcadm get "clients/$id/scope-mappings" -r "$REALM")" \
    --argjson defaults "$(kcadm get "clients/$id/default-client-scopes" -r "$REALM" | jq 'map(.name) | sort')" \
    --argjson optionals "$(kcadm get "clients/$id/optional-client-scopes" -r "$REALM" | jq 'map(.name) | sort')" \
    --argjson mappers "$(kcadm get "clients/$id/protocol-mappers/models" -r "$REALM" | jq 'sort_by(.name)')" \
    --argjson roles "$(kcadm get "clients/$id/roles" -r "$REALM" | jq 'sort_by(.name)')" \
    --arg secret "$(reference_secret | openssl dgst -sha256 | sed 's/^.* //')" \
    '{$client, $scopes, $defaults, $optionals, $mappers, $roles, $secret}'
}

# jwt_payload TOKEN: the decoded payload (JSON) of a compact JWT.
jwt_payload() {
  local segment
  segment=$(cut -d. -f2 <<<"$1" | tr '_-' '/+')
  case $((${#segment} % 4)) in 2) segment+='==' ;; 3) segment+='=' ;; esac
  base64 -d <<<"$segment"
}

# authorize CLIENT REDIRECT [PARAMETER=VALUE...]: "status redirect_url" of an authorization request.
authorize() {
  local client=$1 redirect=$2 arguments=() pair
  shift 2
  for pair in "$@"; do arguments+=(--data-urlencode "$pair"); done
  curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' -G "$BASE_URL/realms/$REALM/protocol/openid-connect/auth" \
    --data-urlencode "client_id=$client" --data-urlencode "redirect_uri=$redirect" ${arguments[@]+"${arguments[@]}"}
}

# code_flow CLIENT REDIRECT USER [secret]: the token response of a real authorization code flow the
# way core-frontend runs it: PKCE S256, state, scope "openid profile email", the login page, the
# credentials, the redirect back with a code, the code exchanged with the verifier and, for the
# confidential reference, its secret (on curl's stdin).
code_flow() {
  local client=$1 redirect=$2 user=$3 with_secret=${4:-} jar page action location code verifier challenge
  verifier=$(openssl rand -hex 32)
  challenge=$(printf '%s' "$verifier" | openssl dgst -sha256 -binary | base64 | tr '+/' '-_' | tr -d '=\n')
  jar=$(mktemp "${TMPDIR:-/tmp}/sandbox-admin-local-jar.XXXXXX")
  page=$(curl -fsS -c "$jar" -b "$jar" -G "$BASE_URL/realms/$REALM/protocol/openid-connect/auth" \
    --data-urlencode "client_id=$client" --data-urlencode response_type=code \
    --data-urlencode 'scope=openid profile email' --data-urlencode "redirect_uri=$redirect" \
    --data-urlencode state=harness-state \
    --data-urlencode "code_challenge=$challenge" --data-urlencode code_challenge_method=S256)
  action=$(sed -n 's/.*id="kc-form-login"[^>]*action="\([^"]*\)".*/\1/p' <<<"$page" | head -n 1 | sed 's/&amp;/\&/g')
  [[ -n $action ]] || { rm -f "$jar"; fail "no login form for $user through $client"; }
  location=$(curl -sS -c "$jar" -b "$jar" -o /dev/null -w '%{redirect_url}' \
    --data-urlencode "username=$user" --data-urlencode "password=$PERSON_PASSWORD" "$action")
  rm -f "$jar"
  [[ $location == "$redirect?"* ]] || fail "the login of $user through $client did not return to $redirect ($location)"
  [[ $location == *'state=harness-state'* ]] || fail "the state did not come back for $user"
  code=$(sed -n 's/.*[?&]code=\([^&]*\).*/\1/p' <<<"$location")
  [[ -n $code ]] || fail "no authorization code for $user through $client"
  if [[ $with_secret == secret ]]; then
    reference_secret | curl -fsS "$BASE_URL/realms/$REALM/protocol/openid-connect/token" \
      --data-urlencode grant_type=authorization_code --data-urlencode "code=$code" \
      --data-urlencode "redirect_uri=$redirect" --data-urlencode "client_id=$client" \
      --data-urlencode 'client_secret@-' --data-urlencode "code_verifier=$verifier"
  else
    curl -fsS "$BASE_URL/realms/$REALM/protocol/openid-connect/token" \
      --data-urlencode grant_type=authorization_code --data-urlencode "code=$code" \
      --data-urlencode "redirect_uri=$redirect" --data-urlencode "client_id=$client" \
      --data-urlencode "code_verifier=$verifier"
  fi
}

# token_error GRANT_TYPE [PARAMETER=VALUE...]: the error of a token request of admin-local (no secret).
token_error() {
  local grant=$1 arguments=() pair
  shift
  for pair in "$@"; do arguments+=(--data-urlencode "$pair"); done
  curl -sS "$BASE_URL/realms/$REALM/protocol/openid-connect/token" \
    --data-urlencode "grant_type=$grant" --data-urlencode "client_id=$CLIENT" \
    ${arguments[@]+"${arguments[@]}"} | jq -r '.error // "none"'
}

AUD='(.aud // []) | if type == "array" then . else [.] end | sort'
# What differs between the two clients' tokens by construction (and the unmirrored claim panel).
PER_CLIENT='del(.azp, .aud, .sid, .session_state, .jti, .iat, .exp, .auth_time, ."allowed-origins", .panel)'

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='Keycloak start'
[[ -n $IMAGE ]] || fail 'Dockerfile has no ARG KEYCLOAK_IMAGE'
for tool in jq curl openssl base64; do command -v "$tool" >/dev/null || fail "$tool is required"; done
docker run --rm -d --name "$CONTAINER" -p "127.0.0.1:$PORT:8080" \
  -e KC_BOOTSTRAP_ADMIN_USERNAME=admin -e KC_BOOTSTRAP_ADMIN_PASSWORD="$ADMIN_PASSWORD" \
  "$IMAGE" start-dev >/dev/null
for _ in $(seq 1 90); do
  curl -fsS "$BASE_URL/realms/master" >/dev/null 2>&1 && break
  sleep 2
done
curl -fsS "$BASE_URL/realms/master" >/dev/null || fail "Keycloak did not start ($IMAGE)"
docker exec "$CONTAINER" /opt/keycloak/bin/kcadm.sh config credentials --config "$KCADM_CONFIG" \
  --server http://localhost:8080 --realm master --user admin --password "$ADMIN_PASSWORD" >/dev/null 2>&1 \
  || fail 'kcadm login failed'
docker exec -i "$CONTAINER" sh -c "cat > $IN_CONTAINER_SCRIPT" <"$OPERATOR_SCRIPT"

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='only the sandbox realm'
kcadm create realms -s realm=e-skylab -s enabled=true >/dev/null
for mode in --check --apply --revoke; do
  refused=$(RUN_REALM=e-skylab run_expecting 2 "$mode" --apply)
  expect_line "$refused" 'refusing realm e-skylab: that is production, and a localhost login client never goes there' 'production not refused by name'
  reject_line "$refused" 'realm=' 'the refused run went on'
done
for realm in master other-realm; do
  refused=$(RUN_REALM=$realm run_expecting 2 --apply)
  expect_line "$refused" "refusing realm $realm: this script writes only the sandbox realm e-skylab-sandbox" 'realm not refused'
done
refused=$(RUN_REFERENCE=$CLIENT run_expecting 2 --apply)
expect_line "$refused" 'KEYCLOAK_ADMIN_PANEL_CLIENT_ID must name the sandbox panel' 'admin-local accepted as its own reference'
[[ -z $(client_uuid "$CLIENT" e-skylab) && -z $(client_uuid "$CLIENT" master) ]] || fail "a refused run made $CLIENT"
missing=$(run_expecting 1 --apply)
expect_line "$missing" 'realm e-skylab-sandbox does not exist or cannot be read; nothing was changed' 'missing realm not reported'
printf '    e-skylab (by name), master and other-realm refused (exit 2) before a login; a missing sandbox realm is exit 1\n'

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='fixture realm'
kcadm create realms -s realm="$REALM" -s enabled=true -s adminEventsEnabled=true -s adminEventsDetailsEnabled=true >/dev/null
for client in core forms skycms skymail; do
  kcadm create clients -r "$REALM" -s "clientId=$client" -s publicClient=false -s standardFlowEnabled=false >/dev/null
done
for role in event:manage url:moderator; do kcadm create "clients/$(client_uuid core)/roles" -r "$REALM" -s "name=$role" >/dev/null; done
kcadm create "clients/$(client_uuid forms)/roles" -r "$REALM" -s name=forms:manage >/dev/null
kcadm create "clients/$(client_uuid skymail)/roles" -r "$REALM" -s name=skymail:access >/dev/null
# The realm scope groups writes full paths; it is not a realm default, superadmin has it by hand.
groups_scope=$(kcadm create client-scopes -r "$REALM" -i -s name=groups -s protocol=openid-connect)
kcadm create "client-scopes/$groups_scope/protocol-mappers/models" -r "$REALM" -b '{"name":"groups","protocol":"openid-connect","protocolMapper":"oidc-group-membership-mapper","config":{"full.path":"true","claim.name":"groups","multivalued":"true","access.token.claim":"true","id.token.claim":"true","userinfo.token.claim":"true","introspection.token.claim":"true"}}' >/dev/null
# The panel's client as the reconciler and inscribed-cms-roles.sh leave it.
kcadm create clients -r "$REALM" -s clientId="$REFERENCE" -s publicClient=false -s standardFlowEnabled=true \
  -s directAccessGrantsEnabled=false -s fullScopeAllowed=false -s "redirectUris=[\"$PANEL_CALLBACK\"]" \
  -s 'webOrigins=["https://sandbox-admin.yildizskylab.com"]' >/dev/null
reference_id=$(client_uuid "$REFERENCE")
for role in content:read content:write schema:sync; do kcadm create "clients/$reference_id/roles" -r "$REALM" -s "name=$role" >/dev/null; done
kcadm create "clients/$reference_id/protocol-mappers/models" -r "$REALM" -b '{"name":"inscribed-roles","protocol":"openid-connect","protocolMapper":"oidc-usermodel-client-role-mapper","config":{"usermodel.clientRoleMapping.clientId":"superadmin","usermodel.clientRoleMapping.rolePrefix":"","claim.name":"roles","jsonType.label":"String","multivalued":"true","access.token.claim":"true","id.token.claim":"false","userinfo.token.claim":"false","introspection.token.claim":"true"}}' >/dev/null
kcadm create "clients/$reference_id/protocol-mappers/models" -r "$REALM" -b '{"name":"panel","protocol":"openid-connect","protocolMapper":"oidc-hardcoded-claim-mapper","config":{"claim.name":"panel","claim.value":"sandbox","jsonType.label":"String","access.token.claim":"true","id.token.claim":"false","userinfo.token.claim":"false"}}' >/dev/null
kcadm create "clients/$reference_id/scope-mappings/clients/$(client_uuid core)" -r "$REALM" \
  -b "$(kcadm get "clients/$(client_uuid core)/roles" -r "$REALM" | jq -c 'map({id, name})')" >/dev/null
kcadm create "clients/$reference_id/scope-mappings/clients/$(client_uuid forms)" -r "$REALM" \
  -b "$(kcadm get "clients/$(client_uuid forms)/roles" -r "$REALM" | jq -c 'map({id, name})')" >/dev/null
kcadm update "clients/$reference_id/default-client-scopes/$groups_scope" -r "$REALM" -n -b '{}' >/dev/null
for scope in address phone; do kcadm delete "clients/$reference_id/optional-client-scopes/$(scope_uuid "$scope")" -r "$REALM" >/dev/null; done
# Groups and people (the SKY LAB admin panel's grants).
admin_group=$(kcadm create groups -r "$REALM" -i -s name=ADMIN)
uyeler=$(kcadm create groups -r "$REALM" -i -s name=UYELER)
yk=$(kcadm create "groups/$uyeler/children" -r "$REALM" -i -s name=YK)
kcadm create "groups/$admin_group/role-mappings/clients/$(client_uuid core)" -r "$REALM" -b "$(role_ref core event:manage)" >/dev/null
kcadm create "groups/$admin_group/role-mappings/clients/$(client_uuid forms)" -r "$REALM" -b "$(role_ref forms forms:manage)" >/dev/null
kcadm create "groups/$admin_group/role-mappings/clients/$reference_id" -r "$REALM" \
  -b "$(kcadm get "clients/$reference_id/roles" -r "$REALM" | jq -c 'map(select(.name != "schema:sync") | {id, name})')" >/dev/null
kcadm create "groups/$yk/role-mappings/clients/$(client_uuid core)" -r "$REALM" -b "$(role_ref core url:moderator)" >/dev/null
person() { # person USERNAME GROUP_ID...
  local uuid group user=$1
  shift
  uuid=$(kcadm create users -r "$REALM" -i -s "username=$user" -s enabled=true -s "email=$user@example.invalid" \
    -s emailVerified=true -s firstName=Harness -s "lastName=$user")
  kcadm set-password -r "$REALM" --userid "$uuid" --new-password "$PERSON_PASSWORD" >/dev/null
  for group in "$@"; do kcadm update "users/$uuid/groups/$group" -r "$REALM" -n -b '{}' >/dev/null; done
}
person kaan-fixture "$admin_group" "$yk"
person uye-fixture "$uyeler"

CURRENT_STAGE='no audience scope yet'
event_before=$(newest_admin_event)
sleep 1
blocked=$(run_expecting 1 --apply)
expect_line "$blocked" 'PROBLEM: client scope admin-panel-api-audience does not exist in realm e-skylab-sandbox' 'missing audience scope not a PROBLEM'
expect_line "$blocked" 'nothing was changed: the prerequisites above are missing' 'missing prerequisite not reported'
[[ $(newest_admin_event) == "$event_before" && -z $(client_uuid "$CLIENT") ]] || fail 'a run without the audience scope wrote'
printf '    without admin-panel-api-audience: PROBLEM, exit 1, nothing written\n'

# The reconciler's scope, as ensure_client_scope makes it from the source-controlled mappers.
audience_scope=$(kcadm create client-scopes -r "$REALM" -i -b '{"name":"admin-panel-api-audience","protocol":"openid-connect","attributes":{"include.in.token.scope":"false","display.on.consent.screen":"false"}}')
while IFS= read -r mapper; do
  # </dev/null: docker exec -i would read the rest of the loop's input.
  kcadm create "client-scopes/$audience_scope/protocol-mappers/models" -r "$REALM" -b "$mapper" </dev/null >/dev/null
done < <(jq -c '.[]' "$AUDIENCE_MAPPERS_FILE")
json_assert "$(kcadm get "client-scopes/$audience_scope/protocol-mappers/models" -r "$REALM")" \
  'map(.name) | sort == ["core-audience", "forms-audience", "skycms-audience"]' 'the audience scope fixture is incomplete'
kcadm update "clients/$reference_id/default-client-scopes/$audience_scope" -r "$REALM" -n -b '{}' >/dev/null
reference_before=$(reference_snapshot)
json_assert "$reference_before" '.defaults == ["acr", "admin-panel-api-audience", "basic", "email", "groups", "profile", "roles", "web-origins"]' \
  'the reference fixture does not have the expected default scopes'
printf '    reference %s: default scopes %s, optional %s\n' "$REFERENCE" "$(jq -c .defaults <<<"$reference_before")" "$(jq -c .optionals <<<"$reference_before")"

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='--check writes nothing'
event_before=$(newest_admin_event)
sleep 1
check=$(run_expecting 0 --check)
printf '%s\n' "$check" | sed 's/^/    /'
[[ $(newest_admin_event) == "$event_before" ]] || fail '--check wrote to the realm'
expect_line "$check" 'realm=e-skylab-sandbox mode=check client=admin-local reference=superadmin' 'unexpected header'
expect_line "$check" "would create public client admin-local (standard flow only, PKCE S256, fullScopeAllowed=false, no secret; redirect $CALLBACK, web origin http://localhost:3000, post-logout http://localhost:3000/*)" 'client not planned'
expect_line "$check" 'reference mapper inscribed-roles (flat roles of superadmin): mirrored by inscribed-roles' 'inscribed-roles not recognised'
expect_line "$check" "NOTE: the reference's mapper panel (oidc-hardcoded-claim-mapper) is not copied to admin-local" 'the unmirrored mapper not reported'
expect_line "$check" 'would attach the default scope admin-panel-api-audience to admin-local' 'audience scope not planned'
expect_line "$check" 'would attach the default scope groups to admin-local' 'groups scope not planned'
expect_line "$check" 'would detach the optional scope address from admin-local' 'address not planned'
expect_line "$check" 'would detach the optional scope phone from admin-local' 'phone not planned'
expect_line "$check" 'would add the core roles event:manage url:moderator to the role scope of admin-local' 'core roles not planned'
expect_line "$check" 'would add the forms roles forms:manage to the role scope of admin-local' 'forms roles not planned'
expect_line "$check" 'would add the superadmin roles content:read content:write schema:sync to the role scope of admin-local' 'reference roles not planned'
expect_line "$check" 'would add mapper inscribed-roles to admin-local (User Client Role: the roles of superadmin as the flat claim roles' 'inscribed-roles not planned'
expect_line "$check" 'admin-local: full-path groups comes from the default scope mapper(s) groups/groups' 'groups source not recognised'
reject_line "$check" 'would add mapper groups' 'a groups mapper planned although the scope writes full paths'
expect_line "$check" 'check: 9 change(s) pending, 0 warning(s), 0 problem(s)' 'unexpected plan size'
[[ -z $(client_uuid "$CLIENT") ]] || fail '--check made the client'

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='--apply'
apply=$(run_expecting 0 --apply)
printf '%s\n' "$apply" | sed 's/^/    /'
expect_line "$apply" 'applied 9 change(s), 0 warning(s), 0 problem(s)' 'apply did not write the plan'
expect_line "$apply" 'admin-local: created (id ' 'creation not reported'
local_id=$(client_uuid "$CLIENT")
[[ -n $local_id ]] || fail 'the client was not made'
live=$(kcadm get "clients/$local_id" -r "$REALM")
json_assert "$live" '.enabled and .protocol == "openid-connect" and .publicClient and (.bearerOnly | not)
  and .standardFlowEnabled and (.implicitFlowEnabled | not) and (.directAccessGrantsEnabled | not)
  and (.serviceAccountsEnabled | not) and (.fullScopeAllowed | not) and (.consentRequired | not) and (.frontchannelLogout | not)
  and .attributes["pkce.code.challenge.method"] == "S256" and .attributes["post.logout.redirect.uris"] == "http://localhost:3000/*"
  and .attributes["standard.token.exchange.enabled"] == "false" and .attributes["oauth2.device.authorization.grant.enabled"] == "false"' \
  'the client flags are not the contract'
json_assert "$live" '.redirectUris == [$c] and .webOrigins == ["http://localhost:3000"]' 'the client URIs are not localhost only' --arg c "$CALLBACK"
json_assert "$live" '(.defaultClientScopes | sort) == $r.defaults and (.optionalClientScopes | sort) == $r.optionals' \
  'the client scopes are not the reference'"'"'s' --argjson r "$reference_before"
scope=$(kcadm get "clients/$local_id/scope-mappings" -r "$REALM")
json_assert "$scope" '(.realmMappings // []) == [] and (.clientMappings | keys) == ["core", "forms", "superadmin"]
  and (.clientMappings.core.mappings | map(.name) | sort) == ["event:manage", "url:moderator"]
  and (.clientMappings.forms.mappings | map(.name)) == ["forms:manage"]
  and (.clientMappings.superadmin.mappings | map(.name) | sort) == ["content:read", "content:write", "schema:sync"]' 'the role scope is not the contract'
mappers=$(kcadm get "clients/$local_id/protocol-mappers/models" -r "$REALM")
json_assert "$mappers" 'map(.name) == ["inscribed-roles"]' 'unexpected client mappers'
[[ $(reference_snapshot) == "$reference_before" ]] || fail 'the run changed the reference superadmin'
printf '    client: %s\n' "$(jq -c '{publicClient, standardFlowEnabled, fullScopeAllowed, pkce: .attributes["pkce.code.challenge.method"], redirectUris, webOrigins, defaultClientScopes, optionalClientScopes}' <<<"$live")"
printf '    role scope: %s; superadmin unchanged\n' "$(jq -c '.clientMappings | map_values(.mappings | map(.name) | sort)' <<<"$scope")"

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='tokens: admin-local (public, PKCE) against superadmin'
response=$(code_flow "$CLIENT" "$CALLBACK" kaan-fixture)
local_access=$(jwt_payload "$(jq -r .access_token <<<"$response")")
reference_access=$(jwt_payload "$(jq -r .access_token <<<"$(code_flow "$REFERENCE" "$PANEL_CALLBACK" kaan-fixture secret)")")
json_assert "$local_access" ".azp == \"$CLIENT\" and ($AUD) == [\"core\", \"forms\", \"skycms\", \"superadmin\"]" 'admin-local token: azp or aud'
json_assert "$reference_access" ".azp == \"$REFERENCE\" and ($AUD) == [\"core\", \"forms\", \"skycms\"] and .panel == \"sandbox\"" 'superadmin token: azp, aud or panel'
for payload in "$local_access" "$reference_access"; do
  json_assert "$payload" '(has("realm_access") | not) and (.resource_access | keys) == ["core", "forms", "superadmin"]
    and (.resource_access.core.roles | sort) == ["event:manage", "url:moderator"] and .resource_access.forms.roles == ["forms:manage"]
    and (.roles | sort) == ["content:read", "content:write"] and (.groups | sort) == ["/ADMIN", "/UYELER/YK"]
    and .preferred_username == "kaan-fixture" and .email == "kaan-fixture@example.invalid"' 'a token lacks the panel'"'"'s claims'
done
json_assert "$local_access" '(has("panel") | not) and ."allowed-origins" == ["http://localhost:3000"]' 'admin-local token: panel or allowed-origins'
[[ "$(jq -S "$PER_CLIENT" <<<"$local_access")" == "$(jq -S "$PER_CLIENT" <<<"$reference_access")" ]] || {
  diff <(jq -S "$PER_CLIENT" <<<"$reference_access") <(jq -S "$PER_CLIENT" <<<"$local_access") >&2 || true
  fail 'the admin-local token differs from superadmin'"'"'s beyond azp, aud, session, allowed-origins and panel'
}
printf '    kaan-fixture admin-local: aud=%s resource_access=%s roles=%s groups=%s\n' "$(jq -c "$AUD" <<<"$local_access")" \
  "$(jq -c '.resource_access | map_values(.roles | sort)' <<<"$local_access")" "$(jq -c '.roles | sort' <<<"$local_access")" "$(jq -c .groups <<<"$local_access")"
printf '    kaan-fixture superadmin:  aud=%s; every other claim equal but azp, session, allowed-origins and the unmirrored panel\n' \
  "$(jq -c "$AUD" <<<"$reference_access")"
refreshed=$(jq -j .refresh_token <<<"$response" | curl -fsS "$BASE_URL/realms/$REALM/protocol/openid-connect/token" \
  --data-urlencode grant_type=refresh_token --data-urlencode "client_id=$CLIENT" --data-urlencode 'refresh_token@-')
json_assert "$(jwt_payload "$(jq -r .access_token <<<"$refreshed")")" ".azp == \"$CLIENT\" and (.roles | sort) == [\"content:read\", \"content:write\"]" \
  'the refresh grant without a secret failed'
member=$(jwt_payload "$(jq -r .access_token <<<"$(code_flow "$CLIENT" "$CALLBACK" uye-fixture)")")
json_assert "$member" "($AUD) == [\"core\", \"forms\", \"skycms\"] and .groups == [\"/UYELER\"] and (has(\"roles\") | not)
  and ((.resource_access // {}) | keys | length == 0) and (has(\"realm_access\") | not)" 'uye-fixture token'
printf '    refresh without a secret: ok; uye-fixture: aud=%s groups=%s, no roles\n' "$(jq -c "$AUD" <<<"$member")" "$(jq -c .groups <<<"$member")"

CURRENT_STAGE='what Keycloak refuses'
for redirect in "$PANEL_CALLBACK" http://localhost:3001/api/auth/callback http://127.0.0.1:3000/api/auth/callback; do
  result=$(authorize "$CLIENT" "$redirect" response_type=code scope=openid code_challenge=abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG code_challenge_method=S256)
  [[ ${result%% *} == 400 ]] || fail "admin-local accepted the redirect URI $redirect ($result)"
done
result=$(authorize "$REFERENCE" "$CALLBACK" response_type=code scope=openid)
[[ ${result%% *} == 400 ]] || fail "superadmin accepts the localhost callback ($result)"
result=$(authorize "$CLIENT" "$CALLBACK" response_type=code scope=openid)
[[ $result == "302 $CALLBACK?"*error=invalid_request* ]] || fail "a request without PKCE was not refused ($result)"
result=$(authorize "$CLIENT" "$CALLBACK" response_type=code scope=openid code_challenge=abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG code_challenge_method=plain)
[[ $result == "302 $CALLBACK?"*error=invalid_request* ]] || fail "the plain PKCE method was not refused ($result)"
result=$(authorize "$CLIENT" "$CALLBACK" response_type=code scope=openid code_challenge=abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG code_challenge_method=S256)
[[ ${result%% *} == 200 ]] || fail "the localhost callback with PKCE was refused ($result)"
[[ $(token_error password username=kaan-fixture "password=$PERSON_PASSWORD") == unauthorized_client ]] || fail 'the password grant was not refused'
[[ $(token_error client_credentials) == unauthorized_client ]] || fail 'the client_credentials grant was not refused'
printf '    refused: the panel'"'"'s callback, localhost:3001, 127.0.0.1:3000, no PKCE, plain PKCE, password, client_credentials; superadmin still refuses localhost\n'

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='second run is a no-op'
event_before=$(newest_admin_event)
sleep 1
again=$(run_expecting 0 --check)
expect_line "$again" 'check: 0 change(s) pending, 0 warning(s), 0 problem(s)' 'second --check plans changes'
expect_line "$again" "admin-local: redirect URI exactly $CALLBACK" 'the redirect URI not recognised'
expect_line "$again" 'admin-local: mapper inscribed-roles unchanged' 'inscribed-roles not recognised'
expect_line "$again" 'admin-local: role scope holds every core role (event:manage url:moderator)' 'role scope not recognised'
again=$(run_expecting 0 --apply)
expect_line "$again" 'applied 0 change(s), 0 warning(s), 0 problem(s)' 'second --apply wrote'
[[ $(newest_admin_event) == "$event_before" ]] || fail 'the second run wrote to the realm'
printf '    second --check and --apply: 0 change(s), no admin event\n'

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='drift is planned, then repaired'
kcadm update "clients/$local_id" -r "$REALM" -s "redirectUris=[\"$CALLBACK\",\"https://evil.example/*\"]" -s 'webOrigins=["*"]' \
  -s fullScopeAllowed=true -s directAccessGrantsEnabled=true >/dev/null
kcadm create "clients/$local_id/scope-mappings/realm" -r "$REALM" -b "$(kcadm get roles/offline_access -r "$REALM" | jq -c '[{id, name}]')" >/dev/null
kcadm create "clients/$local_id/scope-mappings/clients/$(client_uuid skymail)" -r "$REALM" -b "$(role_ref skymail skymail:access)" >/dev/null
kcadm delete "clients/$local_id/scope-mappings/clients/$(client_uuid core)" -r "$REALM" -b "$(role_ref core url:moderator)" >/dev/null
kcadm delete "clients/$local_id/default-client-scopes/$groups_scope" -r "$REALM" >/dev/null
kcadm update "clients/$local_id/optional-client-scopes/$(scope_uuid phone)" -r "$REALM" -n -b '{}' >/dev/null
kcadm create "clients/$local_id/protocol-mappers/models" -r "$REALM" -b '{"name":"stray","protocol":"openid-connect","protocolMapper":"oidc-hardcoded-claim-mapper","config":{"claim.name":"stray","claim.value":"x","jsonType.label":"String","access.token.claim":"true"}}' >/dev/null
roles_mapper=$(kcadm get "clients/$local_id/protocol-mappers/models" -r "$REALM" | jq -c '.[] | select(.name == "inscribed-roles") | .config["id.token.claim"] = "true"')
kcadm update "clients/$local_id/protocol-mappers/models/$(jq -r .id <<<"$roles_mapper")" -r "$REALM" -b "$roles_mapper" >/dev/null
event_before=$(newest_admin_event)
sleep 1
drift=$(run_expecting 0 --check)
printf '%s\n' "$drift" | grep -F 'would' | sed 's/^/    /'
[[ $(newest_admin_event) == "$event_before" ]] || fail '--check wrote while drifted'
expect_line "$drift" 'would update admin-local flags' 'flags not planned'
expect_line "$drift" "would set the redirect URIs of admin-local to exactly $CALLBACK (removing https://evil.example/*)" 'redirect not planned'
expect_line "$drift" 'would set the web origins of admin-local to exactly http://localhost:3000 (removing *)' 'web origin not planned'
expect_line "$drift" 'would detach the optional scope phone from admin-local' 'phone not planned'
expect_line "$drift" 'would attach the default scope groups to admin-local' 'groups not planned'
expect_line "$drift" 'would remove the realm roles offline_access from the role scope of admin-local' 'realm role not planned'
expect_line "$drift" 'would remove the skymail roles skymail:access from the role scope of admin-local' 'foreign role not planned'
expect_line "$drift" 'would add the core roles url:moderator to the role scope of admin-local' 'missing core role not planned'
expect_line "$drift" 'would repair mapper inscribed-roles on admin-local' 'inscribed-roles not planned'
expect_line "$drift" 'would remove mapper stray (oidc-hardcoded-claim-mapper) from admin-local' 'stray mapper not planned'
expect_line "$drift" 'check: 10 change(s) pending, 0 warning(s), 0 problem(s)' 'unexpected drift plan size'
repaired=$(run_expecting 0 --apply)
expect_line "$repaired" 'applied 10 change(s), 0 warning(s), 0 problem(s)' 'drift not repaired'
again=$(run_expecting 0 --check)
expect_line "$again" 'check: 0 change(s) pending' 'drift left something'
live=$(kcadm get "clients/$local_id" -r "$REALM")
json_assert "$live" '.redirectUris == [$c] and .webOrigins == ["http://localhost:3000"] and (.fullScopeAllowed | not) and (.directAccessGrantsEnabled | not)
  and (.defaultClientScopes | sort) == $r.defaults and (.optionalClientScopes | sort) == $r.optionals' 'the repaired client is not the contract' \
  --arg c "$CALLBACK" --argjson r "$reference_before"
[[ $(reference_snapshot) == "$reference_before" ]] || fail 'the repair changed the reference superadmin'
printf '    drift: 10 change(s) planned without a write, repaired, third --check 0\n'

CURRENT_STAGE='reference not narrowed, groups without full paths'
kcadm update "clients/$reference_id" -r "$REALM" -s fullScopeAllowed=true >/dev/null
narrow=$(run_expecting 0 --check)
expect_line "$narrow" 'WARNING: the reference superadmin is not narrowed yet (fullScopeAllowed=true, admin-panel-api-audience attached)' 'not-narrowed reference not a WARNING'
expect_line "$narrow" 'check: 0 change(s) pending, 1 warning(s), 0 problem(s)' 'the not-narrowed reference changed the plan'
kcadm update "clients/$reference_id" -r "$REALM" -s fullScopeAllowed=false >/dev/null
groups_mapper=$(kcadm get "client-scopes/$groups_scope/protocol-mappers/models" -r "$REALM" | jq -c '.[0]')
kcadm update "client-scopes/$groups_scope/protocol-mappers/models/$(jq -r .id <<<"$groups_mapper")" -r "$REALM" \
  -b "$(jq -c '.config["full.path"] = "false"' <<<"$groups_mapper")" >/dev/null
kcadm update "clients/$local_id" -r "$REALM" -s 'redirectUris=["https://evil.example/*"]' >/dev/null
event_before=$(newest_admin_event)
sleep 1
broken=$(run_expecting 1 --apply)
expect_line "$broken" 'PROBLEM: the default scope mapper(s) groups/groups write groups differently from full paths' 'flat groups not a PROBLEM'
expect_line "$broken" 'nothing was changed: fix the PROBLEM(s) above by hand and run again' 'PROBLEM run not reported as unchanged'
[[ $(newest_admin_event) == "$event_before" ]] || fail 'a PROBLEM run wrote'
kcadm update "client-scopes/$groups_scope/protocol-mappers/models/$(jq -r .id <<<"$groups_mapper")" -r "$REALM" -b "$groups_mapper" >/dev/null
fixed=$(run_expecting 0 --apply)
expect_line "$fixed" 'applied 1 change(s), 0 warning(s), 0 problem(s)' 'the redirect URI not repaired after the PROBLEM'
printf '    a not-narrowed reference is a WARNING (plan unchanged); flat groups in a default scope: PROBLEM, exit 1, nothing written\n'

CURRENT_STAGE='groups from the reference'"'"'s own mapper'
# inscribed-cms-roles.sh's shape when no default scope writes full paths: the client mapper inscribed-groups.
kcadm delete "clients/$reference_id/default-client-scopes/$groups_scope" -r "$REALM" >/dev/null
kcadm create "clients/$reference_id/protocol-mappers/models" -r "$REALM" -b '{"name":"inscribed-groups","protocol":"openid-connect","protocolMapper":"oidc-group-membership-mapper","config":{"claim.name":"groups","full.path":"true","multivalued":"true","access.token.claim":"true","id.token.claim":"false","userinfo.token.claim":"false","introspection.token.claim":"true"}}' >/dev/null
reference_before=$(reference_snapshot)
own=$(run_expecting 0 --check)
expect_line "$own" 'reference mapper inscribed-groups (full-path groups): admin-local gets full-path groups too' 'the reference groups mapper not recognised'
expect_line "$own" 'would detach the default scope groups from admin-local (the reference does not have it)' 'groups scope not detached'
expect_line "$own" 'would add mapper groups to admin-local (Group Membership: claim groups, full path, access token and introspection)' 'groups mapper not planned'
expect_line "$own" 'check: 2 change(s) pending, 0 warning(s), 0 problem(s)' 'unexpected plan for the own groups mapper'
own=$(run_expecting 0 --apply)
expect_line "$own" 'applied 2 change(s), 0 warning(s), 0 problem(s)' 'own groups mapper not applied'
expect_line "$(run_expecting 0 --check)" 'check: 0 change(s) pending' 'own groups mapper not idempotent'
local_access=$(jwt_payload "$(jq -r .access_token <<<"$(code_flow "$CLIENT" "$CALLBACK" kaan-fixture)")")
reference_access=$(jwt_payload "$(jq -r .access_token <<<"$(code_flow "$REFERENCE" "$PANEL_CALLBACK" kaan-fixture secret)")")
json_assert "$local_access" '(.groups | sort) == ["/ADMIN", "/UYELER/YK"]' 'admin-local lost the full-path groups'
[[ "$(jq -S "$PER_CLIENT" <<<"$local_access")" == "$(jq -S "$PER_CLIENT" <<<"$reference_access")" ]] || {
  diff <(jq -S "$PER_CLIENT" <<<"$reference_access") <(jq -S "$PER_CLIENT" <<<"$local_access") >&2 || true
  fail 'with groups from client mappers the two tokens differ beyond the per-client claims'
}
[[ $(reference_snapshot) == "$reference_before" ]] || fail 'the run changed the reference superadmin'
printf '    groups from the reference'"'"'s own mapper: admin-local gets the mapper groups, the tokens still match\n'

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='--revoke'
event_before=$(newest_admin_event)
sleep 1
revoke=$(run_expecting 0 --revoke)
expect_line "$revoke" 'would delete client admin-local' 'revoke not planned'
expect_line "$revoke" 'check: 1 change(s) pending' 'unexpected revoke plan'
[[ $(newest_admin_event) == "$event_before" && -n $(client_uuid "$CLIENT") ]] || fail '--revoke --check wrote'
revoke=$(run_expecting 0 --revoke --apply)
expect_line "$revoke" 'applied 1 change(s), 0 warning(s), 0 problem(s)' 'revoke not applied'
[[ -z $(client_uuid "$CLIENT") ]] || fail 'admin-local still exists'
[[ $(reference_snapshot) == "$reference_before" ]] || fail 'the revoke changed the reference superadmin'
result=$(authorize "$CLIENT" "$CALLBACK" response_type=code scope=openid code_challenge=abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG code_challenge_method=S256)
[[ ${result%% *} == 400 ]] || fail "the revoked client still starts a login ($result)"
revoke=$(run_expecting 0 --revoke --apply)
expect_line "$revoke" 'client admin-local does not exist in realm e-skylab-sandbox; nothing to revoke' 'second revoke not a no-op'
expect_line "$revoke" 'applied 0 change(s)' 'second revoke wrote'
printf '    --revoke: planned without a write, deleted admin-local only (superadmin unchanged), second run 0\n'

CURRENT_STAGE='secrets'
if reference_secret | grep -Fq -f - "$OUTPUTS"; then fail 'an output carries the secret of superadmin'; fi
printf 'sandbox-admin-local-client: all checks passed\n'
