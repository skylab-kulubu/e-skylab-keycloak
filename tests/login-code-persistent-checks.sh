#!/usr/bin/env bash
# Sourced by the separate login-code-persistent.sh entrypoint after the shared bootstrap.
# Every database and identity below belongs only to the throwaway harness.

COUNTER_ASSERTIONS=0
counter_pass() { COUNTER_ASSERTIONS=$((COUNTER_ASSERTIONS + 1)); }
counter_expect_error() { expect_error "$@"; COUNTER_ASSERTIONS=$((COUNTER_ASSERTIONS + 2)); }

counter_sql() { docker exec -i "$DB_CONTAINER" psql -X -q -v ON_ERROR_STOP=1 -U keycloak -d keycloak "$@"; }
counter_seed() {
  counter_sql -v "uid=$1" -v "amount=$2" >/dev/null <<'SQL'
BEGIN;
SELECT id FROM user_entity WHERE id = :'uid' FOR UPDATE;
DELETE FROM user_attribute WHERE user_id = :'uid' AND name = 'skyEmailCodeConsecutiveFailures';
INSERT INTO user_attribute(id, user_id, name, value)
VALUES (gen_random_uuid()::text, :'uid', 'skyEmailCodeConsecutiveFailures', :'amount');
COMMIT;
SQL
}
counter_value() {
  counter_sql -tA -v "uid=$1" <<'SQL'
SELECT coalesce(max(value::integer), 0) FROM user_attribute
WHERE user_id = :'uid' AND name = 'skyEmailCodeConsecutiveFailures';
SQL
}
counter_alarm_count() {
  skymail_records | jq -s --arg to "$ALARM_TO" '[.[] | select(.event == "mail_task"
    and .template_key == "keycloak.login-code-alarm" and .recipient_email == $to
    and .body_variables.subjectKey == "skyLoginCodeAlarmConsecutiveSubject")] | length'
}
counter_password_login() {
  JAR="$STATE_DIR/$1.cookies"
  rm -f "$JAR"
  APP_CODE=''
  follow "$JAR" "$(auth_url)"
  on_form kc-form-login || fail 'counter fixture did not reach the password form'
  counter_pass
  follow "$JAR" "$(form_action kc-form-login)" --data-urlencode "username=$2" --data-urlencode "password=$PASSWORD"
  finish
}
counter_dag() {
  COUNTER_TOKEN_RESPONSE=$(curl -sS -o "$STATE_DIR/counter-token.json" -w '%{http_code}' \
    -X POST -H 'Accept: application/json' "$BASE_URL/realms/$REALM/protocol/openid-connect/token" \
    --data-urlencode grant_type=password --data-urlencode "client_id=$APP" \
    --data-urlencode "username=$1" --data-urlencode "password=$PASSWORD" --data-urlencode scope=openid)
}

counter_signup_page() {
  JAR="$STATE_DIR/$1.cookies"
  rm -f "$JAR"
  follow "$JAR" "$(auth_url)"
  follow "$JAR" "$(form_action kc-form-login)" --data-urlencode "authenticationExecution=$STEP_ID" \
    --data-urlencode sky-email-code-intent=sign-up
  on_form kc-email-code-identifier-form || fail 'the fixture signup intent did not open the identifier page'
  counter_pass
}

stage 'persistent counter: signup address becomes an existing account; pending proof recheck'
counter_signup_config=$(kcadm create "authentication/executions/$STEP_ID/config" -r "$REALM" -i \
  -s alias=counter-signup-fixture -s 'config={"sign-up":"true"}')
counter_signup_page counter-late
ask_code counter-late@example.invalid
late_code=$(await_code counter-late@example.invalid 0 signup)
type_code "$(other_code "$late_code")"
counter_expect_error kc-email-code-form wrong_code 'an unknown signup address'
[[ $(counter_sql -tAc "SELECT count(*) FROM user_attribute WHERE name = 'skyEmailCodeConsecutiveFailures'") == 0 ]] \
  || fail 'an unknown signup address created an account counter'
