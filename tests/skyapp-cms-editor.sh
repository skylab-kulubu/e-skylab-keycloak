#!/usr/bin/env bash
# Real-Keycloak contract for config/skyapp-cms-editor.sh (SkyApp edits the main site's news and team
# pages, ADR-0056 addendum of 2026-10-03), with config/inscribed-cms-roles.sh before it. Stand-alone:
# starts the stock Keycloak image this repository builds on (the Dockerfile's KEYCLOAK_IMAGE) in dev
# mode with docker run --rm and no volume, builds a small production-shaped realm e-skylab, runs the
# scripts inside that container the way the wizard does and reads real tokens. The container is
# removed on exit (docker rm -fv).
#
# The fixture realm e-skylab: skycms (confidential, no login); frontend-main (confidential, full
# scope, as in production) with the shared skycms-audience scope; skyapp (public, full scope,
# redirect com.yildizskylab.app:/oauth2redirect, as in production); a realm scope groups (full-path
# Group Membership) that both use; groups /ADMIN, /UYELER, /UYELER/YK, /UYELER/DK,
# /UYELER/ARGE/MOBILAB/LIDERLER, /UYELER/ESKI-EDITORLER; people in some of them. frontend-main's
# CMS roles come from inscribed-cms-roles.sh and are granted to groups as the admin panel does.
#
# What it proves:
#   - every realm but e-skylab and e-skylab-sandbox (and an unset KEYCLOAK_REALM) is refused before a
#     login (exit 2); a missing skyapp or source client role stops the run before any write (exit 1);
#   - --check writes nothing and plans skyapp's four roles, its cms:access composite, the two links
#     from frontend-main, the skycms-audience scope and the roles mapper; --apply writes exactly that,
#     grants no role to a group or a person and does not change frontend-main's own mappers; a second
#     run writes nothing;
#   - a SkyApp offline session (SkyApp's scopes) opened BEFORE the change gets, on its next refresh, an access token with azp
#     skyapp, aud ⊇ skycms, flat roles = cms:access + content:read + content:write,
#     resource_access.skyapp.roles ∋ cms:access (SkyApp's editor buttons) and full-path groups: no
#     new login is needed; ADMIN also gets client:admin; a plain member gets aud skycms and no CMS
#     role; the ID token carries no roles;
#   - the main site's own token is unchanged (its flat roles claim holds only frontend-main's roles);
#   - a direct grant of a skyapp CMS role is a WARNING and is not taken away;
#   - --revoke takes away only the two links: the next refresh carries no CMS role; --apply restores
#     them.
# Requirements on the host: docker, curl, jq, openssl, base64. SKYAPP_CMS_TEST_PORT (default 18095).
# The jq programs name jq variables ($t, $m), not shell ones:
# shellcheck disable=SC2016
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPOSITORY_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
EDITOR_SCRIPT="$REPOSITORY_ROOT/config/skyapp-cms-editor.sh"
ROLES_SCRIPT="$REPOSITORY_ROOT/config/inscribed-cms-roles.sh"
IMAGE=$(sed -n 's/^ARG KEYCLOAK_IMAGE=//p' "$REPOSITORY_ROOT/Dockerfile")
PORT=${SKYAPP_CMS_TEST_PORT:-18095}
BASE_URL="http://127.0.0.1:$PORT"
REALM=e-skylab
SANDBOX_REALM=e-skylab-sandbox
APP=skyapp
APP_CALLBACK=com.yildizskylab.app:/oauth2redirect
SITE_CALLBACK=https://yildizskylab.com/api/auth/callback/keycloak
CONTAINER="skyapp-cms-test-$$"
ADMIN_PASSWORD=harness-admin-password
PERSON_PASSWORD=harness-person-password
KCADM_CONFIG=/tmp/harness-kcadm.config
CURRENT_STAGE=startup

fail() {
  printf 'skyapp-cms-editor failure during %s: %s\n' "$CURRENT_STAGE" "$1" >&2
  exit 1
}
cleanup() {
  docker rm -fv "$CONTAINER" >/dev/null 2>&1 || true
}
trap 'status=$?; trap - EXIT; cleanup; exit "$status"' EXIT
on_error() {
  local status=$?
  printf 'skyapp-cms-editor command failed during %s (line %s)\n' "$CURRENT_STAGE" "$1" >&2
  exit "$status"
}
trap 'on_error "$LINENO"' ERR

