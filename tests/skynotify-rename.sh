#!/usr/bin/env bash
# Real-Keycloak contract for config/skynotify-rename.sh (sky_lab_genel .scratch/skynotify-ad ticket
# 07). Stand-alone: starts the stock Keycloak image this repository builds on (the Dockerfile's
# KEYCLOAK_IMAGE) in dev mode with docker run --rm and no volume, and runs the script inside that
# container the way the window's wizard does (--kcadm-config): the stock image stands for the old
# production image, which has none of this repository's code.
#
# Fixtures: realm e-skylab with SkyMail's objects under their old names, as production has them:
#   clients skymail (the UI's login client, with SkyMail's roles and a User Profile mapper of the
#   out-of-scope skyMail attribute), skymail-backend and skymail-seed (service accounts),
#   core (a service account holding skymail:access and skymail:mails:send, with the client scope
#   skymail-api-audience among its default scopes), keycloak-mailer (a narrowed service account
#   holding skymail:mails:send, the role in its role scope) and forms (unrelated);
#   client scopes skymail-api-audience and account-erase-skymail with Audience mappers
#   (included.client.audience=skymail); groups /ROLLER/SKYMAIL-ACCESS and /ROLLER/SKYMAIL-MAILS-WRITE
#   with production's display_name_tr and description_tr, and /ROLLER/FORMS-ACCESS; one person in
#   /ROLLER/SKYMAIL-ACCESS who also holds skymail:mails:send directly.
# Realm e-skylab-sandbox holds both skymail and skynotify (a rename that cannot be one).
#
# What it proves:
#   - realms other than e-skylab and e-skylab-sandbox are refused before anything is read (exit 2);
#     a missing realm is exit 1;
#   - the dry run lists exactly the eleven renames and each renamed role's holders, prints no
#     person's name or id and changes nothing;
#   - a realm where the new name is already taken is a PROBLEM: exit 1, nothing written;
#   - --apply renames in place: client uuids, secrets and service account users are kept (their
#     usernames follow the client), role, group and client scope ids are kept, every role mapping
#     (users, groups, role scope) stays, the Audience mappers name skynotify, the texts follow the
#     Turkish rule and equal what this repository writes (config/role-groups.json, the reconciler's
#     SKYNOTIFY_PRIVILEGED_ROLE_DEFINITIONS); the skyMail mapper and the unrelated objects are
#     untouched; core's client-credentials token then carries aud skynotify and
#     resource_access.skynotify instead of skymail;
#   - a second --apply renames nothing;
#   - --reverse --apply restores every object exactly as it was read before (the rollback).
# Requirements on the host: docker, jq, curl. SKYNOTIFY_RENAME_TEST_PORT (default 18102),
# SKYNOTIFY_RENAME_TEST_CONTAINER (default skynotify-rename-test-<pid>), SKYNOTIFY_RENAME_TEST_MEMORY
# (default 2g).
# shellcheck disable=SC2016  # jq programs name jq variables
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=kcadm-jvm.sh
source "$SCRIPT_DIR/kcadm-jvm.sh"
# shellcheck source=kcadm-rest.sh
source "$SCRIPT_DIR/kcadm-rest.sh"
REPOSITORY_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
OPERATOR_SCRIPT="$REPOSITORY_ROOT/config/skynotify-rename.sh"
IMAGE=$(sed -n 's/^ARG KEYCLOAK_IMAGE=//p' "$REPOSITORY_ROOT/Dockerfile")
PORT=${SKYNOTIFY_RENAME_TEST_PORT:-18102}
BASE_URL="http://127.0.0.1:$PORT"
CONTAINER=${SKYNOTIFY_RENAME_TEST_CONTAINER:-skynotify-rename-test-$$}
MEMORY=${SKYNOTIFY_RENAME_TEST_MEMORY:-2g}
ADMIN_PASSWORD=harness-admin-password
KCADM_CONFIG=/tmp/harness-kcadm.config
IN_CONTAINER_SCRIPT=/tmp/skynotify-rename.sh
REALM=e-skylab
SANDBOX=e-skylab-sandbox
PERSON=snr-member
CURRENT_STAGE=startup

