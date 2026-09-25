#!/usr/bin/env bash
# Real-Keycloak evidence for account erasure ticket 09: which personal data Keycloak's admin and
# user event stores keep once core's erasure saga has deleted a person, and the Keycloak behaviour
# each remedy relies on. Invoked by run-integration.sh once the reconciled test realm exists. It
# works in a throwaway realm with production's event settings (user events kept 30 days, admin
# events with representation, jboss-logging only) and the reconciled User Profile of the test
# realm, and removes the realm at the end.
#
# What it proves on Keycloak 26.7.4:
#   - core's calls, made the way core's gocloak adapter makes them (a GET of the whole user, then
#     a PUT of the gocloak User fields: WriteSkyNumber and disable_identity; POST logout; DELETE):
#       · each whole-representation PUT stores an UPDATE admin event whose representation holds
#         the person's e-mail, first and last name, username, schoolEmail and personalEmail;
#       · the logout ACTION stores no representation; the DELETE stores the id and the username;
#       · after the DELETE the person's admin events and user events (LOGIN and LOGIN_ERROR with
#         the address typed as username) are all still stored, and so is the LOGIN_ERROR of an
#         address that is no login name: it carries the address but no user id;
#   - remedy (a): a PUT of {"enabled":false} alone disables the person and keeps everything else
#     (e-mail, names, verification, every attribute, required actions, IdP link, groups,
#     credentials), also for a person without e-mail or names, and its UPDATE event holds only
#     {"enabled":false};
#   - remedy (c): with adminEventsDetailsEnabled=false a whole-representation PUT stores no
#     representation;
#   - remedy (b): the realm attribute adminEventsExpiration makes Keycloak's scheduled task delete
#     admin events older than it, including those written before it was set, and keep newer ones.
#     The harness Keycloak runs its scheduled tasks every 5 seconds (KC_SPI_SCHEDULED_INTERVAL);
#     production keeps Keycloak's default of 15 minutes.
# The table it prints names fields, never their values.
# Inputs: EVENT_PII_COMPOSE_FILE, EVENT_PII_ADMIN_CONFIG, TEST_STATE_DIR, EVENT_PII_SOURCE_REALM,
#         EVENT_PII_BASE_URL.
set -Eeuo pipefail

