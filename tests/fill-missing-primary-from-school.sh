#!/usr/bin/env bash
# Real-Keycloak contract for config/fill-missing-primary-from-school.sh (eskylab-login-ux ticket 06).
# Stand-alone: starts the stock Keycloak image this repository builds on (the Dockerfile's
# KEYCLOAK_IMAGE) in dev mode with docker run --rm and no volume, and runs the script inside that
# container the way the wizard does (--kcadm-config).
#
# Fixtures: realm e-skylab with the settings that matter in production (duplicateEmailsAllowed=false,
# loginWithEmailAllowed=true, user and admin events on) and the User Profile the reconciler writes
# (config/account-center-user-profile.json merged by config/ReconcileJson.java), identity providers
# OBS (microsoft) and github, and one person per case (usernames fmp-*):
#   fill-a, fill-b          no email, OBS link, valid schoolEmail (fill-a's in mixed case)       -> filled
#   no-link                 no email, schoolEmail, linked to github only                         -> noObsLink
#   no-school, blank-school no email, OBS link, no schoolEmail / a blank one                     -> noSchoolEmail
#   bad-school              no email, OBS link, schoolEmail that is not an address               -> invalidSchoolEmail
#   taken-email             no email, OBS link, schoolEmail = holder-email's email (in capitals) -> taken
#   taken-personal          no email, OBS link, schoolEmail = holder-personal's personalEmail    -> taken
#   twin-a, twin-b          no email, OBS link, the same schoolEmail                             -> taken
#   has-email, holder-email, holder-personal: they have a Primary e-mail                         -> untouched
# plus a service account without an address. Realm e-skylab-sandbox has no OBS, like production's.
#
# What it proves:
#   - realms other than e-skylab and e-skylab-sandbox are refused before anything is read (exit 2);
#     a missing realm is exit 1;
#   - the dry run counts exactly (fill=2 noObsLink=1 noSchoolEmail=2 invalidSchoolEmail=1 taken=4),
#     prints no address, username or id and changes nothing (no admin event);
#   - --skipped-list writes the eight skipped accounts (class, username, id; no address) to a new
#     0600 file and refuses an existing one;
#   - an administrator who may read but not write users fills nothing and the run fails (exit 1,
#     failed=2 forbidden=2); a realm with registrationEmailAsUsername=true is refused (exit 1);
#   - --apply writes exactly the two qualifying accounts: email = the school address lowercased,
#     emailVerified=true, everything else as it was (schoolEmail included); Keycloak then finds them
#     by that address; exactly two UPDATE USER admin events and no user event (no mail);
#   - a second dry run plans nothing and a second --apply writes nothing;
#   - without the OBS identity provider (the sandbox) nothing is filled;
#   - the script never calls a Keycloak endpoint that sends mail.
# Requirements on the host: docker, jq. FILL_PRIMARY_TEST_PORT (default 18096),
# FILL_PRIMARY_TEST_CONTAINER (default fill-missing-primary-test-<pid>), FILL_PRIMARY_TEST_MEMORY
# (default 2g).
# shellcheck disable=SC2016  # jq programs name jq variables
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPOSITORY_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
OPERATOR_SCRIPT="$REPOSITORY_ROOT/config/fill-missing-primary-from-school.sh"
IMAGE=$(sed -n 's/^ARG KEYCLOAK_IMAGE=//p' "$REPOSITORY_ROOT/Dockerfile")
PORT=${FILL_PRIMARY_TEST_PORT:-18096}
BASE_URL="http://127.0.0.1:$PORT"
CONTAINER=${FILL_PRIMARY_TEST_CONTAINER:-fill-missing-primary-test-$$}
MEMORY=${FILL_PRIMARY_TEST_MEMORY:-2g}
ADMIN_PASSWORD=harness-admin-password
VIEWER_PASSWORD=harness-viewer-password
KCADM_CONFIG=/tmp/harness-kcadm.config
VIEWER_CONFIG=/tmp/harness-viewer-kcadm.config
IN_CONTAINER_SCRIPT=/tmp/fill-missing-primary-from-school.sh
JACKSON_GLOB='/opt/keycloak/lib/lib/main/com.fasterxml.jackson.core.jackson-*.jar'
REALM=e-skylab
SANDBOX=e-skylab-sandbox
CURRENT_STAGE=startup

