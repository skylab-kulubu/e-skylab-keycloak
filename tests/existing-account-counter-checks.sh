#!/usr/bin/env bash
# Sourced only by the separate B24 LINK counter entrypoint, inside disposable PG/Keycloak fixtures.
LINK_COUNTER_ASSERTIONS=0
link_counter_pass() { LINK_COUNTER_ASSERTIONS=$((LINK_COUNTER_ASSERTIONS + 1)); }
link_counter_sql() { docker exec -i "$PG_CONTAINER" psql -X -q -v ON_ERROR_STOP=1 -U keycloak -d keycloak "$@"; }
link_counter_seed() {
  link_counter_sql -v "uid=$1" -v "amount=$2" >/dev/null <<'SQL'
BEGIN;
SELECT id FROM user_entity WHERE id = :'uid' FOR UPDATE;
DELETE FROM user_attribute WHERE user_id = :'uid' AND name = 'skyEmailCodeConsecutiveFailures';
INSERT INTO user_attribute(id, user_id, name, value)
VALUES (gen_random_uuid()::text, :'uid', 'skyEmailCodeConsecutiveFailures', :'amount');
COMMIT;
SQL
}
link_counter_value() {
  link_counter_sql -tA -v "uid=$1" <<'SQL'
SELECT coalesce(max(value::integer), 0) FROM user_attribute
WHERE user_id = :'uid' AND name = 'skyEmailCodeConsecutiveFailures';
SQL
}
link_counter_shape() { grep -Eo '(id|data-sky-existing-account-stage)="[^"]*"' <<<"$BODY" | sort | paste -sd' ' -; }
link_counter_otp() {
  local encoded
  encoded=$(node -e '
    const alphabet="ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";let bits=0,value=0,out="";
    for(const byte of Buffer.from("b12-fixed-fixture-secret-0123456789")){
      value=((value<<8)|byte)&65535;bits+=8;
      while(bits>=5){out+=alphabet[(value>>>(bits-5))&31];bits-=5;}}
    if(bits>0)out+=alphabet[(value<<(5-bits))&31];process.stdout.write(out);')
  node "$SCRIPT_DIR/totp-code.mjs" "$encoded"
}

stage 'persistent LINK counter:100 suppresses new mail without enumeration'
cap_user=$(local_person counter-link-cap counter.link.cap@example.invalid)
link_counter_seed "$cap_user" 100
mock_person counter-link-cap@std.yildiz.edu.tr 'Fizik'
ytu_login counter-link-cap "$MOCK_USERNAME"
link_action existing
link_action send --data-urlencode username=counter-link-cap
on_link_stage code || fail 'a capped LINK did not show the generic code page'
link_counter_pass
cap_shape=$(link_counter_shape)
[[ $(mail_count counter.link.cap@example.invalid) == 0 && $(links "$cap_user") == 0 ]] || fail 'a capped LINK sent mail or linked'
link_counter_pass
mock_person counter-link-unknown@std.yildiz.edu.tr 'Fizik'
ytu_login counter-link-unknown "$MOCK_USERNAME"
link_action existing
link_action send --data-urlencode username=counter-link-never-existed
[[ $(link_counter_shape) == "$cap_shape" ]] || fail 'the LINK cap reveals whether the account exists'
link_counter_pass
printf '  LINK100: no mail/link; known blocked and unknown page shapes match\n'

stage 'persistent LINK counter:99-to-100 single alarm and old correct code blocked'
alarm_group=$(kcadm create groups -r "$REALM" -i -s name=ADMIN)
alarm_user=$(kcadm create users -r "$REALM" -i -s username=counter-link-operator -s enabled=true \
  -s email=counter.link.ops@example.invalid -s emailVerified=true)
kcadm update "users/$alarm_user/groups/$alarm_group" -r "$REALM" -n >/dev/null
wrong_user=$(local_person counter-link-wrong counter.link.wrong@example.invalid)
link_counter_seed "$wrong_user" 99
mock_person counter-link-wrong@std.yildiz.edu.tr 'Fizik'
ytu_login counter-link-wrong "$MOCK_USERNAME"
link_action existing
link_action send --data-urlencode username=counter-link-wrong
code=$(mail_code counter.link.wrong@example.invalid)
if [[ ${code:0:1} == 9 ]]; then wrong_code="0${code:1}"; else wrong_code="9${code:1}"; fi
link_action verify --data-urlencode "code=$wrong_code"
[[ $(link_counter_value "$wrong_user") == 100 && $(links "$wrong_user") == 0 ]] || fail 'wrong LINK code did not reach100 safely'
link_counter_pass
link_action verify --data-urlencode "code=$code"
[[ $LANDED == page && $STATUS == 200 && $BODY == *'role="alert"'* && $(links "$wrong_user") == 0 ]] \
  || fail 'the old correct LINK code bypassed100'
link_counter_pass
for _ in $(seq 1 30); do [[ $(mail_count counter.link.ops@example.invalid) == 1 ]] && break; sleep 1; done
[[ $(mail_count counter.link.ops@example.invalid) == 1 ]] || fail 'the persistent LINK transition did not alarm exactly once'
link_counter_pass
[[ $(link_counter_value "$wrong_user") == 100 ]] || fail 'the blocked correct LINK code reset100'
link_counter_pass
printf '  LINK99-to-100: one SMTP operator alarm, old correct code denied, no native link\n'

stage 'persistent LINK counter:valid email proof and pending TOTP boundary'
happy_user=$(local_person counter-link-happy counter.link.happy@example.invalid)
link_counter_seed "$happy_user" 42
mock_person counter-link-happy@std.yildiz.edu.tr 'Fizik'
ytu_login counter-link-happy "$MOCK_USERNAME"
link_action existing
link_action send --data-urlencode username=counter-link-happy
link_action verify --data-urlencode "code=$(mail_code counter.link.happy@example.invalid)"
[[ $LANDED == app && $(links "$happy_user") == 1 && $(link_counter_value "$happy_user") == 0 ]] \
  || fail 'a valid LINK email LOGIN did not link and reset'
link_counter_pass
otp_user=$(local_person counter-link-otp counter.link.otp@example.invalid)
curl -fsS -X POST "$PROBE/counter-otp/factor?user=counter-link-otp" >/dev/null
link_counter_seed "$otp_user" 77
mock_person counter-link-otp@std.yildiz.edu.tr 'Fizik'
ytu_login counter-link-otp "$MOCK_USERNAME"
link_action existing
link_action send --data-urlencode username=counter-link-otp
link_action verify --data-urlencode "code=$(mail_code counter.link.otp@example.invalid)"
[[ $BODY == *'id="kc-otp-login-form"'* && $(link_counter_value "$otp_user") == 77 ]] \
  || fail 'a partial LINK email proof bypassed TOTP or reset the counter'
link_counter_pass
link_counter_seed "$otp_user" 100
follow "$JAR" "$(form_action kc-otp-login-form)" --data-urlencode "otp=$(link_counter_otp)"
[[ $LANDED != app && $LOCATION != *'code='* && $(links "$otp_user") == 0 && $(link_counter_value "$otp_user") == 100 ]] \
  || fail 'a pending TOTP LINK proof bypassed the new cap'
link_counter_pass
printf '  valid email LINK LOGIN resets42; pending TOTP keeps77 and refuses after another request sets100\n'

stage 'persistent LINK counter:separate callback admission and actual SQL fault rollback'
for callback_case in cap fault; do
  callback_user=$(local_person "counter-callback-$callback_case" "counter.callback.$callback_case@example.invalid")
  link_counter_seed "$callback_user" 99
  extra=''
  [[ $callback_case != fault ]] || extra='&counterFault=true'
  curl -fsS -X POST "$PROBE/counter-$callback_case/prepare?user=counter-callback-$callback_case&subject=counter-$callback_case$extra" >/dev/null
  [[ $callback_case != cap ]] || link_counter_seed "$callback_user" 100
  callback_status=$(curl -sS -o "$STATE_DIR/counter-callback-$callback_case.json" -w '%{http_code}' \
    -X POST "$PROBE/counter-$callback_case/complete")
  [[ $callback_status == 409 && $(links "$callback_user") == 0 ]] || fail 'the counter callback veto failed to roll back its native insert'
  link_counter_pass
  if [[ $callback_case == cap ]]; then expected=100; else expected=99; fi
  [[ $(link_counter_value "$callback_user") == "$expected" ]] || fail 'callback rollback changed the counter or failed to restore its table'
  link_counter_pass
done
printf '  actual JPA callback: proof-before-cap and counter SQL fault return409, roll back native insert and preserve counter\n'

stage 'persistent LINK counter:password and native YTU can reset a blocked email account'
password_user=$(local_person counter-link-password counter.link.password@example.invalid)
link_counter_seed "$password_user" 100
mock_person counter-link-password@std.yildiz.edu.tr 'Fizik'
password_mock=$MOCK_USERNAME
ytu_login counter-link-password "$password_mock"
link_action existing
link_action password --data-urlencode username=counter-link-password
follow "$JAR" "$(form_action kc-form-login)" --data-urlencode username=counter-link-password \
  --data-urlencode "password=$LOCAL_PASSWORD" --data-urlencode credentialId=
[[ $LANDED == app && $(links "$password_user") == 1 && $(link_counter_value "$password_user") == 0 ]] \
  || fail 'password LINK LOGIN was blocked by the email cap or failed to reset'
link_counter_pass
link_counter_seed "$password_user" 100
ytu_login counter-linked-ytu "$password_mock"
[[ $LANDED == app && $(link_counter_value "$password_user") == 0 ]] || fail 'an existing native YTU LOGIN could not reset100'
link_counter_pass
printf '  password LINK LOGIN and already-linked native YTU LOGIN reset100; email-only cap stays scoped\n'

stage 'persistent LINK counter:existing A6 login remains available at100'
a6_user=$(local_person counter-link-a6 counter.link.a6@example.invalid)
link_counter_seed "$a6_user" 100
mock_person counter-link-a6@std.yildiz.edu.tr 'Fizik'
JAR="$STATE_DIR/counter-a6.cookies"
follow "$JAR" "$(auth_url '&kc_action=idp_link:OBS')"
follow "$JAR" "$(form_action kc-form-login)" --data-urlencode username=counter-link-a6 \
  --data-urlencode "password=$LOCAL_PASSWORD" --data-urlencode credentialId=
follow "$JAR" "$(form_action '')" --data-urlencode continue=
follow "$JAR" "$(form_action kc-form-login)" --data-urlencode "username=$MOCK_USERNAME" \
  --data-urlencode "password=$MOCK_PASSWORD" --data-urlencode credentialId=
[[ $LANDED == app && $(links "$a6_user") == 1 && $(link_counter_value "$a6_user") == 0 ]] \
  || fail 'native A6 authentication/link was blocked or failed to reset100'
link_counter_pass
printf '  A6 existing-account password authentication/link stays available and resets100\n'

stage 'persistent LINK counter:native resident passkey resets100 after registration'
passkey_user=$(local_person b24-passkey counter.link.passkey@example.invalid)
other_passkey_user=$(local_person b24-other-passkey counter.link.other.passkey@example.invalid)
mock_person counter-passkey-wrong@std.yildiz.edu.tr 'Fizik'
passkey_mock_wrong=$MOCK_USERNAME
mock_person counter-passkey-right@std.yildiz.edu.tr 'Fizik'
passkey_mock_right=$MOCK_USERNAME
kcadm update "realms/$REALM" -s webAuthnPolicyPasswordlessRpId=localhost \
  -s webAuthnPolicyPasswordlessPasskeysEnabled=true -s webAuthnPolicyPasswordlessMediation=conditional \
  -s webAuthnPolicyPasswordlessResidentKey=required -s webAuthnPolicyPasswordlessUserVerificationRequirement=required >/dev/null
jq -n --arg baseUrl "http://localhost:$PORT" --arg realm "$REALM" --arg clientId "$APP" \
  --arg callbackUrl "$BROWSER_REDIRECT" --arg username b24-passkey --arg otherUsername b24-other-passkey \
  --arg password "$LOCAL_PASSWORD" --arg mockUsername "$passkey_mock_wrong" --arg secondMockUsername "$passkey_mock_right" \
  --arg mockPassword "$MOCK_PASSWORD" --arg counterSeedUrl "$PROBE/counter-passkey/counter?user=b24-passkey&amount=100" \
  '{baseUrl:$baseUrl,realm:$realm,clientId:$clientId,callbackUrl:$callbackUrl,username:$username,
    otherUsername:$otherUsername,password:$password,mockUsername:$mockUsername,
    secondMockUsername:$secondMockUsername,mockPassword:$mockPassword,counterSeedUrl:$counterSeedUrl}' >"$STATE_DIR/counter-passkey.json"
chmod 600 "$STATE_DIR/counter-passkey.json"
(
  cd "$REPOSITORY_ROOT/theme"
  B12_PASSKEY_CONFIG="$STATE_DIR/counter-passkey.json" npx --no-install playwright test \
    --config=playwright.integration.config.ts tests/integration/broker-existing-account.spec.ts
)
[[ $(links "$passkey_user") == 1 && $(links "$other_passkey_user") == 0 && $(link_counter_value "$passkey_user") == 0 ]] \
  || fail 'the selected passkey account failed to link/reset100'
link_counter_pass
[[ $(mail_count counter.link.ops@example.invalid) == 1 ]] || fail 'blocked LINK attempts repeated the operator alarm'
link_counter_pass
printf '  native passkey:100 seeded after registration, wrong target keeps100, correct LOGIN links/reset0; one alarm total\n'