kcadm() {
  local command=$1
  shift
  docker exec -i "$CONTAINER" /opt/keycloak/bin/kcadm.sh "$command" --config "$KCADM_CONFIG" "$@" \
    2> >(grep -v -e '^Created new ' -e '^$' >&2 || true)
}

# run SCRIPT REALM ARGS...: an operator script inside the container with the harness's kcadm session.
run() {
  local script=$1 realm=$2
  shift 2
  docker exec -e KEYCLOAK_ADMIN_URL=http://localhost:8080 -e KEYCLOAK_REALM="$realm" "$CONTAINER" \
    bash "/tmp/$script" --kcadm-config "$KCADM_CONFIG" "$@" 2>&1
}
run_expecting() {
  local wanted=$1 output status=0
  shift
  trap - ERR
  output=$(run "$@") || status=$?
  trap 'on_error "$LINENO"' ERR
  [[ $status == "$wanted" ]] || { printf '%s\n' "$output" >&2; fail "$1 did not exit $wanted (exit $status)"; }
  printf '%s\n' "$output"
}
editor() { run skyapp-cms-editor.sh "$REALM" "$@"; }

expect_line() {
  grep -Fq -- "$2" <<<"$1" || { printf '%s\n' "$1" >&2; fail "$3: $2"; }
}
reject_line() {
  if grep -Fq -- "$2" <<<"$1"; then printf '%s\n' "$1" >&2; fail "$3: $2"; fi
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
  kcadm get admin-events -r "${1:-$REALM}" -q max=1 | jq -r '.[0].time // 0'
}
jwt_payload() {
  local segment
  segment=$(cut -d. -f2 <<<"$1" | tr '_-' '/+')
  case $(( ${#segment} % 4 )) in 2) segment+='==' ;; 3) segment+='=' ;; esac
  base64 -d <<<"$segment"
}
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# login CLIENT CALLBACK USER VERIFIER [SCOPE]: the authorization code of a real browser login with
# PKCE S256.
login() {
  local client=$1 callback=$2 user=$3 verifier=$4 scope=${5:-openid} jar page action headers location code challenge
  challenge=$(printf '%s' "$verifier" | openssl dgst -sha256 -binary | b64url)
  jar=$(mktemp "${TMPDIR:-/tmp}/skyapp-cms-jar.XXXXXX")
  page=$(curl -fsS -c "$jar" -b "$jar" -G "$BASE_URL/realms/$REALM/protocol/openid-connect/auth" \
    --data-urlencode "client_id=$client" --data-urlencode response_type=code \
    --data-urlencode "scope=$scope" --data-urlencode "redirect_uri=$callback" \
    --data-urlencode state=harness-state --data-urlencode "code_challenge=$challenge" \
    --data-urlencode code_challenge_method=S256)
  action=$(sed -n 's/.*id="kc-form-login"[^>]*action="\([^"]*\)".*/\1/p' <<<"$page" | head -n 1 | sed 's/&amp;/\&/g')
  [[ -n $action ]] || { rm -f "$jar"; fail "no login form for $user"; }
  headers=$(curl -sS -c "$jar" -b "$jar" -o /dev/null -D - \
    --data-urlencode "username=$user" --data-urlencode "password=$PERSON_PASSWORD" "$action")
  rm -f "$jar"
  location=$(tr -d '\r' <<<"$headers" | sed -n 's/^[Ll]ocation: //p' | head -n 1)
  [[ $location == "$callback?"* ]] || fail "the login of $user did not return to $callback ($location)"
  code=$(sed -n 's/.*[?&]code=\([^&]*\).*/\1/p' <<<"$location")
  [[ -n $code ]] || fail "no authorization code for $user"
  printf '%s' "$code"
}

# app_tokens USER: SkyApp's token response (public client, PKCE, no secret, SkyApp's own scopes: an
# offline session, as the app keeps it).
app_tokens() {
  local verifier code
  verifier=$(openssl rand -hex 32)
  code=$(login "$APP" "$APP_CALLBACK" "$1" "$verifier" 'openid profile email offline_access')
  curl -fsS "$BASE_URL/realms/$REALM/protocol/openid-connect/token" \
    --data-urlencode grant_type=authorization_code --data-urlencode "code=$code" \
    --data-urlencode "redirect_uri=$APP_CALLBACK" --data-urlencode "client_id=$APP" \
    --data-urlencode "code_verifier=$verifier"
}
# app_refresh REFRESH_TOKEN: SkyApp's refresh (public client).
app_refresh() {
  curl -fsS "$BASE_URL/realms/$REALM/protocol/openid-connect/token" \
    --data-urlencode grant_type=refresh_token --data-urlencode "client_id=$APP" \
    --data-urlencode "refresh_token=$1"
}
# site_tokens USER: the main site's token response (confidential, PKCE, secret on stdin).
site_tokens() {
  local verifier code
  verifier=$(openssl rand -hex 32)
  code=$(login frontend-main "$SITE_CALLBACK" "$1" "$verifier")
  kcadm get "clients/$(client_uuid frontend-main)/client-secret" -r "$REALM" | jq -j .value \
    | curl -fsS "$BASE_URL/realms/$REALM/protocol/openid-connect/token" \
      --data-urlencode grant_type=authorization_code --data-urlencode "code=$code" \
      --data-urlencode "redirect_uri=$SITE_CALLBACK" --data-urlencode client_id=frontend-main \
      --data-urlencode "code_verifier=$verifier" --data-urlencode 'client_secret@-'
}
access_of() { jwt_payload "$(jq -r .access_token <<<"$1")"; }

CMS_ROLES='(.roles // []) | map(select(startswith("content:") or . == "cms:access" or . == "schema:sync" or . == "client:admin")) | sort'
APP_GATE='(.resource_access.skyapp.roles // []) | index("cms:access") != null'
AUD='(.aud // []) | if type == "array" then . else [.] end'

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='Keycloak start'
[[ -n $IMAGE ]] || fail 'Dockerfile has no ARG KEYCLOAK_IMAGE'
for tool in jq curl openssl; do command -v "$tool" >/dev/null || fail "$tool is required"; done
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
docker exec -i "$CONTAINER" sh -c 'cat > /tmp/skyapp-cms-editor.sh' <"$EDITOR_SCRIPT"
docker exec -i "$CONTAINER" sh -c 'cat > /tmp/inscribed-cms-roles.sh' <"$ROLES_SCRIPT"

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='only the club realms'
for realm in '' master other-realm; do
  refused=$(run_expecting 2 skyapp-cms-editor.sh "$realm" --apply)
  expect_line "$refused" "refusing realm ${realm:-(unset)}" 'realm not refused'
  reject_line "$refused" 'realm=' 'the refused run went on'
done
printf '    unset, master and other-realm refused (exit 2) before a login\n'

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='fixture realm'
kcadm create realms -s realm="$REALM" -s enabled=true -s adminEventsEnabled=true >/dev/null
group() { # group PARENT_ID|'' NAME -> id
  if [[ -z $1 ]]; then kcadm create groups -r "$REALM" -i -s "name=$2"; else kcadm create "groups/$1/children" -r "$REALM" -i -s "name=$2"; fi
}
admin_group=$(group '' ADMIN)
uyeler=$(group '' UYELER)
yk=$(group "$uyeler" YK)
dk=$(group "$uyeler" DK)
arge=$(group "$uyeler" ARGE)
mobilab=$(group "$arge" MOBILAB)
mobilab_leaders=$(group "$mobilab" LIDERLER)
stale_editors=$(group "$uyeler" ESKI-EDITORLER)
person() {
  local uuid
  uuid=$(kcadm create users -r "$REALM" -i -s "username=$1" -s enabled=true -s "email=$1@example.invalid" \
    -s emailVerified=true -s firstName=Harness -s "lastName=$1")
  kcadm set-password -r "$REALM" --userid "$uuid" --new-password "$PERSON_PASSWORD" >/dev/null
  kcadm update "users/$uuid/groups/$2" -r "$REALM" -n -b '{}' >/dev/null
}
person boss "$admin_group"
person ykmember "$yk"
person mobilead "$mobilab_leaders"
person member "$uyeler"
kcadm create clients -r "$REALM" -s clientId=skycms -s publicClient=false -s standardFlowEnabled=false >/dev/null
kcadm create clients -r "$REALM" -s clientId=frontend-main -s publicClient=false -s fullScopeAllowed=true \
  -s serviceAccountsEnabled=true -s "redirectUris=[\"https://yildizskylab.com/*\"]" >/dev/null
kcadm create clients -r "$REALM" -s clientId="$APP" -s publicClient=true -s fullScopeAllowed=true \
  -s standardFlowEnabled=true -s directAccessGrantsEnabled=false \
  -s "redirectUris=[\"$APP_CALLBACK\",\"https://app.yildizskylab.com/*\"]" >/dev/null
main=$(client_uuid frontend-main)
app=$(client_uuid "$APP")
# The realm scope groups (full path) and the shared skycms-audience scope, production's shapes.
groups_scope=$(kcadm create client-scopes -r "$REALM" -i -s name=groups -s protocol=openid-connect)
kcadm create "client-scopes/$groups_scope/protocol-mappers/models" -r "$REALM" -b '{"name":"groups","protocol":"openid-connect","protocolMapper":"oidc-group-membership-mapper","config":{"claim.name":"groups","full.path":"true","multivalued":"true","access.token.claim":"true","id.token.claim":"true","userinfo.token.claim":"true","introspection.token.claim":"true"}}' >/dev/null
audience_scope=$(kcadm create client-scopes -r "$REALM" -i -s name=skycms-audience -s protocol=openid-connect)
kcadm create "client-scopes/$audience_scope/protocol-mappers/models" -r "$REALM" -b '{"name":"audience-mapper","protocol":"openid-connect","protocolMapper":"oidc-audience-mapper","config":{"included.client.audience":"skycms","access.token.claim":"true","id.token.claim":"false","introspection.token.claim":"true"}}' >/dev/null
for client in "$main" "$app"; do
  kcadm update "clients/$client/default-client-scopes/$groups_scope" -r "$REALM" -n -b '{}' >/dev/null
done
kcadm update "clients/$main/default-client-scopes/$audience_scope" -r "$REALM" -n -b '{}' >/dev/null
out=$(run inscribed-cms-roles.sh "$REALM" --apply --client frontend-main) || { printf '%s\n' "$out" >&2; fail 'inscribed-cms-roles.sh failed'; }
# The admin panel's grants: cms:access to the Privileged groups and the Leader group, client:admin to ADMIN.
grant() { # grant CLIENT_UUID ROLE GROUP_ID
  kcadm create "groups/$3/role-mappings/clients/$1" -r "$REALM" \
    -b "$(kcadm get "clients/$1/roles/$2" -r "$REALM" | jq -c '[{id, name}]')" >/dev/null
}
for gid in "$admin_group" "$yk" "$dk" "$mobilab_leaders"; do grant "$main" cms:access "$gid"; done
grant "$main" client:admin "$admin_group"
main_mappers_before=$(kcadm get "clients/$main/protocol-mappers/models" -r "$REALM" | jq -c 'map({name, config}) | sort_by(.name)')

CURRENT_STAGE='a SkyApp session opened before the change'
before=$(app_tokens mobilead)
old_refresh=$(jq -r .refresh_token <<<"$before")
json_assert "$(jwt_payload "$old_refresh")" '.typ == "Offline"' 'SkyApp did not get an offline session'
access=$(access_of "$before")
json_assert "$access" ".azp == \"$APP\" and ((($AUD) | index(\"skycms\")) == null) and .roles == null" \
  'before the change SkyApp already had aud skycms or a roles claim'
printf '    before: aud=%s roles=%s skyapp gate=%s\n' "$(jq -c "$AUD" <<<"$access")" "$(jq -c .roles <<<"$access")" "$(jq -c "$APP_GATE" <<<"$access")"

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='missing prerequisites'
event_before=$(newest_admin_event)
sleep 1
missing=$(run_expecting 1 skyapp-cms-editor.sh "$REALM" --apply --editors-from frontend-arge)
expect_line "$missing" 'MISSING: client frontend-arge (the editors'"'"' source) does not exist in realm e-skylab' 'missing source not reported'
expect_line "$missing" 'nothing was changed: 1 prerequisite(s) missing' 'missing run went on'
[[ $(newest_admin_event) == "$event_before" ]] || fail 'a run with a missing prerequisite wrote to the realm'
bad=$(run_expecting 2 skyapp-cms-editor.sh "$REALM" --editors-from skyapp)
expect_line "$bad" 'bad --editors-from skyapp' 'a non-site source was accepted'
kcadm create realms -s realm="$SANDBOX_REALM" -s enabled=true >/dev/null
missing=$(run_expecting 1 skyapp-cms-editor.sh "$SANDBOX_REALM" --apply)
expect_line "$missing" "MISSING: client $APP does not exist in realm $SANDBOX_REALM" 'missing skyapp not reported'
expect_line "$missing" "MISSING: client skycms (inscribed's audience) does not exist in realm $SANDBOX_REALM" 'missing skycms not reported'
expect_line "$missing" 'MISSING: client scope skycms-audience does not exist' 'missing scope not reported'
printf '    a missing source client, skyapp, skycms or scope stops the run before any write (exit 1)\n'

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='--check writes nothing'
event_before=$(newest_admin_event)
sleep 1
check=$(editor --check) || { printf '%s\n' "$check" >&2; fail '--check failed'; }
printf '%s\n' "$check" | sed 's/^/    /'
[[ $(newest_admin_event) == "$event_before" ]] || fail '--check wrote to the realm'
expect_line "$check" 'realm=e-skylab mode=check editors-from=frontend-main' 'unexpected header'
expect_line "$check" 'skyapp: publicClient=true fullScopeAllowed=true (left as is)' 'client flags not reported'
for role in content:read content:write cms:access client:admin; do
  expect_line "$check" "would create client role $role on skyapp" "$role not planned"
done
expect_line "$check" 'would make skyapp/cms:access include skyapp/content:write' 'skyapp composite not planned'
expect_line "$check" 'would make frontend-main/cms:access include skyapp/cms:access' 'editor link not planned'
expect_line "$check" 'would make frontend-main/client:admin include skyapp/client:admin' 'admin link not planned'
expect_line "$check" 'would attach skycms-audience as a default scope of skyapp' 'audience scope not planned'
expect_line "$check" 'would add mapper inscribed-roles to skyapp (User Client Role' 'roles mapper not planned'
expect_line "$check" 'skyapp: groups (full path) comes from default scope groups mapper groups' 'groups source not found'
expect_line "$check" 'frontend-main/cms:access <- /ADMIN /UYELER/ARGE/MOBILAB/LIDERLER /UYELER/DK /UYELER/YK' 'editors not reported'
# 4 roles, 2 for skyapp's cms:access, 2 links, the scope, the mapper.
expect_line "$check" 'check: 10 change(s) pending, 0 warning(s), 0 problem(s)' 'unexpected plan size'

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='--apply'
event_before=$(newest_admin_event)
apply=$(editor --apply) || { printf '%s\n' "$apply" >&2; fail '--apply failed'; }
expect_line "$apply" 'applied 10 change(s), 0 warning(s), 0 problem(s)' 'apply did not write the plan'
json_assert "$(kcadm get admin-events -r "$REALM" -q max=1000)" \
  '[.[] | select(.time > $t and (.resourceType == "CLIENT_ROLE_MAPPING" or .resourceType == "REALM_ROLE_MAPPING"))] | length == 0' \
  'the script granted a role to a group or a person' --argjson t "$event_before"
[[ $(kcadm get "clients/$main/protocol-mappers/models" -r "$REALM" | jq -c 'map({name, config}) | sort_by(.name)') == "$main_mappers_before" ]] \
  || fail "frontend-main's mappers changed"
json_assert "$(kcadm get "clients/$app" -r "$REALM")" '.publicClient and .fullScopeAllowed and (.redirectUris | sort) == ["com.yildizskylab.app:/oauth2redirect","https://app.yildizskylab.com/*"]' \
  "skyapp's flags or redirects changed"
json_assert "$(kcadm get "clients/$app/roles/cms:access/composites" -r "$REALM")" '[.[].name] | sort == ["content:read","content:write"]' \
  "skyapp's cms:access is not content:read + content:write"

CURRENT_STAGE='second run is a no-op'
event_before=$(newest_admin_event)
sleep 1
again=$(editor --apply) || { printf '%s\n' "$again" >&2; fail 'second --apply failed'; }
expect_line "$again" 'applied 0 change(s), 0 warning(s), 0 problem(s)' 'second --apply wrote'
[[ $(newest_admin_event) == "$event_before" ]] || fail 'the second run wrote to the realm'
printf '    second --apply: 0 change(s), no admin event\n'

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='tokens'
refreshed=$(app_refresh "$old_refresh") || fail 'the old SkyApp session could not refresh'
access=$(access_of "$refreshed")
json_assert "$access" ".azp == \"$APP\" and ((($AUD) | index(\"skycms\")) != null)" 'the refreshed SkyApp token has no aud skycms'
json_assert "$access" "($CMS_ROLES) == [\"cms:access\", \"content:read\", \"content:write\"]" 'the leader'"'"'s SkyApp roles are not cms:access + content:*'
json_assert "$access" "$APP_GATE" 'resource_access.skyapp.roles has no cms:access (SkyApp'"'"'s buttons stay hidden)'
json_assert "$access" '.groups == ["/UYELER/ARGE/MOBILAB/LIDERLER"]' 'the SkyApp token has no full-path groups'
printf '    mobilead, old session refreshed: aud=%s roles=%s groups=%s skyapp gate=%s\n' "$(jq -c "$AUD" <<<"$access")" \
  "$(jq -c "$CMS_ROLES" <<<"$access")" "$(jq -c .groups <<<"$access")" "$(jq -c "$APP_GATE" <<<"$access")"
response=$(app_tokens boss)
access=$(access_of "$response")
json_assert "$access" "($CMS_ROLES) == [\"client:admin\", \"cms:access\", \"content:read\", \"content:write\"]" 'ADMIN'"'"'s SkyApp roles are wrong'
json_assert "$(jwt_payload "$(jq -r .id_token <<<"$response")")" '.roles == null' 'the ID token carries roles'
access=$(access_of "$(app_tokens ykmember)")
json_assert "$access" "($CMS_ROLES) == [\"cms:access\", \"content:read\", \"content:write\"]" 'YK is no SkyApp editor'
access=$(access_of "$(app_tokens member)")
json_assert "$access" "((($AUD) | index(\"skycms\")) != null) and (($CMS_ROLES) == []) and (($APP_GATE) | not)" 'a plain member got a CMS role'
printf '    member: aud=%s roles=%s skyapp gate=%s\n' "$(jq -c "$AUD" <<<"$access")" "$(jq -c "$CMS_ROLES" <<<"$access")" "$(jq -c "$APP_GATE" <<<"$access")"
access=$(access_of "$(site_tokens mobilead)")
json_assert "$access" ".azp == \"frontend-main\" and (($CMS_ROLES) == [\"cms:access\", \"content:read\", \"content:write\"])" \
  "the main site's flat roles claim changed"
printf '    mobilead @ frontend-main: roles=%s (its own, unchanged)\n' "$(jq -c "$CMS_ROLES" <<<"$access")"

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='a direct grant is a WARNING'
grant "$app" cms:access "$stale_editors"
out=$(editor --apply) || { printf '%s\n' "$out" >&2; fail 'run with a direct grant failed'; }
expect_line "$out" 'WARNING: skyapp/cms:access is granted directly to the group(s) /UYELER/ESKI-EDITORLER' 'direct grant not reported'
expect_line "$out" 'applied 0 change(s), 1 warning(s), 0 problem(s)' 'the direct grant changed the plan'
[[ $(kcadm get "groups/$stale_editors/role-mappings/clients/$app" -r "$REALM" | jq 'length') == 1 ]] || fail 'the direct grant was taken away'
kcadm delete "groups/$stale_editors/role-mappings/clients/$app" -r "$REALM" \
  -b "$(kcadm get "clients/$app/roles/cms:access" -r "$REALM" | jq -c '[{id, name}]')" >/dev/null

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='--revoke'
session=$(app_tokens mobilead)
out=$(editor --apply --revoke) || { printf '%s\n' "$out" >&2; fail '--revoke failed'; }
expect_line "$out" 'take skyapp/cms:access out of frontend-main/cms:access' 'editor link not taken away'
expect_line "$out" 'applied 2 change(s), 0 warning(s), 0 problem(s)' 'revoke did more than the two links'
access=$(access_of "$(app_refresh "$(jq -r .refresh_token <<<"$session")")")
json_assert "$access" "(($CMS_ROLES) == []) and (($APP_GATE) | not)" 'after --revoke the refreshed token still has CMS roles'
printf '    after --revoke the next refresh: roles=%s skyapp gate=%s\n' "$(jq -c "$CMS_ROLES" <<<"$access")" "$(jq -c "$APP_GATE" <<<"$access")"
out=$(editor --apply) || { printf '%s\n' "$out" >&2; fail 're-apply failed'; }
expect_line "$out" 'applied 2 change(s), 0 warning(s), 0 problem(s)' 're-apply did not restore exactly the two links'
access=$(access_of "$(app_tokens mobilead)")
json_assert "$access" "($CMS_ROLES) == [\"cms:access\", \"content:read\", \"content:write\"]" 're-apply did not restore the roles'

printf 'skyapp-cms-editor.sh contract holds against %s.\n' "$IMAGE"