fail() {
  printf 'fill-missing-primary failure during %s: %s\n' "$CURRENT_STAGE" "$1" >&2
  exit 1
}
cleanup() {
  docker rm -fv "$CONTAINER" >/dev/null 2>&1 || true
}
trap 'status=$?; trap - EXIT; cleanup; exit "$status"' EXIT
on_error() {
  local status=$?
  printf 'fill-missing-primary command failed during %s (line %s)\n' "$CURRENT_STAGE" "$1" >&2
  exit "$status"
}
trap 'on_error "$LINENO"' ERR

kcadm() {
  local command=$1
  shift
  docker exec -i "$CONTAINER" /opt/keycloak/bin/kcadm.sh "$command" --config "$KCADM_CONFIG" "$@" \
    2> >(grep -v -e '^Created new ' -e '^$' >&2 || true)
}

# run_with CONFIG STATUS REALM ARGS...: the operator script inside the container with a kcadm
# session, for a run that must exit STATUS; prints the output.
run_with() {
  local config=$1 wanted=$2 realm=$3 output status=0
  shift 3
  trap - ERR
  output=$(docker exec -e KEYCLOAK_ADMIN_URL=http://localhost:8080 "$CONTAINER" \
    bash "$IN_CONTAINER_SCRIPT" --realm "$realm" --kcadm-config "$config" "$@" 2>&1) || status=$?
  trap 'on_error "$LINENO"' ERR
  [[ $status == "$wanted" ]] || { printf '%s\n' "$output" >&2; fail "the run did not exit $wanted (exit $status)"; }
  printf '%s\n' "$output"
}

run_expecting() {
  run_with "$KCADM_CONFIG" "$@"
}

expect_line() {
  grep -Fq -- "$2" <<<"$1" || { printf '%s\n' "$1" >&2; fail "$3: $2"; }
}

# indent TEXT: the script's own output (counts only, checked) under the stage line, for the CI log.
indent() {
  local line
  while IFS= read -r line; do
    printf '      %s\n' "$line"
  done <<<"$1"
}

reject_line() {
  if grep -Fq -- "$2" <<<"$1"; then
    printf '%s\n' "$1" >&2
    fail "$3: $2"
  fi
}

# person REALM USERNAME EMAIL|- [attribute=value ...] -> the new id (attribute value "[]" is kept as JSON)
person() {
  local realm=$1 username=$2 email=$3 attribute
  shift 3
  local args=(-s "username=$username" -s enabled=true -s firstName=Fixture -s lastName=Person)
  [[ $email != - ]] && args+=(-s "email=$email" -s emailVerified=true)
  for attribute in "$@"; do
    args+=(-s "attributes.${attribute%%=*}=[\"${attribute#*=}\"]")
  done
  kcadm create users -r "$realm" -i "${args[@]}"
}

link() { # link REALM USER_ID PROVIDER
  kcadm create "users/$2/federated-identity/$3" -r "$1" \
    -b "{\"identityProvider\":\"$3\",\"userId\":\"$3-$2\",\"userName\":\"$3-$2\"}" >/dev/null
}

# Every person of the realm plus the service account, as {username: representation}.
snapshot() {
  local users service
  users=$(kcadm get users -r "$REALM" -q max=1000 -q briefRepresentation=false)
  service=$(kcadm get "users/$robot_id" -r "$REALM")
  jq -S -c --argjson service "$service" '(. + [$service]) | unique_by(.id) | map({key: .username, value: .}) | from_entries' <<<"$users"
}

admin_updates() {
  kcadm get admin-events -r "$REALM" -q max=500 \
    | jq -c '[.[] | select(.resourceType == "USER" and .operationType == "UPDATE") | .resourcePath] | sort'
}

user_events() {
  kcadm get events -r "$REALM" -q max=500 | jq 'length'
}

# Counts only: no address, username or id of a fixture person reaches the terminal.
assert_counts_only() {
  local output=$1 run=$2 name id
  if grep -Fq '@' <<<"$output"; then
    printf '%s\n' "$output" >&2
    fail "$run printed an address"
  fi
  for name in "${all_usernames[@]}"; do
    [[ $output != *"$name"* ]] || fail "$run printed a username"
  done
  for id in "${all_ids[@]}"; do
    [[ $output != *"$id"* ]] || fail "$run printed a user id"
  done
}

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='Keycloak start'
[[ -n $IMAGE ]] || fail 'Dockerfile has no ARG KEYCLOAK_IMAGE'
command -v jq >/dev/null || fail 'jq is required'
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
docker exec -i "$CONTAINER" sh -c "cat > $IN_CONTAINER_SCRIPT" <"$OPERATOR_SCRIPT"

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='static: no mail-sending endpoint'
if grep -vE '^[[:space:]]*(#|\*|/\*\*)' "$OPERATOR_SCRIPT" \
  | grep -Eq 'execute-actions-email|send-verify-email|reset-password-email|send-reset'; then
  fail 'the script calls a Keycloak endpoint that sends mail'
