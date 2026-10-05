#!/usr/bin/env bash
# Real-Keycloak contract for config/site-clients.sh and config/site-editor-grants.sh (the event
# sites' Site clients, ADR-0056 addendum of 2026-10-03), with config/inscribed-cms-roles.sh between
# them. Stand-alone: starts the stock Keycloak image this repository builds on (the Dockerfile's
# KEYCLOAK_IMAGE) in dev mode with docker run --rm and no volume, builds a small production-shaped
# realm e-skylab and a sandbox realm, runs the scripts inside that container the way the wizard
# does and reads real tokens. The container is removed on exit (docker rm -fv).
#
# The fixture realm e-skylab: skycms and core (confidential, no login), a hand-made frontend-main,
# Keycloak's own microprofile-jwt scope (its mapper writes realm roles into the claim groups) made a
# realm default scope, groups /ADMIN, /UYELER, /UYELER/YK, /UYELER/DK,
# /UYELER/ARGE/AIRLAB/{LIDERLER,KOORDINATORLER}, /UYELER/ARGE/GAMELAB/LIDERLER and
# /UYELER/ORGANIZASYON/ARTLAB/LIDERLER, /UYELER/ESKI-EDITORLER (nobody in it), people in some of
# them. /UYELER is a default group.
#
# What it proves:
#   - every realm but e-skylab and e-skylab-sandbox (and an unset KEYCLOAK_REALM) is refused before
#     a login (exit 2); without the skycms client nothing is written (exit 1);
#   - --check writes nothing and plans the shared skycms-audience scope, the three clients, their
#     core scopes, the groups mapper and the detaching of microprofile-jwt; --apply writes exactly
#     that and grants no role; the clients are confidential, PKCE S256, fullScopeAllowed=false,
#     redirect exactly https://<site>/api/auth/callback/keycloak; the realm keeps microprofile-jwt
#     as a default scope and frontend-main is not written; a second run writes nothing;
#   - inscribed-cms-roles.sh --client frontend-artlab makes cms:access and client:admin on the event
#     site and gives the service account content:read + schema:sync only;
#   - site-editor-grants.sh grants cms:access to /ADMIN, /UYELER/YK, /UYELER/DK and, by default, the
#     Leader groups of the owning lab team and of the event's organization team, client:admin to
#     /ADMIN only, nothing to a person; a --team adds a team; a missing organization team is a
#     WARNING; a holder outside the set is a WARNING and is not taken away; a second run writes
#     nothing; a site without roles is reported (exit 1);
#   - a real authorization code flow with PKCE (as NextAuth runs it) gives an AIRLAB leader an
#     access token with azp frontend-artlab, aud ⊇ {skycms, core}, full-path groups, roles ⊇
#     {cms:access, content:read, content:write} and the editor gate open; a GAMELAB leader who edits
#     YıldızJam gets no CMS role and a shut gate on ARTLAB (Full scope off); a leader of the ARTLAB
#     organization team is an editor; the flow without PKCE,
#     a localhost and a foreign redirect URI are refused; the service account token carries
#     content:read + schema:sync, no content:write;
#   - drift (Full scope on, a localhost redirect) is repaired and the extra URI removed;
#   - in the sandbox realm the origin is sandbox-<site>, a missing core client is a NOTE, the
#     Privileged group /UYELER/ADMIN is found and missing teams are WARNINGs;
#   - --site main is refused in e-skylab (production's frontend-main is hand-made) by both scripts
#     before a login; in the sandbox realm it makes frontend-main in the event sites' shape with the
#     origin https://sandbox.yildizskylab.com, its editors are the Privileged groups only, an ADMIN
#     member's token through it carries cms:access + client:admin, its service account stays
#     content:read + schema:sync, and a second run writes nothing;
#   - the client secret is never printed.
# Requirements on the host: docker, curl, jq, openssl, base64. SITE_CLIENTS_TEST_PORT (default 18093).
# The jq programs name jq variables ($s, $t), not shell ones:
# shellcheck disable=SC2016
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPOSITORY_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
CLIENTS_SCRIPT="$REPOSITORY_ROOT/config/site-clients.sh"
GRANTS_SCRIPT="$REPOSITORY_ROOT/config/site-editor-grants.sh"
ROLES_SCRIPT="$REPOSITORY_ROOT/config/inscribed-cms-roles.sh"
CORE_MAPPERS_FILE="$REPOSITORY_ROOT/config/frontend-arge-core-audience-mappers.json"
IMAGE=$(sed -n 's/^ARG KEYCLOAK_IMAGE=//p' "$REPOSITORY_ROOT/Dockerfile")
PORT=${SITE_CLIENTS_TEST_PORT:-18093}
BASE_URL="http://127.0.0.1:$PORT"
REALM=e-skylab
SANDBOX_REALM=e-skylab-sandbox
CLIENT=frontend-artlab
SITE=https://artlab.yildizskylab.com
CALLBACK="$SITE/api/auth/callback/keycloak"
CONTAINER="site-clients-test-$$"
ADMIN_PASSWORD=harness-admin-password
PERSON_PASSWORD=harness-person-password
KCADM_CONFIG=/tmp/harness-kcadm.config
OUTPUTS=$(mktemp "${TMPDIR:-/tmp}/site-clients-outputs.XXXXXX")
CURRENT_STAGE=startup

