#!/usr/bin/env bash
# Real-Keycloak contract for config/inscribed-cms-roles.sh (CMS moves to inscribed, ADR-0056).
# Stand-alone: starts the stock Keycloak image this repository builds on (the Dockerfile's
# KEYCLOAK_IMAGE, tag and digest) in dev mode with docker run --rm and no volume, builds a small
# realm shaped like production, runs the script inside that container the way the operator does
# and reads real tokens. The container is removed on exit (docker rm -fv).
#
# The fixture realm (e-skylab), shaped after the production facts of 2026-09-21:
#   frontend-main   service account (holds cms:access), realm scope "groups" (full path) as a
#                   default scope, skycms audience scope; group /YK holds its cms:access
#   frontend-arge   service account (holds nothing), fullScopeAllowed=false, same scopes;
#                   group /UYELER/WEBLAB/LIDERLER holds its cms:access
#   admin           no service account, no groups mapper at all; group /YK holds its cms:access
#   foreign-site    a hardcoded "roles" mapper and a flat (not full path) groups mapper
#   people          editor (in /YK and /UYELER/WEBLAB/LIDERLER), outsider (no group)
# Direct access grants are on for the site clients so the harness can get a person's token; the
# mappers do not depend on the grant.
#
# What it proves:
#   - --check writes nothing (no admin event), prints the state and plans every change; a client
#     missing from the realm (the sandbox) is skipped with a warning;
#   - --apply creates content:read, content:write, schema:sync, makes cms:access include
#     content:read + content:write, adds inscribed-roles, adds inscribed-groups only where no
#     full-path groups mapper reaches the access token, gives the service accounts content:read +
#     schema:sync; a second --check plans nothing and a second --apply writes nothing;
#   - the editor's access token (password grant, real signature) of every site client carries
#     roles ⊇ {cms:access, content:read, content:write} and groups as full paths; the ID token
#     and userinfo carry no roles; resource_access and aud (skycms) are unchanged;
#   - fullScopeAllowed=false still lets the client's own roles through (frontend-arge);
#   - the outsider's token carries no content:* role;
#   - the service accounts' client_credentials tokens carry content:read and schema:sync;
#   - drift (the mapper written to the ID token, a composite removed) is repaired;
#   - a foreign "roles" mapper or a flat groups claim is reported as PROBLEM (exit 1) and left
#     as is, and inscribed-roles is not added next to it;
#   - frontend-arge -> core audience: the scope frontend-arge-core-audience, made by hand the way
#     ops/wizards/inscribed-keycloak-roles-wizard.sh makes it tonight (the reconciled shape of
#     reconcile_login_client_audience and config/frontend-arge-core-audience-mappers.json, so
#     the reconciler adopts it unchanged later), puts core in the aud of an arge editor's access
#     token next to skycms, not in the ID token. The reconciler itself is covered by
#     login-client-audiences.sh in the integration harness.
# Requirements on the host: docker, curl, jq, base64. INSCRIBED_TEST_PORT (default 18091).
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPOSITORY_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
OPERATOR_SCRIPT="$REPOSITORY_ROOT/config/inscribed-cms-roles.sh"
IMAGE=$(sed -n 's/^ARG KEYCLOAK_IMAGE=//p' "$REPOSITORY_ROOT/Dockerfile")
PORT=${INSCRIBED_TEST_PORT:-18091}
BASE_URL="http://127.0.0.1:$PORT"
REALM=e-skylab
CONTAINER="inscribed-roles-test-$$"
ADMIN_PASSWORD=harness-admin-password
PERSON_PASSWORD=harness-person-password
KCADM_CONFIG=/tmp/harness-kcadm.config
IN_CONTAINER_SCRIPT=/tmp/inscribed-cms-roles.sh
CURRENT_STAGE=startup

# The fixture clients' secrets (throwaway values; bash 3.2 on macOS has no associative arrays).
secret_of() {
  printf 'harness-%s-secret' "$1"
}