COMPOSE_FILE=${EVENT_PII_COMPOSE_FILE:?set EVENT_PII_COMPOSE_FILE}
ADMIN_CONFIG=${EVENT_PII_ADMIN_CONFIG:?set EVENT_PII_ADMIN_CONFIG}
STATE_DIR=${TEST_STATE_DIR:?set TEST_STATE_DIR}
SOURCE_REALM=${EVENT_PII_SOURCE_REALM:-e-skylab-test}
BASE_URL=${EVENT_PII_BASE_URL:-http://localhost:18080}
REALM=erasure-event-pii
COMPOSE=(docker compose -f "$COMPOSE_FILE")
CORE_CLIENT=core-fixture
CORE_SECRET=erasure-event-pii-core-secret
LOGIN_CLIENT=login-fixture
PASSWORD=Erasure-Event-Pii-1
# Production (realm facts 2026-09-21): user events kept 30 days, admin events with details.
EVENTS_EXPIRATION=2592000
# The fields of gocloak v13.9.0's User struct (all omitempty): the only ones core's GET → PUT
# round trip sends back (core internal/identity/keycloak.go DisableUser and WriteSkyNumber).
GOCLOAK_USER_FIELDS='["id","createdTimestamp","username","enabled","totp","emailVerified","firstName","lastName","email","federationLink","attributes","disableableCredentialTypes","requiredActions","access","clientRoles","realmRoles","groups","serviceAccountClientId","credentials"]'
# The personal fields a representation is checked for.
PERSONAL_FIELDS='["username","email","firstName","lastName","attributes.schoolEmail","attributes.personalEmail","attributes.skyNumber","attributes.department","attributes.university"]'
# The purge proof: expiration in seconds and how long to wait for the scheduled task.
PURGE_EXPIRATION=45
PURGE_WAIT=30
CURRENT_STAGE='erasure event PII fixture'

fail() {
  printf 'erasure event PII failure during %s: %s\n' "$CURRENT_STAGE" "$1" >&2
  exit 1
}
# shellcheck disable=SC2154  # status is assigned inside the trap string itself
trap 'status=$?; printf "erasure event PII command failed during %s (line %s)\n" "$CURRENT_STAGE" "$LINENO" >&2; exit "$status"' ERR

kcadm() {
  local command=$1
  shift
  "${COMPOSE[@]}" exec -T keycloak /opt/keycloak/bin/kcadm.sh "$command" --config "$ADMIN_CONFIG" "$@"
}

core_token() {
  local response
  response=$(curl --fail --silent --show-error \
    --user "$CORE_CLIENT:$CORE_SECRET" \
    --data-urlencode grant_type=client_credentials \
    "$BASE_URL/realms/$REALM/protocol/openid-connect/token")
  jq -r .access_token <<<"$response"
}

# core_call METHOD PATH [BODY]: an Admin REST call with core's service-account token, the way
# gocloak sends it. Prints the body; the HTTP status lands in $STATE_DIR/event-pii.status.
core_call() {
  local method=$1 path=$2 body=${3:-} token arguments
  token=$(core_token)
  arguments=(--silent --show-error --request "$method" --output "$STATE_DIR/event-pii.body"
    --write-out '%{http_code}' -H "Authorization: Bearer $token")
  [[ -z $body ]] || arguments+=(-H 'Content-Type: application/json' --data-binary "$body")
  curl "${arguments[@]}" "$BASE_URL/admin/realms/$REALM/$path" >"$STATE_DIR/event-pii.status"
  cat "$STATE_DIR/event-pii.body"
}

core_status() {
  cat "$STATE_DIR/event-pii.status"
}

# core_put_whole ID JQ_EDIT: core's GetUserByID, the gocloak User struct round trip, the edit
# (DisableUser sets enabled=false, WriteSkyNumber the skyNumber attribute) and UpdateUser.
core_put_whole() {
  local id=$1 edit=$2 user body
  user=$(core_call GET "users/$id")
  [[ $(core_status) == 200 ]] || fail "core's GET of the user returned HTTP $(core_status)"
  body=$(jq -c --argjson fields "$GOCLOAK_USER_FIELDS" \
    "with_entries(select(.key as \$k | \$fields | index(\$k)) | select(.value != null)) | $edit" <<<"$user")
  core_call PUT "users/$id" "$body" >/dev/null
  [[ $(core_status) == 204 ]] || fail "core's whole-representation PUT returned HTTP $(core_status)"
}

minimal_disable() {
  core_call PUT "users/$1" '{"enabled":false}' >/dev/null
  [[ $(core_status) == 204 ]] || fail "the minimal disable PUT returned HTTP $(core_status)"
}

password_login() {
  curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
    --data-urlencode grant_type=password \
    --data-urlencode "client_id=$LOGIN_CLIENT" \
    --data-urlencode "username=$1" \
    --data-urlencode "password=$2" \
    --data-urlencode scope=openid \
    "$BASE_URL/realms/$REALM/protocol/openid-connect/token"
}

admin_events() {
  kcadm get admin-events -r "$REALM" -q max=1000 -c | jq -c 'sort_by(.time)'
}

user_events() {
  kcadm get events -r "$REALM" -q max=1000 -c | jq -c 'sort_by(.time)'
}

# The admin events of one person (resource path users/ID or below it), oldest first.
person_admin_events() {
  admin_events | jq -c --arg id "$1" \
    '[.[] | (.resourcePath // "") as $path | select($path == "users/\($id)" or ($path | startswith("users/\($id)/")))]'
}

# new_updates ID KNOWN_IDS: the UPDATE admin events of a person that are not in KNOWN_IDS.
new_updates() {
  person_admin_events "$1" | jq -c --argjson known "$2" \
    '[.[] | select(.operationType == "UPDATE" and (.id as $id | $known | index($id) | not))]'
}

# representation_fields EVENT: the personal fields its representation holds, as a JSON array.
representation_fields() {
  jq -c --argjson personal "$PERSONAL_FIELDS" '
    (.representation // "") as $r
    | if $r == "" then []
      else ($r | fromjson) as $rep
        | if ($rep | type) != "object" then []
          else [(($rep | keys[]) , (($rep.attributes // {}) | keys[] | "attributes." + .))]
            | map(select(. as $f | $personal | index($f)))
          end
      end' <<<"$1"
}

# person <username> <email|-> <first|-> <last|-> [attribute=value ...] → the new id
person() {
  local username=$1 email=$2 first=$3 last=$4 attribute
  shift 4
  local args=(-s "username=$username" -s enabled=true)
  [[ $email != - ]] && args+=(-s "email=$email" -s emailVerified=true)
  [[ $first != - ]] && args+=(-s "firstName=$first")
  [[ $last != - ]] && args+=(-s "lastName=$last")
  for attribute in "$@"; do
    args+=(-s "attributes.${attribute%%=*}=[\"${attribute#*=}\"]")
  done
  kcadm create users -r "$REALM" -i "${args[@]}"
}

# Everything Keycloak holds for a person besides the enabled flag: the representation, IdP links,
# groups, credentials (id, type, label) and role mappings.
person_snapshot() {
  local id=$1
  {
    kcadm get "users/$id" -r "$REALM" -c | jq -S -c 'del(.enabled, .access)'
    kcadm get "users/$id/federated-identity" -r "$REALM" -c | jq -S -c .
    kcadm get "users/$id/groups" -r "$REALM" -c | jq -S -c '[.[].path] | sort'
    kcadm get "users/$id/credentials" -r "$REALM" -c | jq -S -c '[.[] | {id, type, userLabel, createdDate}] | sort_by(.id)'
    kcadm get "users/$id/role-mappings" -r "$REALM" -c | jq -S -c .
  } | jq -S -c -s .
}

print_row() {
  printf '  %-26s %-24s %s\n' "$1" "$2" "$3"
}

CURRENT_STAGE='erasure event PII realm with production event settings'
kcadm delete "realms/$REALM" >/dev/null 2>&1 || true
kcadm create realms -s "realm=$REALM" -s enabled=true \
  -s eventsEnabled=true -s "eventsExpiration=$EVENTS_EXPIRATION" -s 'eventsListeners=["jboss-logging"]' \
  -s adminEventsEnabled=true -s adminEventsDetailsEnabled=true >/dev/null
kcadm get users/profile -r "$SOURCE_REALM" -c >"$STATE_DIR/event-pii-profile.json"
kcadm update users/profile -r "$REALM" -f - <"$STATE_DIR/event-pii-profile.json" >/dev/null
[[ $(kcadm get users/profile -r "$REALM" -c | jq -r '[.attributes[].name | select(. == "schoolEmail" or . == "personalEmail")] | length') == 2 ]] \
  || fail 'the throwaway realm did not take the reconciled User Profile'
realm_settings=$(kcadm get "realms/$REALM" -c)
jq -e --argjson expiration "$EVENTS_EXPIRATION" \
  '.eventsEnabled and .eventsExpiration == $expiration and .adminEventsEnabled and .adminEventsDetailsEnabled and .eventsListeners == ["jboss-logging"]' \
  <<<"$realm_settings" >/dev/null || fail 'the throwaway realm does not have production event settings'

# core's own client: confidential, service account only, realm-management roles as production's
# service-account-core after the least-privilege script (manage-users is what the saga needs).
core_client_uuid=$(kcadm create clients -r "$REALM" -s "clientId=$CORE_CLIENT" -s enabled=true -s publicClient=false \
  -s "secret=$CORE_SECRET" -s serviceAccountsEnabled=true -s standardFlowEnabled=false \
  -s directAccessGrantsEnabled=false -i)
kcadm add-roles -r "$REALM" --uusername "service-account-$CORE_CLIENT" --cclientid realm-management \
  --rolename manage-users --rolename view-users --rolename query-users >/dev/null
# A public client whose password grant writes LOGIN and LOGIN_ERROR user events.
kcadm create clients -r "$REALM" -s "clientId=$LOGIN_CLIENT" -s enabled=true -s publicClient=true \
  -s standardFlowEnabled=false -s directAccessGrantsEnabled=true >/dev/null
# The OBS broker link of production people (no login through it is needed here).
kcadm create identity-provider/instances -r "$REALM" -s alias=OBS -s providerId=oidc -s enabled=true \
  -s 'config.clientId=obs-fixture' -s 'config.clientSecret=obs-fixture-secret' \
  -s 'config.authorizationUrl=https://obs.invalid/authorize' -s 'config.tokenUrl=https://obs.invalid/token' >/dev/null
group_id=$(kcadm create groups -r "$REALM" -s name=event-pii-members -i)

# The erased person: school and personal e-mail, SKY number and YTÜ attributes, as production.
FIRST=Ayşe
LAST=Yılmaz
PRIMARY=ayse.yilmaz@std.example.edu.tr
SCHOOL=ayse.yilmaz@std.example.edu.tr
PERSONAL=ayse.kisisel@example.com
subject=$(person erased-fixture "$PRIMARY" "$FIRST" "$LAST" \
  "schoolEmail=$SCHOOL" "personalEmail=$PERSONAL" department=Matematik university=YTU)
kcadm set-password -r "$REALM" --userid "$subject" --new-password "$PASSWORD" >/dev/null

CURRENT_STAGE='user events of the person'
# Keycloak answers a failed password grant with 400 invalid_grant (401 for a confidential client).
[[ $(password_login "$PRIMARY" wrong-password) == 40[01] ]] || fail 'a wrong password was accepted'
[[ $(password_login "$PERSONAL" wrong-password) == 40[01] ]] || fail 'the personal e-mail logged in as a username'
[[ $(password_login "$PRIMARY" "$PASSWORD") == 200 ]] || fail 'the person could not log in with the e-mail'

CURRENT_STAGE="core's earlier update and the saga (disable, logout, delete)"
core_put_whole "$subject" '.attributes = ((.attributes // {}) + {skyNumber: ["SKY-0042"]})'
core_put_whole "$subject" '.enabled = false'
core_call POST "users/$subject/logout" >/dev/null
[[ $(core_status) == 204 ]] || fail "core's logout returned HTTP $(core_status)"
# The saga reads the addresses of the disabled person before any service step.
addresses=$(core_call GET "users/$subject")
jq -e --arg p "$PRIMARY" --arg s "$SCHOOL" --arg q "$PERSONAL" \
  '.enabled == false and .email == $p and .attributes.schoolEmail == [$s] and .attributes.personalEmail == [$q]' \
  <<<"$addresses" >/dev/null || fail 'the disabled person no longer holds the addresses the saga reads'
before_delete=$(person_admin_events "$subject")
core_call DELETE "users/$subject" >/dev/null
[[ $(core_status) == 204 ]] || fail "core's delete returned HTTP $(core_status)"
core_call GET "users/$subject" >/dev/null
[[ $(core_status) == 404 ]] || fail 'the deleted person is still readable'

CURRENT_STAGE='what the event stores keep after the delete'
events=$(person_admin_events "$subject")
[[ $(jq length <<<"$events") == $(( $(jq length <<<"$before_delete") + 1 )) ]] \
  || fail 'the delete removed or added admin events of the person other than its own'
printf 'Admin events of the deleted person (oldest first), personal fields in the representation:\n'
while IFS= read -r event; do
  suffix=$(jq -r --arg id "$subject" '.resourcePath | sub("^users/\($id)"; "users/{id}")' <<<"$event")
  print_row "$(jq -r '"\(.operationType) \(.resourceType)"' <<<"$event")" "$suffix" \
    "$(representation_fields "$event" | jq -r 'if length == 0 then "-" else join(", ") end')"
done < <(jq -c '.[]' <<<"$events")

# authDetails.clientId is the client's internal id.
core_updates=$(jq -c --arg id "$subject" --arg client "$core_client_uuid" \
  '[.[] | select(.operationType == "UPDATE" and .resourcePath == "users/\($id)" and .authDetails.clientId == $client)]' <<<"$events")
[[ $(jq length <<<"$core_updates") == 2 ]] || fail "core's two whole-representation PUTs did not store two UPDATE events"
jq -e --arg p "$PRIMARY" --arg f "$FIRST" --arg l "$LAST" --arg s "$SCHOOL" --arg q "$PERSONAL" '
  all(.[]; .representation | fromjson
    | .email == $p and .firstName == $f and .lastName == $l and .username == "erased-fixture"
      and .attributes.schoolEmail == [$s] and .attributes.personalEmail == [$q])' <<<"$core_updates" >/dev/null \
  || fail "core's UPDATE events do not hold the person's e-mail, names, school and personal e-mail"
jq -e '.[1].representation | fromjson | .enabled == false' <<<"$core_updates" >/dev/null \
  || fail "the disable UPDATE event is not the one that set enabled=false"
jq -e --arg id "$subject" \
  '[.[] | select(.operationType == "ACTION" and .resourcePath == "users/\($id)/logout")] | length == 1 and all(.[]; (.representation // "") == "")' \
  <<<"$events" >/dev/null || fail 'the logout ACTION is missing or stores a representation'
jq -e --arg id "$subject" \
  '[.[] | select(.operationType == "DELETE" and .resourcePath == "users/\($id)")]
   | length == 1 and (.[0].representation | fromjson) == {id: $id, username: "erased-fixture"}' \
  <<<"$events" >/dev/null || fail 'the DELETE event is missing or stores more than the id and the username'
jq -e --arg p "$PRIMARY" \
  '[.[] | select(.operationType == "CREATE" and .resourceType == "USER")] | length == 1 and (.[0].representation | fromjson | .email == $p)' \
  <<<"$events" >/dev/null || fail 'the CREATE event does not hold the e-mail it was created with'

all_user_events=$(user_events)
person_user_events=$(jq -c --arg id "$subject" '[.[] | select(.userId == $id)]' <<<"$all_user_events")
unlinked_user_events=$(jq -c --arg q "$PERSONAL" '[.[] | select(.userId == null and .details.username == $q)]' <<<"$all_user_events")
printf 'User events of the deleted person (oldest first), detail keys:\n'
while IFS= read -r event; do
  print_row "$(jq -r '"\(.type) \(.error // "")"' <<<"$event")" \
    "$(jq -r 'if .userId == null then "no userId" else "userId kept" end' <<<"$event")" \
    "$(jq -r '(.details // {}) | keys | if length == 0 then "-" else join(", ") end' <<<"$event")"
done < <(jq -c '(. + $unlinked) | sort_by(.time) | .[]' --argjson unlinked "$unlinked_user_events" <<<"$person_user_events")
jq -e --arg p "$PRIMARY" '
  ([.[] | select(.type == "LOGIN")] | length >= 1 and all(.[]; .details.username == $p))
  and ([.[] | select(.type == "LOGIN_ERROR")] | length >= 1 and all(.[]; .details.username == $p))' \
  <<<"$person_user_events" >/dev/null || fail 'the LOGIN and LOGIN_ERROR events of the deleted person are not kept with the typed address'
jq -e 'length == 1 and .[0].type == "LOGIN_ERROR"' <<<"$unlinked_user_events" >/dev/null \
  || fail 'the failed login with an address that is no login name is not kept without a user id'

CURRENT_STAGE='remedy (a): a minimal disable PUT keeps the person whole'
kept=$(person kept-fixture ali.kaya@std.example.edu.tr Ali Kaya \
  schoolEmail=ali.kaya@std.example.edu.tr personalEmail=ali.kisisel@example.com skyNumber=SKY-0043 \
  department=Fizik university=YTU personalEmailVerifiedAt=2026-09-20T10:00:00Z)
kcadm set-password -r "$REALM" --userid "$kept" --new-password "$PASSWORD" >/dev/null
kcadm update "users/$kept" -r "$REALM" -s 'requiredActions=["CONFIGURE_TOTP"]' >/dev/null
kcadm create "users/$kept/federated-identity/OBS" -r "$REALM" \
  -s identityProvider=OBS -s userId=obs-subject-fixture -s userName=ali.kaya@std.example.edu.tr >/dev/null
kcadm update "users/$kept/groups/$group_id" -r "$REALM" -n >/dev/null
bare=$(person bare-fixture - - -)
for id in "$kept" "$bare"; do
  snapshot_before=$(person_snapshot "$id")
  known=$(admin_events | jq -c '[.[].id]')
  minimal_disable "$id"
  [[ $(kcadm get "users/$id" -r "$REALM" -c | jq -r .enabled) == false ]] || fail 'the minimal PUT did not disable the person'
  [[ $(person_snapshot "$id") == "$snapshot_before" ]] || {
    diff <(jq . <<<"$snapshot_before") <(person_snapshot "$id" | jq .) >&2 || true
    fail 'the minimal PUT changed the person beyond enabled'
  }
  update=$(new_updates "$id" "$known")
  [[ $(jq length <<<"$update") == 1 ]] || fail 'the minimal PUT did not store exactly one UPDATE event'
  [[ $(jq -c '.[0].representation | fromjson' <<<"$update") == '{"enabled":false}' ]] \
    || fail 'the minimal PUT UPDATE event holds more than {"enabled":false}'
done
print_row 'UPDATE USER (minimal PUT)' 'users/{id}' 'representation {"enabled":false}: no personal field'

CURRENT_STAGE='remedy (c): admin events without details store no representation'
kcadm update "realms/$REALM" -s adminEventsDetailsEnabled=false >/dev/null
known=$(admin_events | jq -c '[.[].id]')
core_put_whole "$kept" '.attributes = ((.attributes // {}) + {skyNumber: ["SKY-0044"]})'
update=$(new_updates "$kept" "$known")
[[ $(jq length <<<"$update") == 1 ]] || fail 'the whole-representation PUT did not store exactly one UPDATE event'
[[ $(jq -r '.[0].representation // ""' <<<"$update") == '' ]] \
  || fail 'an admin event stored a representation with adminEventsDetailsEnabled=false'
print_row 'UPDATE USER (details off)' 'users/{id}' 'no representation'
kcadm update "realms/$REALM" -s adminEventsDetailsEnabled=true >/dev/null

CURRENT_STAGE='remedy (b): adminEventsExpiration purges older admin events, retroactively'
newest=$(admin_events | jq -r 'map(.time) | max')
wait_seconds=$(( PURGE_EXPIRATION + 5 - ($(date +%s) - newest / 1000) ))
(( wait_seconds <= 0 )) || sleep "$wait_seconds"
# Every admin event so far is now older than the expiration and was written before it was set.
old_ids=$(admin_events | jq -c '[.[].id]')
old_count=$(jq length <<<"$old_ids")
(( old_count > 0 )) || fail 'no admin event exists before the expiration is set'
kcadm update "realms/$REALM" -s "attributes.adminEventsExpiration=$PURGE_EXPIRATION" >/dev/null
[[ $(kcadm get "realms/$REALM" -c | jq -r '.attributes.adminEventsExpiration') == "$PURGE_EXPIRATION" ]] \
  || fail 'the realm did not keep the adminEventsExpiration attribute'
person fresh-fixture - - - >/dev/null
# The realm update and the new person: younger than the expiration for the whole wait.
new_ids=$(admin_events | jq -c --argjson old "$old_ids" '[.[].id | select(. as $id | $old | index($id) | not)] | sort')
(( $(jq length <<<"$new_ids") >= 2 )) || fail 'the realm update and the new person stored no admin events'
purged=false
for _ in $(seq 1 "$PURGE_WAIT"); do
  if [[ $(admin_events | jq --argjson old "$old_ids" '[.[] | select(.id as $id | $old | index($id))] | length') == 0 ]]; then
    purged=true
    break
  fi
  sleep 1
done
[[ $purged == true ]] || fail "admin events older than adminEventsExpiration=$PURGE_EXPIRATION were not purged within ${PURGE_WAIT}s"
[[ $(admin_events | jq -c '[.[].id] | sort') == "$new_ids" ]] \
  || fail 'the purge deleted an admin event younger than the expiration'
print_row 'adminEventsExpiration' "$PURGE_EXPIRATION s" "purged all $old_count older admin events, kept the $(jq length <<<"$new_ids") newer ones"
[[ $(user_events | jq --arg id "$subject" '[.[] | select(.userId == $id)] | length') -ge 2 ]] \
  || fail 'adminEventsExpiration removed user events'

CURRENT_STAGE='erasure event PII cleanup'
kcadm delete "realms/$REALM" >/dev/null
rm -f "$STATE_DIR/event-pii.body" "$STATE_DIR/event-pii.status" "$STATE_DIR/event-pii-profile.json"
printf 'Erasure event PII evidence passed.\n'
