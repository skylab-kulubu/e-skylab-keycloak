#!/usr/bin/env bash
# Real-Keycloak contract for config/adopt-legacy-personal-email.sh (A1c). Invoked by
# run-integration.sh once the reconciled test realm exists. It works in a throwaway realm of its
# own, so its counts are exact and no other stage's people are adopted: the realm copies the
# reconciled User Profile of the test realm (personalEmail and personalEmailVerifiedAt with their
# validators) and holds one fixture person per case. Dry run → apply → a run that writes nothing.
# Inputs: LEGACY_EMAIL_COMPOSE_FILE, LEGACY_EMAIL_ADMIN_CONFIG, TEST_STATE_DIR. Removes its realm.
set -Eeuo pipefail

COMPOSE_FILE=${LEGACY_EMAIL_COMPOSE_FILE:?set LEGACY_EMAIL_COMPOSE_FILE}
ADMIN_CONFIG=${LEGACY_EMAIL_ADMIN_CONFIG:?set LEGACY_EMAIL_ADMIN_CONFIG}
STATE_DIR=${TEST_STATE_DIR:?set TEST_STATE_DIR}
SOURCE_REALM=${LEGACY_EMAIL_SOURCE_REALM:-e-skylab-test}
REALM=a1c-legacy-email
COMPOSE=(docker compose -f "$COMPOSE_FILE")
ISO_UTC_SECONDS='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
CURRENT_STAGE='legacy personal e-mail adoption fixture'

fail() {
  printf 'legacy personal e-mail adoption failure during %s: %s\n' "$CURRENT_STAGE" "$1" >&2
  exit 1
}
trap 'status=$?; printf "legacy personal e-mail adoption command failed during %s (line %s)\n" "$CURRENT_STAGE" "$LINENO" >&2; exit "$status"' ERR

kcadm() {
  local command=$1
  shift
  "${COMPOSE[@]}" exec -T keycloak /opt/keycloak/bin/kcadm.sh "$command" --config "$ADMIN_CONFIG" "$@"
}

adopt() {
  "${COMPOSE[@]}" run --rm --no-deps \
    -e KEYCLOAK_ADMIN_REALM=master \
    -e KEYCLOAK_REALM="$REALM" \
    -e KEYCLOAK_LEGACY_EMAIL_ADMIN_USERNAME=admin \
    -e KEYCLOAK_LEGACY_EMAIL_ADMIN_PASSWORD=integration-admin-password \
    -e SKY_HARNESS=1 \
    --entrypoint /opt/keycloak/config/adopt-legacy-personal-email.sh \
    keycloak-config "$@" 2>&1
}

expect_line() {
  local output=$1 expected=$2 message=$3
  grep -Fq -- "$expected" <<<"$output" || { printf '%s\n' "$output" >&2; fail "$message: $expected"; }
}

# person <username> <email|-> <emailVerified> [attribute=value ...] -> the new id
person() {
  local username=$1 email=$2 verified=$3 attribute
  shift 3
  local args=(-s "username=$username" -s enabled=true -s firstName=Legacy -s lastName=Fixture -s "emailVerified=$verified")
  [[ $email != - ]] && args+=(-s "email=$email")
  for attribute in "$@"; do
    args+=(-s "attributes.${attribute%%=*}=[\"${attribute#*=}\"]")
  done
  kcadm create users -r "$REALM" -i "${args[@]}"
}

# Every person of the realm, service accounts included, as {username: representation}.
snapshot() {
  local users service
  users=$(kcadm get users -r "$REALM" -q max=1000 -q briefRepresentation=false -c)
  service=$(kcadm get "users/$robot_uuid" -r "$REALM" -c)
  jq -S -c --argjson service "$service" '(. + [$service]) | map({key: .username, value: .}) | from_entries' <<<"$users"
}

# Counts only: no address, username or id of a fixture person reaches the terminal.
assert_counts_only() {
  local output=$1 run=$2 username id
  if grep -Fq '@' <<<"$output"; then
    printf '%s\n' "$output" >&2
    fail "$run printed an address"
  fi
  for username in "${all_usernames[@]}"; do
    [[ $output != *"$username"* ]] || fail "$run printed a username"
  done
  for id in "${all_ids[@]}"; do
    [[ $output != *"$id"* ]] || fail "$run printed a user id"
  done
}

admin_event_count() {
  kcadm get admin-events -r "$REALM" -q max=500 -c | jq '[.[] | select(.resourceType == "USER")] | length'
}

kcadm delete "realms/$REALM" >/dev/null 2>&1 || true
# Login by e-mail is off only so two people can share one address: the duplicate case cannot
# exist in a realm with duplicateEmailsAllowed=false, which is exactly why production has none.
kcadm create realms -s "realm=$REALM" -s enabled=true \
  -s loginWithEmailAllowed=false -s duplicateEmailsAllowed=true \
  -s adminEventsEnabled=true -s adminEventsDetailsEnabled=false >/dev/null