counter_pass
counter_late=$(person counter-late counter-late@example.invalid)
counter_seed "$counter_late" 99
type_code "$(other_code "$late_code")"
counter_expect_error kc-email-code-form wrong_code 'a signup address that now names a real account'
[[ $(counter_value "$counter_late") == 100 ]] || fail 'the late account did not reach 100'
counter_pass
type_code "$late_code"
counter_expect_error kc-email-code-form wrong_code 'a late account right code at 100'
[[ $(counter_value "$counter_late") == 100 ]] || fail 'a blocked signup code reset the late account'
counter_pass
for _ in $(seq 1 30); do
  [[ $(counter_alarm_count) == 1 ]] && break
  sleep 1
done
[[ $(counter_alarm_count) == 1 ]] || fail 'the late account transition did not deliver exactly one alarm'
counter_pass
counter_proof=$(person counter-proof counter-proof@example.invalid)
counter_seed "$counter_proof" 99
counter_signup_page counter-proof
ask_code counter-proof@example.invalid
type_code "$(await_code counter-proof@example.invalid 0)"
on_form kc-email-code-sign-up-existing-form || fail 'the existing account proof did not open its continue page'
counter_pass
[[ $(counter_value "$counter_proof") == 99 ]] || fail 'the existing-account notice reset before actual LOGIN'
counter_pass
counter_seed "$counter_proof" 100
follow "$JAR" "$(form_action kc-email-code-sign-up-existing-form)" --data-urlencode sky-email-code-action=continue
counter_expect_error kc-email-code-identifier-form code_expired 'a proof whose account reached 100 before continue'
[[ $LANDED != app && -z $APP_CODE && $(counter_value "$counter_proof") == 100 ]] \
  || fail 'a pending existing-account proof bypassed the limit'
counter_pass
kcadm update "authentication/config/$counter_signup_config" -r "$REALM" -s 'config={"sign-up":"false"}' >/dev/null
printf '    unknown signup has no counter; a late account counts; existing proof cannot continue after 100\n'

stage 'persistent counter: independent Keycloak instances share PostgreSQL'
start_keycloak "$REPLICA_CONTAINER" "$SECOND_PORT"
for _ in $(seq 1 120); do
  curl -fsS "http://127.0.0.1:$SECOND_PORT/realms/$REALM" >/dev/null 2>&1 && break
  sleep 2
done
curl -fsS "http://127.0.0.1:$SECOND_PORT/realms/$REALM" >/dev/null || fail 'the second Keycloak did not start'
counter_pass
counter_person=$(person counter-race counter-race@example.invalid)
primary_url=$BASE_URL
replica_url="http://127.0.0.1:$SECOND_PORT"
open_code_page counter-race-a
ask_code counter-race
race_jar_a=$JAR
race_action_a=$(form_action kc-email-code-form)
race_code_a=$(await_code counter-race@example.invalid 0)
BASE_URL=$replica_url
open_code_page counter-race-b
ask_code counter-race
race_jar_b=$JAR
race_action_b=$(form_action kc-email-code-form)
race_code_b=$(await_code counter-race@example.invalid 1)
BASE_URL=$primary_url
counter_seed "$counter_person" 99
alarms_before=$(counter_alarm_count)
# Both JVMs loaded the user before the DB changed to 99. Separate response files avoid curl races.
counter_race_worker() (
  STATE_DIR=$1
  mkdir -p "$STATE_DIR"
  request "$2" "$3" --data-urlencode "code=$4" --data-urlencode sky-email-code-action=verify
  [[ $STATUS == 200 ]] || fail 'a concurrent counter refusal changed HTTP status'
  [[ $(code_error) == wrong_code ]] || fail 'a concurrent counter refusal changed the generic error'
  form_action kc-email-code-form >"$STATE_DIR/next-action"
)
counter_race_worker "$STATE_DIR/race-a" "$race_jar_a" "$race_action_a" "$(other_code "$race_code_a")" &
counter_race_pid_a=$!
counter_race_worker "$STATE_DIR/race-b" "$race_jar_b" "$race_action_b" "$(other_code "$race_code_b")" &
counter_race_pid_b=$!
wait "$counter_race_pid_a"
wait "$counter_race_pid_b"
# Each successful worker verified both HTTP status and the generic error.
COUNTER_ASSERTIONS=$((COUNTER_ASSERTIONS + 4))
[[ $(counter_value "$counter_person") == 100 ]] || fail 'two instances did not saturate at 100'
counter_pass
for _ in $(seq 1 30); do
  (($(counter_alarm_count) == alarms_before + 1)) && break
  sleep 1
