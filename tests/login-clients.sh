#!/usr/bin/env bash
# Real-Keycloak contract for the reconciler's login client step (reconcile_login_clients in
# config/reconcile-account-center.sh; ADR-0058, ADR-0059; admin-token-authz tickets 16, 17, 18):
# frontend-main, frontend-arge and skymail narrowed to the APIs their apps call. Stand-alone: starts
# the stock Keycloak image this repository builds on (the Dockerfile's KEYCLOAK_IMAGE) in dev mode
# with docker run --rm and no volume, copies config/ into it and runs the step alone with the
# harness's kcadm session (KEYCLOAK_RECONCILE_KCADM_CONFIG + KEYCLOAK_RECONCILE_ONLY=login-clients),
# the way an operator runs it in the sandbox realm; the full reconciliation runs the same function
# (run-integration.sh). Real tokens throughout; the container is removed on exit (docker rm -fv).
#
# The fixture realm e-skylab is production-shaped: the three clients made by hand with full scope;
# frontend-main confidential with a service account, the realm scope groups (full path), its
# hand-made frontend-main-core-audience scope and the shared skycms-audience scope as production has
# it (one audience-mapper that names no audience: skycms reached the sites' tokens only through
# audience-resolve); frontend-arge confidential with a service account and frontend-arge-core-audience;
# skymail public (PKCE) with the realm scope groups and Keycloak's optional microprofile-jwt; the CMS
# roles, the flat roles mapper and the groups mapper from inscribed-cms-roles.sh; skyapp (public, full
# scope) for SkyApp's CMS editing. The people hold what the admin panel grants (runbook §12) plus, for
# the Privileged person, roles of eight other clients and nine realm roles, as production's admin token
# showed (11 audiences, 12 realm roles, 4 group paths).
#
# What it proves:
#   - before the step (positive control) the Privileged person's tokens carry foreign audiences,
#     roles of other clients and realm roles; a member without a skycms role gets no aud skycms on the
#     main site (inscribed would answer 401); a DK member opens arge's editor gate with the main
#     site's cms:access although inscribed would refuse every arge write (no content:write in roles);
#   - the step adopts the hand-made scopes in place, repairs the shared skycms-audience (the empty
#     mapper is pruned, skycms-audience added), clears the clients' role scope (a realm and a foreign
#     role mapped by hand), takes groups out of SkyMail's token only (the realm scope groups and
#     microprofile-jwt stay realm defaults and stay on the sites) and turns full scope off; secrets,
#     redirect URIs and the clients' own mappers are unchanged;
#   - after it, real logins (authorization code, PKCE, openid email profile) give: the sites aud
#     exactly core and skycms, no realm_access, resource_access only the site itself, and the claims
#     the sites, core and inscribed read (azp, sub, e-mail, name, flat roles, own roles, full-path
#     groups) equal to before, for the Privileged person, a team leader and a plain member (who now
#     also gets aud skycms); the sites' service-account tokens keep aud skycms and content:read +
#     schema:sync; SkyMail aud exactly skymail, resource_access only skymail with the same roles, no
#     groups, no realm_access, the same sub and scope, and Keycloak userinfo (SkyMail's backend) still
#     answers with sub, name and e-mail; every token is smaller;
#   - the DK member's arge editor gate is shut after the step (the intended F15 fix), while the
#     main site's gate stays open for them;
#   - sessions opened before the step (main site, arge, SkyMail) get the narrowed token on their next
#     refresh, with the same claims: nobody has to sign in again;
#   - a second run writes nothing (no admin event); inscribed-cms-roles.sh --check plans nothing;
#     skyapp-cms-editor.sh --apply now passes its skycms-audience prerequisite and SkyApp gets its CMS
#     roles through frontend-main's cms:access; from then on an editor's main-site token also carries
#     those skyapp roles and aud skyapp (Keycloak expands the composites of a client's own roles even
#     without full scope; nothing reads them there), a member's does not; the step after it writes
#     nothing;
#   - skycms-audience has two writers, this step and site-clients.sh --shared-scope (e-skylab-keycloak
#     #71, run alone before a release): after the step site-clients.sh --shared-scope --check plans
#     nothing; back on production's hand-made shape, site-clients.sh --shared-scope --apply writes
#     the same scope attributes and the same mapper as the step, byte for byte, and the step then
#     writes nothing;
#   - drift (full scope on, a realm and a foreign role in the role scope, skycms-audience among the
#     optional scopes and its mapper changed, a foreign mapper in it, groups back on SkyMail through
#     the realm scope and a client mapper, SkyMail's audience scope detached) is repaired;
#   - in the sandbox realm, frontend-main made by site-clients.sh --site main and frontend-arge made
#     by sandbox-site-clients.sh: the step only attaches skycms-audience to frontend-arge, warns about
#     the missing skymail, and afterwards site-clients.sh, sandbox-site-clients.sh and
#     inscribed-cms-roles.sh --check plan nothing (the scripts agree).
# A table of the token sizes before and after is printed at the end.
# Requirements on the host: docker, curl, jq, openssl, base64. LOGIN_CLIENTS_TEST_PORT (default
# 18097), LOGIN_CLIENTS_TEST_MEMORY (default 1536m).
# The jq programs name jq variables, not shell ones:
# shellcheck disable=SC2016
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPOSITORY_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
IMAGE=$(sed -n 's/^ARG KEYCLOAK_IMAGE=//p' "$REPOSITORY_ROOT/Dockerfile")
PORT=${LOGIN_CLIENTS_TEST_PORT:-18097}
MEMORY=${LOGIN_CLIENTS_TEST_MEMORY:-1536m}
BASE_URL="http://127.0.0.1:$PORT"
REALM=e-skylab
SANDBOX_REALM=e-skylab-sandbox
CONTAINER="login-clients-test-$$"
ADMIN_PASSWORD=harness-admin-password
PERSON_PASSWORD=harness-person-password
KCADM_CONFIG=/tmp/harness-kcadm.config
MAIN_CALLBACK=https://yildizskylab.com/api/auth/callback/keycloak
ARGE_CALLBACK=https://arge.yildizskylab.com/api/auth/callback/keycloak
MAIL_CALLBACK=https://mail.yildizskylab.com/api/auth/callback/keycloak
APP_CALLBACK=com.yildizskylab.app:/oauth2redirect
SANDBOX_MAIN_CALLBACK=https://sandbox.yildizskylab.com/api/auth/callback/keycloak
SANDBOX_ARGE_CALLBACK=https://sandbox-arge.yildizskylab.com/api/auth/callback/keycloak
SIZES=''
# Token responses by name (before-main-privileged, after-mail-leader, ...): plain files, so the harness
# also runs under macOS's bash 3.2 (no associative arrays).
TOKENS=$(mktemp -d "${TMPDIR:-/tmp}/login-clients-tokens.XXXXXX")
CURRENT_STAGE=startup

fail() {
  printf 'login-clients failure during %s: %s\n' "$CURRENT_STAGE" "$1" >&2
  exit 1
}
cleanup() {
  docker rm -fv "$CONTAINER" >/dev/null 2>&1 || true
  rm -rf "$TOKENS"
}
trap 'status=$?; trap - EXIT; cleanup; exit "$status"' EXIT
on_error() {
  local status=$?
  printf 'login-clients command failed during %s (line %s)\n' "$CURRENT_STAGE" "$1" >&2
  exit "$status"
}
trap 'on_error "$LINENO"' ERR