fail() {
  printf 'site-clients failure during %s: %s\n' "$CURRENT_STAGE" "$1" >&2
  exit 1
}
cleanup() {
  docker rm -fv "$CONTAINER" >/dev/null 2>&1 || true
  rm -f "$OUTPUTS"
}
trap 'status=$?; trap - EXIT; cleanup; exit "$status"' EXIT
on_error() {
  local status=$?
  printf 'site-clients command failed during %s (line %s)\n' "$CURRENT_STAGE" "$1" >&2
  exit "$status"
}
trap 'on_error "$LINENO"' ERR

kcadm() {
  local command=$1
  shift
  docker exec -i "$CONTAINER" /opt/keycloak/bin/kcadm.sh "$command" --config "$KCADM_CONFIG" "$@" \
    2> >(grep -v -e '^Created new ' -e '^$' >&2 || true)
}

# run SCRIPT REALM ARGS...: an operator script inside the container with the harness's kcadm
# session. Prints the output (also kept in OUTPUTS for the secret check); returns its status.
run() {
  local script=$1 realm=$2 output status=0
  shift 2
  output=$(docker exec -e KEYCLOAK_ADMIN_URL=http://localhost:8080 -e KEYCLOAK_REALM="$realm" "$CONTAINER" \
    bash "/tmp/$script" --kcadm-config "$KCADM_CONFIG" "$@" 2>&1) || status=$?
  printf '%s\n' "$output" >>"$OUTPUTS"
  printf '%s\n' "$output"
  return "$status"
}
# run_expecting STATUS SCRIPT REALM ARGS...
run_expecting() {
  local wanted=$1 output status=0
  shift
  trap - ERR
  output=$(run "$@") || status=$?
  trap 'on_error "$LINENO"' ERR
  [[ $status == "$wanted" ]] || { printf '%s\n' "$output" >&2; fail "$1 did not exit $wanted (exit $status)"; }
  printf '%s\n' "$output"
}
clients() { run site-clients.sh "${RUN_REALM:-$REALM}" "$@"; }
grants() { run site-editor-grants.sh "${RUN_REALM:-$REALM}" "$@"; }
roles() { run inscribed-cms-roles.sh "${RUN_REALM:-$REALM}" "$@"; }

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
scope_uuids() {
  kcadm get client-scopes -r "${2:-$REALM}" | jq -r --arg name "$1" '.[] | select(.name == $name) | .id'
}
newest_admin_event() {
  kcadm get admin-events -r "${1:-$REALM}" -q max=1 | jq -r '.[0].time // 0'
}
client_secret() { # client_secret CLIENT [REALM]
  kcadm get "clients/$(client_uuid "$1" "${2:-$REALM}")/client-secret" -r "${2:-$REALM}" | jq -j .value
}
jwt_payload() {
  local segment
  segment=$(cut -d. -f2 <<<"$1" | tr '_-' '/+')
  case $(( ${#segment} % 4 )) in 2) segment+='==' ;; 3) segment+='=' ;; esac
  base64 -d <<<"$segment"
}
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# code_flow_response CLIENT USER [REALM SITE]: the person's token response from the real
# authorization code flow with PKCE S256 (as NextAuth's Keycloak provider runs it); the code is
# exchanged with the secret.
code_flow_response() {
  local client=$1 user=$2 realm=${3:-$REALM} site=${4:-} callback jar page action location code verifier challenge
  [[ -n $site ]] || site="https://${client#frontend-}.yildizskylab.com"
  callback="$site/api/auth/callback/keycloak"
  verifier=$(openssl rand -hex 32)
  challenge=$(printf '%s' "$verifier" | openssl dgst -sha256 -binary | b64url)
  jar=$(mktemp "${TMPDIR:-/tmp}/site-clients-jar.XXXXXX")
  page=$(curl -fsS -c "$jar" -b "$jar" -G "$BASE_URL/realms/$realm/protocol/openid-connect/auth" \
    --data-urlencode "client_id=$client" --data-urlencode response_type=code \
    --data-urlencode 'scope=openid email profile' --data-urlencode "redirect_uri=$callback" \
    --data-urlencode state=harness-state --data-urlencode "code_challenge=$challenge" \
    --data-urlencode code_challenge_method=S256)
  action=$(sed -n 's/.*id="kc-form-login"[^>]*action="\([^"]*\)".*/\1/p' <<<"$page" | head -n 1 | sed 's/&amp;/\&/g')
  [[ -n $action ]] || { rm -f "$jar"; fail "no login form for $user"; }
  location=$(curl -sS -c "$jar" -b "$jar" -o /dev/null -w '%{redirect_url}' \
    --data-urlencode "username=$user" --data-urlencode "password=$PERSON_PASSWORD" "$action")
  rm -f "$jar"
  [[ $location == "$callback?"* ]] || fail "the login of $user did not return to $callback ($location)"
  code=$(sed -n 's/.*[?&]code=\([^&]*\).*/\1/p' <<<"$location")
  [[ -n $code ]] || fail "no authorization code for $user"
  client_secret "$client" "$realm" | curl -fsS "$BASE_URL/realms/$realm/protocol/openid-connect/token" \
    --data-urlencode grant_type=authorization_code --data-urlencode "code=$code" \
    --data-urlencode "redirect_uri=$callback" --data-urlencode "client_id=$client" \
    --data-urlencode "code_verifier=$verifier" --data-urlencode 'client_secret@-'
}

CMS_ROLES='(.roles // []) | map(select(startswith("content:") or . == "cms:access" or . == "schema:sync" or . == "client:admin")) | sort'
EDITOR_GATE='[.resource_access // {} | .[] | .roles // [] | .[]] | index("cms:access") != null'
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
docker exec -i "$CONTAINER" sh -c 'cat > /tmp/site-clients.sh' <"$CLIENTS_SCRIPT"
docker exec -i "$CONTAINER" sh -c 'cat > /tmp/site-editor-grants.sh' <"$GRANTS_SCRIPT"
docker exec -i "$CONTAINER" sh -c 'cat > /tmp/inscribed-cms-roles.sh' <"$ROLES_SCRIPT"

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='only the club realms'
for realm in '' master other-realm; do
  for script in site-clients.sh site-editor-grants.sh; do
    refused=$(run_expecting 2 "$script" "$realm" --apply)
    expect_line "$refused" "refusing realm ${realm:-(unset)}" 'realm not refused'
    reject_line "$refused" 'realm=' 'the refused run went on'
  done
done
printf '    unset, master and other-realm refused (exit 2) before a login\n'
for script in site-clients.sh site-editor-grants.sh; do
  refused=$(run_expecting 2 "$script" "$REALM" --apply --site main)
  expect_line "$refused" 'refusing --site main in realm e-skylab' '--site main not refused in production'
  reject_line "$refused" 'realm=' 'the refused --site main run went on'
done
printf '    --site main refused in e-skylab (exit 2) before a login\n'

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='fixture realm'
kcadm create realms -s realm="$REALM" -s enabled=true -s adminEventsEnabled=true >/dev/null
group() { # group PARENT_ID|'' NAME -> id
  if [[ -z $1 ]]; then kcadm create groups -r "$REALM" -i -s "name=$2"; else kcadm create "groups/$1/children" -r "$REALM" -i -s "name=$2"; fi
}
admin_group=$(group '' ADMIN)
uyeler=$(group '' UYELER)
yk=$(group "$uyeler" YK)
group "$uyeler" DK >/dev/null
arge=$(group "$uyeler" ARGE)
airlab=$(group "$arge" AIRLAB)
airlab_leaders=$(group "$airlab" LIDERLER)
group "$airlab" KOORDINATORLER >/dev/null
gamelab=$(group "$arge" GAMELAB)
gamelab_leaders=$(group "$gamelab" LIDERLER)
organizasyon=$(group "$uyeler" ORGANIZASYON)
org_artlab=$(group "$organizasyon" ARTLAB)
org_artlab_leaders=$(group "$org_artlab" LIDERLER)
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
person airlead "$airlab_leaders"
person gamelead "$gamelab_leaders"
person orglead "$org_artlab_leaders"
person member "$uyeler"
# After the people: a default group joins only users made later.
kcadm update "default-groups/$uyeler" -r "$REALM" -n -b '{}' >/dev/null
# Keycloak's microprofile-jwt shape (realm roles into the claim groups), as a realm default scope.
mp=$(scope_uuids microprofile-jwt)
[[ -n $mp ]] || fail 'the realm has no microprofile-jwt scope'
json_assert "$(kcadm get "client-scopes/$mp/protocol-mappers/models" -r "$REALM")" \
  'any(.[]; .config["claim.name"] == "groups" and .protocolMapper == "oidc-usermodel-realm-role-mapper")' \
  'microprofile-jwt does not write realm roles into groups'
kcadm delete "default-optional-client-scopes/$mp" -r "$REALM" >/dev/null 2>&1 || true
kcadm update "default-default-client-scopes/$mp" -r "$REALM" -n -b '{}' >/dev/null
kcadm create clients -r "$REALM" -s clientId=frontend-main -s publicClient=false -s fullScopeAllowed=true \
  -s 'redirectUris=["https://yildizskylab.com/*"]' >/dev/null

CURRENT_STAGE='missing skycms client'
event_before=$(newest_admin_event)
sleep 1
missing=$(run_expecting 1 site-clients.sh "$REALM" --apply)
expect_line "$missing" 'the skycms client (inscribed'"'"'s audience) does not exist in realm e-skylab; nothing was changed' 'missing skycms not reported'
[[ $(newest_admin_event) == "$event_before" ]] || fail 'a run without skycms wrote to the realm'
kcadm create clients -r "$REALM" -s clientId=skycms -s publicClient=false -s standardFlowEnabled=false >/dev/null
kcadm create clients -r "$REALM" -s clientId=core -s publicClient=false -s standardFlowEnabled=false >/dev/null

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='--check writes nothing'
event_before=$(newest_admin_event)
sleep 1
check=$(clients --check) || { printf '%s\n' "$check" >&2; fail '--check failed'; }
printf '%s\n' "$check" | sed 's/^/    /'
[[ $(newest_admin_event) == "$event_before" ]] || fail '--check wrote to the realm'
expect_line "$check" 'realm=e-skylab mode=check clients=frontend-artlab frontend-yildizjam frontend-skydays' 'unexpected header'
expect_line "$check" 'would create client scope skycms-audience' 'shared skycms scope not planned'
expect_line "$check" 'would create confidential client frontend-artlab (standard flow with PKCE S256 and service account on, implicit and direct grants off, fullScopeAllowed=false; redirect https://artlab.yildizskylab.com/api/auth/callback/keycloak, web origin https://artlab.yildizskylab.com, post-logout https://artlab.yildizskylab.com/*' 'artlab client not planned'
expect_line "$check" 'would create confidential client frontend-skydays' 'skydays client not planned'
expect_line "$check" 'would attach skycms-audience as a default scope of frontend-yildizjam' 'skycms scope link not planned'
expect_line "$check" 'would create client scope frontend-artlab-core-audience' 'core scope not planned'
expect_line "$check" 'would detach the default scope microprofile-jwt from frontend-artlab' 'microprofile-jwt detach not planned'
expect_line "$check" 'would add mapper groups to frontend-artlab (Group Membership' 'groups mapper not planned'
expect_line "$check" 'hand-made frontend-main (report only, never written here): fullScopeAllowed=true' 'frontend-main not reported'
expect_line "$check" 'NOTE: frontend-arge does not exist in realm e-skylab' 'frontend-arge absence not reported'
# 2 for the shared scope, 7 per site (client, skycms link, core scope, its mapper, its link,
# microprofile-jwt detached, groups mapper).
expect_line "$check" 'check: 23 change(s) pending, 0 warning(s), 0 problem(s)' 'unexpected plan size'
[[ -z $(client_uuid "$CLIENT") ]] || fail '--check made the client'

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='--apply'
event_before=$(newest_admin_event)
apply=$(clients --apply) || { printf '%s\n' "$apply" >&2; fail '--apply failed'; }
expect_line "$apply" 'applied 23 change(s), 0 warning(s), 0 problem(s)' 'apply did not write the plan'
artlab=$(client_uuid "$CLIENT")
[[ -n $artlab && -n $(client_uuid frontend-yildizjam) && -n $(client_uuid frontend-skydays) ]] || fail 'the clients were not made'
live=$(kcadm get "clients/$artlab" -r "$REALM")
json_assert "$live" '.enabled and (.publicClient | not) and .clientAuthenticatorType == "client-secret" and .standardFlowEnabled
  and (.implicitFlowEnabled | not) and (.directAccessGrantsEnabled | not) and .serviceAccountsEnabled
  and (.fullScopeAllowed | not) and (.consentRequired | not) and .attributes["pkce.code.challenge.method"] == "S256"' \
  'the client flags are wrong'
json_assert "$live" '.redirectUris == [$s + "/api/auth/callback/keycloak"] and .webOrigins == [$s]
  and .attributes["post.logout.redirect.uris"] == $s + "/*"' 'the client URIs are wrong' --arg s "$SITE"
printf '    client: %s\n' "$(jq -c '{fullScopeAllowed, pkce: .attributes["pkce.code.challenge.method"], redirectUris, webOrigins}' <<<"$live")"
defaults=$(kcadm get "clients/$artlab/default-client-scopes" -r "$REALM")
json_assert "$defaults" 'any(.[]; .name == "skycms-audience") and any(.[]; .name == "frontend-artlab-core-audience")
  and (any(.[]; .name == "microprofile-jwt") | not)' 'the default scopes are wrong'
json_assert "$(kcadm get default-default-client-scopes -r "$REALM")" 'any(.[]; .name == "microprofile-jwt")' \
  'the realm lost microprofile-jwt as a default scope'
core_scope=$(scope_uuids frontend-artlab-core-audience)
json_assert "$(kcadm get "client-scopes/$core_scope/protocol-mappers/models" -r "$REALM")" \
  'length == 1 and (.[0] as $m | $want[0][0] as $w | $m.name == $w.name and $m.protocolMapper == $w.protocolMapper
     and ($w.config | to_entries | all(.value == $m.config[.key])))' \
  'the core-audience mapper differs from the reconciler'"'"'s shape' --slurpfile want "$CORE_MAPPERS_FILE"
[[ $(scope_uuids skycms-audience | wc -l | tr -d ' ') == 1 ]] || fail 'not exactly one skycms-audience scope'
json_assert "$(kcadm get admin-events -r "$REALM" -q max=1000)" \
  '[.[] | select(.time > $t and (.resourceType == "CLIENT_ROLE_MAPPING" or .resourceType == "REALM_ROLE_MAPPING"))] | length == 0' \
  'the script granted a role' --argjson t "$event_before"
main_uuid=$(client_uuid frontend-main)
json_assert "$(kcadm get admin-events -r "$REALM" -q max=1000)" \
  '[.[] | select(.time > $t and (.resourcePath | contains($m)))] | length == 0' \
  'the script wrote frontend-main' --argjson t "$event_before" --arg m "$main_uuid"

CURRENT_STAGE='second run is a no-op'
event_before=$(newest_admin_event)
sleep 1
again=$(clients --check) || { printf '%s\n' "$again" >&2; fail 'second --check failed'; }
expect_line "$again" 'check: 0 change(s) pending, 0 warning(s), 0 problem(s)' 'second --check plans changes'
again=$(clients --apply) || { printf '%s\n' "$again" >&2; fail 'second --apply failed'; }
expect_line "$again" 'applied 0 change(s)' 'second --apply wrote'
[[ $(newest_admin_event) == "$event_before" ]] || fail 'the second run wrote to the realm'
printf '    second --check and --apply: 0 change(s), no admin event\n'

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='CMS roles (inscribed-cms-roles.sh)'
out=$(roles --apply --client "$CLIENT" --client frontend-yildizjam) || { printf '%s\n' "$out" >&2; fail 'roles --apply failed'; }
expect_line "$out" 'create client role cms:access on frontend-artlab' 'cms:access not made on the event site'
expect_line "$out" 'create client role client:admin on frontend-yildizjam' 'client:admin not made on the event site'
expect_line "$out" 'frontend-artlab: groups (full path) comes from client mapper groups' 'roles script did not find the groups mapper'
again=$(clients --check) || { printf '%s\n' "$again" >&2; fail '--check after roles failed'; }
expect_line "$again" 'check: 0 change(s) pending' 'the roles script disturbed site-clients.sh'"'"'s state'

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='editor grants'
missing=$(run_expecting 1 site-editor-grants.sh "$REALM" --check --site skydays)
expect_line "$missing" 'MISSING: frontend-skydays has no cms:access or client:admin role' 'missing roles not reported'
event_before=$(newest_admin_event)
sleep 1
check=$(grants --check --site artlab) || { printf '%s\n' "$check" >&2; fail 'grants --check failed'; }
printf '%s\n' "$check" | sed 's/^/    /'
[[ $(newest_admin_event) == "$event_before" ]] || fail 'grants --check wrote'
expect_line "$check" 'Privileged groups: /ADMIN /UYELER/YK /UYELER/DK' 'Privileged groups not found'
expect_line "$check" 'would grant frontend-artlab/cms:access to the group /UYELER/ARGE/AIRLAB/KOORDINATORLER' 'owner team coordinators not planned'
expect_line "$check" 'would grant frontend-artlab/cms:access to the group /UYELER/ORGANIZASYON/ARTLAB/LIDERLER' 'organization team leaders not planned by default'
expect_line "$check" 'would grant frontend-artlab/client:admin to the group /ADMIN' 'client:admin not planned'
reject_line "$check" 'GAMELAB' 'another team planned'
expect_line "$check" 'check: 7 change(s) pending, 0 warning(s), 0 problem(s)' 'unexpected grant plan'
out=$(grants --apply --site artlab) || { printf '%s\n' "$out" >&2; fail 'grants --apply failed'; }
expect_line "$out" 'applied 7 change(s)' 'grants not applied'
holders=$(kcadm get "clients/$artlab/roles/cms:access/groups" -r "$REALM" | jq -c '[.[].path] | sort')
[[ $holders == '["/ADMIN","/UYELER/ARGE/AIRLAB/KOORDINATORLER","/UYELER/ARGE/AIRLAB/LIDERLER","/UYELER/DK","/UYELER/ORGANIZASYON/ARTLAB/LIDERLER","/UYELER/YK"]' ]] \
  || fail "unexpected cms:access holders $holders"
[[ $(kcadm get "clients/$artlab/roles/client:admin/groups" -r "$REALM" | jq -c '[.[].path]') == '["/ADMIN"]' ]] || fail 'client:admin not only on /ADMIN'
[[ $(kcadm get "clients/$artlab/roles/cms:access/users" -r "$REALM" | jq 'length') == 0 ]] || fail 'a person got cms:access'
printf '    cms:access <- %s\n' "$holders"
again=$(grants --apply --site artlab) || { printf '%s\n' "$again" >&2; fail 'second grants failed'; }
expect_line "$again" 'applied 0 change(s), 0 warning(s), 0 problem(s)' 'second grants run wrote'
again=$(grants --check --site artlab --team artlab=/UYELER/ARGE/GAMELAB --team artlab=/UYELER/ORGANIZASYON/ARTLAB) \
  || { printf '%s\n' "$again" >&2; fail 'grants with --team failed'; }
expect_line "$again" 'would grant frontend-artlab/cms:access to the group /UYELER/ARGE/GAMELAB/LIDERLER' '--team not planned'
expect_line "$again" 'check: 1 change(s) pending, 0 warning(s), 0 problem(s)' 'a --team naming a default team was planned twice'
editor_role=$(kcadm get "clients/$artlab/roles/cms:access" -r "$REALM" | jq -c '[{id, name}]')
kcadm create "groups/$stale_editors/role-mappings/clients/$artlab" -r "$REALM" -b "$editor_role" >/dev/null
again=$(grants --apply --site artlab) || { printf '%s\n' "$again" >&2; fail 'grants with an extra holder failed'; }
expect_line "$again" 'WARNING: frontend-artlab/cms:access is also held by the group /UYELER/ESKI-EDITORLER (not taken away' 'extra holder not reported'
expect_line "$again" 'applied 0 change(s), 1 warning(s), 0 problem(s)' 'the extra holder changed the plan'
[[ $(kcadm get "groups/$stale_editors/role-mappings/clients/$artlab" -r "$REALM" | jq 'length') == 1 ]] || fail 'the extra holder was taken away'
out=$(grants --apply --site yildizjam) || { printf '%s\n' "$out" >&2; fail 'yildizjam grants failed'; }
expect_line "$out" 'grant frontend-yildizjam/cms:access to the group /UYELER/ARGE/GAMELAB/LIDERLER' 'GAMELAB not granted on yildizjam'
expect_line "$out" 'WARNING: frontend-yildizjam: the team /UYELER/ORGANIZASYON/YILDIZJAM does not exist in realm e-skylab' 'missing organization team not a WARNING'

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='person tokens through the client (authorization code + PKCE)'
response=$(code_flow_response "$CLIENT" airlead)
access=$(jwt_payload "$(jq -r .access_token <<<"$response")")
id_token=$(jwt_payload "$(jq -r .id_token <<<"$response")")
json_assert "$access" ".azp == \"$CLIENT\" and (($AUD) | index(\"skycms\") != null and index(\"core\") != null)" \
  'the editor access token does not name skycms and core'
json_assert "$access" '.groups == ["/UYELER/ARGE/AIRLAB/LIDERLER"]' 'the editor token has no full-path groups (or realm roles leaked into groups)'
json_assert "$access" "($CMS_ROLES) == [\"cms:access\", \"content:read\", \"content:write\"]" 'the editor roles are not cms:access + content:*'
json_assert "$access" "$EDITOR_GATE" 'the editor gate is shut for the owner team leader'
json_assert "$id_token" ".roles == null and .groups == null" 'the ID token carries roles or groups'
printf '    airlead  @ %s: aud=%s groups=%s roles=%s editor=%s\n' "$CLIENT" "$(jq -c "$AUD" <<<"$access")" \
  "$(jq -c .groups <<<"$access")" "$(jq -c "$CMS_ROLES" <<<"$access")" "$(jq -c "$EDITOR_GATE" <<<"$access")"
access=$(jwt_payload "$(code_flow_response "$CLIENT" orglead | jq -r .access_token)")
json_assert "$access" "($CMS_ROLES) == [\"cms:access\", \"content:read\", \"content:write\"]" 'the organization team leader is no editor'
access=$(jwt_payload "$(code_flow_response "$CLIENT" boss | jq -r .access_token)")
json_assert "$access" "($CMS_ROLES) == [\"client:admin\", \"cms:access\", \"content:read\", \"content:write\"]" 'ADMIN roles wrong'
access=$(jwt_payload "$(code_flow_response "$CLIENT" gamelead | jq -r .access_token)")
json_assert "$access" "(($CMS_ROLES) == []) and (($EDITOR_GATE) | not)" 'another site'"'"'s editor opens this site'"'"'s editor'
printf '    gamelead @ %s: roles=%s editor=%s (a YıldızJam editor)\n' "$CLIENT" "$(jq -c "$CMS_ROLES" <<<"$access")" "$(jq -c "$EDITOR_GATE" <<<"$access")"
access=$(jwt_payload "$(code_flow_response frontend-yildizjam gamelead | jq -r .access_token)")
json_assert "$access" "$EDITOR_GATE" 'the GAMELAB leader is no YıldızJam editor'
access=$(jwt_payload "$(code_flow_response "$CLIENT" member | jq -r .access_token)")
json_assert "$access" "(($CMS_ROLES) == []) and (($EDITOR_GATE) | not)" 'a plain member got a CMS role'
location=$(curl -sS -o /dev/null -w '%{redirect_url}' -G "$BASE_URL/realms/$REALM/protocol/openid-connect/auth" \
  --data-urlencode "client_id=$CLIENT" --data-urlencode response_type=code --data-urlencode scope=openid \
  --data-urlencode "redirect_uri=$CALLBACK" --data-urlencode state=x)
[[ $location == "$CALLBACK?"*error=invalid_request* ]] || fail "a flow without PKCE was not refused ($location)"
for uri in http://localhost:3000/api/auth/callback/keycloak https://sandbox-artlab.yildizskylab.com/api/auth/callback/keycloak "$SITE/other"; do
  code=$(curl -s -o /dev/null -w '%{http_code}' -G "$BASE_URL/realms/$REALM/protocol/openid-connect/auth" \
    --data-urlencode "client_id=$CLIENT" --data-urlencode response_type=code --data-urlencode scope=openid \
    --data-urlencode "redirect_uri=$uri")
  [[ $code == 400 ]] || fail "the redirect URI $uri was not refused (HTTP $code)"
done
printf '    no PKCE, localhost, the sandbox host and another path are refused\n'

CURRENT_STAGE='service-account token'
access=$(jwt_payload "$(client_secret "$CLIENT" | curl -fsS "$BASE_URL/realms/$REALM/protocol/openid-connect/token" \
  --data-urlencode grant_type=client_credentials --data-urlencode "client_id=$CLIENT" \
  --data-urlencode 'client_secret@-' | jq -r .access_token)")
json_assert "$access" ".azp == \"$CLIENT\" and (($AUD) | index(\"skycms\") != null)
  and (($CMS_ROLES) == [\"content:read\", \"schema:sync\"])" 'the service account is not read-only (content:read + schema:sync)'
printf '    service account: aud=%s roles=%s\n' "$(jq -c "$AUD" <<<"$access")" "$(jq -c "$CMS_ROLES" <<<"$access")"

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='drift repair'
kcadm update "clients/$artlab" -r "$REALM" -s fullScopeAllowed=true \
  -s "redirectUris=[\"$CALLBACK\",\"http://localhost:3000/*\"]" >/dev/null
drift=$(clients --check --site artlab) || { printf '%s\n' "$drift" >&2; fail 'drift --check failed'; }
expect_line "$drift" 'would update frontend-artlab flags' 'flag drift not found'
expect_line "$drift" 'would set the redirect URIs of frontend-artlab to exactly https://artlab.yildizskylab.com/api/auth/callback/keycloak (removing http://localhost:3000/*)' 'localhost not removed'
expect_line "$drift" 'check: 2 change(s) pending' 'unexpected drift plan'
repair=$(clients --apply --site artlab) || { printf '%s\n' "$repair" >&2; fail 'drift --apply failed'; }
json_assert "$(kcadm get "clients/$artlab" -r "$REALM")" '(.fullScopeAllowed | not) and .redirectUris == [$c]' \
  'drift not repaired' --arg c "$CALLBACK"

CURRENT_STAGE='the secret is never printed'
for client in frontend-artlab frontend-yildizjam frontend-skydays; do
  secret=$(client_secret "$client")
  [[ ${#secret} -ge 16 ]] || fail "$client has no generated secret"
  if grep -Fq -- "$secret" "$OUTPUTS"; then fail "a script printed the $client secret"; fi
done
secret=''

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='sandbox realm'
kcadm create realms -s realm="$SANDBOX_REALM" -s enabled=true >/dev/null
kcadm create clients -r "$SANDBOX_REALM" -s clientId=skycms -s publicClient=false -s standardFlowEnabled=false >/dev/null
s_uyeler=$(kcadm create groups -r "$SANDBOX_REALM" -i -s name=UYELER)
kcadm create "groups/$s_uyeler/children" -r "$SANDBOX_REALM" -i -s name=ADMIN >/dev/null
out=$(RUN_REALM=$SANDBOX_REALM clients --apply --site artlab) || { printf '%s\n' "$out" >&2; fail 'sandbox --apply failed'; }
expect_line "$out" 'redirect https://sandbox-artlab.yildizskylab.com/api/auth/callback/keycloak' 'sandbox origin wrong'
expect_line "$out" 'NOTE: realm e-skylab-sandbox has no core client; frontend-artlab-core-audience skipped' 'missing core not a NOTE'
out=$(RUN_REALM=$SANDBOX_REALM roles --apply --client "$CLIENT") || { printf '%s\n' "$out" >&2; fail 'sandbox roles failed'; }
out=$(RUN_REALM=$SANDBOX_REALM grants --apply --site artlab) || { printf '%s\n' "$out" >&2; fail 'sandbox grants failed'; }
expect_line "$out" 'Privileged groups: /UYELER/ADMIN' 'sandbox Privileged group not found'
expect_line "$out" 'WARNING: frontend-artlab: the team /UYELER/ARGE/AIRLAB does not exist in realm e-skylab-sandbox' 'missing team not a WARNING'
expect_line "$out" 'WARNING: frontend-artlab: the team /UYELER/ORGANIZASYON/ARTLAB does not exist in realm e-skylab-sandbox' 'missing organization team not a WARNING'
expect_line "$out" 'grant frontend-artlab/client:admin to the group /UYELER/ADMIN' 'sandbox client:admin not granted'

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='sandbox: the main site (--site main)'
SANDBOX_MAIN=https://sandbox.yildizskylab.com
s_admin=$(kcadm get groups -r "$SANDBOX_REALM" -q search=ADMIN | jq -r '.. | objects | select(.path? == "/UYELER/ADMIN") | .id' | head -n 1)
[[ -n $s_admin ]] || fail 'no /UYELER/ADMIN in the sandbox fixture'
s_boss=$(kcadm create users -r "$SANDBOX_REALM" -i -s username=sboss -s enabled=true -s email=sboss@example.invalid \
  -s emailVerified=true -s firstName=Harness -s lastName=sboss)
kcadm set-password -r "$SANDBOX_REALM" --userid "$s_boss" --new-password "$PERSON_PASSWORD" >/dev/null
kcadm update "users/$s_boss/groups/$s_admin" -r "$SANDBOX_REALM" -n -b '{}' >/dev/null
s_member=$(kcadm create users -r "$SANDBOX_REALM" -i -s username=smember -s enabled=true -s email=smember@example.invalid \
  -s emailVerified=true -s firstName=Harness -s lastName=smember)
kcadm set-password -r "$SANDBOX_REALM" --userid "$s_member" --new-password "$PERSON_PASSWORD" >/dev/null
check=$(RUN_REALM=$SANDBOX_REALM clients --check --site main) || { printf '%s\n' "$check" >&2; fail 'sandbox main --check failed'; }
printf '%s\n' "$check" | sed 's/^/    /'
expect_line "$check" 'realm=e-skylab-sandbox mode=check clients=frontend-main' 'unexpected sandbox main header'
expect_line "$check" "would create confidential client frontend-main (standard flow with PKCE S256 and service account on, implicit and direct grants off, fullScopeAllowed=false; redirect $SANDBOX_MAIN/api/auth/callback/keycloak, web origin $SANDBOX_MAIN, post-logout $SANDBOX_MAIN/*" 'sandbox main client not planned'
reject_line "$check" 'hand-made frontend-main' 'the managed sandbox frontend-main was reported as hand-made'
expect_line "$check" 'NOTE: frontend-arge does not exist in realm e-skylab-sandbox' 'frontend-arge report missing'
[[ -z $(client_uuid frontend-main "$SANDBOX_REALM") ]] || fail '--check made the sandbox frontend-main'
out=$(RUN_REALM=$SANDBOX_REALM clients --apply --site main) || { printf '%s\n' "$out" >&2; fail 'sandbox main --apply failed'; }
s_main=$(client_uuid frontend-main "$SANDBOX_REALM")
[[ -n $s_main ]] || fail 'the sandbox frontend-main was not made'
live=$(kcadm get "clients/$s_main" -r "$SANDBOX_REALM")
json_assert "$live" '.enabled and (.publicClient | not) and .standardFlowEnabled and (.implicitFlowEnabled | not)
  and (.directAccessGrantsEnabled | not) and .serviceAccountsEnabled and (.fullScopeAllowed | not)
  and .attributes["pkce.code.challenge.method"] == "S256" and .name == "SKY LAB"
  and .redirectUris == [$s + "/api/auth/callback/keycloak"] and .webOrigins == [$s]
  and .attributes["post.logout.redirect.uris"] == $s + "/*"' 'the sandbox frontend-main is not in the Site client shape' --arg s "$SANDBOX_MAIN"
json_assert "$(kcadm get "clients/$s_main/default-client-scopes" -r "$SANDBOX_REALM")" 'any(.[]; .name == "skycms-audience")' \
  'skycms-audience is not a default scope of the sandbox frontend-main'
printf '    sandbox frontend-main: %s\n' "$(jq -c '{name, fullScopeAllowed, pkce: .attributes["pkce.code.challenge.method"], redirectUris}' <<<"$live")"
out=$(RUN_REALM=$SANDBOX_REALM roles --apply --client frontend-main) || { printf '%s\n' "$out" >&2; fail 'sandbox main roles failed'; }
expect_line "$out" 'create client role cms:access on frontend-main' 'cms:access not made on the sandbox frontend-main'
out=$(RUN_REALM=$SANDBOX_REALM grants --apply --site main) || { printf '%s\n' "$out" >&2; fail 'sandbox main grants failed'; }
expect_line "$out" 'grant frontend-main/cms:access to the group /UYELER/ADMIN' 'sandbox main cms:access not granted'
expect_line "$out" 'grant frontend-main/client:admin to the group /UYELER/ADMIN' 'sandbox main client:admin not granted'
# The sandbox fixture has only /UYELER/ADMIN: YK and DK are missing, a WARNING each, and nothing else.
expect_line "$out" 'WARNING: no Privileged group YK (neither /YK nor /UYELER/YK)' 'missing sandbox YK not a WARNING'
expect_line "$out" 'WARNING: no Privileged group DK (neither /DK nor /UYELER/DK)' 'missing sandbox DK not a WARNING'
expect_line "$out" 'applied 2 change(s), 2 warning(s), 0 problem(s)' 'the main site got team grants or other warnings'
[[ $(kcadm get "clients/$s_main/roles/cms:access/groups" -r "$SANDBOX_REALM" | jq -c '[.[].path]') == '["/UYELER/ADMIN"]' ]] \
  || fail 'cms:access on the sandbox frontend-main is not only on /UYELER/ADMIN'
access=$(jwt_payload "$(code_flow_response frontend-main sboss "$SANDBOX_REALM" "$SANDBOX_MAIN" | jq -r .access_token)")
json_assert "$access" ".azp == \"frontend-main\" and (($AUD) | index(\"skycms\") != null)
  and (($CMS_ROLES) == [\"client:admin\", \"cms:access\", \"content:read\", \"content:write\"]) and ($EDITOR_GATE)" \
  'the sandbox ADMIN member is no main-site editor'
access=$(jwt_payload "$(code_flow_response frontend-main smember "$SANDBOX_REALM" "$SANDBOX_MAIN" | jq -r .access_token)")
json_assert "$access" "(($CMS_ROLES) == []) and (($EDITOR_GATE) | not)" 'a plain sandbox member got a main-site CMS role'
access=$(jwt_payload "$(client_secret frontend-main "$SANDBOX_REALM" | curl -fsS "$BASE_URL/realms/$SANDBOX_REALM/protocol/openid-connect/token" \
  --data-urlencode grant_type=client_credentials --data-urlencode client_id=frontend-main \
  --data-urlencode 'client_secret@-' | jq -r .access_token)")
json_assert "$access" ".azp == \"frontend-main\" and (($AUD) | index(\"skycms\") != null)
  and (($CMS_ROLES) == [\"content:read\", \"schema:sync\"])" 'the sandbox frontend-main service account is not read-only'
printf '    sandbox frontend-main: ADMIN member editor with client:admin, plain member none, service account %s\n' "$(jq -c "$CMS_ROLES" <<<"$access")"
again=$(RUN_REALM=$SANDBOX_REALM clients --check --site main) || { printf '%s\n' "$again" >&2; fail 'second sandbox main --check failed'; }
expect_line "$again" 'check: 0 change(s) pending, 0 warning(s), 0 problem(s)' 'second sandbox main --check plans changes'
again=$(RUN_REALM=$SANDBOX_REALM grants --check --site main) || { printf '%s\n' "$again" >&2; fail 'second sandbox main grants failed'; }
expect_line "$again" 'check: 0 change(s) pending, 2 warning(s), 0 problem(s)' 'second sandbox main grants plan changes'
secret=$(client_secret frontend-main "$SANDBOX_REALM")
[[ ${#secret} -ge 16 ]] || fail 'the sandbox frontend-main has no generated secret'
if grep -Fq -- "$secret" "$OUTPUTS"; then fail 'a script printed the sandbox frontend-main secret'; fi
secret=''

printf 'site-clients.sh and site-editor-grants.sh contract holds against %s.\n' "$IMAGE"