done
[[ $(counter_alarm_count) == $((alarms_before + 1)) ]] || fail 'the 99-to-100 transition did not alarm once'
counter_pass
# The already issued, correct code is still live, but the persistent cap prevents comparison.
JAR=$race_jar_a
follow "$JAR" "$(cat "$STATE_DIR/race-a/next-action")" --data-urlencode "code=$race_code_a" \
  --data-urlencode sky-email-code-action=verify
counter_expect_error kc-email-code-form wrong_code 'a previously mailed right code at 100'
[[ $(counter_value "$counter_person") == 100 ]] || fail 'a blocked right code reset the counter'
counter_pass
[[ $(counter_alarm_count) == $((alarms_before + 1)) ]] || fail 'a blocked right code repeated the alarm'
counter_pass
open_code_page counter-blocked
ask_code counter-race
blocked_shape=$(page_shape)
open_code_page counter-unknown
ask_code counter-never-existed@example.invalid
[[ $blocked_shape == "$(page_shape)" ]] || fail 'the persistent limit reveals account existence'
counter_pass
[[ $(code_count counter-race@example.invalid) == 2 ]] || fail 'a code was mailed above the persistent limit'
counter_pass
counter_other=$(person counter-other counter-other@example.invalid)
open_code_page counter-other
ask_code counter-other
type_code "$(await_code counter-other@example.invalid 0)"
finish
[[ $LANDED == app && $(counter_value "$counter_other") == 0 ]] || fail 'another account was affected'
counter_pass
printf '    PostgreSQL + two JVMs: stale caches, atomic 99-to-100, one alarm, generic refusal and account isolation\n'

stage 'persistent counter: Keycloak and PostgreSQL restart'
counter_seed "$counter_person" 99
docker restart "$CONTAINER" >/dev/null
for _ in $(seq 1 120); do
  curl -fsS "$BASE_URL/realms/$REALM" >/dev/null 2>&1 && break
  sleep 2
done
sessions_login
[[ $(counter_value "$counter_person") == 99 ]] || fail 'Keycloak restart cleared the counter'
counter_pass
# Restart PostgreSQL inside its running tmpfs container, preserving the mounted test data.
counter_db_container_before=$(docker inspect --format '{{.Id}}' "$DB_CONTAINER")
counter_db_pid_before=$(docker exec "$DB_CONTAINER" sh -ec 'head -n 1 "$PGDATA/postmaster.pid"')
docker exec --user postgres "$DB_CONTAINER" sh -ec 'pg_ctl -D "$PGDATA" restart -m fast -l /tmp/counter-pg-restarted.log' \
  >"$STATE_DIR/counter-pg-restart.log" 2>&1
for _ in $(seq 1 30); do
  docker exec "$DB_CONTAINER" pg_isready -U keycloak -d keycloak >/dev/null 2>&1 && break
  sleep 1
done
[[ $(docker inspect --format '{{.Id}}' "$DB_CONTAINER") == "$counter_db_container_before" ]] \
  || fail 'the PostgreSQL container and tmpfs changed during process restart'
counter_pass
[[ $(docker exec "$DB_CONTAINER" sh -ec 'head -n 1 "$PGDATA/postmaster.pid"') != "$counter_db_pid_before" ]] \
  || fail 'the PostgreSQL process did not actually restart'
