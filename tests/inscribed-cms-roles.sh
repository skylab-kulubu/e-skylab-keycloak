#!/usr/bin/env bash
# Real-Keycloak contract for config/inscribed-cms-roles.sh (CMS moves to inscribed, ADR-0056).
# Stand-alone: starts the stock Keycloak image this repository builds on (the Dockerfile's
# KEYCLOAK_IMAGE, tag and digest) in dev mode with docker run --rm and no volume, builds a small
# realm shaped like production, runs the script inside that container the way the operator does
# and reads real tokens. The container is removed on exit (docker rm -fv).
#
# The fixture realm (e-skylab), shaped after the production facts of 2026-09-28 before the script:
#   frontend-main   service account holding cms:access (the old CMS renders with it), cms:access
#                   held by no group, realm scope "groups" (full path) and the skycms audience
#                   scope as default scopes
#   frontend-arge   service account holding nothing, fullScopeAllowed=false, no role at all, same
#                   scopes
#   admin           no service account, no role, no groups mapper (the admin panel's client)
#   foreign-site    a hardcoded "roles" mapper and a flat (not full path) groups mapper
#   groups          /ADMIN, /UYELER/YK/BASKAN, /UYELER/DK, /UYELER/WEBLAB/LIDERLER
#   people          ykmember (in /UYELER/YK/BASKAN), leader (in /UYELER/WEBLAB/LIDERLER), member (in
#                   /UYELER/WEBLAB, a plain team member)
# and a second realm e-skylab-sandbox with only superadmin (the sandbox admin panel's client).
# Direct access grants are on for the site clients so the harness can get a person's token; the
# mappers do not depend on the grant.
#
# What it proves:
#   - --check writes nothing, prints the state, the plan and who holds each role; a client missing
#     from the realm is skipped with a NOTE;
#   - --apply creates content:read, content:write, schema:sync everywhere, cms:access (composite of
#     content:read + content:write) and client:admin on frontend-main and frontend-arge only, adds
#     inscribed-roles, adds inscribed-groups only where no full-path groups mapper reaches the
#     access token, gives the service accounts content:read + schema:sync and grants NOTHING to a
#     group or a person (admin events); a second --check plans nothing, a second --apply writes
#     nothing;
#   - with the grants made the way the SKY LAB admin panel makes them (group -> client role), the
#     report lists each group per role, directly or via cms:access, and real access tokens show:
#       a YK member (subgroup /UYELER/YK/BASKAN) on frontend-main and frontend-arge: roles =
#       {client:admin, cms:access, content:read, content:write}; on admin: {content:read,
#       content:write}; a leader on frontend-arge and on frontend-main: {cms:access, content:read,
#       content:write}, no client:admin; a plain member: no CMS role anywhere. cms:access is in
#       resource_access where the sites' editor UI (inscribed-auth 0.3.1) looks for it, and the
#       frontend-arge token (fullScopeAllowed=false) carries no frontend-main role, so each site
#       needs its own cms:access; ID token and userinfo carry no roles;
#   - a direct grant to a person is a WARNING; a CMS role in the realm's default roles or reaching
#     a default group is a PROBLEM (exit 1);
#   - --post-cutover takes cms:access away from the frontend-main service account, which is left
#     with exactly content:read + schema:sync in its real token; without the flag it keeps it;
#   - drift (the mapper written to the ID token, a composite removed) is repaired;
#   - a foreign "roles" mapper or a flat groups claim is reported as PROBLEM (exit 1) and left
#     as is, and inscribed-roles is not added next to it;
#   - frontend-arge -> core audience: the scope frontend-arge-core-audience, made by hand the way
#     ops/wizards/inscribed-keycloak-roles-wizard.sh makes it (the reconciled shape of
#     reconcile_login_client_audience and config/frontend-arge-core-audience-mappers.json, so
#     the reconciler adopts it unchanged later), puts core in the aud of an arge editor's access
#     token next to skycms, not in the ID token. The reconciler itself is covered by
#     login-client-audiences.sh in the integration harness;
#   - in e-skylab-sandbox the default clients are frontend-main, frontend-arge and superadmin; the
#     two missing sites are skipped with a NOTE and superadmin gets the capability roles only.
# Requirements on the host: docker, curl, jq, base64. INSCRIBED_TEST_PORT (default 18091).
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPOSITORY_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
OPERATOR_SCRIPT="$REPOSITORY_ROOT/config/inscribed-cms-roles.sh"
IMAGE=$(sed -n 's/^ARG KEYCLOAK_IMAGE=//p' "$REPOSITORY_ROOT/Dockerfile")
PORT=${INSCRIBED_TEST_PORT:-18091}
BASE_URL="http://127.0.0.1:$PORT"
REALM=e-skylab
SANDBOX_REALM=e-skylab-sandbox
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
# RUN_REALM overrides the realm.
run_script() {
  docker exec -e KEYCLOAK_REALM="${RUN_REALM:-$REALM}" "$CONTAINER" \
    bash "$IN_CONTAINER_SCRIPT" --kcadm-config "$KCADM_CONFIG" "$@" 2>&1
}