kcadm() {
  local command=$1
  shift
  docker exec -i "$CONTAINER" /opt/keycloak/bin/kcadm.sh "$command" --config "$KCADM_CONFIG" "$@" \
    2> >(grep -v -e '^Created new ' -e '^$' >&2 || true)
}

# step [REALM]: the reconciler's login client step alone, with the harness's kcadm session (the
# operator path). Prints the output; returns the reconciler's status.
step() {
  docker exec -e KEYCLOAK_ADMIN_URL=http://localhost:8080 -e "KEYCLOAK_REALM=${1:-$REALM}" \
    -e "KEYCLOAK_RECONCILE_KCADM_CONFIG=$KCADM_CONFIG" -e KEYCLOAK_RECONCILE_ONLY=login-clients \
    "$CONTAINER" bash /tmp/config/reconcile-account-center.sh 2>&1
}
# run SCRIPT REALM ARGS...: an operator script of config/ inside the container with the harness's
# kcadm session; prints its output and returns its status.
run() {
  local script=$1 realm=$2
  shift 2
  docker exec -e KEYCLOAK_ADMIN_URL=http://localhost:8080 -e "KEYCLOAK_REALM=$realm" "$CONTAINER" \
    bash "/tmp/config/$script" --kcadm-config "$KCADM_CONFIG" "$@" 2>&1
}

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