counter_pass
[[ $(counter_value "$counter_person") == 99 ]] || fail 'PostgreSQL restart cleared the counter'
counter_pass
# A restarted database invalidates pooled JDBC connections. Wait for a real successful master
# LOGIN/reset transaction (a separate account), rather than issuing the counter assertion on a
# stale connection's first 500. This is readiness only; the target's persisted 99 is unchanged.
counter_database_ready=0
for _ in $(seq 1 30); do
  if docker exec "$CONTAINER" /opt/keycloak/bin/kcadm.sh config credentials --config "$ADMIN_CONFIG" \
      --server "http://localhost:$PORT" --realm master --user admin --password "$ADMIN_PASSWORD" >/dev/null 2>&1; then
    counter_database_ready=1
    break
  fi
  sleep 1
done
[[ $counter_database_ready == 1 ]] || fail 'Keycloak did not recover its JDBC pool after PostgreSQL restart'
counter_pass
sessions_login
open_code_page counter-restarted
ask_code counter-race
type_code "$(other_code "$(await_code counter-race@example.invalid 2)")"
counter_expect_error kc-email-code-form wrong_code 'a wrong code after restart'
[[ $(counter_value "$counter_person") == 100 ]] || fail 'post-restart comparison forgot the prior 99'
counter_pass
printf '    persistent 99 survives Keycloak and PostgreSQL process restarts; the next wrong code reaches 100\n'

stage 'persistent counter: successful password, code and TOTP logins reset'
counter_original_listeners=$(kcadm get "realms/$REALM" --fields eventsListeners | jq -c '.eventsListeners // []')
kcadm update "realms/$REALM" -s eventsEnabled=false -s 'eventsListeners=[]' >/dev/null
counter_password_login counter-password-reset counter-race
[[ $LANDED == app && $(counter_value "$counter_person") == 0 ]] || fail 'password LOGIN did not reset a blocked account'
counter_pass
counter_browser_token_status=$(curl -sS -o "$STATE_DIR/counter-browser-token.json" -w '%{http_code}' \
  -X POST "$BASE_URL/realms/$REALM/protocol/openid-connect/token" --data-urlencode grant_type=authorization_code \
  --data-urlencode "client_id=$APP" --data-urlencode "redirect_uri=$APP_REDIRECT" --data-urlencode "code=$APP_CODE")
[[ $counter_browser_token_status == 200 ]] || fail 'the positive browser authorization code could not be redeemed'
counter_pass
jq -e '.access_token | type == "string"' "$STATE_DIR/counter-browser-token.json" >/dev/null \
  || fail 'the positive browser authorization code returned no token'
counter_pass
kcadm update "realms/$REALM" -s eventsEnabled=true -s "eventsListeners=$counter_original_listeners" >/dev/null
counter_email=$(person counter-email counter-email@example.invalid)
counter_seed "$counter_email" 42
open_code_page counter-email
ask_code counter-email
type_code "$(await_code counter-email@example.invalid 0)"
finish
[[ $LANDED == app && $(counter_value "$counter_email") == 0 ]] || fail 'completed email LOGIN did not reset the counter'
counter_pass
counter_totp=$(jq -n --arg password "$PASSWORD" --arg secret "$OTP_SECRET" '{
  username: "counter-totp", enabled: true, emailVerified: true, firstName: "Counter", lastName: "TOTP",
  email: "counter-totp@example.invalid", credentials: [{type: "password", value: $password, temporary: false},
  {type: "otp", userLabel: "counter fixture", secretData: ({value: $secret} | tojson),
   credentialData: ({subType: "totp", digits: 6, counter: 0, period: 30, algorithm: "HmacSHA1"} | tojson)}]}' \
  | kcadm create users -r "$REALM" -i -f -)
counter_seed "$counter_totp" 77
open_code_page counter-totp
ask_code counter-totp
type_code "$(await_code counter-totp@example.invalid 0)"
on_form kc-otp-login-form || fail 'TOTP was skipped by the counter change'
counter_pass
[[ $(counter_value "$counter_totp") == 77 ]] || fail 'the partial email proof reset before TOTP'
counter_pass
follow "$JAR" "$(form_action kc-otp-login-form)" \
  --data-urlencode "otp=$(node "$SCRIPT_DIR/totp-code.mjs" "$(base32 "$OTP_SECRET")")"