kcadm get users/profile -r "$SOURCE_REALM" -c | kcadm update users/profile -r "$REALM" -n -f - >/dev/null
kcadm get users/profile -r "$REALM" -c \
  | jq -e '([.attributes[].name] | index("personalEmail") != null and index("personalEmailVerifiedAt") != null and index("schoolEmail") != null) and .unmanagedAttributePolicy == "ADMIN_VIEW"' >/dev/null \
  || fail 'the throwaway realm did not take the reconciled User Profile'

adopt_uuid=$(person a1c-verified a1c-verified@example.invalid true \
  schoolEmail=a1c-verified@std.yildiz.edu.tr skyNumber=1234 department=Bilgisayar)
noschool_uuid=$(person a1c-noschool a1c-noschool@example.invalid true)
unverified_uuid=$(person a1c-unverified a1c-unverified@example.invalid false schoolEmail=a1c-unverified@std.yildiz.edu.tr)
staff_uuid=$(person a1c-staff a1c-staff@yildiz.edu.tr true schoolEmail=a1c-staff@std.yildiz.edu.tr)
dept_uuid=$(person a1c-dept a1c-dept@ce.yildiz.edu.tr true)
person a1c-has-personal a1c-has-personal@example.invalid true \
  personalEmail=a1c-has-personal-other@example.invalid personalEmailVerifiedAt=2026-09-01T12:00:00Z >/dev/null
person a1c-school a1c-school@std.yildiz.edu.tr true schoolEmail=a1c-school@std.yildiz.edu.tr >/dev/null
taken_uuid=$(person a1c-taken a1c-taken@example.invalid true)
person a1c-holder a1c-holder@std.yildiz.edu.tr true \
  schoolEmail=a1c-holder@std.yildiz.edu.tr personalEmail=a1c-taken@example.invalid >/dev/null
person a1c-no-email - true >/dev/null
twin_a_uuid=$(person a1c-twin-a a1c-twin@example.invalid true)
twin_b_uuid=$(person a1c-twin-b a1c-twin@example.invalid true)
# A service account with an address of its own is still not a person.
kcadm create clients -r "$REALM" -s clientId=a1c-robot -s publicClient=false \
  -s serviceAccountsEnabled=true -s standardFlowEnabled=false >/dev/null
robot_client=$(kcadm get clients -r "$REALM" -q clientId=a1c-robot -c | jq -r '.[0].id')
robot_uuid=$(kcadm get "clients/$robot_client/service-account-user" -r "$REALM" -c | jq -r .id)
kcadm update "users/$robot_uuid" -r "$REALM" -s email=a1c-robot@example.invalid -s emailVerified=true >/dev/null
all_ids=("$adopt_uuid" "$noschool_uuid" "$unverified_uuid" "$staff_uuid" "$dept_uuid" "$taken_uuid" \
  "$twin_a_uuid" "$twin_b_uuid" "$robot_uuid")
all_usernames=(a1c-verified a1c-noschool a1c-unverified a1c-staff a1c-dept a1c-has-personal a1c-school \
  a1c-taken a1c-holder a1c-no-email a1c-twin-a a1c-twin-b)

CURRENT_STAGE='legacy personal e-mail adoption refuses an environment password outside the harness'
if "${COMPOSE[@]}" run --rm --no-deps \
  -e KEYCLOAK_REALM="$REALM" \
  -e KEYCLOAK_LEGACY_EMAIL_ADMIN_USERNAME=admin \
  -e KEYCLOAK_LEGACY_EMAIL_ADMIN_PASSWORD=integration-admin-password \
  --entrypoint /opt/keycloak/config/adopt-legacy-personal-email.sh \
  keycloak-config >"$STATE_DIR/legacy-email-refused.log" 2>&1; then
  cat "$STATE_DIR/legacy-email-refused.log" >&2
  fail 'the script accepted an environment password without SKY_HARNESS=1'
fi
grep -Fq 'KEYCLOAK_LEGACY_EMAIL_ADMIN_PASSWORD is accepted only by the test harness (SKY_HARNESS=1)' \
  "$STATE_DIR/legacy-email-refused.log" \
  || { cat "$STATE_DIR/legacy-email-refused.log" >&2; fail 'the refusal of the environment password is not explained'; }

CURRENT_STAGE='legacy personal e-mail adoption dry run'
before=$(snapshot)
events_before=$(admin_event_count)
output=$(adopt)
printf '%s\n' "$output" >"$STATE_DIR/legacy-email-dry-run.log"
expect_line "$output" "[adopt-legacy-personal-email] realm=$REALM mode=dry-run" 'the dry run did not name its realm and mode'
grep -Eq '^\[adopt-legacy-personal-email\] users scanned=12 \(service accounts skipped=[01]\) legacyPrimaries=8$' <<<"$output" \
  || { printf '%s\n' "$output" >&2; fail 'the dry run did not scan the twelve people and find the eight legacy primaries'; }
