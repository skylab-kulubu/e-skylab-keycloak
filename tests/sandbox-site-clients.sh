#!/usr/bin/env bash
# Real-Keycloak contract for config/sandbox-site-clients.sh (the sandbox realm's frontend-arge).
# Stand-alone: starts the stock Keycloak image this repository builds on (the Dockerfile's
# KEYCLOAK_IMAGE, tag and digest) in dev mode with docker run --rm and no volume, builds a small
# realm e-skylab-sandbox, runs the script (and then config/inscribed-cms-roles.sh) inside that
# container the way the wizard does and reads real tokens. The container is removed on exit
# (docker rm -fv).
#
# The fixture realm (e-skylab-sandbox): skycms and core (confidential, no login), groups /UYELER,
# /UYELER/ADMIN (the sandbox's editor group) and /UYELER/YK, people sandboxadmin (in /UYELER/ADMIN)
# and member (in /UYELER), no frontend-* client and no realm scope "groups". A realm e-skylab
# stands for production.
#
# What it proves:
#   - every realm but e-skylab-sandbox is refused before a login (exit 2) and e-skylab stays as it
#     is; without the skycms client nothing is written (exit 1);
#   - --check writes nothing (admin events) and plans the client, the skycms audience mapper, the
#     frontend-arge-core-audience scope (the reconciler's shape: its mapper equals
#     config/frontend-arge-core-audience-mappers.json) and the groups mapper; frontend-main is not
#     made; --apply writes exactly that and grants no role to anyone; the client's flags and URIs
#     are production's with the sandbox host; the secret is never printed; a second --check plans
#     nothing and a second --apply writes nothing;
#   - inscribed-cms-roles.sh (KEYCLOAK_REALM=e-skylab-sandbox --client frontend-arge) then adds the
#     CMS roles and the roles mapper, finds the full-path groups this script made (no second groups
#     mapper) and gives the service account content:read + schema:sync; afterwards this script
#     still plans nothing;
#   - with /UYELER/ADMIN granted frontend-arge cms:access the way the SKY LAB admin panel does it, a
#     real authorization code flow through the client (login page, credentials, redirect to
#     https://sandbox-arge.yildizskylab.com/api/auth/callback/keycloak, code exchanged with the
#     secret, as NextAuth does) gives an access token with azp=frontend-arge, aud ⊇ {skycms, core},
#     groups ["/UYELER/ADMIN"] and roles ⊇ {cms:access, content:read, content:write} (and cms:access
#     in resource_access, the editor gate); the ID token carries no roles, no groups, no API in aud;
#     a plain member gets no CMS role; a foreign redirect URI is refused; the service account's
#     client_credentials token carries aud ⊇ {skycms, core} and roles content:read + schema:sync;
#   - drift (flags, the site's redirect and post-logout URIs, the skycms mapper, the core mapper) is
#     repaired and a developer's extra redirect URI is kept; a flat groups mapper is a PROBLEM
#     (exit 1) and is left as is;
#   - with a realm scope "groups" (the production shape) a new client gets it as a default scope
#     instead of its own mapper; the existing core scope is reused, not duplicated;
#   - without a core client the core audience is skipped with a NOTE.
# Requirements on the host: docker, curl, jq, base64. SANDBOX_CLIENTS_TEST_PORT (default 18092).
# The jq programs name jq variables ($s, $t, $want), not shell ones:
# shellcheck disable=SC2016
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPOSITORY_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
OPERATOR_SCRIPT="$REPOSITORY_ROOT/config/sandbox-site-clients.sh"
ROLES_SCRIPT="$REPOSITORY_ROOT/config/inscribed-cms-roles.sh"
CORE_MAPPERS_FILE="$REPOSITORY_ROOT/config/frontend-arge-core-audience-mappers.json"
IMAGE=$(sed -n 's/^ARG KEYCLOAK_IMAGE=//p' "$REPOSITORY_ROOT/Dockerfile")
PORT=${SANDBOX_CLIENTS_TEST_PORT:-18092}
BASE_URL="http://127.0.0.1:$PORT"
REALM=e-skylab-sandbox
PRODUCTION_REALM=e-skylab
CLIENT=frontend-arge
SITE=https://sandbox-arge.yildizskylab.com
CALLBACK="$SITE/api/auth/callback/keycloak"
CONTAINER="sandbox-clients-test-$$"
ADMIN_PASSWORD=harness-admin-password
PERSON_PASSWORD=harness-person-password
KCADM_CONFIG=/tmp/harness-kcadm.config
IN_CONTAINER_SCRIPT=/tmp/sandbox-site-clients.sh
IN_CONTAINER_ROLES=/tmp/inscribed-cms-roles.sh
OUTPUTS=$(mktemp "${TMPDIR:-/tmp}/sandbox-clients-outputs.XXXXXX")
CURRENT_STAGE=startup