client_uuid() { # client_uuid CLIENT [REALM]
  kcadm get clients -r "${2:-$REALM}" -q "clientId=$1" | jq -r --arg id "$1" '.[] | select(.clientId == $id) | .id'
}
scope_uuid() { # scope_uuid NAME [REALM]
  kcadm get client-scopes -r "${2:-$REALM}" | jq -r --arg name "$1" '.[] | select(.name == $name) | .id'
}
client_secret() { # client_secret CLIENT [REALM]
  kcadm get "clients/$(client_uuid "$1" "${2:-$REALM}")/client-secret" -r "${2:-$REALM}" | jq -j .value
}
newest_admin_event() {
  kcadm get admin-events -r "${1:-$REALM}" -q max=1 | jq -r '.[0].time // 0'
}
# no_admin_event_since TIME MESSAGE [REALM]: fails when the realm logged an admin event after TIME.
no_admin_event_since() {
  json_assert "$(kcadm get admin-events -r "${3:-$REALM}" -q max=1000)" '[.[] | select(.time > $t)] | length == 0' \
    "$2" --argjson t "$1"
}
jwt_payload() {
  local segment
  segment=$(cut -d. -f2 <<<"$1" | tr '_-' '/+')
  case $(( ${#segment} % 4 )) in 2) segment+='==' ;; 3) segment+='=' ;; esac
  base64 -d <<<"$segment"
}
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# tokens CLIENT CALLBACK USER [REALM]: the token response of a real browser login through Keycloak's
# own form: authorization code with PKCE S256 and the scope openid email profile (what NextAuth and
# Auth.js ask for). A confidential client exchanges the code with its secret (on stdin), a public one
# without.
tokens() {
  local client=$1 callback=$2 user=$3 realm=${4:-$REALM} jar page action headers location code verifier challenge
  verifier=$(openssl rand -hex 32)
  challenge=$(printf '%s' "$verifier" | openssl dgst -sha256 -binary | b64url)
  jar=$(mktemp "${TMPDIR:-/tmp}/login-clients-jar.XXXXXX")
  page=$(curl -fsS -c "$jar" -b "$jar" -G "$BASE_URL/realms/$realm/protocol/openid-connect/auth" \
    --data-urlencode "client_id=$client" --data-urlencode response_type=code \
    --data-urlencode 'scope=openid email profile' --data-urlencode "redirect_uri=$callback" \
    --data-urlencode state=harness-state --data-urlencode "code_challenge=$challenge" \
    --data-urlencode code_challenge_method=S256)
  action=$(sed -n 's/.*id="kc-form-login"[^>]*action="\([^"]*\)".*/\1/p' <<<"$page" | head -n 1 | sed 's/&amp;/\&/g')
  [[ -n $action ]] || { rm -f "$jar"; fail "no login form for $user on $client"; }
  headers=$(curl -sS -c "$jar" -b "$jar" -o /dev/null -D - \
    --data-urlencode "username=$user" --data-urlencode "password=$PERSON_PASSWORD" "$action")
  rm -f "$jar"
  location=$(tr -d '\r' <<<"$headers" | sed -n 's/^[Ll]ocation: //p' | head -n 1)
  [[ $location == "$callback?"* ]] || fail "the login of $user on $client did not return to $callback ($location)"
  code=$(sed -n 's/.*[?&]code=\([^&]*\).*/\1/p' <<<"$location")
  [[ -n $code ]] || fail "no authorization code for $user on $client"
  if [[ $(kcadm get "clients/$(client_uuid "$client" "$realm")" -r "$realm" | jq -r .publicClient) == true ]]; then
    curl -fsS "$BASE_URL/realms/$realm/protocol/openid-connect/token" \
      --data-urlencode grant_type=authorization_code --data-urlencode "code=$code" \
      --data-urlencode "redirect_uri=$callback" --data-urlencode "client_id=$client" \
      --data-urlencode "code_verifier=$verifier"
  else
    client_secret "$client" "$realm" | curl -fsS "$BASE_URL/realms/$realm/protocol/openid-connect/token" \
      --data-urlencode grant_type=authorization_code --data-urlencode "code=$code" \
      --data-urlencode "redirect_uri=$callback" --data-urlencode "client_id=$client" \
      --data-urlencode "code_verifier=$verifier" --data-urlencode 'client_secret@-'
  fi
}
# service_tokens CLIENT [REALM]: the client's service-account token response (client_credentials).
service_tokens() {
  client_secret "$1" "${2:-$REALM}" | curl -fsS "$BASE_URL/realms/${2:-$REALM}/protocol/openid-connect/token" \
    --data-urlencode grant_type=client_credentials --data-urlencode "client_id=$1" --data-urlencode 'client_secret@-'
}
# refresh CLIENT RESPONSE [REALM]: the refresh grant of a session (no scope parameter, as the sites'
# NextAuth and SkyMail's Auth.js send it); a confidential client sends its secret on stdin.
refresh() {
  local client=$1 realm=${3:-$REALM} token
  token=$(jq -r .refresh_token <<<"$2")
  if [[ $(kcadm get "clients/$(client_uuid "$client" "$realm")" -r "$realm" | jq -r .publicClient) == true ]]; then
    curl -fsS "$BASE_URL/realms/$realm/protocol/openid-connect/token" \
      --data-urlencode grant_type=refresh_token --data-urlencode "client_id=$client" --data-urlencode "refresh_token=$token"
  else
    client_secret "$client" "$realm" | curl -fsS "$BASE_URL/realms/$realm/protocol/openid-connect/token" \
      --data-urlencode grant_type=refresh_token --data-urlencode "client_id=$client" \
      --data-urlencode "refresh_token=$token" --data-urlencode 'client_secret@-'
  fi
}
access_of() { jwt_payload "$(jq -r .access_token <<<"$1")"; }
id_of() { jwt_payload "$(jq -r .id_token <<<"$1")"; }
keep() { printf '%s' "$2" >"$TOKENS/$1"; } # keep NAME RESPONSE
kept() { cat "$TOKENS/$1"; }               # kept NAME

AUD='((.aud // []) | if type == "array" then . else [.] end | sort)'
# What the sites, core and inscribed read from a site token (measured on the apps' origin/main,
# 2026-10-05): must be the same before and after the step.
SITE_VIEW='{azp, sub, email, name, preferred_username, roles: ((.roles // []) | sort), groups: ((.groups // []) | sort), own: ((.resource_access[.azp].roles // []) | sort)}'
# What SkyMail's UI and backend read from its access token (the rest comes from userinfo).
MAIL_VIEW='{azp, sub, own: ((.resource_access.skymail.roles // []) | sort), scope: ((.scope // "") | split(" ") | map(select(. == "openid" or . == "profile" or . == "email")) | sort)}'
# The sites' editor gate (@skylab-kulubu/inscribed-auth 0.3.1): cms:access in ANY client's roles.
EDITOR_GATE='[(.resource_access // {})[] | .roles // [] | .[]] | index("cms:access") != null'
SUMMARY="{aud: $AUD, resource_access: ((.resource_access // {}) | keys), realm_roles: ((.realm_access.roles // []) | length), groups: ((.groups // []) | length)}"

# size_line LABEL BEFORE_RESPONSE AFTER_RESPONSE: one row of the size table (bytes of the access
# token as sent in Authorization, and of its JSON payload).
size_line() {
  local before after before_payload after_payload
  before=$(jq -r .access_token <<<"$2")
  after=$(jq -r .access_token <<<"$3")
  before_payload=$(jwt_payload "$before" | jq -c . | tr -d '\n' | wc -c | tr -d ' ')
  after_payload=$(jwt_payload "$after" | jq -c . | tr -d '\n' | wc -c | tr -d ' ')
  [[ ${#after} -lt ${#before} ]] || fail "$1: the token did not shrink (${#before} -> ${#after} bytes)"
  SIZES+=$(printf '    %-40s JWT %5s -> %5s B   payload %5s -> %5s B' "$1" "${#before}" "${#after}" "$before_payload" "$after_payload")$'\n'
}

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='Keycloak start'
[[ -n $IMAGE ]] || fail 'Dockerfile has no ARG KEYCLOAK_IMAGE'
for tool in jq curl openssl; do command -v "$tool" >/dev/null || fail "$tool is required"; done
docker run --rm -d --name "$CONTAINER" --memory "$MEMORY" -p "127.0.0.1:$PORT:8080" \
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
docker cp "$REPOSITORY_ROOT/config/." "$CONTAINER:/tmp/config" >/dev/null

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='fixture realm'
kcadm create realms -s realm="$REALM" -s enabled=true -s adminEventsEnabled=true >/dev/null
group() { # group REALM PARENT_ID|'' NAME -> id
  if [[ -z $2 ]]; then kcadm create groups -r "$1" -i -s "name=$3"; else kcadm create "groups/$2/children" -r "$1" -i -s "name=$3"; fi
}
person() { # person REALM USERNAME GROUP_ID...
  local realm=$1 username=$2 uuid gid
  shift 2
  uuid=$(kcadm create users -r "$realm" -i -s "username=$username" -s enabled=true -s "email=$username@example.invalid" \
    -s emailVerified=true -s firstName=Harness -s "lastName=$username")
  kcadm set-password -r "$realm" --userid "$uuid" --new-password "$PERSON_PASSWORD" >/dev/null
  for gid in "$@"; do
    kcadm update "users/$uuid/groups/$gid" -r "$realm" -n -b '{}' >/dev/null
  done
}
grant() { # grant REALM CLIENT ROLE GROUP_ID
  local uuid
  uuid=$(client_uuid "$2" "$1")
  kcadm create "groups/$4/role-mappings/clients/$uuid" -r "$1" \
    -b "$(kcadm get "clients/$uuid/roles/$3" -r "$1" | jq -c '[{id, name}]')" >/dev/null
}
api_client() { # api_client CLIENT ROLE...: a resource client (confidential, no login) and its roles
  local client=$1 uuid role
  shift
  kcadm create clients -r "$REALM" -s "clientId=$client" -s publicClient=false -s standardFlowEnabled=false >/dev/null
  uuid=$(client_uuid "$client")
  for role in "$@"; do
    kcadm create "clients/$uuid/roles" -r "$REALM" -s "name=$role" >/dev/null
  done
}
admin_group=$(group "$REALM" '' ADMIN)
uyeler=$(group "$REALM" '' UYELER)
yk=$(group "$REALM" "$uyeler" YK)
dk=$(group "$REALM" "$uyeler" DK)
arge_group=$(group "$REALM" "$uyeler" ARGE)
weblab=$(group "$REALM" "$arge_group" WEBLAB)
weblab_leaders=$(group "$REALM" "$weblab" LIDERLER)

api_client core url:create url:moderator event:manage
api_client forms skyforms:form:manage
api_client skycms cms:access cms:account:erase
api_client skycloud skycloud:user
api_client skylapp url:create
api_client cloudflare-zero-trust access
kcadm create clients -r "$REALM" -s clientId=admin -s publicClient=false -s fullScopeAllowed=true \
  -s "redirectUris=[\"https://admin.yildizskylab.com/api/auth/callback\"]" >/dev/null
kcadm create clients -r "$REALM" -s clientId=skyapp -s publicClient=true -s fullScopeAllowed=true \
  -s standardFlowEnabled=true -s directAccessGrantsEnabled=false -s "redirectUris=[\"$APP_CALLBACK\"]" >/dev/null
kcadm create clients -r "$REALM" -s clientId=frontend-main -s 'name=SKY LAB site' -s publicClient=false \
  -s fullScopeAllowed=true -s serviceAccountsEnabled=true -s standardFlowEnabled=true \
  -s "redirectUris=[\"https://yildizskylab.com/*\"]" >/dev/null
kcadm create clients -r "$REALM" -s clientId=frontend-arge -s 'name=SKY LAB arge' -s publicClient=false \
  -s fullScopeAllowed=true -s serviceAccountsEnabled=true -s standardFlowEnabled=true \
  -s "redirectUris=[\"https://arge.yildizskylab.com/*\"]" >/dev/null
kcadm create clients -r "$REALM" -s clientId=skymail -s 'name=SkyMail' -s publicClient=true -s fullScopeAllowed=true \
  -s standardFlowEnabled=true -s directAccessGrantsEnabled=false -s "redirectUris=[\"$MAIL_CALLBACK\"]" \
  -s 'attributes."pkce.code.challenge.method"=S256' >/dev/null
skymail=$(client_uuid skymail)
for role in skymail:access skymail:templates:read skymail:templates:write skymail:lists:read skymail:mails:read \
  skymail:mails:write skymail:mails:send skymail:mails:approve; do
  kcadm create "clients/$skymail/roles" -r "$REALM" -s "name=$role" >/dev/null
done
main=$(client_uuid frontend-main)
arge=$(client_uuid frontend-arge)
app=$(client_uuid skyapp)

# The realm scope groups (full path), production's hand-made frontend-main-core-audience (the Admin
# Console's shape, adopted by the reconciler) and production's shared skycms-audience: one mapper that
# names no audience, shown on the consent screen (skyapp-cms-editor-wizard --check, 2026-10-05).
groups_scope=$(kcadm create client-scopes -r "$REALM" -i -s name=groups -s protocol=openid-connect)
kcadm create "client-scopes/$groups_scope/protocol-mappers/models" -r "$REALM" -b '{"name":"groups","protocol":"openid-connect","protocolMapper":"oidc-group-membership-mapper","config":{"claim.name":"groups","full.path":"true","multivalued":"true","access.token.claim":"true","id.token.claim":"true","userinfo.token.claim":"true","introspection.token.claim":"true"}}' >/dev/null
main_core_scope=$(kcadm create client-scopes -r "$REALM" -i \
  -b '{"name":"frontend-main-core-audience","description":"","protocol":"openid-connect","attributes":{"include.in.token.scope":"true","display.on.consent.screen":"true","gui.order":"","consent.screen.text":""}}')
kcadm create "client-scopes/$main_core_scope/protocol-mappers/models" -r "$REALM" \
  -b '{"name":"core-audience","protocol":"openid-connect","protocolMapper":"oidc-audience-mapper","consentRequired":false,"config":{"included.client.audience":"core","id.token.claim":"false","access.token.claim":"true","lightweight.claim":"false","introspection.token.claim":"true"}}' >/dev/null
arge_core_scope=$(kcadm create client-scopes -r "$REALM" -i \
  -b '{"name":"frontend-arge-core-audience","protocol":"openid-connect","attributes":{"include.in.token.scope":"false","display.on.consent.screen":"false"}}')
kcadm create "client-scopes/$arge_core_scope/protocol-mappers/models" -r "$REALM" \
  -b "$(jq -c '.[0]' "$REPOSITORY_ROOT/config/frontend-arge-core-audience-mappers.json")" >/dev/null
skycms_scope=$(kcadm create client-scopes -r "$REALM" -i \
  -b '{"name":"skycms-audience","protocol":"openid-connect","attributes":{"include.in.token.scope":"true","display.on.consent.screen":"true"}}')
kcadm create "client-scopes/$skycms_scope/protocol-mappers/models" -r "$REALM" \
  -b '{"name":"audience-mapper","protocol":"openid-connect","protocolMapper":"oidc-audience-mapper","config":{"access.token.claim":"true","id.token.claim":"false","introspection.token.claim":"true"}}' >/dev/null
for scope in "$groups_scope" "$main_core_scope" "$skycms_scope"; do
  kcadm update "clients/$main/default-client-scopes/$scope" -r "$REALM" -n -b '{}' >/dev/null
done
kcadm update "clients/$arge/default-client-scopes/$arge_core_scope" -r "$REALM" -n -b '{}' >/dev/null
for client in "$skymail" "$app"; do
  kcadm update "clients/$client/default-client-scopes/$groups_scope" -r "$REALM" -n -b '{}' >/dev/null
done
json_assert "$(kcadm get "clients/$skymail/optional-client-scopes" -r "$REALM")" 'any(.[]; .name == "microprofile-jwt")' \
  'skymail did not get Keycloak'"'"'s optional microprofile-jwt'
# A hand-made role scope mapping on frontend-main: harmless while full scope is on, it would leak a
# realm role and a SkyMail role into the site's token once full scope is off.
kcadm create "clients/$main/scope-mappings/realm" -r "$REALM" \
  -b "$(kcadm get roles/offline_access -r "$REALM" | jq -c '[{id, name}]')" >/dev/null
kcadm create "clients/$main/scope-mappings/clients/$skymail" -r "$REALM" \
  -b "$(kcadm get "clients/$skymail/roles/skymail:access" -r "$REALM" | jq -c '[{id, name}]')" >/dev/null

# The CMS roles, the flat roles mapper, the groups mapper of frontend-arge and the service accounts'
# content:read + schema:sync, as in production.
out=$(run inscribed-cms-roles.sh "$REALM" --apply) || { printf '%s\n' "$out" >&2; fail 'inscribed-cms-roles.sh failed'; }

# Realm roles: production's admin token carried 12 (default-roles-e-skylab, offline_access,
# uma_authorization and nine more).
for role in legacy-admin legacy-yk legacy-member legacy-editor legacy-media legacy-events legacy-mail legacy-forms legacy-sky; do
  kcadm create roles -r "$REALM" -s "name=$role" >/dev/null
  kcadm create "groups/$admin_group/role-mappings/realm" -r "$REALM" \
    -b "$(kcadm get "roles/$role" -r "$REALM" | jq -c '[{id, name}]')" >/dev/null
done
# The admin panel's grants (runbook §12) and the Privileged person's roles of other clients.
for gid in "$admin_group" "$yk" "$dk" "$weblab_leaders"; do grant "$REALM" frontend-main cms:access "$gid"; done
for gid in "$admin_group" "$yk" "$weblab_leaders"; do grant "$REALM" frontend-arge cms:access "$gid"; done
for gid in "$admin_group" "$yk"; do
  grant "$REALM" frontend-main client:admin "$gid"
  grant "$REALM" frontend-arge client:admin "$gid"
done
for role in content:read content:write; do grant "$REALM" admin "$role" "$admin_group"; done
for role in url:create event:manage; do grant "$REALM" core "$role" "$admin_group"; done
grant "$REALM" forms skyforms:form:manage "$admin_group"
grant "$REALM" skycms cms:access "$admin_group"
grant "$REALM" skycloud skycloud:user "$admin_group"
grant "$REALM" skylapp url:create "$admin_group"
grant "$REALM" cloudflare-zero-trust access "$admin_group"
grant "$REALM" broker read-token "$admin_group"
for role in skymail:access skymail:templates:read skymail:templates:write skymail:lists:read skymail:mails:read \
  skymail:mails:write skymail:mails:send skymail:mails:approve; do
  grant "$REALM" skymail "$role" "$admin_group"
done
grant "$REALM" skymail skymail:access "$weblab_leaders"
grant "$REALM" skymail skymail:templates:read "$weblab_leaders"
person "$REALM" privileged "$admin_group" "$yk" "$weblab_leaders" "$uyeler"
person "$REALM" dkmember "$dk"
person "$REALM" leader "$weblab_leaders"
person "$REALM" member "$uyeler"
main_secret=$(client_secret frontend-main)
arge_secret=$(client_secret frontend-arge)
clients_before=$(for c in "$main" "$arge" "$skymail"; do kcadm get "clients/$c" -r "$REALM" | jq -c '{clientId, redirectUris, publicClient, serviceAccountsEnabled, attributes: {pkce: .attributes["pkce.code.challenge.method"]}}'; done)
mappers_before=$(for c in "$main" "$arge"; do kcadm get "clients/$c/protocol-mappers/models" -r "$REALM" | jq -c 'map({name, protocolMapper, config}) | sort_by(.name)'; done)

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='before: the hand-made full-scope tokens'
for who in privileged dkmember leader member; do
  keep before-main-$who "$(tokens frontend-main "$MAIN_CALLBACK" "$who")"
done
for who in privileged dkmember leader; do
  keep before-arge-$who "$(tokens frontend-arge "$ARGE_CALLBACK" "$who")"
done
keep before-mail-privileged "$(tokens skymail "$MAIL_CALLBACK" privileged)"
keep before-mail-leader "$(tokens skymail "$MAIL_CALLBACK" leader)"
keep before-main-service "$(service_tokens frontend-main)"
keep before-arge-service "$(service_tokens frontend-arge)"
access=$(access_of "$(kept before-main-privileged)")
printf '    frontend-main, privileged: %s\n' "$(jq -c "$SUMMARY" <<<"$access")"
json_assert "$access" "($AUD | index(\"skymail\")) != null and ($AUD | index(\"forms\")) != null and (.realm_access.roles | length) == 12 and (.resource_access | has(\"skyapp\") | not) and (.groups | length) == 4" \
  'the full-scope control token lacks the foreign audiences, the 12 realm roles or the 4 group paths; narrowing would prove nothing'
json_assert "$(access_of "$(kept before-main-member)")" "($AUD | index(\"skycms\")) == null" \
  'a member without a skycms role already had aud skycms on the main site (the fixture is not production-shaped)'
access=$(access_of "$(kept before-arge-dkmember)")
json_assert "$access" "($EDITOR_GATE) and ((.roles // []) | index(\"content:write\")) == null" \
  'the DK member did not open arge'"'"'s editor gate through the main site'"'"'s cms:access (the F15 control)'
access=$(access_of "$(kept before-mail-privileged)")
printf '    skymail, privileged:       %s\n' "$(jq -c "$SUMMARY" <<<"$access")"
json_assert "$access" '(.groups | length) == 4 and (.realm_access.roles | length) == 12' \
  'the SkyMail control token lacks the groups or the realm roles'

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='the step narrows the hand-made clients'
event_before=$(newest_admin_event)
sleep 1
output=$(step) || { printf '%s\n' "$output" >&2; fail 'the login client step failed'; }
printf '%s\n' "$output" | sed 's/^/    /'
expect_line "$output" 'Login client configuration is reconciled.' 'the step did not report completion'
expect_line "$output" '[reconcile] client scope frontend-main-core-audience: updated (attributes)' 'the hand-made core scope was not adopted'
expect_line "$output" '[reconcile] client scope skycms-audience: updated (attributes)' 'the shared skycms scope was not adopted'
expect_line "$output" "[reconcile] pruned protocol mappers from scope $skycms_scope: audience-mapper" 'the empty audience mapper was not pruned'
expect_line "$output" "[reconcile] protocol mappers of scope $skycms_scope: updated (+skycms-audience)" 'skycms-audience was not added'
expect_line "$output" "[reconcile] default client scope skycms-audience attached to client $arge" 'skycms-audience was not attached to frontend-arge'
expect_line "$output" '[reconcile] role scope mappings of frontend-main (none: only its own roles): updated (-realm/offline_access -skymail/skymail:access)' \
  'the hand-made role scope of frontend-main was not cleared'
expect_line "$output" '[reconcile] role scope mappings of frontend-arge (none: only its own roles): unchanged' 'frontend-arge role scope'
expect_line "$output" '[reconcile] role scope mappings of skymail (none: only its own roles): unchanged' 'skymail role scope'
for client in frontend-main frontend-arge skymail; do
  expect_line "$output" "[reconcile] client $client (no full scope): updated (fullScopeAllowed)" "full scope of $client not turned off"
done
expect_line "$output" '[reconcile] client scope skymail-api-audience: created' 'the SkyMail audience scope was not made'
expect_line "$output" "[reconcile] default client scope skymail-api-audience attached to client $skymail" 'the SkyMail audience scope was not attached'
expect_line "$output" '[reconcile] groups claim of skymail (none): updated (-default scope groups -optional scope microprofile-jwt)' \
  'the groups were not taken out of SkyMail'"'"'s token'
reject_line "$output" 'groups claim of frontend-' 'the sites'"'"' groups were touched'
reject_line "$output" 'WARNING' 'the step warned on a realm with every client'

CURRENT_STAGE='the narrowed contract'
for c in "$main" "$arge" "$skymail"; do
  json_assert "$(kcadm get "clients/$c" -r "$REALM")" '(.fullScopeAllowed | not)' 'a client still allows the full scope'
  json_assert "$(kcadm get "clients/$c/scope-mappings" -r "$REALM")" '((.realmMappings // []) | length) == 0 and ((.clientMappings // {}) | length) == 0' \
    'a client still has role scope mappings'
done
[[ $(client_secret frontend-main) == "$main_secret" && $(client_secret frontend-arge) == "$arge_secret" ]] \
  || fail 'the step changed a client secret'
[[ $(for c in "$main" "$arge" "$skymail"; do kcadm get "clients/$c" -r "$REALM" | jq -c '{clientId, redirectUris, publicClient, serviceAccountsEnabled, attributes: {pkce: .attributes["pkce.code.challenge.method"]}}'; done) == "$clients_before" ]] \
  || fail 'the step changed redirect URIs or flags of a client'
[[ $(for c in "$main" "$arge"; do kcadm get "clients/$c/protocol-mappers/models" -r "$REALM" | jq -c 'map({name, protocolMapper, config}) | sort_by(.name)'; done) == "$mappers_before" ]] \
  || fail 'the step changed the sites'"'"' own mappers'
[[ $(scope_uuid skycms-audience | wc -l | tr -d ' ') == 1 && $(scope_uuid skycms-audience) == "$skycms_scope" ]] \
  || fail 'the shared skycms-audience scope was replaced or duplicated'
json_assert "$(kcadm get "client-scopes/$skycms_scope/protocol-mappers/models" -r "$REALM")" \
  'length == 1 and .[0].name == "skycms-audience" and .[0].protocolMapper == "oidc-audience-mapper" and .[0].config["included.client.audience"] == "skycms" and .[0].config["access.token.claim"] == "true" and .[0].config["id.token.claim"] == "false" and .[0].config["introspection.token.claim"] == "true"' \
  'skycms-audience is not in the shape site-clients.sh makes'
json_assert "$(kcadm get "clients/$main/default-client-scopes" -r "$REALM")" 'any(.[]; .name == "groups") and any(.[]; .name == "skycms-audience") and any(.[]; .name == "frontend-main-core-audience")' \
  'frontend-main lost its groups or an audience scope'
json_assert "$(kcadm get "clients/$skymail/default-client-scopes" -r "$REALM")" '(any(.[]; .name == "groups") | not) and any(.[]; .name == "skymail-api-audience")' \
  'skymail still has the groups scope or lacks its audience scope'
json_assert "$(kcadm get "clients/$skymail/optional-client-scopes" -r "$REALM")" '(any(.[]; .name == "microprofile-jwt") | not)' \
  'skymail still has microprofile-jwt'
json_assert "$(kcadm get default-optional-client-scopes -r "$REALM")" 'any(.[]; .name == "microprofile-jwt")' \
  'the realm lost microprofile-jwt as an optional default scope'
json_assert "$(kcadm get "clients/$app/default-client-scopes" -r "$REALM")" 'any(.[]; .name == "groups")' \
  'another client (skyapp) lost the realm scope groups'

CURRENT_STAGE='after: the narrowed tokens'
for who in privileged dkmember leader member; do
  keep after-main-$who "$(tokens frontend-main "$MAIN_CALLBACK" "$who")"
done
for who in privileged dkmember leader; do
  keep after-arge-$who "$(tokens frontend-arge "$ARGE_CALLBACK" "$who")"
done
keep after-mail-privileged "$(tokens skymail "$MAIL_CALLBACK" privileged)"
keep after-mail-leader "$(tokens skymail "$MAIL_CALLBACK" leader)"
keep after-main-service "$(service_tokens frontend-main)"
keep after-arge-service "$(service_tokens frontend-arge)"
for key in main-privileged main-dkmember main-leader main-member arge-privileged arge-dkmember arge-leader; do
  before=$(access_of "$(kept before-$key)")
  after=$(access_of "$(kept after-$key)")
  client=$(jq -r .azp <<<"$after")
  json_assert "$after" "$AUD == [\"core\", \"skycms\"] and (has(\"realm_access\") | not) and (((.resource_access // {}) | keys) - [\$c] | length) == 0" \
    "$key: aud is not exactly core and skycms, or realm roles or another client's roles remain" --arg c "$client"
  [[ $(jq -c "$SITE_VIEW" <<<"$after") == "$(jq -c "$SITE_VIEW" <<<"$before")" ]] \
    || { jq -c "$SITE_VIEW" <<<"$before" >&2; jq -c "$SITE_VIEW" <<<"$after" >&2; fail "$key: a claim the site, core or inscribed reads changed"; }
  [[ $(jq -c '{name, email, sub}' <<<"$(id_of "$(kept after-$key)")") == "$(jq -c '{name, email, sub}' <<<"$(id_of "$(kept before-$key)")")" ]] \
    || fail "$key: the ID token's name, e-mail or sub changed"
done
for key in main-service arge-service; do
  before=$(access_of "$(kept before-$key)")
  after=$(access_of "$(kept after-$key)")
  json_assert "$after" "$AUD == [\"core\", \"skycms\"] and ((.roles // []) | sort) == [\"content:read\", \"schema:sync\"] and (has(\"realm_access\") | not)" \
    "$key: the service-account token lost aud skycms or its content:read + schema:sync"
  json_assert "$before" '((.roles // []) | sort) == ["content:read", "schema:sync"]' "$key: the control service token differs"
done
printf '    frontend-main, privileged: %s\n' "$(jq -c "$SUMMARY" <<<"$(access_of "$(kept after-main-privileged)")")"
json_assert "$(access_of "$(kept after-main-privileged)")" '(.resource_access["frontend-main"].roles | sort) == ["client:admin", "cms:access", "content:read", "content:write"] and (.roles | sort) == ["client:admin", "cms:access", "content:read", "content:write"]' \
  'the Privileged person lost a main-site CMS role'
json_assert "$(access_of "$(kept after-main-member)")" "$AUD == [\"core\", \"skycms\"] and ((.resource_access // {}) | length) == 0" \
  'a plain member did not get aud skycms on the main site'
# The editor gates: unchanged for the main site; the DK member no longer opens arge's editor (F15).
for key in main-privileged main-dkmember main-leader main-member arge-privileged arge-leader; do
  [[ $(jq -c "$EDITOR_GATE" <<<"$(access_of "$(kept after-$key)")") == "$(jq -c "$EDITOR_GATE" <<<"$(access_of "$(kept before-$key)")")" ]] \
    || fail "$key: the site's editor gate changed"
done
json_assert "$(access_of "$(kept after-arge-dkmember)")" "($EDITOR_GATE | not)" 'the DK member still opens arge'"'"'s editor gate'
for key in mail-privileged mail-leader; do
  before=$(access_of "$(kept before-$key)")
  after=$(access_of "$(kept after-$key)")
  json_assert "$after" "$AUD == [\"skymail\"] and (has(\"realm_access\") | not) and (has(\"groups\") | not) and ((.resource_access // {}) | keys) == [\"skymail\"]" \
    "$key: aud is not exactly skymail, or realm roles, groups or another client's roles remain"
  [[ $(jq -c "$MAIL_VIEW" <<<"$after") == "$(jq -c "$MAIL_VIEW" <<<"$before")" ]] \
    || { jq -c "$MAIL_VIEW" <<<"$before" >&2; jq -c "$MAIL_VIEW" <<<"$after" >&2; fail "$key: a claim SkyMail reads changed"; }
  json_assert "$(id_of "$(kept after-$key)")" '(.name | length) > 0 and (.email | length) > 0 and (has("groups") | not)' \
    "$key: the ID token lost name or e-mail, or still carries groups"
  # SkyMail's backend authenticates every /v1 call with Keycloak userinfo.
  userinfo=$(printf 'Authorization: Bearer %s\n' "$(jq -r .access_token <<<"$(kept after-$key)")" \
    | curl -fsS -H @- "$BASE_URL/realms/$REALM/protocol/openid-connect/userinfo")
  json_assert "$userinfo" '.sub == $s and (.name | length) > 0 and (.email | length) > 0 and .email_verified == true and (has("groups") | not)' \
    "$key: userinfo no longer answers SkyMail's backend with sub, name and e-mail" --arg s "$(jq -r .sub <<<"$after")"
done
printf '    skymail, privileged:       %s\n' "$(jq -c "$SUMMARY" <<<"$(access_of "$(kept after-mail-privileged)")")"
size_line 'frontend-main, Privileged person' "$(kept before-main-privileged)" "$(kept after-main-privileged)"
size_line 'frontend-main, team leader' "$(kept before-main-leader)" "$(kept after-main-leader)"
size_line 'frontend-arge, Privileged person' "$(kept before-arge-privileged)" "$(kept after-arge-privileged)"
size_line 'frontend-arge, team leader' "$(kept before-arge-leader)" "$(kept after-arge-leader)"
size_line 'skymail, Privileged person' "$(kept before-mail-privileged)" "$(kept after-mail-privileged)"
size_line 'skymail, team leader' "$(kept before-mail-leader)" "$(kept after-mail-leader)"

CURRENT_STAGE='sessions opened before the step'
# A session opened before the step gets the narrowed token on its next refresh (the sites and SkyMail
# refresh without a scope parameter): nobody has to sign in again.
for pair in 'main-privileged frontend-main' 'arge-leader frontend-arge' 'mail-privileged skymail'; do
  read -r key client <<<"$pair"
  refreshed=$(refresh "$client" "$(kept before-$key)") || fail "$key: the refresh of a session opened before the step failed"
  before=$(access_of "$(kept before-$key)")
  after=$(access_of "$refreshed")
  if [[ $client == skymail ]]; then
    json_assert "$after" "$AUD == [\"skymail\"] and (has(\"groups\") | not) and (has(\"realm_access\") | not)" "$key: the refreshed token is not narrowed"
    [[ $(jq -c "$MAIL_VIEW" <<<"$after") == "$(jq -c "$MAIL_VIEW" <<<"$before")" ]] || fail "$key: the refresh changed a claim SkyMail reads"
  else
    json_assert "$after" "$AUD == [\"core\", \"skycms\"] and (has(\"realm_access\") | not) and ((.resource_access // {}) | keys) == [\$c]" \
      "$key: the refreshed token is not narrowed" --arg c "$client"
    [[ $(jq -c "$SITE_VIEW" <<<"$after") == "$(jq -c "$SITE_VIEW" <<<"$before")" ]] || fail "$key: the refresh changed a claim the site reads"
  fi
done
printf '    sessions opened before the step: the next refresh gives the narrowed token (main site, arge, SkyMail)\n'

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='a second run writes nothing'
event_before=$(newest_admin_event)
sleep 1
output=$(step) || { printf '%s\n' "$output" >&2; fail 'the second run failed'; }
no_admin_event_since "$event_before" 'the second run wrote to the realm'
reject_line "$output" ': updated' 'the second run reported a change'
reject_line "$output" 'attached' 'the second run attached a scope'
printf '    second run: no admin event\n'

CURRENT_STAGE='the other scripts agree'
out=$(run inscribed-cms-roles.sh "$REALM" --check) || { printf '%s\n' "$out" >&2; fail 'inscribed-cms-roles.sh --check failed after the step'; }
expect_line "$out" 'check: 0 change(s) pending' 'inscribed-cms-roles.sh wants to change the narrowed clients'
expect_line "$out" 'frontend-main: fullScopeAllowed=false' 'inscribed-cms-roles.sh did not see the narrowed frontend-main'
printf '    inscribed-cms-roles.sh --check: 0 changes\n'
# SkyApp's CMS editing (e-skylab-keycloak#62) needed a working skycms-audience; the step repaired it.
out=$(run skyapp-cms-editor.sh "$REALM" --apply) || { printf '%s\n' "$out" >&2; fail 'skyapp-cms-editor.sh failed after the step'; }
expect_line "$out" 'applied ' 'skyapp-cms-editor.sh did not apply'
event_before=$(newest_admin_event)
sleep 1
output=$(step) || { printf '%s\n' "$output" >&2; fail 'the step failed after skyapp-cms-editor.sh'; }
no_admin_event_since "$event_before" 'the step undid part of skyapp-cms-editor.sh'
# Keycloak expands the composites of the roles in a client's scope, and a client's own roles are always
# in it: frontend-main's cms:access now includes skyapp's CMS roles, so an editor's site token carries
# them (and aud skyapp) even without full scope. Nothing reads them there: inscribed reads the flat
# roles (frontend-main's own) and the site's editor gate opens on the same cms:access holders.
access=$(access_of "$(tokens frontend-main "$MAIN_CALLBACK" leader)")
json_assert "$access" "$AUD == [\"core\", \"skyapp\", \"skycms\"] and ((.resource_access // {}) | keys) == [\"frontend-main\", \"skyapp\"]
  and (.resource_access.skyapp.roles | sort) == [\"cms:access\", \"content:read\", \"content:write\"]
  and (.roles | sort) == [\"cms:access\", \"content:read\", \"content:write\"] and (has(\"realm_access\") | not)" \
  'the main site'"'"'s token carries more than its own roles and the SkyApp roles of its composites'
json_assert "$(access_of "$(tokens frontend-main "$MAIN_CALLBACK" member)")" '((.resource_access // {}) | length) == 0' \
  'a member without a main-site role got SkyApp roles on the main site'
json_assert "$(access_of "$(tokens skyapp "$APP_CALLBACK" leader)")" '((.resource_access.skyapp.roles // []) | index("cms:access")) != null and ((.aud | if type == "array" then . else [.] end) | index("skycms")) != null' \
  'SkyApp lost the CMS role it gets through frontend-main'"'"'s cms:access'
printf '    skyapp-cms-editor.sh applies after the step; SkyApp gets cms:access through frontend-main; the site token adds only the SkyApp roles of its own composites; the step after it writes nothing\n'

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='skycms-audience: the step and site-clients.sh --shared-scope agree'
# Two writers of the shared scope: this step (config/skycms-audience-mappers.json) and
# site-clients.sh --shared-scope, which repairs it on its own before a release. Each must leave
# nothing for the other to do.
out=$(run site-clients.sh "$REALM" --check --shared-scope) \
  || { printf '%s\n' "$out" >&2; fail 'site-clients.sh --shared-scope --check failed after the step'; }
expect_line "$out" 'client scope skycms-audience: attributes unchanged' 'site-clients.sh wants other attributes than the step wrote'
expect_line "$out" 'client scope skycms-audience: mapper skycms-audience unchanged' 'site-clients.sh wants another mapper than the step wrote'
expect_line "$out" 'check: 0 change(s) pending, 0 warning(s), 0 problem(s)' 'site-clients.sh --shared-scope plans changes after the step'
skycms_mappers() { kcadm get "client-scopes/$skycms_scope/protocol-mappers/models" -r "$REALM" | jq -cS 'map(del(.id)) | sort_by(.name)'; }
skycms_shape() { kcadm get "client-scopes/$skycms_scope" -r "$REALM" | jq -cS 'del(.id, .protocolMappers)'; }
step_mappers=$(skycms_mappers)
step_shape=$(skycms_shape)
# Back to production's hand-made shape; this time site-clients.sh repairs it.
kcadm delete "client-scopes/$skycms_scope/protocol-mappers/models/$(kcadm get "client-scopes/$skycms_scope/protocol-mappers/models" -r "$REALM" \
  | jq -r '.[] | select(.name == "skycms-audience") | .id')" -r "$REALM" >/dev/null
kcadm create "client-scopes/$skycms_scope/protocol-mappers/models" -r "$REALM" \
  -b '{"name":"audience-mapper","protocol":"openid-connect","protocolMapper":"oidc-audience-mapper","config":{"access.token.claim":"true","id.token.claim":"false","introspection.token.claim":"true"}}' >/dev/null
kcadm update "client-scopes/$skycms_scope" -r "$REALM" -s 'attributes."include.in.token.scope"=true' \
  -s 'attributes."display.on.consent.screen"=true' >/dev/null
out=$(run site-clients.sh "$REALM" --apply --shared-scope) \
  || { printf '%s\n' "$out" >&2; fail 'site-clients.sh --shared-scope --apply failed'; }
expect_line "$out" 'applied 3 change(s), 0 warning(s), 0 problem(s)' 'site-clients.sh --shared-scope did not repair the hand-made shape'
[[ $(skycms_mappers) == "$step_mappers" ]] \
  || { printf 'step: %s\nsite-clients.sh: %s\n' "$step_mappers" "$(skycms_mappers)" >&2; fail 'site-clients.sh wrote another skycms-audience mapper than the step'; }
[[ $(skycms_shape) == "$step_shape" ]] \
  || { printf 'step: %s\nsite-clients.sh: %s\n' "$step_shape" "$(skycms_shape)" >&2; fail 'site-clients.sh left the skycms-audience scope otherwise than the step'; }
event_before=$(newest_admin_event)
sleep 1
output=$(step) || { printf '%s\n' "$output" >&2; fail 'the step failed after site-clients.sh --shared-scope'; }
no_admin_event_since "$event_before" 'the step rewrote the skycms-audience scope site-clients.sh had repaired'
json_assert "$(access_of "$(tokens frontend-main "$MAIN_CALLBACK" member)")" "$AUD == [\"core\", \"skycms\"]" \
  'a member lost aud skycms on the main site after site-clients.sh repaired the scope'
printf '    skycms-audience: site-clients.sh --shared-scope plans nothing after the step; it writes the same scope and mapper as the step, and the step then writes nothing\n'

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='drift is repaired'
kcadm update "clients/$arge" -r "$REALM" -s fullScopeAllowed=true >/dev/null
kcadm create "clients/$main/scope-mappings/realm" -r "$REALM" \
  -b "$(kcadm get roles/legacy-admin -r "$REALM" | jq -c '[{id, name}]')" >/dev/null
kcadm create "clients/$arge/scope-mappings/clients/$(client_uuid core)" -r "$REALM" \
  -b "$(kcadm get "clients/$(client_uuid core)/roles/url:create" -r "$REALM" | jq -c '[{id, name}]')" >/dev/null
kcadm delete "clients/$arge/default-client-scopes/$skycms_scope" -r "$REALM" >/dev/null
kcadm update "clients/$arge/optional-client-scopes/$skycms_scope" -r "$REALM" -n -b '{}' >/dev/null
mapper=$(kcadm get "client-scopes/$skycms_scope/protocol-mappers/models" -r "$REALM" | jq -r '.[0].id')
kcadm update "client-scopes/$skycms_scope/protocol-mappers/models/$mapper" -r "$REALM" -s 'config."id.token.claim"=true' >/dev/null
kcadm create "client-scopes/$skycms_scope/protocol-mappers/models" -r "$REALM" \
  -b '{"name":"unexpected","protocol":"openid-connect","protocolMapper":"oidc-audience-mapper","config":{"included.custom.audience":"unexpected","access.token.claim":"true"}}' >/dev/null
kcadm update "clients/$skymail/default-client-scopes/$groups_scope" -r "$REALM" -n -b '{}' >/dev/null
kcadm create "clients/$skymail/protocol-mappers/models" -r "$REALM" \
  -b '{"name":"skymail-groups","protocol":"openid-connect","protocolMapper":"oidc-group-membership-mapper","config":{"claim.name":"groups","full.path":"true","access.token.claim":"true"}}' >/dev/null
kcadm delete "clients/$skymail/default-client-scopes/$(scope_uuid skymail-api-audience)" -r "$REALM" >/dev/null
output=$(step) || { printf '%s\n' "$output" >&2; fail 'the repairing run failed'; }
for expected in \
  '[reconcile] client frontend-arge (no full scope): updated (fullScopeAllowed)' \
  '[reconcile] role scope mappings of frontend-main (none: only its own roles): updated (-realm/legacy-admin)' \
  '[reconcile] role scope mappings of frontend-arge (none: only its own roles): updated (-core/url:create)' \
  '[reconcile] client frontend-arge: detached optional scope skycms-audience (it must be a default scope)' \
  "[reconcile] default client scope skycms-audience attached to client $arge" \
  "[reconcile] pruned protocol mappers from scope $skycms_scope: unexpected" \
  "[reconcile] protocol mappers of scope $skycms_scope: updated (~skycms-audience)" \
  "[reconcile] default client scope skymail-api-audience attached to client $skymail" \
  '[reconcile] groups claim of skymail (none): updated (-default scope groups -mapper skymail-groups)'; do
  expect_line "$output" "$expected" 'the drift was not repaired'
done
json_assert "$(access_of "$(tokens frontend-arge "$ARGE_CALLBACK" privileged)")" "$AUD == [\"core\", \"skycms\"] and (has(\"realm_access\") | not) and ((.resource_access // {}) | keys) == [\"frontend-arge\"]" \
  'the repaired frontend-arge token differs from the contract'
json_assert "$(access_of "$(tokens skymail "$MAIL_CALLBACK" privileged)")" "$AUD == [\"skymail\"] and (has(\"groups\") | not)" \
  'the repaired SkyMail token differs from the contract'
event_before=$(newest_admin_event)
sleep 1
output=$(step) || { printf '%s\n' "$output" >&2; fail 'the run after the repair failed'; }
no_admin_event_since "$event_before" 'the run after the repair wrote to the realm'
printf '    drift repaired; the next run writes nothing\n'

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='sandbox realm: the clients the operator scripts make'
kcadm create realms -s realm="$SANDBOX_REALM" -s enabled=true -s adminEventsEnabled=true >/dev/null
for client in skycms core; do
  kcadm create clients -r "$SANDBOX_REALM" -s "clientId=$client" -s publicClient=false -s standardFlowEnabled=false >/dev/null
done
sandbox_admin=$(group "$SANDBOX_REALM" '' ADMIN)
for script_args in 'site-clients.sh --apply --site main' 'sandbox-site-clients.sh --apply' \
  'inscribed-cms-roles.sh --apply --client frontend-main --client frontend-arge'; do
  read -r -a words <<<"$script_args"
  out=$(run "${words[0]}" "$SANDBOX_REALM" "${words[@]:1}") || { printf '%s\n' "$out" >&2; fail "${words[0]} failed in the sandbox"; }
done
for client in frontend-main frontend-arge; do grant "$SANDBOX_REALM" "$client" cms:access "$sandbox_admin"; done
person "$SANDBOX_REALM" sandboxadmin "$sandbox_admin"
event_before=$(newest_admin_event "$SANDBOX_REALM")
sleep 1
output=$(step "$SANDBOX_REALM") || { printf '%s\n' "$output" >&2; fail 'the step failed in the sandbox'; }
printf '%s\n' "$output" | sed 's/^/    /'
expect_line "$output" "[reconcile] WARNING: client skymail does not exist in realm $SANDBOX_REALM; skipped client scope skymail-api-audience and its token narrowing" \
  'the missing sandbox skymail was not reported'
expect_line "$output" "[reconcile] default client scope skycms-audience attached to client $(client_uuid frontend-arge "$SANDBOX_REALM")" \
  'skycms-audience was not attached to the sandbox frontend-arge'
changes=$(grep -E 'updated|attached|created|pruned|detached' <<<"$output" || true)
[[ $(grep -c . <<<"$changes") == 1 ]] \
  || { printf '%s\n' "$changes" >&2; fail 'the step changed more in the sandbox than attaching skycms-audience to frontend-arge'; }
event_before=$(newest_admin_event "$SANDBOX_REALM")
sleep 1
output=$(step "$SANDBOX_REALM") || { printf '%s\n' "$output" >&2; fail 'the second sandbox run failed'; }
no_admin_event_since "$event_before" 'the second sandbox run wrote to the realm' "$SANDBOX_REALM"
for script_args in 'site-clients.sh --check --site main' 'sandbox-site-clients.sh --check' \
  'inscribed-cms-roles.sh --check --client frontend-main --client frontend-arge'; do
  read -r -a words <<<"$script_args"
  out=$(run "${words[0]}" "$SANDBOX_REALM" "${words[@]:1}") || { printf '%s\n' "$out" >&2; fail "${words[0]} --check failed after the step"; }
  expect_line "$out" 'check: 0 change(s) pending' "${words[0]} wants to change what the step left"
done
for pair in "frontend-main $SANDBOX_MAIN_CALLBACK" "frontend-arge $SANDBOX_ARGE_CALLBACK"; do
  read -r client callback <<<"$pair"
  json_assert "$(access_of "$(tokens "$client" "$callback" sandboxadmin "$SANDBOX_REALM")")" \
    "$AUD == [\"core\", \"skycms\"] and ((.resource_access // {}) | keys) == [\$c] and (.groups == [\"/ADMIN\"]) and ((.roles // []) | index(\"content:write\")) != null" \
    "the sandbox $client token differs from the contract" --arg c "$client"
done
printf '    sandbox: one change (skycms-audience on frontend-arge), skymail missing is a WARNING; site-clients.sh, sandbox-site-clients.sh and inscribed-cms-roles.sh --check plan nothing afterwards\n'

# ---------------------------------------------------------------------------------------------
CURRENT_STAGE='sizes'
printf '    access token sizes, real logins (openid email profile), before -> after the step:\n%s' "$SIZES"
printf 'login-clients: all stages passed\n'