expect_line "$output" 'legacy primaries: adopt=2 unverified=1 schoolDomain=2 duplicate=2 taken=1' 'the dry run counted wrongly'
expect_line "$output" '1 unverified legacy primary address(es) stay as they are; the person proves them with the code on my./email' \
  'the dry run did not point the unverified people at the code flow'
expect_line "$output" '3 legacy primary address(es) were skipped because another person holds the address or would get it too; they need a manual decision' \
  'the dry run did not report the skipped addresses'
expect_line "$output" 'dry run: 2 adoption(s) pending; rerun with --apply to execute them' 'the dry run did not plan exactly two adoptions'
assert_counts_only "$output" 'the dry run'
[[ $(snapshot) == "$before" ]] || fail 'the dry run changed a person'
[[ $(admin_event_count) == "$events_before" ]] || fail 'the dry run wrote something'

CURRENT_STAGE='legacy personal e-mail adoption apply'
started=$(date -u +%s)
output=$(adopt --apply)
finished=$(date -u +%s)
printf '%s\n' "$output" >"$STATE_DIR/legacy-email-apply.log"
expect_line "$output" 'applied 2 adoption(s); failed=0 changedSinceScan=0' 'the apply did not adopt exactly the two planned people'
expect_line "$output" 'after: legacy primaries still to adopt=0' 'the adoptions did not persist'
assert_counts_only "$output" 'the apply'
after=$(snapshot)
for username in a1c-verified a1c-noschool; do
  jq -e --arg u "$username" --arg regex "$ISO_UTC_SECONDS" --argjson from "$started" --argjson to "$finished" '
    .[$u] as $p
    | ($p.attributes.personalEmail == [$p.email])
      and ($p.attributes.personalEmailVerifiedAt | length == 1)
      and ($p.attributes.personalEmailVerifiedAt[0] | test($regex))
      and ($p.attributes.personalEmailVerifiedAt[0] | fromdateiso8601) >= $from
      and ($p.attributes.personalEmailVerifiedAt[0] | fromdateiso8601) <= $to
      and $p.emailVerified == true' <<<"$after" >/dev/null \
    || fail "$username did not get its own address and a UTC stamp of this run as its personal e-mail"
  # Everything but the two attributes is exactly what it was: the primary, the flags, the other attributes.
  adopted_rest=$(jq -S -c --arg u "$username" \
    '.[$u] | del(.attributes.personalEmail, .attributes.personalEmailVerifiedAt) | if .attributes == {} then del(.attributes) else . end' <<<"$after")
  adopted_before=$(jq -S -c --arg u "$username" '.[$u]' <<<"$before")
  if [[ $adopted_rest != "$adopted_before" ]]; then
    printf 'before: %s\nafter:  %s\n' "$adopted_before" "$adopted_rest" >&2
    fail "the adoption changed more than the personal e-mail of $username"
  fi
done
jq -e '.["a1c-verified"].attributes | .skyNumber == ["1234"] and .department == ["Bilgisayar"] and .schoolEmail == ["a1c-verified@std.yildiz.edu.tr"]' \
  <<<"$after" >/dev/null || fail 'the other attributes of an adopted person were not kept'
others_after=$(jq -S -c 'del(.["a1c-verified"], .["a1c-noschool"])' <<<"$after")
others_before=$(jq -S -c 'del(.["a1c-verified"], .["a1c-noschool"])' <<<"$before")
[[ $others_after == "$others_before" ]] \
  || fail 'the apply touched an unverified, school-domain, taken, duplicate, service-account or already-personal person'
[[ $(( $(admin_event_count) - events_before )) == 2 ]] || fail 'the apply did not write exactly two people'

CURRENT_STAGE='legacy personal e-mail adoption is idempotent'
events_before=$(admin_event_count)
output=$(adopt)
expect_line "$output" 'legacy primaries: adopt=0 unverified=1 schoolDomain=2 duplicate=2 taken=1' 'a second dry run still found people to adopt'
expect_line "$output" 'dry run: 0 adoption(s) pending' 'a second dry run planned a change'
output=$(adopt --apply)
printf '%s\n' "$output" >"$STATE_DIR/legacy-email-noop.log"
expect_line "$output" 'applied 0 adoption(s); failed=0 changedSinceScan=0' 'a second apply wrote something'
[[ $(admin_event_count) == "$events_before" ]] || fail 'a no-op run produced admin events'
[[ $(snapshot) == "$after" ]] || fail 'a no-op run changed a person'

CURRENT_STAGE='legacy personal e-mail adoption cleanup'
kcadm delete "realms/$REALM" >/dev/null
printf 'Legacy personal e-mail adoption contract passed.\n'
