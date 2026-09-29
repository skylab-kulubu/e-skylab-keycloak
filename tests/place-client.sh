#!/usr/bin/env bash
# Real-Keycloak contract for config/create-place-client.sh (Place's login client, ADR-0060).
# Stand-alone: starts the stock Keycloak image this repository builds on (the Dockerfile's
# KEYCLOAK_IMAGE, tag and digest) in dev mode with docker run --rm and no volume, builds a small
# realm e-skylab, runs the script inside that container the way the wizard does and reads real
# tokens. The container is removed on exit (docker rm -fv).
#
# The fixture realm (e-skylab): its User Profile declares schoolEmail as
# config/account-center-user-profile.json does; a realm scope "groups" (full-path Group Membership
# into every token) is a realm DEFAULT scope, so a new client gets it (the worst case; Keycloak's
# own microprofile-jwt, a realm optional scope, carries a "groups" mapper too); a client core with
# a role events:manage; groups /UYELER, /UYELER/YK and /UYELER/ETKINLIK; people ayse (school
# e-mail, a personal primary e-mail, in /UYELER/YK, holds core events:manage), zeynep (school
# e-mail, in /UYELER/ETKINLIK) and mehmet (no school e-mail, in /UYELER). A realm e-skylab-sandbox
# stands for a realm the script must refuse.
#
# What it proves:
#   - every realm but e-skylab is refused before a login (exit 2); without the realm nothing is
#     written (exit 1);
#   - --check writes nothing (admin events) and plans the client, the two roles, the two mappers and
#     the detachment of the two scopes that write groups; --apply writes exactly that and grants no
#     role to anyone; the client is confidential, standard flow only, PKCE S256, fullScopeAllowed
#     off, front-channel logout off, redirect URI exactly Place's callback, no web origin; the
#     secret is never printed; a second --check plans nothing and a second --apply writes nothing;
#   - with place:moderator granted to ayse and place:admin to /UYELER/ETKINLIK the way the SKY LAB
#     admin panel does it, a real authorization code flow with PKCE S256 and a nonce through the
#     client (login page, credentials, redirect to https://api.place.yildizskylab.com/api/auth/eskylab/callback,
#     code exchanged with the secret and the verifier, as Place's backend does) gives an ID token
#     (aud place, the nonce), an access token and a userinfo response that carry school_email (the
#     school address, not the primary e-mail) and resource_access.place.roles, and no groups, no
#     realm_access and no other client's roles; zeynep's come through her group; mehmet gets no
#     school_email and no Place role; asking for the groups or microprofile-jwt scope is refused;
#   - an authorization request without PKCE, with the plain method, with response_type=token or
#     with a foreign redirect URI is refused; so are the password and client_credentials grants;
#   - drift (flags, PKCE, the redirect URIs, a web origin, both mappers, the two scopes) is
#     repaired; a groups mapper and a second school_email mapper on the client are PROBLEMs (exit
#     1) and are left as is; a User Profile without schoolEmail is a WARNING.
# Requirements on the host: docker, curl, jq, openssl, base64. PLACE_CLIENT_TEST_PORT (default
# 18093), PLACE_CLIENT_TEST_CONTAINER (default place-client-test-<pid>).
# The jq programs name jq variables ($s, $t, $want), not shell ones:
# shellcheck disable=SC2016
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPOSITORY_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
OPERATOR_SCRIPT="$REPOSITORY_ROOT/config/create-place-client.sh"
USER_PROFILE_FILE="$REPOSITORY_ROOT/config/account-center-user-profile.json"
IMAGE=$(sed -n 's/^ARG KEYCLOAK_IMAGE=//p' "$REPOSITORY_ROOT/Dockerfile")
PORT=${PLACE_CLIENT_TEST_PORT:-18093}
BASE_URL="http://127.0.0.1:$PORT"
REALM=e-skylab
CLIENT=place
CALLBACK=https://api.place.yildizskylab.com/api/auth/eskylab/callback
CONTAINER=${PLACE_CLIENT_TEST_CONTAINER:-place-client-test-$$}
ADMIN_PASSWORD=harness-admin-password
PERSON_PASSWORD=harness-person-password
KCADM_CONFIG=/tmp/harness-kcadm.config
IN_CONTAINER_SCRIPT=/tmp/create-place-client.sh
OUTPUTS=$(mktemp "${TMPDIR:-/tmp}/place-client-outputs.XXXXXX")
CURRENT_STAGE=startup