fail() {
  printf 'skynotify-rename failure during %s: %s\n' "$CURRENT_STAGE" "$1" >&2
  exit 1
}
cleanup() {
  kcadm_rest_cleanup
  docker rm -fv "$CONTAINER" >/dev/null 2>&1 || true
}
trap 'status=$?; trap - EXIT; cleanup; exit "$status"' EXIT
on_error() {
  local status=$?
  printf 'skynotify-rename command failed during %s (line %s)\n' "$CURRENT_STAGE" "$1" >&2
  exit "$status"
}
trap 'on_error "$LINENO"' ERR

# kcadm "get" reads go to Admin REST from the host (tests/kcadm-rest.sh); writes stay on kcadm.
kcadm_rest_setup "$BASE_URL" "$ADMIN_PASSWORD"

kcadm() {
  local command=$1
  shift
  if kcadm_rest_handles "$command" "$@"; then
    kcadm_rest_get "$@"
    return
  fi
  docker exec -i "$CONTAINER" /opt/keycloak/bin/kcadm.sh "$command" --config "$KCADM_CONFIG" "$@" \
    2> >(grep -v -e '^Created new ' -e '^$' >&2 || true)
}

# run_expecting STATUS REALM ARGS...: the operator script inside the container, for a run that must
# exit STATUS; prints the output.
run_expecting() {
  local wanted=$1 realm=$2 output status=0
  shift 2
  trap - ERR
  output=$(docker exec -e KEYCLOAK_ADMIN_URL=http://localhost:8080 "$CONTAINER" \
    bash "$IN_CONTAINER_SCRIPT" --realm "$realm" --kcadm-config "$KCADM_CONFIG" "$@" 2>&1) || status=$?
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

# indent TEXT: the script's own output under the stage line, for the CI log.
indent() {
  local line
  while IFS= read -r line; do
    printf '      %s\n' "$line"
  done <<<"$1"
}

client_uuid() { # client_uuid REALM CLIENT_ID
  kcadm get clients -r "$1" -q "clientId=$2" | jq -r '.[0].id // empty'
}

role_id() { # role_id CLIENT_UUID ROLE
  kcadm get "clients/$1/roles/$2" -r "$REALM" | jq -r .id
}

group_id() { # group_id PATH
  kcadm get "group-by-path/$1" -r "$REALM" | jq -r .id
}

scope_id() { # scope_id NAME
  kcadm get client-scopes -r "$REALM" | jq -r --arg name "$1" '.[] | select(.name == $name) | .id'
}

secret_of() { # secret_of CLIENT_UUID
  kcadm get "clients/$1/client-secret" -r "$REALM" | jq -r '.value // empty'
}

jwt_payload() {
  local segment
  segment=$(cut -d. -f2 <<<"$1")
  case $((${#segment} % 4)) in
    2) segment="${segment}==" ;;
    3) segment="${segment}=" ;;
  esac
  tr '_-' '/+' <<<"$segment" | base64 --decode
}

# core_claims: aud and the client roles of core's client-credentials access token.
core_claims() {
  local token
  token=$(curl --fail --silent --show-error --user "core:$(secret_of "$core")" -d grant_type=client_credentials \
    "$BASE_URL/realms/$REALM/protocol/openid-connect/token" | jq -r .access_token)
  [[ -n $token && $token != null ]] || fail 'no access token for core'
  jwt_payload "$token" | jq -c '{aud: ([.aud] | flatten | map(select(. != "account")) | sort), roles: (.resource_access // {} | del(.account) | map_values(.roles | sort))}'
}

# snapshot: every object the script may touch, read by id and normalised (mapper lists sorted), so
# that a rename and its reverse can be compared whole.
snapshot() {
  local id clients=() roles=() groups=() scopes=() sas=()
  for id in "$skymail" "$backend" "$seed" "$core" "$mailer" "$forms"; do
    clients+=("$(kcadm get "clients/$id" -r "$REALM" | jq -S -c '.protocolMappers |= ((. // []) | sort_by(.id))')")
  done
  for id in "$role_access" "$role_send" "$role_system" "$role_suppressions"; do
    roles+=("$(kcadm get "roles-by-id/$id" -r "$REALM" | jq -S -c .)")
  done
  for id in "$group_access" "$group_write" "$group_forms"; do
    groups+=("$(kcadm get "groups/$id" -r "$REALM" | jq -S -c 'del(.subGroupCount)')")
  done
  for id in "$scope_audience" "$scope_erase"; do
    scopes+=("$(kcadm get "client-scopes/$id" -r "$REALM" | jq -S -c '.protocolMappers |= ((. // []) | sort_by(.id))')")
  done
  for id in "$backend" "$seed" "$core" "$mailer"; do
    sas+=("$(kcadm get "clients/$id/service-account-user" -r "$REALM" | jq -S -c '{id, username}')")
  done
  jq -S -c -n '$ARGS.positional | map(fromjson)' --args "${clients[@]}" "${roles[@]}" "${groups[@]}" "${scopes[@]}" "${sas[@]}"
}

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='Keycloak start'
[[ -n $IMAGE ]] || fail 'Dockerfile has no ARG KEYCLOAK_IMAGE'
command -v jq >/dev/null || fail 'jq is required'
docker run --rm -d --name "$CONTAINER" --memory "$MEMORY" -p "127.0.0.1:$PORT:8080" \
  -e KC_OPTS="$KCADM_JVM_STANDALONE_OPTS" \
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
kcadm_jvm_dump "$CONTAINER" "$KCADM_CONFIG"
docker exec -i "$CONTAINER" sh -c "cat > $IN_CONTAINER_SCRIPT" <"$OPERATOR_SCRIPT"

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='refused and missing realms'
for realm in master other-realm ''; do
  refused=$(run_expecting 2 "$realm" --apply)
  expect_line "$refused" "refusing realm ${realm:-(unset)}" 'realm not refused'
  reject_line "$refused" 'realm=' 'the refused run went on'
done
missing=$(run_expecting 1 "$REALM")
expect_line "$missing" "realm $REALM does not exist or cannot be read; nothing was changed" 'missing realm not reported'
printf '    master, other-realm and no realm refused (exit 2); a missing realm is exit 1\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='e-skylab fixture'
kcadm create realms -s "realm=$REALM" -s enabled=true >/dev/null
kcadm create clients -r "$REALM" -s clientId=skymail -s name=SkyMail -s "description=SkyMail'in arayüzü (iletişim konsolu)" \
  -s publicClient=true -s standardFlowEnabled=true -s 'redirectUris=["https://notify.yildizskylab.com/*"]' >/dev/null
kcadm create clients -r "$REALM" -s clientId=skymail-backend -s publicClient=false -s serviceAccountsEnabled=true \
  -s standardFlowEnabled=false -s rootUrl=https://api.yildizskylab.com/api/skymail >/dev/null
kcadm create clients -r "$REALM" -s clientId=skymail-seed -s publicClient=false -s serviceAccountsEnabled=true \
  -s standardFlowEnabled=false >/dev/null
kcadm create clients -r "$REALM" -s clientId=core -s publicClient=false -s serviceAccountsEnabled=true \
  -s standardFlowEnabled=false >/dev/null
kcadm create clients -r "$REALM" -s clientId=keycloak-mailer -s publicClient=false -s serviceAccountsEnabled=true \
  -s standardFlowEnabled=false -s fullScopeAllowed=false >/dev/null
kcadm create clients -r "$REALM" -s clientId=forms -s description=Forms -s publicClient=false \
  -s serviceAccountsEnabled=true -s standardFlowEnabled=false >/dev/null
skymail=$(client_uuid "$REALM" skymail)
backend=$(client_uuid "$REALM" skymail-backend)
seed=$(client_uuid "$REALM" skymail-seed)
core=$(client_uuid "$REALM" core)
mailer=$(client_uuid "$REALM" keycloak-mailer)
forms=$(client_uuid "$REALM" forms)
# The out-of-scope User Profile attribute skyMail, as a mapper of the client being renamed.
kcadm create "clients/$skymail/protocol-mappers/models" -r "$REALM" -s name=skyMail -s protocol=openid-connect \
  -s protocolMapper=oidc-usermodel-attribute-mapper -s 'config."user.attribute"=skyMail' \
  -s 'config."claim.name"=skyMail' -s 'config."access.token.claim"=false' -s 'config."id.token.claim"=true' >/dev/null

kcadm create "clients/$skymail/roles" -r "$REALM" -s name=skymail:access \
  -s "description=SkyMail'e girer; diğer SkyMail rolleri bunun üstüne eklenir." >/dev/null
kcadm create "clients/$skymail/roles" -r "$REALM" -s name=skymail:mails:send >/dev/null
kcadm create "clients/$skymail/roles" -r "$REALM" -s name=skymail:templates:system \
  -s "description=The Template seed marks a template as a system template (skymail-backend README). skymail-seed's service account only." >/dev/null
kcadm create "clients/$skymail/roles" -r "$REALM" -s name=skymail:suppressions:manage \
  -s 'description=SkyMail: bastırma listesini görür, kalıcı ret (bounce) kaydını kaldırır, bounce oranını okur (ADR 0073)' \
  -s 'attributes.seeded=["2026-11-01T00:00:00Z where skymail:suppressions:manage is held: groups 2"]' >/dev/null
role_access=$(role_id "$skymail" skymail:access)
role_send=$(role_id "$skymail" skymail:mails:send)
role_system=$(role_id "$skymail" skymail:templates:system)
role_suppressions=$(role_id "$skymail" skymail:suppressions:manage)

kcadm add-roles -r "$REALM" --uusername service-account-core --cclientid skymail \
  --rolename skymail:access --rolename skymail:mails:send >/dev/null
kcadm add-roles -r "$REALM" --uusername service-account-keycloak-mailer --cclientid skymail --rolename skymail:mails:send >/dev/null
kcadm add-roles -r "$REALM" --uusername service-account-skymail-seed --cclientid skymail --rolename skymail:templates:system >/dev/null
kcadm create "clients/$mailer/scope-mappings/clients/$skymail" -r "$REALM" \
  -b "[{\"id\":\"$role_send\",\"name\":\"skymail:mails:send\"}]" >/dev/null

kcadm create client-scopes -r "$REALM" -s name=skymail-api-audience -s protocol=openid-connect \
  -s 'attributes."include.in.token.scope"=false' -s 'attributes."display.on.consent.screen"=false' >/dev/null
kcadm create client-scopes -r "$REALM" -s name=account-erase-skymail -s protocol=openid-connect \
  -s 'description=core erases a person in SkyMail' -s 'attributes."include.in.token.scope"=true' >/dev/null
scope_audience=$(scope_id skymail-api-audience)
scope_erase=$(scope_id account-erase-skymail)
kcadm create "client-scopes/$scope_audience/protocol-mappers/models" -r "$REALM" -s name=skymail-audience \
  -s protocol=openid-connect -s protocolMapper=oidc-audience-mapper -s 'config."included.client.audience"=skymail' \
  -s 'config."access.token.claim"=true' -s 'config."id.token.claim"=false' -s 'config."introspection.token.claim"=true' >/dev/null
kcadm create "client-scopes/$scope_erase/protocol-mappers/models" -r "$REALM" -s name=account-erase-skymail-audience \
  -s protocol=openid-connect -s protocolMapper=oidc-audience-mapper -s 'config."included.client.audience"=skymail' \
  -s 'config."access.token.claim"=true' -s 'config."id.token.claim"=false' >/dev/null
kcadm update "clients/$core/default-client-scopes/$scope_audience" -r "$REALM" -n -b '{}' >/dev/null

kcadm create groups -r "$REALM" -s name=ROLLER >/dev/null
roller=$(group_id ROLLER)
kcadm create "groups/$roller/children" -r "$REALM" -s name=SKYMAIL-ACCESS \
  -s 'attributes.display_name_tr=["SkyMail: erişim"]' \
  -s "attributes.description_tr=[\"SkyMail'e girer (skymail:access); diğer SkyMail rolleri bunun üstüne eklenir.\"]" >/dev/null
kcadm create "groups/$roller/children" -r "$REALM" -s name=SKYMAIL-MAILS-WRITE \
  -s 'attributes.display_name_tr=["SkyMail: gönderim yapar"]' \
  -s "attributes.description_tr=[\"SkyMail'den Mail onayı olmadan gönderim yapar (skymail:mails:write).\"]" >/dev/null
kcadm create "groups/$roller/children" -r "$REALM" -s name=FORMS-ACCESS \
  -s 'attributes.display_name_tr=["Forms: yönetim paneli erişimi"]' >/dev/null
group_access=$(group_id ROLLER/SKYMAIL-ACCESS)
group_write=$(group_id ROLLER/SKYMAIL-MAILS-WRITE)
group_forms=$(group_id ROLLER/FORMS-ACCESS)
kcadm create "groups/$group_access/role-mappings/clients/$skymail" -r "$REALM" \
  -b "[{\"id\":\"$role_access\",\"name\":\"skymail:access\"}]" >/dev/null

person=$(kcadm create users -r "$REALM" -i -s "username=$PERSON" -s enabled=true -s firstName=Fixture -s lastName=Person)
kcadm update "users/$person/groups/$group_access" -r "$REALM" -n -b '{}' >/dev/null
kcadm add-roles -r "$REALM" --uusername "$PERSON" --cclientid skymail --rolename skymail:mails:send >/dev/null

before=$(snapshot)
claims_before=$(core_claims)
jq -e '.aud == ["skymail"] and .roles.skymail == ["skymail:access", "skymail:mails:send"]' <<<"$claims_before" >/dev/null \
  || fail "core's token before the rename is not the fixture's: $claims_before"
secrets_before=$(for id in "$backend" "$seed" "$core"; do secret_of "$id"; done | sha256sum)

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='sandbox: the new name is taken'
kcadm create realms -s "realm=$SANDBOX" -s enabled=true >/dev/null
kcadm create clients -r "$SANDBOX" -s clientId=skymail -s publicClient=true >/dev/null
kcadm create clients -r "$SANDBOX" -s clientId=skynotify -s publicClient=true >/dev/null
taken=$(run_expecting 1 "$SANDBOX" --apply)
expect_line "$taken" 'PROBLEM: client skynotify already exists next to skymail' 'the taken name is not a PROBLEM'
reject_line "$taken" 'applied' 'a refused rename wrote'
[[ -n $(client_uuid "$SANDBOX" skymail) ]] || fail 'the refused rename changed the sandbox realm'
printf '    a realm that already has skynotify next to skymail is refused (exit 1), nothing written\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='dry run'
dry=$(run_expecting 0 "$REALM")
indent "$dry"
for line in \
  'rename client: client skymail -> skynotify (clientId name description; uuid, secret and service account kept)' \
  'rename client: client skymail-backend -> skynotify-backend (clientId rootUrl;' \
  'rename client: client skymail-seed -> skynotify-seed (clientId;' \
  'rename role: role skymail:access -> skynotify:access (client skymail) (id kept)' \
  'rename role: role skymail:mails:send -> skynotify:mails:send (client skymail) (id kept)' \
  'rename role: role skymail:templates:system -> skynotify:templates:system (client skymail) (id kept)' \
  'rename role: role skymail:suppressions:manage -> skynotify:suppressions:manage (client skymail) (id kept)' \
  'rename client-scope: client scope skymail-api-audience -> skynotify-api-audience' \
  'rename client-scope: client scope account-erase-skymail -> account-erase-skynotify' \
  'rename mapper: mapper skymail-audience -> skynotify-audience (client scope skymail-api-audience; config included.client.audience)' \
  'rename mapper: mapper account-erase-skymail-audience -> account-erase-skynotify-audience (client scope account-erase-skymail; config included.client.audience)' \
  'rename group: group /ROLLER/SKYMAIL-ACCESS -> SKYNOTIFY-ACCESS' \
  'rename group: group /ROLLER/SKYMAIL-MAILS-WRITE -> SKYNOTIFY-MAILS-WRITE' \
  'service account user: service-account-skymail-backend' \
  'service account user: service-account-skymail-seed' \
  'holders of role skymail:access -> skynotify:access (client skymail): users=1 groups=1' \
  'holders of role skymail:mails:send -> skynotify:mails:send (client skymail): users=3 groups=0' \
  'plan: rename=13 alreadyRenamed=0 roles counted=4' \
  'dry run: 13 change(s); rerun with --apply to execute them'; do
  expect_line "$dry" "$line" 'the dry run misses'
done
# Two clients' core fields, four roles, two scopes, two mappers, two groups (thirteen with the third client).
reject_line "$dry" 'forms' 'the dry run touches an unrelated client'
reject_line "$dry" 'skyMail' 'the dry run touches the out-of-scope skyMail mapper'
reject_line "$dry" "$PERSON" "the dry run printed a person's username"
reject_line "$dry" "$person" "the dry run printed a person's id"
[[ $(snapshot) == "$before" ]] || fail 'the dry run changed the realm'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='apply'
applied=$(run_expecting 0 "$REALM" --apply)
indent "$applied"
expect_line "$applied" 'applied 13 rename(s); failed=0' 'the apply did not rename everything'
expect_line "$applied" 'after: holders equal for 4 role(s); nothing left to rename' 'the apply did not check the holders'
reject_line "$applied" "$PERSON" "the apply printed a person's username"

after=$(snapshot)
jq -e '.[0].clientId == "skynotify" and .[0].name == "SkyNotify" and .[0].description == "SkyNotify'"'"'ın arayüzü (iletişim konsolu)"
  and .[1].clientId == "skynotify-backend" and .[1].rootUrl == "https://api.yildizskylab.com/api/skynotify"
  and .[2].clientId == "skynotify-seed" and .[3].clientId == "core" and .[4].clientId == "keycloak-mailer"' \
  <<<"$after" >/dev/null || fail "the clients are not renamed: $(jq -c '[.[0:6][] | {clientId, name, description, rootUrl}]' <<<"$after")"
jq -e --argjson before "$before" '.[0:6] | map(.id) == ($before[0:6] | map(.id))' <<<"$after" >/dev/null \
  || fail 'a client uuid changed'
[[ $(for id in "$backend" "$seed" "$core"; do secret_of "$id"; done | sha256sum) == "$secrets_before" ]] \
  || fail 'a client secret changed'
jq -e '.[0].protocolMappers | map(select(.name == "skyMail")) | .[0].config["user.attribute"] == "skyMail" and .[0].config["claim.name"] == "skyMail"' \
  <<<"$after" >/dev/null || fail 'the out-of-scope skyMail mapper changed'
jq -e --argjson before "$before" '.[5] == $before[5]' <<<"$after" >/dev/null || fail 'the unrelated client forms changed'
jq -e --argjson before "$before" '.[15:19] | map(.id) == ($before[15:19] | map(.id))' <<<"$after" >/dev/null \
  || fail 'a service account user was replaced'
jq -e '.[15:19] | map(.username) == ["service-account-skynotify-backend", "service-account-skynotify-seed", "service-account-core", "service-account-keycloak-mailer"]' \
  <<<"$after" >/dev/null || fail "the service account usernames do not follow their clients: $(jq -c '[.[15:19][] | .username]' <<<"$after")"

# The text of the reconciler's SKYNOTIFY_PRIVILEGED_ROLE_DEFINITIONS line for this role.
suppressions_text='SkyNotify: bastırma listesini görür, kalıcı ret (bounce) kaydını kaldırır, bounce oranını okur (ADR 0073)'
jq -e --arg text "$suppressions_text" '.[6].name == "skynotify:access" and .[6].description == "SkyNotify'"'"'a girer; diğer SkyNotify rolleri bunun üstüne eklenir."
  and .[7].name == "skynotify:mails:send"
  and .[8].name == "skynotify:templates:system"
  and .[8].description == "The Template seed marks a template as a system template (skynotify-backend README). skynotify-seed'"'"'s service account only."
  and .[9].name == "skynotify:suppressions:manage" and .[9].description == $text
  and .[9].attributes.seeded == ["2026-11-01T00:00:00Z where skynotify:suppressions:manage is held: groups 2"]' \
  <<<"$after" >/dev/null || fail "the roles are not renamed as the reconciler writes them: $(jq -c '.[6:10]' <<<"$after")"
jq -e --argjson before "$before" '.[6:10] | map(.id) == ($before[6:10] | map(.id))' <<<"$after" >/dev/null || fail 'a role id changed'

role_groups="$REPOSITORY_ROOT/config/role-groups.json"
for name in SKYNOTIFY-ACCESS SKYNOTIFY-MAILS-WRITE; do
  expected=$(jq -c --arg name "$name" '.groups[] | select(.name == $name) | {name, display_name_tr: [.display_name_tr], description_tr: [.description_tr]}' "$role_groups")
  [[ -n $expected ]] || fail "config/role-groups.json has no $name"
  got=$(jq -c --arg name "$name" '.[10:12][] | select(.name == $name) | {name, display_name_tr: .attributes.display_name_tr, description_tr: .attributes.description_tr}' <<<"$after")
  [[ $got == "$expected" ]] || fail "group $name is not what config/role-groups.json writes: $got (expected $expected)"
done
jq -e '.[10].path == "/ROLLER/SKYNOTIFY-ACCESS" and .[11].path == "/ROLLER/SKYNOTIFY-MAILS-WRITE"' <<<"$after" >/dev/null \
  || fail 'the group paths do not follow their names'
jq -e --argjson before "$before" '.[12] == $before[12] and (.[10:13] | map(.id)) == ($before[10:13] | map(.id))' <<<"$after" >/dev/null \
  || fail 'a group id changed or FORMS-ACCESS changed'

jq -e '.[13].name == "skynotify-api-audience" and .[13].protocolMappers[0].name == "skynotify-audience"
  and .[13].protocolMappers[0].config["included.client.audience"] == "skynotify"
  and .[14].name == "account-erase-skynotify" and .[14].description == "core erases a person in SkyNotify"
  and .[14].protocolMappers[0].name == "account-erase-skynotify-audience"
  and .[14].protocolMappers[0].config["included.client.audience"] == "skynotify"' <<<"$after" >/dev/null \
  || fail "the client scopes are not renamed: $(jq -c '.[13:15]' <<<"$after")"

# Every mapping by id stayed: the group's role, the person's direct role and group, the role scope.
[[ $(kcadm get "groups/$group_access/role-mappings/clients/$skymail" -r "$REALM" | jq -c 'map(.name)') == '["skynotify:access"]' ]] \
  || fail "the group lost its role"
[[ $(kcadm get "users/$person/role-mappings/clients/$skymail" -r "$REALM" | jq -c 'map(.name)') == '["skynotify:mails:send"]' ]] \
  || fail "the person lost the direct role"
[[ $(kcadm get "clients/$mailer/scope-mappings/clients/$skymail" -r "$REALM" | jq -c 'map(.name)') == '["skynotify:mails:send"]' ]] \
  || fail "keycloak-mailer's role scope lost the role"
kcadm get "clients/$core/default-client-scopes" -r "$REALM" | jq -e 'map(.name) | index("skynotify-api-audience")' >/dev/null \
  || fail "core lost its default client scope"
claims_after=$(core_claims)
jq -e '.aud == ["skynotify"] and .roles == {skynotify: ["skynotify:access", "skynotify:mails:send"]}' <<<"$claims_after" >/dev/null \
  || fail "core's token does not name skynotify: $claims_after"
printf '    renamed in place: ids, secrets, service accounts and mappings kept; core'"'"'s token says skynotify\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='second apply'
again=$(run_expecting 0 "$REALM" --apply)
expect_line "$again" 'plan: rename=0 alreadyRenamed=' 'the second run planned a rename'
expect_line "$again" 'applied 0 rename(s); failed=0' 'the second run wrote'
[[ $(snapshot) == "$after" ]] || fail 'the second run changed the realm'
printf '    a second --apply renames nothing\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='reverse (rollback)'
reverse_dry=$(run_expecting 0 "$REALM" --reverse)
expect_line "$reverse_dry" 'dry run: 13 change(s)' 'the reverse dry run does not plan every rename back'
expect_line "$reverse_dry" 'rename client: client skynotify -> skymail' 'the reverse dry run misses the client'
reversed=$(run_expecting 0 "$REALM" --reverse --apply)
indent "$reversed"
expect_line "$reversed" 'applied 13 rename(s); failed=0' 'the reverse did not rename everything back'
restored=$(snapshot)
if [[ $restored != "$before" ]]; then
  diff <(jq . <<<"$before") <(jq . <<<"$restored") >&2 || true
  fail 'the reverse did not restore every object exactly'
fi
[[ $(core_claims) == "$claims_before" ]] || fail "core's token after the reverse differs from before"
printf '    --reverse --apply restores every object exactly as before\n'
printf 'skynotify-rename: all checks passed\n'