fi

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
kcadm create realms -s "realm=$REALM" -s enabled=true -s loginWithEmailAllowed=true -s duplicateEmailsAllowed=false \
  -s eventsEnabled=true -s adminEventsEnabled=true -s adminEventsDetailsEnabled=true >/dev/null
# The fixture values go in while unmanaged attributes are admin-editable, so a value the production
# User Profile would refuse (the invalid school address) can exist, as one written by a mapper can.
kcadm get users/profile -r "$REALM" | jq '.unmanagedAttributePolicy = "ADMIN_EDIT"' \
  | kcadm update users/profile -r "$REALM" -n -f - >/dev/null
kcadm create identity-provider/instances -r "$REALM" -s alias=OBS -s providerId=microsoft -s enabled=true \
  -s 'config.clientId=harness-client' -s 'config.clientSecret=harness-secret' >/dev/null
kcadm create identity-provider/instances -r "$REALM" -s alias=github -s providerId=github -s enabled=true \
  -s 'config.clientId=harness-client' -s 'config.clientSecret=harness-secret' >/dev/null

fill_a=$(person "$REALM" fmp-fill-a - 'schoolEmail=FMP-Fill-A@STD.Yildiz.edu.tr' skyNumber=1001 department=Bilgisayar university=YTU)
fill_b=$(person "$REALM" fmp-fill-b - schoolEmail=fmp-fill-b@std.yildiz.edu.tr)
no_link=$(person "$REALM" fmp-no-link - schoolEmail=fmp-no-link@std.yildiz.edu.tr)
no_school=$(person "$REALM" fmp-no-school -)
blank_school=$(person "$REALM" fmp-blank-school - 'schoolEmail=   ')
bad_school=$(person "$REALM" fmp-bad-school - 'schoolEmail=not an address')
taken_email=$(person "$REALM" fmp-taken-email - schoolEmail=FMP-Shared-Primary@STD.yildiz.edu.tr)
holder_email=$(person "$REALM" fmp-holder-email fmp-shared-primary@std.yildiz.edu.tr)
taken_personal=$(person "$REALM" fmp-taken-personal - schoolEmail=fmp-shared-personal@std.yildiz.edu.tr)
holder_personal=$(person "$REALM" fmp-holder-personal fmp-holder-personal@std.yildiz.edu.tr \
  schoolEmail=fmp-holder-personal@std.yildiz.edu.tr personalEmail=fmp-shared-personal@std.yildiz.edu.tr \
  personalEmailVerifiedAt=2026-09-01T12:00:00Z)
twin_a=$(person "$REALM" fmp-twin-a - schoolEmail=fmp-twin@std.yildiz.edu.tr)
twin_b=$(person "$REALM" fmp-twin-b - schoolEmail=fmp-twin@std.yildiz.edu.tr)
has_email=$(person "$REALM" fmp-has-email fmp-has-email@example.invalid schoolEmail=fmp-has-email@std.yildiz.edu.tr)
for id in "$fill_a" "$fill_b" "$no_school" "$blank_school" "$bad_school" "$taken_email" "$taken_personal" \
  "$twin_a" "$twin_b" "$has_email" "$holder_personal"; do
  link "$REALM" "$id" OBS
done
link "$REALM" "$no_link" github
kcadm create clients -r "$REALM" -s clientId=fmp-robot -s publicClient=false \
  -s serviceAccountsEnabled=true -s standardFlowEnabled=false >/dev/null
robot_client=$(kcadm get clients -r "$REALM" -q clientId=fmp-robot | jq -r '.[0].id')
robot_id=$(kcadm get "clients/$robot_client/service-account-user" -r "$REALM" | jq -r .id)
all_ids=("$fill_a" "$fill_b" "$no_link" "$no_school" "$blank_school" "$bad_school" "$taken_email" "$holder_email"
  "$taken_personal" "$holder_personal" "$twin_a" "$twin_b" "$has_email" "$robot_id")