fail() {
  printf 'place-client failure during %s: %s\n' "$CURRENT_STAGE" "$1" >&2
  exit 1
}
cleanup() {
  docker rm -fv "$CONTAINER" >/dev/null 2>&1 || true
  rm -f "$OUTPUTS"
}
trap 'status=$?; trap - EXIT; cleanup; exit "$status"' EXIT
on_error() {
  local status=$?
  printf 'place-client command failed during %s (line %s)\n' "$CURRENT_STAGE" "$1" >&2
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

# run_script ARGS...: the operator script inside the Keycloak container, reusing the harness's
# kcadm session (the wizard does the same). Prints the output (also kept in OUTPUTS for the secret
# check); returns the script's status. RUN_REALM sets KEYCLOAK_REALM.
run_script() {
  local output status=0
  output=$(docker exec -e KEYCLOAK_ADMIN_URL=http://localhost:8080 -e KEYCLOAK_REALM="${RUN_REALM:-$REALM}" "$CONTAINER" \
    bash "$IN_CONTAINER_SCRIPT" --kcadm-config "$KCADM_CONFIG" "$@" 2>&1) || status=$?
  printf '%s\n' "$output" >>"$OUTPUTS"
  printf '%s\n' "$output"
  return "$status"
}

# run_expecting STATUS ARGS...: run_script for a run that must exit STATUS; prints the output.
run_expecting() {
  local wanted=$1 output status=0
  shift
  # bash 3.2 would fire the inherited ERR trap inside the substitution.
  trap - ERR
  output=$(run_script "$@") || status=$?
  trap 'on_error "$LINENO"' ERR
  [[ $status == "$wanted" ]] || { printf '%s\n' "$output" >&2; fail "the run did not exit $wanted (exit $status)"; }
  printf '%s\n' "$output"
}

expect_line() {
  local output=$1 expected=$2 message=$3
  grep -Fq -- "$expected" <<<"$output" || { printf '%s\n' "$output" >&2; fail "$message: $expected"; }
}

reject_line() {
  local output=$1 unexpected=$2 message=$3
  if grep -Fq -- "$unexpected" <<<"$output"; then
    printf '%s\n' "$output" >&2
    fail "$message: $unexpected"
  fi
}

json_assert() {
  local json=$1 expression=$2 message=$3
  shift 3
  jq -e "$@" "$expression" <<<"$json" >/dev/null || { printf '%s\n' "$json" >&2; fail "$message"; }
}

client_uuid() {
  kcadm get clients -r "${2:-$REALM}" -q "clientId=$1" | jq -r --arg id "$1" '.[] | select(.clientId == $id) | .id'
}

scope_uuid() {
  kcadm get client-scopes -r "$REALM" | jq -r --arg name "$1" '.[] | select(.name == $name) | .id'
}

newest_admin_event() {
  kcadm get admin-events -r "$REALM" -q max=1 | jq -r '.[0].time // 0'
}

# client_secret: the client's secret from the admin API, without a newline (never printed).
client_secret() {
  kcadm get "clients/$(client_uuid "$CLIENT")/client-secret" -r "$REALM" | jq -j .value
}

# jwt_payload TOKEN: the decoded payload (JSON) of a compact JWT.
jwt_payload() {
  local segment
  segment=$(cut -d. -f2 <<<"$1" | tr '_-' '/+')
  case $(( ${#segment} % 4 )) in 2) segment+='==' ;; 3) segment+='=' ;; esac
  base64 -d <<<"$segment"
}

# authorize_location [PARAMETER=VALUE...]: where Keycloak's authorization endpoint sends the browser
# for a request of the client with these parameters (client_id and redirect_uri preset).
authorize_location() {
  local arguments=() pair
  for pair in "$@"; do arguments+=(--data-urlencode "$pair"); done
  curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' -G "$BASE_URL/realms/$REALM/protocol/openid-connect/auth" \
    --data-urlencode "client_id=$CLIENT" --data-urlencode "redirect_uri=$CALLBACK" ${arguments[@]+"${arguments[@]}"}
}

# code_flow_response USER [SCOPE]: a person's token response from the real authorization code flow
# of the client, the way Place's backend runs it: PKCE S256, state and nonce, the login page, the
# credentials, the redirect to Place's callback with a code, the code exchanged with the client
# secret (on curl's stdin) and the verifier.
code_flow_response() {
  local user=$1 scope=${2:-openid} jar page action location code verifier challenge
  verifier=$(openssl rand -hex 32)
  challenge=$(printf '%s' "$verifier" | openssl dgst -sha256 -binary | base64 | tr '+/' '-_' | tr -d '=\n')
  jar=$(mktemp "${TMPDIR:-/tmp}/place-client-jar.XXXXXX")
  page=$(curl -fsS -c "$jar" -b "$jar" -G "$BASE_URL/realms/$REALM/protocol/openid-connect/auth" \
    --data-urlencode "client_id=$CLIENT" --data-urlencode response_type=code \
    --data-urlencode "scope=$scope" --data-urlencode "redirect_uri=$CALLBACK" \
    --data-urlencode state=harness-state --data-urlencode "nonce=harness-nonce-$user" \
    --data-urlencode "code_challenge=$challenge" --data-urlencode code_challenge_method=S256)
  action=$(sed -n 's/.*id="kc-form-login"[^>]*action="\([^"]*\)".*/\1/p' <<<"$page" | head -n 1 | sed 's/&amp;/\&/g')
  [[ -n $action ]] || { rm -f "$jar"; fail "no login form for $user"; }
  location=$(curl -sS -c "$jar" -b "$jar" -o /dev/null -w '%{redirect_url}' \
    --data-urlencode "username=$user" --data-urlencode "password=$PERSON_PASSWORD" "$action")
  rm -f "$jar"
  [[ $location == "$CALLBACK?"* ]] || fail "the login of $user did not return to $CALLBACK ($location)"
  [[ $location == *'state=harness-state'* ]] || fail "the state did not come back for $user"
  code=$(sed -n 's/.*[?&]code=\([^&]*\).*/\1/p' <<<"$location")
  [[ -n $code ]] || fail "no authorization code for $user"
  client_secret | curl -fsS "$BASE_URL/realms/$REALM/protocol/openid-connect/token" \
    --data-urlencode grant_type=authorization_code --data-urlencode "code=$code" \
    --data-urlencode "redirect_uri=$CALLBACK" --data-urlencode "client_id=$CLIENT" \
    --data-urlencode 'client_secret@-' --data-urlencode "code_verifier=$verifier"
}

# userinfo ACCESS_TOKEN: the userinfo response (the token goes to curl on stdin, not argv).
userinfo() {
  printf 'Authorization: Bearer %s\n' "$1" | curl -fsS -H @- "$BASE_URL/realms/$REALM/protocol/openid-connect/userinfo"
}

# token_error GRANT_TYPE [PARAMETER=VALUE...]: the error of a token request with the client secret.
token_error() {
  local grant=$1 arguments=() pair
  shift
  for pair in "$@"; do arguments+=(--data-urlencode "$pair"); done
  client_secret | curl -sS "$BASE_URL/realms/$REALM/protocol/openid-connect/token" \
    --data-urlencode "grant_type=$grant" --data-urlencode "client_id=$CLIENT" \
    --data-urlencode 'client_secret@-' ${arguments[@]+"${arguments[@]}"} | jq -r '.error // "none"'
}

AUD='(.aud // []) | if type == "array" then . else [.] end'
# What must not be in a Place token: groups in any form, realm roles, another client's roles.
NO_GROUPS='(has("groups") | not) and (has("realm_access") | not) and ((.resource_access // {}) | keys - ["place"] | length == 0)'

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
CURRENT_STAGE='only the realm e-skylab'
kcadm create realms -s realm=e-skylab-sandbox -s enabled=true >/dev/null
for realm in e-skylab-sandbox master other-realm; do
  for mode in --check --apply; do
    refused=$(RUN_REALM=$realm run_expecting 2 "$mode")
    expect_line "$refused" "refusing realm $realm: Place has no sandbox, this script writes only the realm e-skylab" 'realm not refused'
    reject_line "$refused" 'realm=' 'the refused run went on'
  done
done
[[ -z $(client_uuid "$CLIENT" e-skylab-sandbox) && -z $(client_uuid "$CLIENT" master) ]] || fail "a refused run made $CLIENT"
printf '    e-skylab-sandbox, master and other-realm refused (exit 2) before a login\n'

CURRENT_STAGE='missing realm'
missing=$(run_expecting 1 --apply)
expect_line "$missing" 'realm e-skylab does not exist or cannot be read; nothing was changed' 'missing realm not reported'
[[ -z $(client_uuid "$CLIENT" master) ]] || fail 'a run without the realm made the client'

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='fixture realm'
kcadm create realms -s realm="$REALM" -s enabled=true -s adminEventsEnabled=true >/dev/null
# The User Profile declares schoolEmail the way the reconciler makes it (view admin+user, edit admin).
kcadm get users/profile -r "$REALM" \
  | jq --slurpfile source "$USER_PROFILE_FILE" \
    '.attributes += [$source[0].attributes[] | select(.name == "schoolEmail") | . + {permissions: {view: ["admin", "user"], edit: ["admin"]}}]' \
  | kcadm update users/profile -r "$REALM" -f - >/dev/null
# The worst case: a realm scope writing full-path groups into every token, a realm default scope.
groups_scope=$(kcadm create client-scopes -r "$REALM" -i -s name=groups -s protocol=openid-connect)
kcadm create "client-scopes/$groups_scope/protocol-mappers/models" -r "$REALM" -b '{"name":"groups","protocol":"openid-connect","protocolMapper":"oidc-group-membership-mapper","config":{"full.path":"true","claim.name":"groups","multivalued":"true","access.token.claim":"true","id.token.claim":"true","userinfo.token.claim":"true","introspection.token.claim":"true"}}' >/dev/null
kcadm update "default-default-client-scopes/$groups_scope" -r "$REALM" -n >/dev/null
json_assert "$(kcadm get default-optional-client-scopes -r "$REALM")" 'any(.[]; .name == "microprofile-jwt")' \
  'microprofile-jwt is not a realm optional scope'
kcadm create clients -r "$REALM" -s clientId=core -s publicClient=false -s standardFlowEnabled=false >/dev/null
kcadm create "clients/$(client_uuid core)/roles" -r "$REALM" -s name=events:manage >/dev/null
uyeler=$(kcadm create groups -r "$REALM" -i -s name=UYELER)
yk=$(kcadm create "groups/$uyeler/children" -r "$REALM" -i -s name=YK)
etkinlik=$(kcadm create "groups/$uyeler/children" -r "$REALM" -i -s name=ETKINLIK)
# person USERNAME GROUP_ID [SCHOOL_EMAIL]: a person with a personal primary e-mail.
person() {
  local uuid
  local school=()
  if [[ -n ${3:-} ]]; then school=(-s "attributes.schoolEmail=[\"$3\"]"); fi
  uuid=$(kcadm create users -r "$REALM" -i -s "username=$1" -s enabled=true -s "email=$1@example.invalid" \
    -s emailVerified=true -s firstName=Harness -s "lastName=$1" ${school[@]+"${school[@]}"})
  kcadm set-password -r "$REALM" --userid "$uuid" --new-password "$PERSON_PASSWORD" >/dev/null
  kcadm update "users/$uuid/groups/$2" -r "$REALM" -n -b '{}' >/dev/null
}
person ayse "$yk" ayse.yilmaz@std.yildiz.edu.tr
person zeynep "$etkinlik" zeynep.kaya@std.yildiz.edu.tr
person mehmet "$uyeler"
kcadm add-roles -r "$REALM" --uusername ayse --cclientid core --rolename events:manage >/dev/null
json_assert "$(kcadm get users -r "$REALM" -q username=ayse -q exact=true)" '.[0].attributes.schoolEmail == ["ayse.yilmaz@std.yildiz.edu.tr"]' \
  'the fixture school e-mail was not stored'

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='--check writes nothing'
event_before=$(newest_admin_event)
sleep 1
check=$(run_script --check) || { printf '%s\n' "$check" >&2; fail '--check failed'; }
printf '%s\n' "$check" | sed 's/^/    /'
[[ $(newest_admin_event) == "$event_before" ]] || fail '--check wrote to the realm'
expect_line "$check" 'realm=e-skylab mode=check client=place' 'unexpected header'
expect_line "$check" 'User Profile declares schoolEmail' 'the User Profile was not read'
expect_line "$check" "would create confidential client place (standard flow only, PKCE S256, fullScopeAllowed=false, front-channel logout off; redirect $CALLBACK, no web origin" 'client not planned'
expect_line "$check" 'would create client role place:admin on place' 'place:admin not planned'
expect_line "$check" 'would create client role place:moderator on place' 'place:moderator not planned'
expect_line "$check" 'would add mapper school-email to place (user attribute schoolEmail -> school_email' 'school-email not planned'
expect_line "$check" 'would add mapper place-roles to place (place roles -> resource_access.place.roles' 'place-roles not planned'
expect_line "$check" 'would detach the default scope groups from place (it writes group data: groups (oidc-group-membership-mapper)' 'groups scope not planned'
expect_line "$check" 'would detach the optional scope microprofile-jwt from place (it writes group data: groups (oidc-usermodel-realm-role-mapper)' 'microprofile-jwt not planned'
expect_line "$check" 'check: 7 change(s) pending, 0 warning(s), 0 problem(s)' 'unexpected plan size'
[[ -z $(client_uuid "$CLIENT") ]] || fail '--check made the client'

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='--apply'
event_before=$(newest_admin_event)
apply=$(run_script --apply) || { printf '%s\n' "$apply" >&2; fail '--apply failed'; }
printf '%s\n' "$apply" | sed 's/^/    /'
expect_line "$apply" 'applied 7 change(s), 0 warning(s), 0 problem(s)' 'apply did not write the plan'
place=$(client_uuid "$CLIENT")
[[ -n $place ]] || fail 'the client was not made'
live=$(kcadm get "clients/$place" -r "$REALM")
json_assert "$live" '.enabled and .protocol == "openid-connect" and (.publicClient | not) and (.bearerOnly | not)
  and .clientAuthenticatorType == "client-secret" and .standardFlowEnabled and (.implicitFlowEnabled | not)
  and (.directAccessGrantsEnabled | not) and (.serviceAccountsEnabled | not) and (.fullScopeAllowed | not)
  and (.consentRequired | not) and (.frontchannelLogout | not)' 'the client flags are not the contract'
json_assert "$live" '.attributes["pkce.code.challenge.method"] == "S256"
  and .attributes["oauth2.device.authorization.grant.enabled"] == "false" and .attributes["oidc.ciba.grant.enabled"] == "false"
  and .attributes["standard.token.exchange.enabled"] == "false"' 'PKCE or the other grants are not the contract'
json_assert "$live" '.redirectUris == [$c] and .webOrigins == []' 'the client URIs are not Place'"'"'s callback only' --arg c "$CALLBACK"
json_assert "$live" '(.defaultClientScopes | index("groups") == null) and (.optionalClientScopes | index("microprofile-jwt") == null)
  and (.defaultClientScopes | index("basic") != null and index("roles") != null)' 'the client scopes are not the contract'
printf '    client: %s\n' "$(jq -c '{publicClient, standardFlowEnabled, implicitFlowEnabled, directAccessGrantsEnabled, serviceAccountsEnabled, fullScopeAllowed, frontchannelLogout, pkce: .attributes["pkce.code.challenge.method"], redirectUris, webOrigins, defaultClientScopes, optionalClientScopes}' <<<"$live")"
json_assert "$(kcadm get "clients/$place/roles" -r "$REALM")" 'map(.name) | sort == ["place:admin", "place:moderator"]' 'unexpected client roles'
mappers=$(kcadm get "clients/$place/protocol-mappers/models" -r "$REALM")
json_assert "$mappers" 'map(.name) | sort == ["place-roles", "school-email"]' 'unexpected client mappers'
json_assert "$mappers" '.[] | select(.name == "school-email") | .protocolMapper == "oidc-usermodel-attribute-mapper"
  and .config["user.attribute"] == "schoolEmail" and .config["claim.name"] == "school_email" and .config["multivalued"] == "false"
  and .config["id.token.claim"] == "true" and .config["access.token.claim"] == "true" and .config["userinfo.token.claim"] == "true"
  and .config["introspection.token.claim"] == "true"' 'school-email is not shaped as expected'
json_assert "$mappers" '.[] | select(.name == "place-roles") | .protocolMapper == "oidc-usermodel-client-role-mapper"
  and .config["usermodel.clientRoleMapping.clientId"] == "place" and .config["claim.name"] == "resource_access.${client_id}.roles"
  and .config["id.token.claim"] == "true" and .config["access.token.claim"] == "true" and .config["userinfo.token.claim"] == "true"' \
  'place-roles is not shaped as expected'
# Nothing is granted: no role mapping among the admin events of the run.
json_assert "$(kcadm get admin-events -r "$REALM" -q max=1000)" \
  '[.[] | select(.time > $t and (.resourceType == "CLIENT_ROLE_MAPPING" or .resourceType == "REALM_ROLE_MAPPING"))] | length == 0' \
  'the script granted a role' --argjson t "$event_before"

CURRENT_STAGE='second run is a no-op'
event_before=$(newest_admin_event)
sleep 1
again=$(run_script --check) || { printf '%s\n' "$again" >&2; fail 'second --check failed'; }
expect_line "$again" 'check: 0 change(s) pending, 0 warning(s), 0 problem(s)' 'second --check plans changes'
expect_line "$again" "place: redirect URI exactly $CALLBACK" 'the redirect URI not recognised'
expect_line "$again" 'place: mapper school-email unchanged' 'own school-email mapper not recognised'
expect_line "$again" 'place: no default or optional scope writes group data' 'scopes not recognised'
expect_line "$again" 'place: role place:admin held directly by 0 person(s); groups: none' 'role holders not reported'
again=$(run_script --apply) || { printf '%s\n' "$again" >&2; fail 'second --apply failed'; }
expect_line "$again" 'applied 0 change(s)' 'second --apply wrote'
[[ $(newest_admin_event) == "$event_before" ]] || fail 'the second run wrote to the realm'
printf '    second --check and --apply: 0 change(s), no admin event\n'

# The SKY LAB admin panel's grants: a person and a group.
kcadm add-roles -r "$REALM" --uusername ayse --cclientid "$CLIENT" --rolename place:moderator >/dev/null
kcadm add-roles -r "$REALM" --gid "$etkinlik" --cclientid "$CLIENT" --rolename place:admin >/dev/null
holders=$(run_script --check) || { printf '%s\n' "$holders" >&2; fail '--check after the grants failed'; }
expect_line "$holders" 'place: role place:moderator held directly by 1 person(s); groups: none' 'the person grant not reported'
expect_line "$holders" 'place: role place:admin held directly by 0 person(s); groups: /UYELER/ETKINLIK' 'the group grant not reported'

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='tokens through the client (authorization code, PKCE)'
response=$(code_flow_response ayse)
id_token=$(jwt_payload "$(jq -r .id_token <<<"$response")")
access=$(jwt_payload "$(jq -r .access_token <<<"$response")")
info=$(userinfo "$(jq -r .access_token <<<"$response")")
json_assert "$id_token" "(($AUD) == [\"$CLIENT\"]) and .azp == \"$CLIENT\" and .nonce == \"harness-nonce-ayse\"" 'the ID token is not Place'"'"'s'
for payload in "$id_token" "$access" "$info"; do
  json_assert "$payload" '.school_email == "ayse.yilmaz@std.yildiz.edu.tr" and .email == "ayse@example.invalid"' \
    'school_email is not the school address (or email was replaced)'
  json_assert "$payload" '.resource_access.place.roles == ["place:moderator"]' 'resource_access.place.roles is not place:moderator'
  json_assert "$payload" "$NO_GROUPS" 'a Place token carries groups, realm roles or another client'"'"'s roles'
done
printf '    ayse   id token: aud=%s school_email=%s roles=%s groups=%s\n' "$(jq -c "$AUD" <<<"$id_token")" \
  "$(jq -r .school_email <<<"$id_token")" "$(jq -c .resource_access.place.roles <<<"$id_token")" "$(jq -c '.groups // "none"' <<<"$id_token")"
printf '    ayse   access token: school_email=%s resource_access=%s realm_access=%s groups=%s\n' "$(jq -r .school_email <<<"$access")" \
  "$(jq -c .resource_access <<<"$access")" "$(jq -c '.realm_access // "none"' <<<"$access")" "$(jq -c '.groups // "none"' <<<"$access")"
printf '    ayse   userinfo: school_email=%s roles=%s groups=%s\n' "$(jq -r .school_email <<<"$info")" \
  "$(jq -c .resource_access.place.roles <<<"$info")" "$(jq -c '.groups // "none"' <<<"$info")"
response=$(code_flow_response zeynep)
for token in id_token access_token; do
  payload=$(jwt_payload "$(jq -r ".$token" <<<"$response")")
  json_assert "$payload" ".school_email == \"zeynep.kaya@std.yildiz.edu.tr\" and .resource_access.place.roles == [\"place:admin\"] and ($NO_GROUPS)" \
    "zeynep's $token does not carry place:admin through her group (or carries groups)"
done
printf '    zeynep %s: school_email=%s roles=%s (through /UYELER/ETKINLIK) groups=none\n' 'id+access' \
  "$(jq -r .school_email <<<"$payload")" "$(jq -c .resource_access.place.roles <<<"$payload")"
response=$(code_flow_response mehmet)
for token in id_token access_token; do
  payload=$(jwt_payload "$(jq -r ".$token" <<<"$response")")
  json_assert "$payload" "(has(\"school_email\") | not) and (.resource_access.place.roles // [] | length == 0) and ($NO_GROUPS)" \
    "mehmet's $token carries a school_email or a Place role"
done
printf '    mehmet id+access: no school_email, no Place role (Place refuses this login)\n'

CURRENT_STAGE='refused requests'
for scope in 'openid groups' 'openid microprofile-jwt'; do
  location=$(authorize_location response_type=code "scope=$scope" state=s nonce=n code_challenge=abcdefghijabcdefghijabcdefghijabcdefghij123 code_challenge_method=S256)
  [[ $location == "302 $CALLBACK?error=invalid_scope"* ]] || fail "the scope $scope was not refused ($location)"
done
location=$(authorize_location response_type=code scope=openid state=s nonce=n)
[[ $location == "302 $CALLBACK?error=invalid_request&error_description=Missing+parameter%3A+code_challenge_method"* ]] \
  || fail "a request without PKCE was not refused ($location)"
location=$(authorize_location response_type=code scope=openid state=s code_challenge=abcdefghijabcdefghijabcdefghijabcdefghij123 code_challenge_method=plain)
[[ $location == "302 $CALLBACK?error=invalid_request"* ]] || fail "the plain PKCE method was not refused ($location)"
location=$(authorize_location response_type=token scope=openid state=s nonce=n)
[[ $location == "302 $CALLBACK#error=unauthorized_client"* ]] || fail "the implicit flow was not refused ($location)"
code=$(curl -s -o /dev/null -w '%{http_code}' -G "$BASE_URL/realms/$REALM/protocol/openid-connect/auth" \
  --data-urlencode "client_id=$CLIENT" --data-urlencode response_type=code --data-urlencode scope=openid \
  --data-urlencode 'redirect_uri=https://place.yildizskylab.com/api/auth/eskylab/callback')
[[ $code == 400 ]] || fail "a foreign redirect URI was not refused (HTTP $code)"
[[ $(token_error password username=ayse "password=$PERSON_PASSWORD" scope=openid) == unauthorized_client ]] || fail 'the password grant was not refused'
[[ $(token_error client_credentials) == unauthorized_client ]] || fail 'the client_credentials grant was not refused'
printf '    refused: the groups and microprofile-jwt scopes (invalid_scope), no PKCE, plain PKCE, response_type=token,\n'
printf '    a foreign redirect URI (HTTP 400), the password and client_credentials grants (unauthorized_client)\n'

CURRENT_STAGE='the secret is never printed'
secret=$(client_secret)
[[ ${#secret} -ge 16 ]] || fail 'the client has no generated secret'
if grep -Fq -- "$secret" "$OUTPUTS"; then fail 'the script printed the client secret'; fi
secret=''

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='drift repair'
kcadm update "clients/$place" -r "$REALM" -s directAccessGrantsEnabled=true -s 'attributes."pkce.code.challenge.method"=' \
  -s "redirectUris=[\"$CALLBACK\",\"http://localhost:8080/*\"]" -s 'webOrigins=["+"]' >/dev/null
school_mapper=$(kcadm get "clients/$place/protocol-mappers/models" -r "$REALM" | jq -r '.[] | select(.name == "school-email") | .id')
kcadm delete "clients/$place/protocol-mappers/models/$school_mapper" -r "$REALM" >/dev/null
roles_mapper=$(kcadm get "clients/$place/protocol-mappers/models" -r "$REALM" | jq -r '.[] | select(.name == "place-roles") | .id')
kcadm get "clients/$place/protocol-mappers/models/$roles_mapper" -r "$REALM" \
  | jq -c '.config["id.token.claim"] = "false"' \
  | kcadm update "clients/$place/protocol-mappers/models/$roles_mapper" -r "$REALM" -f - >/dev/null
kcadm update "clients/$place/default-client-scopes/$groups_scope" -r "$REALM" -n >/dev/null
kcadm update "clients/$place/optional-client-scopes/$(scope_uuid microprofile-jwt)" -r "$REALM" -n >/dev/null
drift=$(run_script --check) || { printf '%s\n' "$drift" >&2; fail 'drift --check failed'; }
grep -E 'would|check:' <<<"$drift" | sed 's/^/    /'
expect_line "$drift" 'would update place flags' 'flag drift not found'
expect_line "$drift" "would set the redirect URIs of place to exactly $CALLBACK (removing http://localhost:8080/*)" 'redirect drift not found'
expect_line "$drift" 'would remove the web origins of place (+)' 'web origin drift not found'
expect_line "$drift" 'would add mapper school-email to place' 'the missing school-email mapper not found'
expect_line "$drift" 'would repair mapper place-roles on place' 'place-roles drift not found'
expect_line "$drift" 'would detach the default scope groups from place' 'the groups scope not found'
expect_line "$drift" 'would detach the optional scope microprofile-jwt from place' 'microprofile-jwt not found'
expect_line "$drift" 'check: 7 change(s) pending, 0 warning(s), 0 problem(s)' 'unexpected drift plan'
repair=$(run_script --apply) || { printf '%s\n' "$repair" >&2; fail 'drift --apply failed'; }
expect_line "$repair" 'applied 7 change(s)' 'drift not repaired'
again=$(run_script --check) || { printf '%s\n' "$again" >&2; fail 'post-repair --check failed'; }
expect_line "$again" 'check: 0 change(s) pending' 'a repair did not hold'
live=$(kcadm get "clients/$place" -r "$REALM")
json_assert "$live" '(.directAccessGrantsEnabled | not) and .attributes["pkce.code.challenge.method"] == "S256" and .redirectUris == [$c]
  and .webOrigins == [] and (.defaultClientScopes | index("groups") == null) and (.optionalClientScopes | index("microprofile-jwt") == null)' \
  'the repair did not restore the contract' --arg c "$CALLBACK"
payload=$(jwt_payload "$(code_flow_response ayse | jq -r .id_token)")
json_assert "$payload" ".school_email == \"ayse.yilmaz@std.yildiz.edu.tr\" and .resource_access.place.roles == [\"place:moderator\"] and ($NO_GROUPS)" \
  'the repaired client lost a claim'
printf '    repaired; the ID token carries school_email and place:moderator again, no groups\n'

CURRENT_STAGE='a groups or a second school_email mapper is a PROBLEM'
kcadm create "clients/$place/protocol-mappers/models" -r "$REALM" -b '{"name":"hand-groups","protocol":"openid-connect","protocolMapper":"oidc-group-membership-mapper","config":{"full.path":"true","claim.name":"groups","access.token.claim":"true","id.token.claim":"true"}}' >/dev/null
kcadm create "clients/$place/protocol-mappers/models" -r "$REALM" -b '{"name":"hand-school","protocol":"openid-connect","protocolMapper":"oidc-usermodel-property-mapper","config":{"user.attribute":"email","claim.name":"school_email","jsonType.label":"String","access.token.claim":"true","id.token.claim":"true"}}' >/dev/null
event_before=$(newest_admin_event)
sleep 1
problems=$(run_expecting 1 --apply)
expect_line "$problems" 'PROBLEM: place: client mapper hand-groups (oidc-group-membership-mapper) writes group data; Place reads no groups (ADR-0059)' 'the groups mapper not reported'
expect_line "$problems" 'PROBLEM: place: client mapper hand-school (oidc-usermodel-property-mapper) also writes school_email' 'the second school_email mapper not reported'
expect_line "$problems" 'applied 0 change(s), 0 warning(s), 2 problem(s)' 'the problem run changed something'
[[ $(newest_admin_event) == "$event_before" ]] || fail 'the problem run wrote to the realm'
json_assert "$(kcadm get "clients/$place/protocol-mappers/models" -r "$REALM")" 'map(.name) | sort == ["hand-groups", "hand-school", "place-roles", "school-email"]' \
  'a hand-made mapper was touched'
for name in hand-groups hand-school; do
  id=$(kcadm get "clients/$place/protocol-mappers/models" -r "$REALM" | jq -r --arg n "$name" '.[] | select(.name == $n) | .id')
  kcadm delete "clients/$place/protocol-mappers/models/$id" -r "$REALM" >/dev/null
done
printf '    a hand-made groups mapper and a second school_email mapper: PROBLEM (exit 1), left as is\n'

CURRENT_STAGE='a User Profile without schoolEmail is a WARNING'
kcadm get users/profile -r "$REALM" | jq '.attributes |= map(select(.name != "schoolEmail"))' \
  | kcadm update users/profile -r "$REALM" -f - >/dev/null
warned=$(run_script --check) || { printf '%s\n' "$warned" >&2; fail '--check without schoolEmail failed'; }
expect_line "$warned" 'WARNING: the User Profile of realm e-skylab does not declare schoolEmail; tokens carry no school_email until it does' 'the missing attribute not warned'
expect_line "$warned" 'check: 0 change(s) pending, 1 warning(s), 0 problem(s)' 'unexpected plan without schoolEmail'

CURRENT_STAGE='the secret is never printed (all runs)'
secret=$(client_secret)
if grep -Fq -- "$secret" "$OUTPUTS"; then fail 'the script printed the client secret'; fi
secret=''

printf 'create-place-client.sh contract holds against %s.\n' "$IMAGE"