finish
[[ $LANDED == app && $(counter_value "$counter_totp") == 0 ]] || fail 'TOTP-complete LOGIN did not reset'
counter_pass
printf '    global password LOGIN reset with event store/listeners off; email LOGIN reset; partial proof keeps 77 until TOTP\n'

stage 'persistent counter: UserProfile APIs cannot overwrite or omit the counter'
counter_api=$(person counter-api counter-api@example.invalid)
app_id=$(kcadm get clients -r "$REALM" -q "clientId=$APP" | jq -r '.[0].id')
kcadm update "clients/$app_id" -r "$REALM" -s directAccessGrantsEnabled=true >/dev/null
kcadm add-roles -r "$REALM" --uusername counter-api --cclientid account --rolename manage-account >/dev/null
counter_dag counter-api
[[ $COUNTER_TOKEN_RESPONSE == 200 ]] || fail 'the controlled Account API actor could not log in'
counter_pass
counter_access_token=$(jq -er '.access_token' "$STATE_DIR/counter-token.json")
counter_account_status=$(curl -sS -o "$STATE_DIR/counter-account.json" -w '%{http_code}' \
  -H 'Accept: application/json' -H "Authorization: Bearer $counter_access_token" "$BASE_URL/realms/$REALM/account/")
[[ $counter_account_status == 200 ]] || fail 'the controlled Account API token is not authorized'
counter_pass
jq -e '.username == "counter-api"' "$STATE_DIR/counter-account.json" >/dev/null \
  || fail 'the Account API positive GET returned no authenticated JSON user representation'
counter_pass
profile_status=$(curl -sS -o "$STATE_DIR/counter-profile-control.json" -w '%{http_code}' \
  -X POST -H 'Accept: application/json' -H "Authorization: Bearer $counter_access_token" -H 'Content-Type: application/json' \
  --data-binary "@$STATE_DIR/counter-account.json" "$BASE_URL/realms/$REALM/account/")
if [[ $profile_status != 204 ]]; then
  # Only schema field names and fixed validation keys, never attribute values/tokens/addresses.
  jq -c '[.. | objects | select(has("errorMessage")) | {field,
    errorCode: (.errorMessage | if test("^[A-Za-z_-]+$") then . else "redacted" end)}]' \
    "$STATE_DIR/counter-profile-control.json" >&2 || true
  fail "the positive Account API profile update control failed (HTTP $profile_status)"