fail() {
  printf 'inscribed-cms-roles failure during %s: %s\n' "$CURRENT_STAGE" "$1" >&2
  exit 1
}
cleanup() {
  docker rm -fv "$CONTAINER" >/dev/null 2>&1 || true
}
trap 'status=$?; trap - EXIT; cleanup; exit "$status"' EXIT
on_error() {
  local status=$?
  printf 'inscribed-cms-roles command failed during %s (line %s)\n' "$CURRENT_STAGE" "$1" >&2
  exit "$status"
}
trap 'on_error "$LINENO"' ERR

# kcadm's "Created new ..." notices go to stderr; they are dropped, errors are kept.
kcadm() {
  local command=$1
  shift
  docker exec -i "$CONTAINER" /opt/keycloak/bin/kcadm.sh "$command" --config "$KCADM_CONFIG" "$@" \
    2> >(grep -v '^Created new ' >&2 || true)
}

# run_script ARGS...: the operator script inside the Keycloak container, reusing the harness's
# kcadm session (the wizard does the same). Prints the output; returns the script's status.
run_script() {
  docker exec -e KEYCLOAK_REALM="$REALM" "$CONTAINER" \
    bash "$IN_CONTAINER_SCRIPT" --kcadm-config "$KCADM_CONFIG" "$@" 2>&1
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
  kcadm get clients -r "$REALM" -q "clientId=$1" | jq -r --arg id "$1" '.[] | select(.clientId == $id) | .id'
}

role_rep() {
  kcadm get "clients/$(client_uuid "$1")/roles/$2" -r "$REALM" | jq -c '[{id, name}]'
}

newest_admin_event() {
  kcadm get admin-events -r "$REALM" -q max=1 | jq -r '.[0].time // 0'
}