fail() {
  printf 'sandbox-site-clients failure during %s: %s\n' "$CURRENT_STAGE" "$1" >&2
  exit 1
}
cleanup() {
  docker rm -fv "$CONTAINER" >/dev/null 2>&1 || true
  rm -f "$OUTPUTS"
}
trap 'status=$?; trap - EXIT; cleanup; exit "$status"' EXIT
on_error() {
  local status=$?
  printf 'sandbox-site-clients command failed during %s (line %s)\n' "$CURRENT_STAGE" "$1" >&2
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

# run_roles ARGS...: config/inscribed-cms-roles.sh the same way, in the sandbox realm.
run_roles() {
  local output status=0
  output=$(docker exec -e KEYCLOAK_ADMIN_URL=http://localhost:8080 -e KEYCLOAK_REALM="$REALM" "$CONTAINER" \
    bash "$IN_CONTAINER_ROLES" --kcadm-config "$KCADM_CONFIG" "$@" 2>&1) || status=$?
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

scope_uuids() {
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

# code_flow_response USER: a person's token response from the real authorization code flow of the
# client, the way NextAuth runs it: the login page, the credentials, the redirect to the site's
# callback with a code, the code exchanged with the client secret (on curl's stdin).
code_flow_response() {
  local user=$1 jar page action location code
  jar=$(mktemp "${TMPDIR:-/tmp}/sandbox-clients-jar.XXXXXX")
  page=$(curl -fsS -c "$jar" -b "$jar" -G "$BASE_URL/realms/$REALM/protocol/openid-connect/auth" \
    --data-urlencode "client_id=$CLIENT" --data-urlencode response_type=code \
    --data-urlencode 'scope=openid email profile' --data-urlencode "redirect_uri=$CALLBACK" \
    --data-urlencode state=harness-state)
  action=$(sed -n 's/.*id="kc-form-login"[^>]*action="\([^"]*\)".*/\1/p' <<<"$page" | head -n 1 | sed 's/&amp;/\&/g')
  [[ -n $action ]] || { rm -f "$jar"; fail "no login form for $user"; }
  location=$(curl -sS -c "$jar" -b "$jar" -o /dev/null -w '%{redirect_url}' \
    --data-urlencode "username=$user" --data-urlencode "password=$PERSON_PASSWORD" "$action")
  rm -f "$jar"
  [[ $location == "$CALLBACK?"* ]] || fail "the login of $user did not return to $CALLBACK ($location)"
  code=$(sed -n 's/.*[?&]code=\([^&]*\).*/\1/p' <<<"$location")
  [[ -n $code ]] || fail "no authorization code for $user"
  client_secret | curl -fsS "$BASE_URL/realms/$REALM/protocol/openid-connect/token" \
    --data-urlencode grant_type=authorization_code --data-urlencode "code=$code" \
    --data-urlencode "redirect_uri=$CALLBACK" --data-urlencode "client_id=$CLIENT" \
    --data-urlencode 'client_secret@-'
}

service_account_access() {
  jwt_payload "$(client_secret | curl -fsS "$BASE_URL/realms/$REALM/protocol/openid-connect/token" \
    --data-urlencode grant_type=client_credentials --data-urlencode "client_id=$CLIENT" \
    --data-urlencode 'client_secret@-' | jq -r .access_token)"
}

# The CMS roles in a token's roles claim, sorted, as compact JSON.
CMS_ROLES='(.roles // []) | map(select(startswith("content:") or . == "cms:access" or . == "schema:sync" or . == "client:admin")) | sort'
# What @skylab-kulubu/inscribed-auth checks to show the editor: cms:access in resource_access.
EDITOR_GATE='[.resource_access // {} | .[] | .roles // [] | .[]] | index("cms:access") != null'
AUD='(.aud // []) | if type == "array" then . else [.] end'

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='Keycloak start'
[[ -n $IMAGE ]] || fail 'Dockerfile has no ARG KEYCLOAK_IMAGE'
if ! command -v jq >/dev/null || ! command -v curl >/dev/null; then fail 'jq and curl are required'; fi
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
docker exec -i "$CONTAINER" sh -c "cat > $IN_CONTAINER_ROLES" <"$ROLES_SCRIPT"

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='only the sandbox realm'
kcadm create realms -s realm="$PRODUCTION_REALM" -s enabled=true >/dev/null
kcadm create clients -r "$PRODUCTION_REALM" -s clientId=skycms -s publicClient=false -s standardFlowEnabled=false >/dev/null
for realm in "$PRODUCTION_REALM" master other-realm; do
  for mode in --check --apply; do
    refused=$(RUN_REALM=$realm run_expecting 2 "$mode")
    expect_line "$refused" "refusing realm $realm: this script writes only the sandbox realm e-skylab-sandbox" 'realm not refused'
    reject_line "$refused" 'realm=' 'the refused run went on'
  done
done
[[ -z $(client_uuid "$CLIENT" "$PRODUCTION_REALM") ]] || fail "a refused run made $CLIENT in $PRODUCTION_REALM"
printf '    e-skylab, master and other-realm refused (exit 2) before a login\n'

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='fixture realm'
kcadm create realms -s realm="$REALM" -s enabled=true -s adminEventsEnabled=true >/dev/null
uyeler=$(kcadm create groups -r "$REALM" -i -s name=UYELER)
admin_group=$(kcadm create "groups/$uyeler/children" -r "$REALM" -i -s name=ADMIN)
kcadm create "groups/$uyeler/children" -r "$REALM" -i -s name=YK >/dev/null
person() {
  local uuid
  uuid=$(kcadm create users -r "$REALM" -i -s "username=$1" -s enabled=true -s "email=$1@example.invalid" \
    -s emailVerified=true -s firstName=Harness -s "lastName=$1")
  kcadm set-password -r "$REALM" --userid "$uuid" --new-password "$PERSON_PASSWORD" >/dev/null
  kcadm update "users/$uuid/groups/$2" -r "$REALM" -n -b '{}' >/dev/null
}
person sandboxadmin "$admin_group"
person member "$uyeler"

CURRENT_STAGE='missing skycms client'
event_before=$(newest_admin_event)
sleep 1
missing=$(run_expecting 1 --apply)
expect_line "$missing" 'the skycms client (inscribed'"'"'s audience) does not exist in realm e-skylab-sandbox; nothing was changed' 'missing skycms not reported'
[[ $(newest_admin_event) == "$event_before" ]] || fail 'a run without skycms wrote to the realm'
kcadm create clients -r "$REALM" -s clientId=skycms -s publicClient=false -s standardFlowEnabled=false >/dev/null
kcadm create clients -r "$REALM" -s clientId=core -s publicClient=false -s standardFlowEnabled=false >/dev/null

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='--check writes nothing'
event_before=$(newest_admin_event)
sleep 1
check=$(run_script --check) || { printf '%s\n' "$check" >&2; fail '--check failed'; }
printf '%s\n' "$check" | sed 's/^/    /'
[[ $(newest_admin_event) == "$event_before" ]] || fail '--check wrote to the realm'
expect_line "$check" 'realm=e-skylab-sandbox mode=check clients=frontend-arge' 'unexpected header'
expect_line "$check" 'NOTE: frontend-main is not made: there is no sandbox main-site app' 'frontend-main not explained'
expect_line "$check" 'would create confidential client frontend-arge (standard flow and service account on, implicit and direct grants off, fullScopeAllowed=false; redirect https://sandbox-arge.yildizskylab.com/*, web origin https://sandbox-arge.yildizskylab.com, post-logout https://sandbox-arge.yildizskylab.com/*' 'client not planned'
expect_line "$check" 'would add mapper skycms-audience to frontend-arge (aud += skycms' 'skycms audience not planned'
expect_line "$check" 'would create client scope frontend-arge-core-audience (include.in.token.scope=false, display.on.consent.screen=false)' 'core scope not planned'
expect_line "$check" 'would add mapper core-audience to frontend-arge-core-audience (aud += core' 'core mapper not planned'
expect_line "$check" 'would attach frontend-arge-core-audience as a default scope of frontend-arge' 'core scope link not planned'
expect_line "$check" 'would add mapper groups to frontend-arge (Group Membership: claim groups, full path' 'groups mapper not planned'
expect_line "$check" 'check: 6 change(s) pending, 0 warning(s), 0 problem(s)' 'unexpected plan size'
[[ -z $(client_uuid "$CLIENT") ]] || fail '--check made the client'

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='--apply'
event_before=$(newest_admin_event)
apply=$(run_script --apply) || { printf '%s\n' "$apply" >&2; fail '--apply failed'; }
printf '%s\n' "$apply" | sed 's/^/    /'
expect_line "$apply" 'applied 6 change(s), 0 warning(s), 0 problem(s)' 'apply did not write the plan'
expect_line "$apply" 'frontend-arge: service account service-account-frontend-arge' 'service account not reported'
arge=$(client_uuid "$CLIENT")
[[ -n $arge ]] || fail 'the client was not made'
[[ -z $(client_uuid frontend-main) ]] || fail 'frontend-main was made'
live=$(kcadm get "clients/$arge" -r "$REALM")
json_assert "$live" '.enabled and .protocol == "openid-connect" and (.publicClient | not) and (.bearerOnly | not)
  and .clientAuthenticatorType == "client-secret" and .standardFlowEnabled and (.implicitFlowEnabled | not)
  and (.directAccessGrantsEnabled | not) and .serviceAccountsEnabled and (.fullScopeAllowed | not) and (.consentRequired | not)' \
  'the client flags are not production'"'"'s'
json_assert "$live" '.redirectUris == [$s + "/*"] and .webOrigins == [$s] and .attributes["post.logout.redirect.uris"] == $s + "/*"' \
  'the client URIs are not the sandbox site'"'"'s' --arg s "$SITE"
printf '    client: %s\n' "$(jq -c '{publicClient, standardFlowEnabled, directAccessGrantsEnabled, serviceAccountsEnabled, fullScopeAllowed, redirectUris, webOrigins, postLogout: .attributes["post.logout.redirect.uris"]}' <<<"$live")"
mappers=$(kcadm get "clients/$arge/protocol-mappers/models" -r "$REALM")
json_assert "$mappers" 'map(.name) | sort == ["groups", "skycms-audience"]' 'unexpected client mappers'
json_assert "$mappers" '.[] | select(.name == "skycms-audience") | .protocolMapper == "oidc-audience-mapper"
  and .config["included.client.audience"] == "skycms" and .config["access.token.claim"] == "true"
  and .config["id.token.claim"] == "false" and .config["introspection.token.claim"] == "true"' 'skycms-audience is not shaped as expected'
json_assert "$mappers" '.[] | select(.name == "groups") | .protocolMapper == "oidc-group-membership-mapper"
  and .config["claim.name"] == "groups" and .config["full.path"] == "true" and .config["access.token.claim"] == "true"
  and .config["id.token.claim"] == "false"' 'the groups mapper is not shaped as expected'
core_scope=$(scope_uuids frontend-arge-core-audience)
[[ -n $core_scope && $core_scope != *$'\n'* ]] || fail 'not exactly one frontend-arge-core-audience scope'
json_assert "$(kcadm get "client-scopes/$core_scope" -r "$REALM")" '.protocol == "openid-connect"
  and .attributes["include.in.token.scope"] == "false" and .attributes["display.on.consent.screen"] == "false"' \
  'the core scope attributes are not the reconciler'"'"'s'
# The reconciler's mapper file is the contract: every field it declares is live, nothing else is.
json_assert "$(kcadm get "client-scopes/$core_scope/protocol-mappers/models" -r "$REALM")" \
  'length == 1 and (.[0] as $m | $want[0][0] as $w | $m.name == $w.name and $m.protocolMapper == $w.protocolMapper
     and ($w.config | to_entries | all(.value == $m.config[.key])))' \
  'the core-audience mapper differs from config/frontend-arge-core-audience-mappers.json' --slurpfile want "$CORE_MAPPERS_FILE"
json_assert "$(kcadm get "clients/$arge/default-client-scopes" -r "$REALM")" 'any(.[]; .name == "frontend-arge-core-audience")' \
  'the core scope is not a default scope'
# Nothing is granted: no role mapping among the admin events of the run.
json_assert "$(kcadm get admin-events -r "$REALM" -q max=1000)" \
  '[.[] | select(.time > $t and (.resourceType == "CLIENT_ROLE_MAPPING" or .resourceType == "REALM_ROLE_MAPPING"))] | length == 0' \
  'the script granted a role' --argjson t "$event_before"

CURRENT_STAGE='second run is a no-op'
event_before=$(newest_admin_event)
sleep 1
again=$(run_script --check) || { printf '%s\n' "$again" >&2; fail 'second --check failed'; }
expect_line "$again" 'check: 0 change(s) pending, 0 warning(s), 0 problem(s)' 'second --check plans changes'
expect_line "$again" 'frontend-arge: mapper groups unchanged (groups, full path)' 'own groups mapper not recognised'
expect_line "$again" 'frontend-arge: default scope frontend-arge-core-audience attached' 'core scope not recognised'
again=$(run_script --apply) || { printf '%s\n' "$again" >&2; fail 'second --apply failed'; }
expect_line "$again" 'applied 0 change(s)' 'second --apply wrote'
[[ $(newest_admin_event) == "$event_before" ]] || fail 'the second run wrote to the realm'
printf '    second --check and --apply: 0 change(s), no admin event\n'

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='CMS roles (inscribed-cms-roles.sh)'
roles=$(run_roles --check --client "$CLIENT") || { printf '%s\n' "$roles" >&2; fail 'roles --check failed'; }
expect_line "$roles" 'realm=e-skylab-sandbox mode=check clients=frontend-arge' 'roles script header'
expect_line "$roles" 'frontend-arge: groups (full path) comes from client mapper groups' 'the roles script did not find the groups mapper'
reject_line "$roles" 'would add mapper inscribed-groups' 'the roles script duplicates the groups mapper'
expect_line "$roles" 'would add mapper inscribed-roles to frontend-arge' 'roles mapper not planned'
expect_line "$roles" 'would create client role cms:access on frontend-arge' 'cms:access not planned'
expect_line "$roles" 'would assign frontend-arge/schema:sync to service-account-frontend-arge' 'service account grant not planned'
roles=$(run_roles --apply --client "$CLIENT") || { printf '%s\n' "$roles" >&2; fail 'roles --apply failed'; }
grep -E 'applied' <<<"$roles" | sed 's/^/    roles script: /'
roles=$(run_roles --check --client "$CLIENT") || { printf '%s\n' "$roles" >&2; fail 'roles second --check failed'; }
expect_line "$roles" 'check: 0 change(s) pending, 0 warning(s), 0 problem(s)' 'the roles script plans more'
again=$(run_script --check) || { printf '%s\n' "$again" >&2; fail '--check after the roles script failed'; }
expect_line "$again" 'check: 0 change(s) pending, 0 warning(s), 0 problem(s)' 'the roles script disturbed this script'"'"'s state'

# The SKY LAB admin panel's grant (group -> client role).
body=$(kcadm get "clients/$arge/roles/cms:access" -r "$REALM" | jq -c '[{id, name}]')
kcadm create "groups/$admin_group/role-mappings/clients/$arge" -r "$REALM" -b "$body" >/dev/null

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='person tokens through the client (authorization code)'
response=$(code_flow_response sandboxadmin)
access=$(jwt_payload "$(jq -r .access_token <<<"$response")")
id_token=$(jwt_payload "$(jq -r .id_token <<<"$response")")
json_assert "$access" ".azp == \"$CLIENT\" and (($AUD) | index(\"skycms\") != null and index(\"core\") != null)" \
  'the editor access token does not name skycms and core'
json_assert "$access" '.groups == ["/UYELER/ADMIN"]' 'the editor access token has no full-path groups'
json_assert "$access" "($CMS_ROLES) == [\"cms:access\", \"content:read\", \"content:write\"]" 'the editor roles are not cms:access + content:*'
json_assert "$access" "$EDITOR_GATE" 'the editor gate (cms:access in resource_access) is shut'
json_assert "$id_token" ".roles == null and .groups == null and (($AUD) == [\"$CLIENT\"])" \
  'the ID token carries roles, groups or an API audience'
printf '    sandboxadmin @ %s: aud=%s groups=%s roles=%s editor=%s\n' "$CLIENT" "$(jq -c "$AUD" <<<"$access")" \
  "$(jq -c .groups <<<"$access")" "$(jq -c "$CMS_ROLES" <<<"$access")" "$(jq -c "$EDITOR_GATE" <<<"$access")"
access=$(jwt_payload "$(code_flow_response member | jq -r .access_token)")
json_assert "$access" ".groups == [\"/UYELER\"] and (($CMS_ROLES) == []) and (($EDITOR_GATE) | not)" 'a plain member got a CMS role'
printf '    member       @ %s: groups=%s roles=%s editor=%s\n' "$CLIENT" "$(jq -c .groups <<<"$access")" \
  "$(jq -c "$CMS_ROLES" <<<"$access")" "$(jq -c "$EDITOR_GATE" <<<"$access")"
code=$(curl -s -o /dev/null -w '%{http_code}' -G "$BASE_URL/realms/$REALM/protocol/openid-connect/auth" \
  --data-urlencode "client_id=$CLIENT" --data-urlencode response_type=code --data-urlencode scope=openid \
  --data-urlencode 'redirect_uri=https://arge.yildizskylab.com/api/auth/callback/keycloak')
[[ $code == 400 ]] || fail "a foreign redirect URI was not refused (HTTP $code)"
printf '    the production callback is refused by the sandbox client (HTTP 400)\n'

CURRENT_STAGE='service-account token'
access=$(service_account_access)
json_assert "$access" ".azp == \"$CLIENT\" and (($AUD) | index(\"skycms\") != null and index(\"core\") != null)
  and (($CMS_ROLES) == [\"content:read\", \"schema:sync\"])" 'the service account token is not aud skycms+core, content:read + schema:sync'
printf '    service account: aud=%s roles=%s\n' "$(jq -c "$AUD" <<<"$access")" "$(jq -c "$CMS_ROLES" <<<"$access")"

CURRENT_STAGE='the secret is never printed'
secret=$(client_secret)
[[ ${#secret} -ge 16 ]] || fail 'the client has no generated secret'
if grep -Fq -- "$secret" "$OUTPUTS"; then fail 'a script printed the client secret'; fi
secret=''

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='drift repair'
kcadm update "clients/$arge" -r "$REALM" -s directAccessGrantsEnabled=true \
  -s 'redirectUris=["http://localhost:3000/*"]' -s 'attributes."post.logout.redirect.uris"=http://localhost:3000/*' >/dev/null
skycms_mapper=$(kcadm get "clients/$arge/protocol-mappers/models" -r "$REALM" | jq -r '.[] | select(.name == "skycms-audience") | .id')
kcadm delete "clients/$arge/protocol-mappers/models/$skycms_mapper" -r "$REALM" >/dev/null
core_mapper=$(kcadm get "client-scopes/$core_scope/protocol-mappers/models" -r "$REALM" | jq -r '.[0].id')
kcadm get "client-scopes/$core_scope/protocol-mappers/models/$core_mapper" -r "$REALM" \
  | jq -c '.config["id.token.claim"] = "true"' \
  | kcadm update "client-scopes/$core_scope/protocol-mappers/models/$core_mapper" -r "$REALM" -f - >/dev/null
drift=$(run_script --check) || { printf '%s\n' "$drift" >&2; fail 'drift --check failed'; }
grep -E 'would|NOTE: frontend-arge also|check:' <<<"$drift" | sed 's/^/    /'
expect_line "$drift" 'would update frontend-arge flags' 'flag drift not found'
expect_line "$drift" 'would add redirect URI https://sandbox-arge.yildizskylab.com/* to frontend-arge' 'redirect drift not found'
expect_line "$drift" 'NOTE: frontend-arge also has redirect URI(s) http://localhost:3000/* (left as is)' 'the extra redirect URI not listed'
expect_line "$drift" 'would add post-logout redirect https://sandbox-arge.yildizskylab.com/* to frontend-arge' 'post-logout drift not found'
expect_line "$drift" 'would add mapper skycms-audience to frontend-arge' 'the missing skycms mapper not found'
expect_line "$drift" 'would repair mapper core-audience in frontend-arge-core-audience' 'core mapper drift not found'
expect_line "$drift" 'check: 5 change(s) pending, 0 warning(s), 0 problem(s)' 'unexpected drift plan'
repair=$(run_script --apply) || { printf '%s\n' "$repair" >&2; fail 'drift --apply failed'; }
expect_line "$repair" 'applied 5 change(s)' 'drift not repaired'
again=$(run_script --check) || { printf '%s\n' "$again" >&2; fail 'post-repair --check failed'; }
expect_line "$again" 'check: 0 change(s) pending' 'a repair did not hold'
live=$(kcadm get "clients/$arge" -r "$REALM")
json_assert "$live" '(.directAccessGrantsEnabled | not) and (.redirectUris | sort) == (["http://localhost:3000/*", $s + "/*"] | sort)
  and (.attributes["post.logout.redirect.uris"] | split("##") | sort) == (["http://localhost:3000/*", $s + "/*"] | sort)' \
  'the repair lost the extra URI or did not restore the site'"'"'s' --arg s "$SITE"
json_assert "$(kcadm get "client-scopes/$core_scope/protocol-mappers/models" -r "$REALM")" \
  'length == 1 and .[0].config["id.token.claim"] == "false"' 'the core mapper was duplicated or not repaired'
json_assert "$(jwt_payload "$(code_flow_response sandboxadmin | jq -r .access_token)")" \
  "($AUD) | index(\"skycms\") != null and index(\"core\") != null" 'the repaired client lost an audience'

CURRENT_STAGE='a flat groups claim is a PROBLEM'
kcadm create "clients/$arge/protocol-mappers/models" -r "$REALM" -b '{"name":"flat-groups","protocol":"openid-connect","protocolMapper":"oidc-group-membership-mapper","config":{"full.path":"false","claim.name":"groups","access.token.claim":"true"}}' >/dev/null
event_before=$(newest_admin_event)
sleep 1
flat=$(run_expecting 1 --apply)
expect_line "$flat" 'PROBLEM: frontend-arge: the claim groups reaches the access token differently from what inscribed reads (client mapper flat-groups)' 'flat groups not reported'
expect_line "$flat" 'applied 0 change(s), 0 warning(s), 1 problem(s)' 'the flat groups run changed something'
[[ $(newest_admin_event) == "$event_before" ]] || fail 'the flat groups run wrote to the realm'
flat_mapper=$(kcadm get "clients/$arge/protocol-mappers/models" -r "$REALM" | jq -r '.[] | select(.name == "flat-groups") | .id')
[[ -n $flat_mapper ]] || fail 'the flat groups mapper was touched'
kcadm delete "clients/$arge/protocol-mappers/models/$flat_mapper" -r "$REALM" >/dev/null

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='realm scope groups (the production shape)'
kcadm delete "clients/$arge" -r "$REALM" >/dev/null
groups_scope=$(kcadm create client-scopes -r "$REALM" -i -s name=groups -s protocol=openid-connect)
kcadm create "client-scopes/$groups_scope/protocol-mappers/models" -r "$REALM" -b '{"name":"groups","protocol":"openid-connect","protocolMapper":"oidc-group-membership-mapper","config":{"full.path":"true","claim.name":"groups","multivalued":"true","access.token.claim":"true","id.token.claim":"true","userinfo.token.claim":"true","introspection.token.claim":"true"}}' >/dev/null
check=$(run_script --check) || { printf '%s\n' "$check" >&2; fail 'scope --check failed'; }
expect_line "$check" 'would attach the realm scope groups (full-path groups) as a default scope of frontend-arge' 'realm groups scope not planned'
reject_line "$check" 'would add mapper groups' 'a groups mapper planned next to the realm scope'
expect_line "$check" 'client scope frontend-arge-core-audience: attributes unchanged' 'the core scope was not reused'
expect_line "$check" 'check: 4 change(s) pending, 0 warning(s), 0 problem(s)' 'unexpected plan with the realm scope'
apply=$(run_script --apply) || { printf '%s\n' "$apply" >&2; fail 'scope --apply failed'; }
expect_line "$apply" 'applied 4 change(s)' 'scope apply'
again=$(run_script --check) || { printf '%s\n' "$again" >&2; fail 'scope second --check failed'; }
expect_line "$again" 'frontend-arge: groups (full path) comes from default scope groups mapper groups' 'the attached scope not recognised'
expect_line "$again" 'check: 0 change(s) pending' 'scope second run plans changes'
arge=$(client_uuid "$CLIENT")
json_assert "$(kcadm get "clients/$arge/protocol-mappers/models" -r "$REALM")" 'map(.name) == ["skycms-audience"]' \
  'the client got its own groups mapper next to the realm scope'
[[ $(scope_uuids frontend-arge-core-audience) == "$core_scope" ]] || fail 'the core scope was recreated or duplicated'
json_assert "$(jwt_payload "$(code_flow_response sandboxadmin | jq -r .access_token)")" \
  ".groups == [\"/UYELER/ADMIN\"] and (($AUD) | index(\"skycms\") != null and index(\"core\") != null)" \
  'the realm groups scope does not reach the token'
printf '    realm scope groups attached as a default scope; one frontend-arge-core-audience scope\n'

CURRENT_STAGE='no core client'
kcadm delete "clients/$(client_uuid core)" -r "$REALM" >/dev/null
check=$(run_script --check) || { printf '%s\n' "$check" >&2; fail 'no-core --check failed'; }
expect_line "$check" 'NOTE: realm e-skylab-sandbox has no core client; frontend-arge-core-audience skipped' 'missing core not skipped'
expect_line "$check" 'check: 0 change(s) pending' 'a missing core client changed the plan'

printf 'sandbox-site-clients.sh contract holds against %s.\n' "$IMAGE"