fi
counter_pass
counter_seed "$counter_api" 100
kcadm update "users/$counter_api" -r "$REALM" -s firstName=CounterAdminControl >/dev/null
[[ $(counter_value "$counter_api") == 100 ]] || fail 'an unrelated successful Admin API edit cleared the counter'
counter_pass
for profile_case in overwrite omission empty-map; do
  profile_body=$(jq --arg key skyEmailCodeConsecutiveFailures --arg scenario "$profile_case" '
    if $scenario == "overwrite" then .attributes[$key] = ["0"]
    elif $scenario == "empty-map" then .attributes = {} else del(.attributes[$key]) end' "$STATE_DIR/counter-account.json")
  profile_status=$(curl -sS -o "$STATE_DIR/counter-profile-result.json" -w '%{http_code}' \
    -X POST -H 'Accept: application/json' -H "Authorization: Bearer $counter_access_token" -H 'Content-Type: application/json' \
    --data "$profile_body" "$BASE_URL/realms/$REALM/account/")
  [[ $profile_status == 204 || $profile_status == 400 ]] || fail 'Account API returned an unexpected profile status'
  counter_pass
  [[ $(counter_value "$counter_api") == 100 ]] || fail 'Account API reset the counter'
  counter_pass
done
for profile_case in overwrite omission empty-map; do
  admin_rep=$(kcadm get "users/$counter_api" -r "$REALM" | jq --arg key skyEmailCodeConsecutiveFailures \
    --arg scenario "$profile_case" 'if $scenario == "overwrite" then .attributes[$key] = ["0"]
    elif $scenario == "empty-map" then .attributes = {} else del(.attributes[$key]) end')
  kcadm update "users/$counter_api" -r "$REALM" -f - <<<"$admin_rep" >"$STATE_DIR/counter-admin-update.log" 2>&1 \
    || true # ADMIN_VIEW may reject or ignore the write; SQL must remain unchanged.
  [[ $(counter_value "$counter_api") == 100 ]] || fail 'Admin UserProfile API reset the counter'
  counter_pass
done
unset counter_access_token
printf '    authenticated Account and Admin UserProfile APIs cannot clear 100 by overwrite, omission or empty-map\n'

stage 'persistent counter: reset SQL failure cannot return a Direct Grant JWT or browser code'
counter_fault=$(person counter-fault counter-fault@example.invalid)
counter_seed "$counter_fault" 100
counter_sql >/dev/null <<'SQL'
CREATE FUNCTION counter_reset_fault() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.name = 'skyEmailCodeConsecutiveFailures' THEN RAISE EXCEPTION 'counter reset fault fixture'; END IF;
  RETURN OLD;
END $$;
CREATE TRIGGER counter_reset_fault BEFORE DELETE ON user_attribute FOR EACH ROW EXECUTE FUNCTION counter_reset_fault();
SQL
counter_dag counter-fault
[[ $COUNTER_TOKEN_RESPONSE == 500 ]] || fail 'a reset failure did not fail the Direct Grant response'
counter_pass
jq -e 'has("access_token") | not' "$STATE_DIR/counter-token.json" >/dev/null \
  || fail 'a reset failure returned a signed Direct Grant JWT'
  counter_pass
[[ $(counter_value "$counter_fault") == 100 ]] || fail 'the failed transaction changed the counter'
counter_pass
counter_password_login counter-browser-fault counter-fault
[[ $STATUS == 500 && -z $APP_CODE && $LANDED != app && $LOCATION != *'code='* ]] \
  || fail 'a reset failure returned a browser authorization code or Location'
counter_pass
[[ $(counter_value "$counter_fault") == 100 ]] || fail 'the browser failure committed its reset'
counter_pass
counter_sql >/dev/null <<'SQL'
DROP TRIGGER counter_reset_fault ON user_attribute;
DROP FUNCTION counter_reset_fault();
SQL
counter_dag counter-fault
[[ $COUNTER_TOKEN_RESPONSE == 200 && $(counter_value "$counter_fault") == 0 ]] \
  || fail 'the repaired Direct Grant path did not reset normally'
  counter_pass
jq -e '.access_token | type == "string"' "$STATE_DIR/counter-token.json" >/dev/null || fail 'the positive JWT control failed'
counter_pass
kcadm update "clients/$app_id" -r "$REALM" -s directAccessGrantsEnabled=false >/dev/null
printf '    SQL reset fault: Direct Grant500/no JWT and browser500/no code; repaired path200/reset works\n'

stage 'persistent counter: documented maintenance reset'
counter_seed "$counter_person" 100
counter_realm_id=$(kcadm get "realms/$REALM" --fields id | jq -r '.id')
docker cp "$REPOSITORY_ROOT/config/reset-email-code-failures.sql" "$DB_CONTAINER:/tmp/reset-email-code-failures.sql" >/dev/null
printf '%s\n' "$counter_realm_id" "$counter_person" | docker exec -i "$DB_CONTAINER" \
  psql -X -q -v ON_ERROR_STOP=1 -U keycloak -d keycloak -f /tmp/reset-email-code-failures.sql \
  >"$STATE_DIR/counter-maintenance.log" 2>&1
[[ $(counter_value "$counter_person") == 0 ]] || fail 'the documented maintenance reset failed'
counter_pass
printf '    documented realm-bound maintenance SQL resets only the persistent counter\n'