all_usernames=(fmp-fill-a fmp-fill-b fmp-no-link fmp-no-school fmp-blank-school fmp-bad-school fmp-taken-email
  fmp-holder-email fmp-taken-personal fmp-holder-personal fmp-twin-a fmp-twin-b fmp-has-email fmp-robot)

# The production User Profile, as the reconciler writes it (ReconcileJson user-profile).
docker exec -i "$CONTAINER" sh -c 'cat > /tmp/ReconcileJson.java' <"$REPOSITORY_ROOT/config/ReconcileJson.java"
docker exec -i "$CONTAINER" sh -c 'cat > /tmp/user-profile-spec.json' <"$REPOSITORY_ROOT/config/account-center-user-profile.json"
docker exec "$CONTAINER" bash -c 'jars=('"$JACKSON_GLOB"'); IFS=:; mkdir -p /tmp/rj
  java -m jdk.compiler/com.sun.tools.javac.Main -d /tmp/rj -cp "${jars[*]}" /tmp/ReconcileJson.java' >/dev/null
# ReconcileJson exits 3 when the merged profile differs from the live one, which it must here.
desired=$(kcadm get users/profile -r "$REALM" | docker exec -i "$CONTAINER" bash -c 'jars=('"$JACKSON_GLOB"'); IFS=:
  java -cp "/tmp/rj:${jars[*]}" ReconcileJson user-profile /tmp/user-profile-spec.json; [ $? = 3 ]')
kcadm update users/profile -r "$REALM" -n -f - <<<"$desired" >/dev/null
kcadm get users/profile -r "$REALM" \
  | jq -e '.unmanagedAttributePolicy == "ADMIN_VIEW" and ([.attributes[].name] | index("schoolEmail") != null and index("personalEmail") != null)' >/dev/null \
  || fail 'the realm did not take the production User Profile'
printf '    e-skylab: 13 people, a service account, OBS and github, production User Profile\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='dry run'
before=$(snapshot)
updates_before=$(admin_updates)
dry=$(run_expecting 0 "$REALM")
expect_line "$dry" "[fill-missing-primary] realm=$REALM mode=dry-run" 'the dry run did not name its realm and mode'
expect_line "$dry" 'admin events: on' 'admin events not reported'
expect_line "$dry" 'identity provider OBS: present' 'OBS not found'
grep -Eq '^\[fill-missing-primary\] users scanned=13 \(service accounts skipped=[01]\) primaryEmpty=10 \(opened in the last 30 days=10\)$' <<<"$dry" \
  || { printf '%s\n' "$dry" >&2; fail 'the dry run did not scan thirteen people and find ten without a Primary e-mail'; }
expect_line "$dry" 'primary empty: fill=2 noObsLink=1 noSchoolEmail=2 invalidSchoolEmail=1 taken=4' 'the dry run counted wrongly'
expect_line "$dry" '4 account(s) were skipped because another account holds the school address; they need a manual decision' 'taken not reported'
expect_line "$dry" '3 linked account(s) have no usable school address and stay without a Primary e-mail' 'no school address not reported'
expect_line "$dry" '1 account(s) without a Primary e-mail are not linked to OBS and are not filled' 'no link not reported'
expect_line "$dry" 'dry run: 2 account(s) to fill; rerun with --apply to execute them' 'the dry run did not plan exactly two fills'
assert_counts_only "$dry" 'the dry run'
[[ $(snapshot) == "$before" ]] || fail 'the dry run changed a person'
[[ $(admin_updates) == "$updates_before" ]] || fail 'the dry run wrote something'
printf '    dry run: fill=2 noObsLink=1 noSchoolEmail=2 invalidSchoolEmail=1 taken=4, counts only, nothing written\n'
indent "$dry"

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='skipped list'
listed=$(run_expecting 0 "$REALM" --skipped-list /tmp/fmp-skipped.tsv)
expect_line "$listed" 'skipped list: 8 line(s) in /tmp/fmp-skipped.tsv (mode 0600: class, username, id)' 'skipped list not reported'
assert_counts_only "$listed" 'the skipped-list run'
[[ $(docker exec "$CONTAINER" stat -c %a /tmp/fmp-skipped.tsv) == 600 ]] || fail 'the skipped list is not mode 0600'
skipped=$(docker exec "$CONTAINER" cat /tmp/fmp-skipped.tsv)
[[ $skipped != *@* ]] || fail 'the skipped list holds an address'
expected_skipped=$(printf '%s\n' \
  "invalidSchoolEmail fmp-bad-school $bad_school" \
  "noObsLink fmp-no-link $no_link" \
  "noSchoolEmail fmp-blank-school $blank_school" \
  "noSchoolEmail fmp-no-school $no_school" \
  "taken fmp-taken-email $taken_email" \
  "taken fmp-taken-personal $taken_personal" \
  "taken fmp-twin-a $twin_a" \
  "taken fmp-twin-b $twin_b")
[[ $(tr '\t' ' ' <<<"$skipped" | sort) == "$expected_skipped" ]] \
  || { printf '%s\n' "$skipped" >&2; fail 'the skipped list does not name exactly the eight skipped accounts'; }
again=$(run_expecting 2 "$REALM" --skipped-list /tmp/fmp-skipped.tsv)
expect_line "$again" 'refusing to overwrite /tmp/fmp-skipped.tsv' 'an existing skipped list was not refused'
printf '    --skipped-list: eight lines, mode 0600, no address; an existing file is refused\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='an administrator who may not write users'
kcadm create users -r master -s username=fmp-viewer -s enabled=true >/dev/null
kcadm set-password -r master --username fmp-viewer --new-password "$VIEWER_PASSWORD" >/dev/null
kcadm add-roles -r master --uusername fmp-viewer --cclientid "$REALM-realm" \
  --rolename view-users --rolename view-realm --rolename view-identity-providers >/dev/null
docker exec "$CONTAINER" /opt/keycloak/bin/kcadm.sh config credentials --config "$VIEWER_CONFIG" \
  --server http://localhost:8080 --realm master --user fmp-viewer --password "$VIEWER_PASSWORD" >/dev/null 2>&1 \
  || fail 'kcadm login of the viewer failed'
denied=$(run_with "$VIEWER_CONFIG" 1 "$REALM" --apply)
expect_line "$denied" 'applied 0 fill(s); failed=2 changedSinceScan=0' 'the forbidden writes were not counted'
expect_line "$denied" 'failed by reason: forbidden=2 conflict=0 invalid=0 other=0' 'the forbidden writes were not classified'
expect_line "$denied" 'after: primaryEmpty=10 toFill=2' 'the read-back after forbidden writes is wrong'
expect_line "$denied" 'The fill is incomplete: 2 write(s) failed and 2 account(s) are still to fill.' 'the incomplete run was not explained'
assert_counts_only "$denied" 'the forbidden run'
[[ $(snapshot) == "$before" ]] || fail 'the forbidden run changed a person'
[[ $(admin_updates) == "$updates_before" ]] || fail 'the forbidden run wrote something'
printf '    read-only administrator: failed=2 forbidden=2, exit 1, nothing written\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='registrationEmailAsUsername'
kcadm update "realms/$REALM" -s registrationEmailAsUsername=true >/dev/null
refused=$(run_expecting 1 "$REALM" --apply)
expect_line "$refused" 'has registrationEmailAsUsername=true: the address would also become the username; nothing was changed' \
  'registrationEmailAsUsername not refused'
kcadm update "realms/$REALM" -s registrationEmailAsUsername=false >/dev/null
[[ $(snapshot) == "$before" ]] || fail 'the refused run changed a person'
printf '    registrationEmailAsUsername=true: refused (exit 1), nothing written\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='apply'
updates_before=$(admin_updates)
applied=$(run_expecting 0 "$REALM" --apply)
expect_line "$applied" "[fill-missing-primary] realm=$REALM mode=apply" 'the apply did not name its realm and mode'
expect_line "$applied" 'applied 2 fill(s); failed=0 changedSinceScan=0' 'the apply did not fill exactly the two planned accounts'
expect_line "$applied" 'after: primaryEmpty=8 toFill=0 noObsLink=1 noSchoolEmail=2 invalidSchoolEmail=1 taken=4' 'the fills did not persist'
reject_line "$applied" 'failed by reason' 'a write failed'
assert_counts_only "$applied" 'the apply'
after=$(snapshot)
for pair in 'fmp-fill-a fmp-fill-a@std.yildiz.edu.tr' 'fmp-fill-b fmp-fill-b@std.yildiz.edu.tr'; do
  username=${pair%% *}
  address=${pair#* }
  jq -e --arg u "$username" --arg a "$address" '.[$u] | .email == $a and .emailVerified == true' <<<"$after" >/dev/null \
    || fail "$username did not get its school address as a verified Primary e-mail"
  rest_after=$(jq -S -c --arg u "$username" '.[$u] | del(.email, .emailVerified)' <<<"$after")
  rest_before=$(jq -S -c --arg u "$username" '.[$u] | del(.email, .emailVerified)' <<<"$before")
  [[ $rest_after == "$rest_before" ]] || {
    printf 'before: %s\nafter:  %s\n' "$rest_before" "$rest_after" >&2
    fail "the fill changed more than the Primary e-mail of $username"
  }
  found=$(kcadm get users -r "$REALM" -q "email=$address" -q exact=true | jq -r '[.[].username] | join(",")')
  [[ $found == "$username" ]] || fail "Keycloak does not find exactly $username by $address (found: $found)"
done
jq -e '.["fmp-fill-a"].attributes | .schoolEmail == ["FMP-Fill-A@STD.Yildiz.edu.tr"] and .skyNumber == ["1001"] and .department == ["Bilgisayar"]' \
  <<<"$after" >/dev/null || fail 'the other attributes of a filled account were not kept'
others_after=$(jq -S -c 'del(.["fmp-fill-a"], .["fmp-fill-b"])' <<<"$after")
others_before=$(jq -S -c 'del(.["fmp-fill-a"], .["fmp-fill-b"])' <<<"$before")
[[ $others_after == "$others_before" ]] || fail 'the apply touched an account that does not qualify'
expected_updates=$(jq -c -n --arg a "users/$fill_a" --arg b "users/$fill_b" --argjson before "$updates_before" '($before + [$a, $b]) | sort')
[[ $(admin_updates) == "$expected_updates" ]] || fail "the apply did not leave exactly two UPDATE USER admin events: $(admin_updates)"
[[ $(user_events) == 0 ]] || fail 'the apply produced a user event (a mail or an action)'
printf '    apply: two accounts filled (lowercased, verified, nothing else changed), two admin events, no user event\n'
indent "$applied"

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='idempotent'
updates_before=$(admin_updates)
again=$(run_expecting 0 "$REALM")
expect_line "$again" 'primary empty: fill=0 noObsLink=1 noSchoolEmail=2 invalidSchoolEmail=1 taken=4' 'a second dry run still found accounts to fill'
expect_line "$again" 'dry run: 0 account(s) to fill' 'a second dry run planned a change'
again=$(run_expecting 0 "$REALM" --apply)
expect_line "$again" 'applied 0 fill(s); failed=0 changedSinceScan=0' 'a second apply wrote something'
[[ $(admin_updates) == "$updates_before" ]] || fail 'a no-op run produced admin events'
[[ $(snapshot) == "$after" ]] || fail 'a no-op run changed a person'
printf '    second dry run and apply: nothing to fill, nothing written\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='e-skylab-sandbox without OBS'
kcadm create realms -s "realm=$SANDBOX" -s enabled=true -s duplicateEmailsAllowed=false >/dev/null
kcadm get users/profile -r "$SANDBOX" | jq '.unmanagedAttributePolicy = "ADMIN_EDIT"' \
  | kcadm update users/profile -r "$SANDBOX" -n -f - >/dev/null
person "$SANDBOX" fmp-sandbox-mail fmp-sandbox-mail@example.invalid >/dev/null
person "$SANDBOX" fmp-sandbox-nomail - schoolEmail=fmp-sandbox-nomail@std.yildiz.edu.tr >/dev/null
sandbox=$(run_expecting 0 "$SANDBOX" --apply)
expect_line "$sandbox" 'identity provider OBS: absent (no account can be linked to it, so none is filled)' 'absent OBS not reported'
expect_line "$sandbox" 'admin events: OFF' 'admin events off not reported'
expect_line "$sandbox" 'primary empty: fill=0 noObsLink=1 noSchoolEmail=0 invalidSchoolEmail=0 taken=0' 'the sandbox counted wrongly'
expect_line "$sandbox" 'applied 0 fill(s); failed=0 changedSinceScan=0' 'the sandbox apply wrote something'
[[ $(kcadm get users -r "$SANDBOX" -q username=fmp-sandbox-nomail -q exact=true | jq -r '.[0].email // ""') == '' ]] \
  || fail 'an account without OBS was filled'
printf '    e-skylab-sandbox without OBS: nothing filled\n'

printf 'fill-missing-primary-from-school: all checks passed\n'