# jwt_payload TOKEN: the decoded payload (JSON) of a compact JWT.
jwt_payload() {
  local segment
  segment=$(cut -d. -f2 <<<"$1" | tr '_-' '/+')
  case $(( ${#segment} % 4 )) in 2) segment+='==' ;; 3) segment+='=' ;; esac
  base64 -d <<<"$segment"
}

# token_response CLIENT GRANT [USER]: the token endpoint's JSON for a password or
# client_credentials grant.
token_response() {
  local client=$1 grant=$2 user=${3:-}
  if [[ $grant == password ]]; then
    curl -fsS "$BASE_URL/realms/$REALM/protocol/openid-connect/token" \
      --data-urlencode grant_type=password --data-urlencode "client_id=$client" \
      --data-urlencode "client_secret=$(secret_of "$client")" --data-urlencode scope=openid \
      --data-urlencode "username=$user" --data-urlencode "password=$PERSON_PASSWORD"
  else
    curl -fsS "$BASE_URL/realms/$REALM/protocol/openid-connect/token" \
      --data-urlencode grant_type=client_credentials --data-urlencode "client_id=$client" \
      --data-urlencode "client_secret=$(secret_of "$client")"
  fi
}

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

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='fixture realm'
kcadm create realms -s realm="$REALM" -s enabled=true -s adminEventsEnabled=true >/dev/null
groups_scope=$(kcadm create client-scopes -r "$REALM" -i -s name=groups -s protocol=openid-connect)
kcadm create "client-scopes/$groups_scope/protocol-mappers/models" -r "$REALM" -b '{"name":"groups","protocol":"openid-connect","protocolMapper":"oidc-group-membership-mapper","config":{"full.path":"true","claim.name":"groups","multivalued":"true","access.token.claim":"true","id.token.claim":"true","userinfo.token.claim":"true","introspection.token.claim":"true"}}' >/dev/null
kcadm create clients -r "$REALM" -s clientId=skycms -s publicClient=false -s standardFlowEnabled=false >/dev/null
kcadm create clients -r "$REALM" -s clientId=core -s publicClient=false -s standardFlowEnabled=false >/dev/null
skycms_scope=$(kcadm create client-scopes -r "$REALM" -i -s name=skycms-audience -s protocol=openid-connect)
kcadm create "client-scopes/$skycms_scope/protocol-mappers/models" -r "$REALM" -b '{"name":"audience-mapper","protocol":"openid-connect","protocolMapper":"oidc-audience-mapper","config":{"included.client.audience":"skycms","access.token.claim":"true","id.token.claim":"false","introspection.token.claim":"true"}}' >/dev/null

site_client() {
  local client_id=$1 service_account=$2 full_scope=$3 uuid
  uuid=$(kcadm create clients -r "$REALM" -i -s "clientId=$client_id" -s publicClient=false \
    -s "secret=$(secret_of "$client_id")" -s standardFlowEnabled=true -s directAccessGrantsEnabled=true \
    -s "serviceAccountsEnabled=$service_account" -s "fullScopeAllowed=$full_scope" \
    -s 'redirectUris=["https://example.invalid/*"]')
  kcadm create "clients/$uuid/roles" -r "$REALM" -s name=cms:access >/dev/null
  printf '%s\n' "$uuid"
}
main_uuid=$(site_client frontend-main true true)
arge_uuid=$(site_client frontend-arge true false)
admin_uuid=$(site_client admin false true)
foreign_uuid=$(site_client foreign-site false true)
for uuid in "$main_uuid" "$arge_uuid"; do
  kcadm update "clients/$uuid/default-client-scopes/$groups_scope" -r "$REALM" -n -b '{}' >/dev/null
  kcadm update "clients/$uuid/default-client-scopes/$skycms_scope" -r "$REALM" -n -b '{}' >/dev/null
done
kcadm create "clients/$foreign_uuid/protocol-mappers/models" -r "$REALM" -b '{"name":"legacy-roles","protocol":"openid-connect","protocolMapper":"oidc-hardcoded-claim-mapper","config":{"claim.name":"roles","claim.value":"legacy","jsonType.label":"String","access.token.claim":"true"}}' >/dev/null
kcadm create "clients/$foreign_uuid/protocol-mappers/models" -r "$REALM" -b '{"name":"flat-groups","protocol":"openid-connect","protocolMapper":"oidc-group-membership-mapper","config":{"full.path":"false","claim.name":"groups","access.token.claim":"true"}}' >/dev/null

yk=$(kcadm create groups -r "$REALM" -i -s name=YK)
uyeler=$(kcadm create groups -r "$REALM" -i -s name=UYELER)
weblab=$(kcadm create "groups/$uyeler/children" -r "$REALM" -i -s name=WEBLAB)
liderler=$(kcadm create "groups/$weblab/children" -r "$REALM" -i -s name=LIDERLER)
kcadm create "groups/$yk/role-mappings/clients/$main_uuid" -r "$REALM" -b "$(role_rep frontend-main cms:access)" >/dev/null
kcadm create "groups/$yk/role-mappings/clients/$admin_uuid" -r "$REALM" -b "$(role_rep admin cms:access)" >/dev/null
kcadm create "groups/$yk/role-mappings/clients/$foreign_uuid" -r "$REALM" -b "$(role_rep foreign-site cms:access)" >/dev/null
kcadm create "groups/$liderler/role-mappings/clients/$arge_uuid" -r "$REALM" -b "$(role_rep frontend-arge cms:access)" >/dev/null

person() {
  local uuid
  uuid=$(kcadm create users -r "$REALM" -i -s "username=$1" -s enabled=true -s "email=$1@example.invalid" \
    -s emailVerified=true -s firstName=Harness -s "lastName=$1")
  kcadm set-password -r "$REALM" --userid "$uuid" --new-password "$PERSON_PASSWORD" >/dev/null
  printf '%s\n' "$uuid"
}
editor=$(person editor)
person outsider >/dev/null
kcadm update "users/$editor/groups/$yk" -r "$REALM" -n -b '{}' >/dev/null
kcadm update "users/$editor/groups/$liderler" -r "$REALM" -n -b '{}' >/dev/null
main_sa=$(kcadm get "clients/$main_uuid/service-account-user" -r "$REALM" | jq -r .id)
kcadm create "users/$main_sa/role-mappings/clients/$main_uuid" -r "$REALM" -b "$(role_rep frontend-main cms:access)" >/dev/null

# Before: the editor's frontend-main token has no roles claim; cms:access only in resource_access.
before=$(jwt_payload "$(token_response frontend-main password editor | jq -r .access_token)")
json_assert "$before" '.roles == null and (.resource_access["frontend-main"].roles == ["cms:access"])' \
  'fixture: the editor token already carries a roles claim or lacks cms:access'

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='--check writes nothing'
event_before=$(newest_admin_event)
sleep 1
check=$(run_script --check --client frontend-main --client frontend-arge --client admin --client sandbox-missing) \
  || { printf '%s\n' "$check" >&2; fail '--check failed'; }
printf '%s\n' "$check" | sed 's/^/    /'
[[ $(newest_admin_event) == "$event_before" ]] || fail '--check wrote to the realm'
expect_line "$check" 'WARNING: client sandbox-missing does not exist in realm e-skylab; skipped' 'missing client not skipped'
for client in frontend-main frontend-arge admin; do
  for role in content:read content:write schema:sync; do
    expect_line "$check" "would create client role $role on $client" 'role not planned'
  done
  expect_line "$check" "would make $client/cms:access include $client/content:read" 'composite not planned'
  expect_line "$check" "would make $client/cms:access include $client/content:write" 'composite not planned'
  expect_line "$check" "would add mapper inscribed-roles to $client" 'roles mapper not planned'
done
expect_line "$check" 'frontend-main: cms:access held directly by 1 user(s) (service accounts included); groups: /YK' 'holders not reported'
expect_line "$check" 'frontend-arge: cms:access held directly by 0 user(s) (service accounts included); groups: /UYELER/WEBLAB/LIDERLER' 'holders not reported'
expect_line "$check" 'admin: cms:access held directly by 0 user(s) (service accounts included); groups: /YK' 'holders not reported'
expect_line "$check" 'frontend-main: groups (full path) comes from default scope groups mapper groups' 'existing groups mapper not found'
expect_line "$check" 'would add mapper inscribed-groups to admin' 'admin groups mapper not planned'
reject_line "$check" 'would add mapper inscribed-groups to frontend-main' 'groups mapper duplicated'
reject_line "$check" 'would add mapper inscribed-groups to frontend-arge' 'groups mapper duplicated'
expect_line "$check" 'frontend-main: service account service-account-frontend-main holds (direct): cms:access' 'SA roles not reported'
expect_line "$check" 'would assign frontend-main/content:read to service-account-frontend-main' 'SA role not planned'
expect_line "$check" 'would assign frontend-arge/schema:sync to service-account-frontend-arge' 'SA role not planned'
expect_line "$check" 'admin: no service account (left disabled)' 'admin SA not reported'
expect_line "$check" 'check: 23 change(s) pending, 1 warning(s), 0 problem(s)' 'unexpected plan size'

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='--apply'
apply=$(run_script --apply) || { printf '%s\n' "$apply" >&2; fail '--apply failed'; }
printf '%s\n' "$apply" | sed 's/^/    /'
expect_line "$apply" 'applied 23 change(s), 0 warning(s), 0 problem(s)' 'apply did not write the plan'

CURRENT_STAGE='second run is a no-op'
event_before=$(newest_admin_event)
sleep 1
again=$(run_script --check) || { printf '%s\n' "$again" >&2; fail 'second --check failed'; }
expect_line "$again" 'check: 0 change(s) pending, 0 warning(s), 0 problem(s)' 'second --check plans changes'
again=$(run_script --apply) || { printf '%s\n' "$again" >&2; fail 'second --apply failed'; }
expect_line "$again" 'applied 0 change(s)' 'second --apply wrote'
[[ $(newest_admin_event) == "$event_before" ]] || fail 'the second run wrote to the realm'

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='editor tokens'
for client in frontend-main frontend-arge admin; do
  response=$(token_response "$client" password editor)
  access=$(jwt_payload "$(jq -r .access_token <<<"$response")")
  id_token=$(jwt_payload "$(jq -r .id_token <<<"$response")")
  userinfo=$(curl -fsS -H "Authorization: Bearer $(jq -r .access_token <<<"$response")" \
    "$BASE_URL/realms/$REALM/protocol/openid-connect/userinfo")
  json_assert "$access" \
    '.azp == $c and (.roles | type == "array") and ((.roles | sort) == ["cms:access", "content:read", "content:write"])' \
    "$client editor access token roles are not exactly cms:access, content:read, content:write" --arg c "$client"
  json_assert "$access" '(.resource_access[$c].roles | sort) == ["cms:access", "content:read", "content:write"]' \
    "$client resource_access changed unexpectedly" --arg c "$client"
  json_assert "$access" '(.groups | sort) == ["/UYELER/WEBLAB/LIDERLER", "/YK"]' "$client editor groups are not full paths"
  json_assert "$id_token" '.roles == null' "$client ID token carries roles"
  json_assert "$userinfo" '.roles == null' "$client userinfo carries roles"
  printf '    %s editor: roles=%s groups=%s aud=%s\n' "$client" "$(jq -c .roles <<<"$access")" \
    "$(jq -c .groups <<<"$access")" "$(jq -c .aud <<<"$access")"
done
json_assert "$(jwt_payload "$(token_response frontend-main password editor | jq -r .access_token)")" \
  '(.aud | if type == "array" then . else [.] end | index("skycms")) != null' 'frontend-main lost the skycms audience'
access=$(jwt_payload "$(token_response frontend-main password outsider | jq -r .access_token)")
json_assert "$access" '((.roles // []) | map(select(startswith("content:") or . == "cms:access" or . == "schema:sync"))) == []' \
  'the outsider got a CMS role'
printf '    frontend-main outsider: roles=%s\n' "$(jq -c '.roles // "none"' <<<"$access")"

CURRENT_STAGE='service-account tokens'
access=$(jwt_payload "$(token_response frontend-main client_credentials | jq -r .access_token)")
json_assert "$access" '.azp == "frontend-main" and ((["content:read", "schema:sync"] - .roles) == [])' \
  'frontend-main service account lacks content:read or schema:sync'
printf '    frontend-main service account: roles=%s\n' "$(jq -c .roles <<<"$access")"
access=$(jwt_payload "$(token_response frontend-arge client_credentials | jq -r .access_token)")
json_assert "$access" '.azp == "frontend-arge" and ((.roles | sort) == ["content:read", "schema:sync"])' \
  'frontend-arge service account roles are not exactly content:read, schema:sync'
printf '    frontend-arge service account: roles=%s\n' "$(jq -c .roles <<<"$access")"

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='drift repair'
mapper_id=$(kcadm get "clients/$main_uuid/protocol-mappers/models" -r "$REALM" | jq -r '.[] | select(.name == "inscribed-roles") | .id')
kcadm get "clients/$main_uuid/protocol-mappers/models/$mapper_id" -r "$REALM" \
  | jq -c '.config["id.token.claim"] = "true"' \
  | kcadm update "clients/$main_uuid/protocol-mappers/models/$mapper_id" -r "$REALM" -f - >/dev/null
legacy_id=$(kcadm get "clients/$main_uuid/roles/cms:access" -r "$REALM" | jq -r .id)
kcadm delete "roles-by-id/$legacy_id/composites" -r "$REALM" -b "$(role_rep frontend-main content:write)" >/dev/null
drift=$(run_script --check --client frontend-main) || { printf '%s\n' "$drift" >&2; fail 'drift --check failed'; }
expect_line "$drift" 'would repair mapper inscribed-roles on frontend-main' 'mapper drift not found'
expect_line "$drift" 'would make frontend-main/cms:access include frontend-main/content:write' 'composite drift not found'
expect_line "$drift" 'check: 2 change(s) pending' 'unexpected drift plan'
repair=$(run_script --apply --client frontend-main) || { printf '%s\n' "$repair" >&2; fail 'drift --apply failed'; }
again=$(run_script --check --client frontend-main) || { printf '%s\n' "$again" >&2; fail 'post-repair --check failed'; }
expect_line "$again" 'check: 0 change(s) pending' 'drift not repaired'
[[ $(kcadm get "clients/$main_uuid/protocol-mappers/models" -r "$REALM" | jq '[.[] | select(.name == "inscribed-roles")] | length') == 1 ]] \
  || fail 'the repair duplicated the mapper'
response=$(token_response frontend-main password editor)
json_assert "$(jwt_payload "$(jq -r .id_token <<<"$response")")" '.roles == null' 'repaired mapper still writes the ID token'
json_assert "$(jwt_payload "$(jq -r .access_token <<<"$response")")" '(.roles | index("content:write")) != null' \
  'repaired composite does not reach the token'

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='frontend-arge -> core audience'
before=$(jwt_payload "$(token_response frontend-arge password editor | jq -r .access_token)")
json_assert "$before" '(.aud | if type == "array" then . else [.] end | index("core")) == null' \
  'fixture: the arge token already names core'
arge_core_scope=$(kcadm create client-scopes -r "$REALM" -i \
  -b '{"name":"frontend-arge-core-audience","protocol":"openid-connect","attributes":{"include.in.token.scope":"false","display.on.consent.screen":"false"}}')
jq -c '.[0]' "$REPOSITORY_ROOT/config/frontend-arge-core-audience-mappers.json" \
  | kcadm create "client-scopes/$arge_core_scope/protocol-mappers/models" -r "$REALM" -f - >/dev/null
kcadm update "clients/$arge_uuid/default-client-scopes/$arge_core_scope" -r "$REALM" -n -b '{}' >/dev/null
response=$(token_response frontend-arge password editor)
access=$(jwt_payload "$(jq -r .access_token <<<"$response")")
json_assert "$access" '.azp == "frontend-arge" and (.aud | if type == "array" then . else [.] end | (index("core") != null and index("skycms") != null))' \
  'the arge editor access token does not name both core and skycms'
json_assert "$access" '(.resource_access.core // null) == null' 'the arge editor unexpectedly holds a core role'
json_assert "$(jwt_payload "$(jq -r .id_token <<<"$response")")" '(.aud | if type == "array" then . else [.] end | index("core")) == null' \
  'the arge ID token names core'
printf '    frontend-arge editor after the core audience scope: aud=%s roles=%s\n' \
  "$(jq -c .aud <<<"$access")" "$(jq -c .roles <<<"$access")"

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='foreign claims'
event_before=$(newest_admin_event)
# The run must fail; bash 3.2 would fire the inherited ERR trap inside the substitution.
trap - ERR
foreign_status=0
foreign=$(run_script --apply --client foreign-site) || foreign_status=$?
trap 'on_error "$LINENO"' ERR
[[ $foreign_status == 1 ]] || { printf '%s\n' "$foreign" >&2; fail "a foreign roles mapper did not fail the run (exit $foreign_status)"; }
printf '%s\n' "$foreign" | sed 's/^/    /'
expect_line "$foreign" 'PROBLEM: foreign-site: something else already emits the claim roles (client mapper legacy-roles (oidc-hardcoded-claim-mapper))' 'foreign roles mapper not reported'
expect_line "$foreign" 'PROBLEM: foreign-site: the claim groups is emitted differently' 'flat groups not reported'
foreign_mappers=$(kcadm get "clients/$foreign_uuid/protocol-mappers/models" -r "$REALM" | jq -c '[.[].name] | sort')
[[ $foreign_mappers == '["flat-groups","legacy-roles"]' ]] || fail "foreign-site mappers changed: $foreign_mappers"

printf 'inscribed-cms-roles.sh contract holds against %s.\n' "$IMAGE"