# run_failing ARGS...: like run_script for a run that must exit 1; prints the output.
run_failing() {
  local output status=0
  # bash 3.2 would fire the inherited ERR trap inside the substitution.
  trap - ERR
  output=$(run_script "$@") || status=$?
  trap 'on_error "$LINENO"' ERR
  [[ $status == 1 ]] || { printf '%s\n' "$output" >&2; fail "the run did not exit 1 (exit $status)"; }
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

# holders OUTPUT CLIENT ROLE: the groups the report lists for one role, sorted, one per line.
holders() {
  local line rest
  line=$(grep -F -- "[inscribed-roles] $2:   $3 <- " <<<"$1" | grep -v ' <- service account(s): ' || true)
  [[ $line == *' <- group(s): '* ]] || return 0
  rest=${line#* <- group(s): }
  while [[ -n $rest ]]; do
    printf '%s\n' "${rest%%, *}"
    if [[ $rest == *', '* ]]; then rest=${rest#*, }; else rest=''; fi
  done | sort
}

# expect_holders OUTPUT CLIENT ROLE GROUP...: the report lists exactly these groups for the role.
expect_holders() {
  local output=$1 client=$2 role=$3 got want
  shift 3
  got=$(holders "$output" "$client" "$role")
  want=$(printf '%s\n' "$@" | sed '/^$/d' | sort)
  [[ $got == "$want" ]] || { printf '%s\n' "$output" >&2; fail "$client/$role holders are [$got], not [$want]"; }
}

json_assert() {
  local json=$1 expression=$2 message=$3
  shift 3
  jq -e "$@" "$expression" <<<"$json" >/dev/null || { printf '%s\n' "$json" >&2; fail "$message"; }
}

client_uuid() {
  kcadm get clients -r "${2:-$REALM}" -q "clientId=$1" | jq -r --arg id "$1" '.[] | select(.clientId == $id) | .id'
}

role_rep() {
  kcadm get "clients/$(client_uuid "$1")/roles/$2" -r "$REALM" | jq -c '[{id, name}]'
}

# grant_group GROUP_ID CLIENT_UUID ROLE...: what the SKY LAB admin panel does (core maps a group
# to client roles through the admin REST API).
grant_group() {
  local group=$1 uuid=$2 body
  shift 2
  body=$(kcadm get "clients/$uuid/roles" -r "$REALM" \
    | jq -c --args '[.[] | select(.name as $n | $ARGS.positional | index($n)) | {id, name}]' "$@")
  [[ $(jq length <<<"$body") == "$#" ]] || fail "grant_group: roles $* not all found"
  kcadm create "groups/$group/role-mappings/clients/$uuid" -r "$REALM" -b "$body" >/dev/null
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

access_of() {
  jwt_payload "$(token_response "$@" | jq -r .access_token)"
}

# The CMS roles in a token's roles claim, sorted, as compact JSON.
CMS_ROLES='(.roles // []) | map(select(startswith("content:") or . == "cms:access" or . == "schema:sync" or . == "client:admin")) | sort'
# What @skylab-kulubu/inscribed-auth 0.3.1 checks to show the editor: cms:access in the roles of
# any client in resource_access.
EDITOR_GATE='[.resource_access // {} | .[] | .roles // [] | .[]] | index("cms:access") != null'

# person_token_assert USER CLIENT ROLES_JSON GATE: the person's real access token on the client
# carries exactly these CMS roles in roles, and the sites' editor gate is open (true) or shut
# (false); - skips the gate (the admin panel does not use it; with fullScopeAllowed=true its
# resource_access also lists the person's roles on the sites).
person_token_assert() {
  local user=$1 client=$2 roles=$3 gate=$4 access
  access=$(access_of "$client" password "$user")
  json_assert "$access" ".azp == \$c and (($CMS_ROLES) == \$r)" \
    "$user on $client: roles is not $roles" --arg c "$client" --argjson r "$roles"
  if [[ $gate != - ]]; then
    json_assert "$access" "($EDITOR_GATE) == \$g" "$user on $client: the editor gate is not $gate" --argjson g "$gate"
  fi
  if [[ $gate == - ]]; then gate=n/a; else gate=$(jq -c "$EDITOR_GATE" <<<"$access"); fi
  printf '    %-8s @ %-13s roles=%s editor=%s groups=%s\n' "$user" "$client" "$(jq -c "$CMS_ROLES" <<<"$access")" \
    "$gate" "$(jq -c '.groups // []' <<<"$access")"
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
  local client_id=$1 service_account=$2 full_scope=$3
  kcadm create clients -r "$REALM" -i -s "clientId=$client_id" -s publicClient=false \
    -s "secret=$(secret_of "$client_id")" -s standardFlowEnabled=true -s directAccessGrantsEnabled=true \
    -s "serviceAccountsEnabled=$service_account" -s "fullScopeAllowed=$full_scope" \
    -s 'redirectUris=["https://example.invalid/*"]'
}
main_uuid=$(site_client frontend-main true true)
arge_uuid=$(site_client frontend-arge true false)
admin_uuid=$(site_client admin false true)
foreign_uuid=$(site_client foreign-site false true)
kcadm create "clients/$main_uuid/roles" -r "$REALM" -s name=cms:access >/dev/null
kcadm create "clients/$foreign_uuid/roles" -r "$REALM" -s name=cms:access >/dev/null
for uuid in "$main_uuid" "$arge_uuid"; do
  kcadm update "clients/$uuid/default-client-scopes/$groups_scope" -r "$REALM" -n -b '{}' >/dev/null
  kcadm update "clients/$uuid/default-client-scopes/$skycms_scope" -r "$REALM" -n -b '{}' >/dev/null
done
kcadm create "clients/$foreign_uuid/protocol-mappers/models" -r "$REALM" -b '{"name":"legacy-roles","protocol":"openid-connect","protocolMapper":"oidc-hardcoded-claim-mapper","config":{"claim.name":"roles","claim.value":"legacy","jsonType.label":"String","access.token.claim":"true"}}' >/dev/null
kcadm create "clients/$foreign_uuid/protocol-mappers/models" -r "$REALM" -b '{"name":"flat-groups","protocol":"openid-connect","protocolMapper":"oidc-group-membership-mapper","config":{"full.path":"false","claim.name":"groups","access.token.claim":"true"}}' >/dev/null

admin_group=$(kcadm create groups -r "$REALM" -i -s name=ADMIN)
uyeler=$(kcadm create groups -r "$REALM" -i -s name=UYELER)
yk=$(kcadm create "groups/$uyeler/children" -r "$REALM" -i -s name=YK)
baskan=$(kcadm create "groups/$yk/children" -r "$REALM" -i -s name=BASKAN)
dk=$(kcadm create "groups/$uyeler/children" -r "$REALM" -i -s name=DK)
weblab=$(kcadm create "groups/$uyeler/children" -r "$REALM" -i -s name=WEBLAB)
liderler=$(kcadm create "groups/$weblab/children" -r "$REALM" -i -s name=LIDERLER)

person() {
  local uuid
  uuid=$(kcadm create users -r "$REALM" -i -s "username=$1" -s enabled=true -s "email=$1@example.invalid" \
    -s emailVerified=true -s firstName=Harness -s "lastName=$1")
  kcadm set-password -r "$REALM" --userid "$uuid" --new-password "$PERSON_PASSWORD" >/dev/null
  kcadm update "users/$uuid/groups/$2" -r "$REALM" -n -b '{}' >/dev/null
  printf '%s\n' "$uuid"
}
person ykmember "$baskan" >/dev/null
person leader "$liderler" >/dev/null
member=$(person member "$weblab")
main_sa=$(kcadm get "clients/$main_uuid/service-account-user" -r "$REALM" | jq -r .id)
arge_sa=$(kcadm get "clients/$arge_uuid/service-account-user" -r "$REALM" | jq -r .id)
kcadm create "users/$main_sa/role-mappings/clients/$main_uuid" -r "$REALM" -b "$(role_rep frontend-main cms:access)" >/dev/null

# Before: nobody's token has a roles claim; the service account's cms:access only in resource_access.
json_assert "$(access_of frontend-main password ykmember)" '.roles == null and .resource_access["frontend-main"] == null' \
  'fixture: the YK member already carries a roles claim or a frontend-main role'
json_assert "$(access_of frontend-main client_credentials)" '.roles == null and (.resource_access["frontend-main"].roles == ["cms:access"])' \
  'fixture: the frontend-main service account is not shaped like production'

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='--check writes nothing'
event_before=$(newest_admin_event)
sleep 1
check=$(run_script --check --client frontend-main --client frontend-arge --client admin --client sandbox-missing) \
  || { printf '%s\n' "$check" >&2; fail '--check failed'; }
printf '%s\n' "$check" | sed 's/^/    /'
[[ $(newest_admin_event) == "$event_before" ]] || fail '--check wrote to the realm'
expect_line "$check" 'NOTE: client sandbox-missing does not exist in realm e-skylab; skipped' 'missing client not skipped'
for client in frontend-main frontend-arge admin; do
  for role in content:read content:write schema:sync; do
    expect_line "$check" "would create client role $role on $client" 'role not planned'
  done
  expect_line "$check" "would add mapper inscribed-roles to $client" 'roles mapper not planned'
done
for client in frontend-main frontend-arge; do
  expect_line "$check" "would create client role client:admin on $client" 'client:admin not planned'
  expect_line "$check" "would make $client/cms:access include $client/content:read" 'composite not planned'
  expect_line "$check" "would make $client/cms:access include $client/content:write" 'composite not planned'
done
expect_line "$check" 'would create client role cms:access on frontend-arge' 'arge cms:access not planned'
reject_line "$check" 'would create client role cms:access on frontend-main' 'an existing role planned'
reject_line "$check" 'would create client role cms:access on admin' 'cms:access spread to the admin panel'
reject_line "$check" 'would create client role client:admin on admin' 'client:admin spread to the admin panel'
expect_line "$check" 'admin: no cms:access role; none is made here' 'admin cms:access not explained'
expect_line "$check" 'frontend-main: groups (full path) comes from default scope groups mapper groups' 'existing groups mapper not found'
expect_line "$check" 'would add mapper inscribed-groups to admin' 'admin groups mapper not planned'
reject_line "$check" 'would add mapper inscribed-groups to frontend-main' 'groups mapper duplicated'
reject_line "$check" 'would add mapper inscribed-groups to frontend-arge' 'groups mapper duplicated'
expect_line "$check" 'frontend-main: service account service-account-frontend-main holds (direct): cms:access' 'SA roles not reported'
expect_line "$check" 'would assign frontend-main/content:read to service-account-frontend-main' 'SA role not planned'
expect_line "$check" 'would assign frontend-arge/schema:sync to service-account-frontend-arge' 'SA role not planned'
expect_line "$check" 'frontend-main: service-account-frontend-main holds cms:access, so content:write through it' 'the SA cms:access note is missing'
reject_line "$check" 'would take frontend-main/cms:access' 'cms:access taken from the SA without --post-cutover'
expect_line "$check" 'admin: no service account (left disabled)' 'admin SA not reported'
expect_line "$check" 'frontend-main:   cms:access <- no group' 'holders not reported'
expect_line "$check" 'frontend-main:   cms:access <- service account(s): service-account-frontend-main' 'SA holder not reported'
expect_line "$check" 'frontend-arge:   cms:access <- no group (the role does not exist yet)' 'planned role not reported'
expect_line "$check" 'check: 24 change(s) pending, 0 warning(s), 0 problem(s)' 'unexpected plan size'

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='--apply'
event_before=$(newest_admin_event)
apply=$(run_script --apply) || { printf '%s\n' "$apply" >&2; fail '--apply failed'; }
printf '%s\n' "$apply" | sed 's/^/    /'
expect_line "$apply" 'realm=e-skylab mode=apply clients=frontend-main frontend-arge admin' 'unexpected default clients'
expect_line "$apply" 'applied 24 change(s), 0 warning(s), 0 problem(s)' 'apply did not write the plan'
# Role mappings the run wrote: only the two service accounts', none on a group or a person.
mappings=$(kcadm get admin-events -r "$REALM" -q max=1000 \
  | jq -c --argjson t "$event_before" '[.[] | select(.time > $t and (.resourceType == "CLIENT_ROLE_MAPPING" or .resourceType == "REALM_ROLE_MAPPING")) | .resourcePath] | sort')
json_assert "$mappings" 'length == 4 and all(.[]; test("^users/(" + $main + "|" + $arge + ")/role-mappings/clients/"))' \
  'the script granted a role to something other than the two service accounts' --arg main "$main_sa" --arg arge "$arge_sa"
printf '    role mappings written by --apply: %s\n' "$(jq -c 'map(sub("/role-mappings.*"; ""))' <<<"$mappings")"

CURRENT_STAGE='second run is a no-op'
event_before=$(newest_admin_event)
sleep 1
again=$(run_script --check) || { printf '%s\n' "$again" >&2; fail 'second --check failed'; }
expect_line "$again" 'check: 0 change(s) pending, 0 warning(s), 0 problem(s)' 'second --check plans changes'
for client in frontend-main frontend-arge; do
  for role in cms:access content:read content:write schema:sync client:admin; do
    expect_line "$again" "$client:   $role <- no group" 'a group holds a CMS role the script made'
  done
done
for role in content:read content:write schema:sync; do
  expect_line "$again" "admin:   $role <- no group" 'a group holds a CMS role the script made'
done
reject_line "$again" 'admin:   cms:access' 'admin got cms:access'
reject_line "$again" 'admin:   client:admin' 'admin got client:admin'
expect_line "$again" 'frontend-main:   content:write <- service account(s): service-account-frontend-main (via cms:access)' 'SA composite holder not reported'
again=$(run_script --apply) || { printf '%s\n' "$again" >&2; fail 'second --apply failed'; }
expect_line "$again" 'applied 0 change(s)' 'second --apply wrote'
[[ $(newest_admin_event) == "$event_before" ]] || fail 'the second run wrote to the realm'

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='admin-panel grants and the report'
grant_group "$admin_group" "$main_uuid" cms:access client:admin
grant_group "$yk" "$main_uuid" cms:access client:admin
grant_group "$dk" "$main_uuid" cms:access
grant_group "$liderler" "$main_uuid" cms:access
grant_group "$admin_group" "$arge_uuid" cms:access client:admin
grant_group "$yk" "$arge_uuid" cms:access client:admin
grant_group "$liderler" "$arge_uuid" cms:access
grant_group "$admin_group" "$admin_uuid" content:read content:write
grant_group "$yk" "$admin_uuid" content:read content:write
grant_group "$dk" "$admin_uuid" content:read content:write
report=$(run_script --check) || { printf '%s\n' "$report" >&2; fail 'report --check failed'; }
grep -F -- ' <- ' <<<"$report" | sed 's/^/    /'
expect_line "$report" 'check: 0 change(s) pending, 0 warning(s), 0 problem(s)' 'the grants changed the plan'
expect_holders "$report" frontend-main cms:access /ADMIN /UYELER/DK /UYELER/WEBLAB/LIDERLER /UYELER/YK
expect_holders "$report" frontend-main content:read '/ADMIN (via cms:access)' '/UYELER/DK (via cms:access)' \
  '/UYELER/WEBLAB/LIDERLER (via cms:access)' '/UYELER/YK (via cms:access)'
expect_holders "$report" frontend-main content:write '/ADMIN (via cms:access)' '/UYELER/DK (via cms:access)' \
  '/UYELER/WEBLAB/LIDERLER (via cms:access)' '/UYELER/YK (via cms:access)'
expect_holders "$report" frontend-main client:admin /ADMIN /UYELER/YK
expect_holders "$report" frontend-main schema:sync
expect_holders "$report" frontend-arge cms:access /ADMIN /UYELER/WEBLAB/LIDERLER /UYELER/YK
expect_holders "$report" frontend-arge content:write '/ADMIN (via cms:access)' '/UYELER/WEBLAB/LIDERLER (via cms:access)' \
  '/UYELER/YK (via cms:access)'
expect_holders "$report" frontend-arge client:admin /ADMIN /UYELER/YK
expect_holders "$report" admin content:read /ADMIN /UYELER/DK /UYELER/YK
expect_holders "$report" admin content:write /ADMIN /UYELER/DK /UYELER/YK
expect_holders "$report" admin schema:sync

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='person tokens'
all_editor='["client:admin","cms:access","content:read","content:write"]'
site_editor='["cms:access","content:read","content:write"]'
panel_editor='["content:read","content:write"]'
person_token_assert ykmember frontend-main "$all_editor" true
person_token_assert ykmember frontend-arge "$all_editor" true
person_token_assert ykmember admin "$panel_editor" -
person_token_assert leader frontend-arge "$site_editor" true
person_token_assert leader frontend-main "$site_editor" true
person_token_assert leader admin '[]' -
person_token_assert member frontend-main '[]' false
person_token_assert member frontend-arge '[]' false
person_token_assert member admin '[]' -
response=$(token_response frontend-arge password ykmember)
access=$(jwt_payload "$(jq -r .access_token <<<"$response")")
json_assert "$access" '(.groups == ["/UYELER/YK/BASKAN"]) and (.resource_access["frontend-main"] == null)' \
  'the arge token has no full-path groups or carries frontend-main roles (fullScopeAllowed=false)'
json_assert "$(jwt_payload "$(jq -r .id_token <<<"$response")")" '.roles == null' 'the ID token carries roles'
json_assert "$(curl -fsS -H "Authorization: Bearer $(jq -r .access_token <<<"$response")" \
  "$BASE_URL/realms/$REALM/protocol/openid-connect/userinfo")" '.roles == null' 'userinfo carries roles'
json_assert "$(access_of frontend-main password leader)" \
  '(.aud | if type == "array" then . else [.] end | index("skycms")) != null' 'frontend-main lost the skycms audience'

CURRENT_STAGE='service-account tokens'
access=$(access_of frontend-main client_credentials)
json_assert "$access" ".azp == \"frontend-main\" and (($CMS_ROLES) == [\"cms:access\", \"content:read\", \"content:write\", \"schema:sync\"])" \
  'frontend-main service account is not content:read + schema:sync + cms:access (before the cutover)'
printf '    frontend-main service account (before the cutover): roles=%s\n' "$(jq -c "$CMS_ROLES" <<<"$access")"
access=$(access_of frontend-arge client_credentials)
json_assert "$access" ".azp == \"frontend-arge\" and (($CMS_ROLES) == [\"content:read\", \"schema:sync\"])" \
  'frontend-arge service account roles are not exactly content:read, schema:sync'
printf '    frontend-arge service account: roles=%s\n' "$(jq -c "$CMS_ROLES" <<<"$access")"

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='direct grants, default roles, default groups'
default_role=$(kcadm get "realms/$REALM" | jq -r .defaultRole.id)
kcadm create "users/$member/role-mappings/clients/$main_uuid" -r "$REALM" -b "$(role_rep frontend-main cms:access)" >/dev/null
kcadm create "roles-by-id/$default_role/composites" -r "$REALM" -b "$(role_rep frontend-arge content:read)" >/dev/null
kcadm update "default-groups/$liderler" -r "$REALM" -n -b '{}' >/dev/null
bad=$(run_failing --check --client frontend-main --client frontend-arge)
grep -E 'WARNING|PROBLEM' <<<"$bad" | sed 's/^/    /'
expect_line "$bad" 'WARNING: frontend-main/cms:access is granted directly to user(s) member, not through a group' 'direct grant not warned'
expect_line "$bad" "PROBLEM: frontend-arge: the realm's default roles (default-roles-e-skylab) include content:read" 'default role not reported'
expect_line "$bad" 'PROBLEM: frontend-main: the default group /UYELER/WEBLAB/LIDERLER gets cms:access (held by /UYELER/WEBLAB/LIDERLER)' 'default group not reported'
expect_line "$bad" 'PROBLEM: frontend-arge: the default group /UYELER/WEBLAB/LIDERLER gets cms:access' 'default group not reported'
expect_line "$bad" 'check: 0 change(s) pending, 1 warning(s), 3 problem(s)' 'unexpected warning or problem count'
kcadm delete "users/$member/role-mappings/clients/$main_uuid" -r "$REALM" -b "$(role_rep frontend-main cms:access)" >/dev/null
kcadm delete "roles-by-id/$default_role/composites" -r "$REALM" -b "$(role_rep frontend-arge content:read)" >/dev/null
kcadm delete "default-groups/$liderler" -r "$REALM" >/dev/null

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='--post-cutover'
post=$(run_script --check --post-cutover --client frontend-main --client frontend-arge) \
  || { printf '%s\n' "$post" >&2; fail 'post-cutover --check failed'; }
expect_line "$post" 'realm=e-skylab mode=check clients=frontend-main frontend-arge post-cutover' 'post-cutover not announced'
expect_line "$post" 'would take frontend-main/cms:access (and so content:write) away from service-account-frontend-main' 'SA cms:access removal not planned'
expect_line "$post" 'frontend-arge: service account service-account-frontend-arge holds exactly: content:read schema:sync' 'arge SA not confirmed'
expect_line "$post" 'check: 1 change(s) pending, 0 warning(s), 0 problem(s)' 'unexpected post-cutover plan'
post=$(run_script --apply --post-cutover --client frontend-main) || { printf '%s\n' "$post" >&2; fail 'post-cutover --apply failed'; }
grep -E 'take |exactly|applied' <<<"$post" | sed 's/^/    /'
expect_line "$post" 'frontend-main: service account service-account-frontend-main holds exactly: content:read schema:sync' 'SA not left with exactly content:read + schema:sync'
expect_line "$post" 'applied 1 change(s), 0 warning(s), 0 problem(s)' 'post-cutover apply wrote something else'
access=$(access_of frontend-main client_credentials)
json_assert "$access" "(($CMS_ROLES) == [\"content:read\", \"schema:sync\"]) and ((.resource_access[\"frontend-main\"].roles | sort) == [\"content:read\", \"schema:sync\"])" \
  'the frontend-main service account token is not exactly content:read + schema:sync after --post-cutover'
printf '    frontend-main service account (after --post-cutover): roles=%s\n' "$(jq -c "$CMS_ROLES" <<<"$access")"
person_token_assert ykmember frontend-main "$all_editor" true
again=$(run_script --check --client frontend-main) || { printf '%s\n' "$again" >&2; fail 'post-cutover plain --check failed'; }
expect_line "$again" 'check: 0 change(s) pending, 0 warning(s), 0 problem(s)' 'a plain run wants cms:access back on the SA'

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
response=$(token_response frontend-main password ykmember)
json_assert "$(jwt_payload "$(jq -r .id_token <<<"$response")")" '.roles == null' 'repaired mapper still writes the ID token'
json_assert "$(jwt_payload "$(jq -r .access_token <<<"$response")")" '(.roles | index("content:write")) != null' \
  'repaired composite does not reach the token'

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='frontend-arge -> core audience'
before=$(access_of frontend-arge password leader)
json_assert "$before" '(.aud | if type == "array" then . else [.] end | index("core")) == null' \
  'fixture: the arge token already names core'
arge_core_scope=$(kcadm create client-scopes -r "$REALM" -i \
  -b '{"name":"frontend-arge-core-audience","protocol":"openid-connect","attributes":{"include.in.token.scope":"false","display.on.consent.screen":"false"}}')
jq -c '.[0]' "$REPOSITORY_ROOT/config/frontend-arge-core-audience-mappers.json" \
  | kcadm create "client-scopes/$arge_core_scope/protocol-mappers/models" -r "$REALM" -f - >/dev/null
kcadm update "clients/$arge_uuid/default-client-scopes/$arge_core_scope" -r "$REALM" -n -b '{}' >/dev/null
response=$(token_response frontend-arge password leader)
access=$(jwt_payload "$(jq -r .access_token <<<"$response")")
json_assert "$access" '.azp == "frontend-arge" and (.aud | if type == "array" then . else [.] end | (index("core") != null and index("skycms") != null))' \
  'the arge editor access token does not name both core and skycms'
json_assert "$access" '(.resource_access.core // null) == null' 'the arge editor unexpectedly holds a core role'
json_assert "$(jwt_payload "$(jq -r .id_token <<<"$response")")" '(.aud | if type == "array" then . else [.] end | index("core")) == null' \
  'the arge ID token names core'
printf '    frontend-arge leader after the core audience scope: aud=%s roles=%s\n' \
  "$(jq -c .aud <<<"$access")" "$(jq -c .roles <<<"$access")"

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='foreign claims'
foreign=$(run_failing --apply --client foreign-site)
printf '%s\n' "$foreign" | grep -E 'PROBLEM|applied' | sed 's/^/    /'
expect_line "$foreign" 'PROBLEM: foreign-site: something else already emits the claim roles (client mapper legacy-roles (oidc-hardcoded-claim-mapper))' 'foreign roles mapper not reported'
expect_line "$foreign" 'PROBLEM: foreign-site: the claim groups is emitted differently' 'flat groups not reported'
reject_line "$foreign" 'client:admin on foreign-site' 'client:admin spread to a non-site client'
foreign_mappers=$(kcadm get "clients/$foreign_uuid/protocol-mappers/models" -r "$REALM" | jq -c '[.[].name] | sort')
[[ $foreign_mappers == '["flat-groups","legacy-roles"]' ]] || fail "foreign-site mappers changed: $foreign_mappers"

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='sandbox realm'
kcadm create realms -s realm="$SANDBOX_REALM" -s enabled=true >/dev/null
kcadm create clients -r "$SANDBOX_REALM" -s clientId=superadmin -s publicClient=false >/dev/null
sandbox=$(RUN_REALM=$SANDBOX_REALM run_script --check) || { printf '%s\n' "$sandbox" >&2; fail 'sandbox --check failed'; }
printf '%s\n' "$sandbox" | grep -E 'realm=|NOTE|would|check:' | sed 's/^/    /'
expect_line "$sandbox" 'realm=e-skylab-sandbox mode=check clients=frontend-main frontend-arge superadmin' 'sandbox default clients'
expect_line "$sandbox" 'NOTE: client frontend-main does not exist in realm e-skylab-sandbox; skipped' 'missing sandbox site not skipped'
expect_line "$sandbox" 'NOTE: client frontend-arge does not exist in realm e-skylab-sandbox; skipped' 'missing sandbox site not skipped'
expect_line "$sandbox" 'would create client role content:write on superadmin' 'superadmin roles not planned'
reject_line "$sandbox" 'client role client:admin on superadmin' 'client:admin spread to superadmin'
reject_line "$sandbox" 'client role cms:access on superadmin' 'cms:access spread to superadmin'
expect_line "$sandbox" 'check: 5 change(s) pending, 0 warning(s), 0 problem(s)' 'unexpected sandbox plan'
sandbox=$(RUN_REALM=$SANDBOX_REALM run_script --apply) || { printf '%s\n' "$sandbox" >&2; fail 'sandbox --apply failed'; }
expect_line "$sandbox" 'applied 5 change(s), 0 warning(s), 0 problem(s)' 'sandbox apply'
sandbox=$(RUN_REALM=$SANDBOX_REALM run_script --check) || { printf '%s\n' "$sandbox" >&2; fail 'sandbox second --check failed'; }
expect_line "$sandbox" 'check: 0 change(s) pending, 0 warning(s), 0 problem(s)' 'sandbox second run plans changes'

printf 'inscribed-cms-roles.sh contract holds against %s.\n' "$IMAGE"
