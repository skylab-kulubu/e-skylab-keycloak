# shellcheck shell=bash
# Sourced by run-integration.sh; uses its COMPOSE, kcadm, fail, json_assert,
# v2_login_account_center, v2_reconcile_log_must_be_quiet, V2_REALM, V2_ID_PAYLOAD and
# TEST_STATE_DIR.
#
# K4: the realm browser flow signs in with sky-username-password-form, Keycloak's
# username/password form whose lookup also takes the School e-mail of a Verified YTÜ account and
# a proven Personal e-mail. The reconciler puts it in the place of auth-username-password-form in
# 'browser plus passkey' and nothing else in the flow changes. The stages prove, on real
# Keycloak: username, Primary, School and Personal e-mail each sign the right person in; a typo,
# an address two people hold and an unproven address get exactly the answer a wrong password
# gets, and never reveal the username; a wrong password by address is counted once for the person
# and brute-force lockout applies to the address too; the reconciler swap is idempotent, refuses
# a flow it cannot swap safely, finishes an interrupted swap, and swaps back on request.

LBE_SKY_FORM=sky-username-password-form
LBE_STOCK_FORM=auth-username-password-form
LBE_FLOW_EXECUTIONS='authentication/flows/browser%20plus%20passkey/executions'
LBE_PASSWORD='k4-login-fixture-password'
LBE_OTHER_PASSWORD='k4-other-fixture-password'
LBE_WRONG_PASSWORD='k4-not-the-password'
LBE_VERIFIED_AT='2026-09-21T14:13:20Z'
LBE_STATUS=''
LBE_BODY=''
LBE_COOKIES=''

# The flow with the username/password form made provider-neutral: equal before and after the
# swap exactly when the swap is the only change (same place, requirement and priority).
lbe_flow_shape() {
  jq -S -c --arg sky "$LBE_SKY_FORM" --arg stock "$LBE_STOCK_FORM" '
    [.[] | if (.providerId == $sky or .providerId == $stock)
      then del(.id, .displayName, .description) | .providerId = "username-password-form"
      else . end]'
}

# Fails with MESSAGE and both shapes when the live flow differs from BEFORE beyond the form.
lbe_expect_same_flow_shape() {
  local before=$1 message=$2 expected actual
  expected=$(lbe_flow_shape <<<"$before")
  actual=$(lbe_flow | lbe_flow_shape)
  if [[ $actual != "$expected" ]]; then
    diff <(jq . <<<"$expected") <(jq . <<<"$actual") >&2 || true
    fail "$message"
  fi
}

lbe_flow() {
  kcadm get "$LBE_FLOW_EXECUTIONS" -r "$V2_REALM" -c
}

# "<stock count> <sky count> <requirements of both, comma separated>"
lbe_form_census() {
  lbe_flow | jq -r --arg sky "$LBE_SKY_FORM" --arg stock "$LBE_STOCK_FORM" '
    "\([.[] | select(.providerId == $stock)] | length) \([.[] | select(.providerId == $sky)] | length) \([.[] | select(.providerId == $stock or .providerId == $sky) | .requirement] | join(","))"'
}

lbe_run_reconciler() {
  local log_file=$1
  shift
  "${COMPOSE[@]}" run --rm --no-deps "$@" keycloak-config >"$log_file" 2>&1
}

# Called right after the first reconciliation with the flow captured before it.
stage_password_form_after_first_reconciliation() {
  CURRENT_STAGE='K4 password form swapped by the first reconciliation'
  local before=$1
  lbe_expect_same_flow_shape "$before" 'the first reconciliation changed the realm browser flow beyond the password form swap'
  [[ $(jq --arg stock "$LBE_STOCK_FORM" '[.[] | select(.providerId == $stock)] | length' <<<"$before") == 1 ]] \
    || fail 'the browser flow fixture did not start with exactly one stock password form'
  [[ $(lbe_form_census) == "0 1 REQUIRED" ]] \
    || fail "the browser flow does not hold exactly one REQUIRED $LBE_SKY_FORM: $(lbe_form_census)"
  grep -Eq "^\[reconcile\] password form of flow 'browser plus passkey': updated \($LBE_STOCK_FORM -> $LBE_SKY_FORM in subflow '[^']+', priority -?[0-9]+, REQUIRED\)$" \
    "$TEST_STATE_DIR/reconcile-first.log" \
    || fail 'the first reconciliation did not report the password form swap'
}

# One PAR login attempt with account-center that may fail. Leaves the HTTP status of the
# credential POST in LBE_STATUS, the page it returned in LBE_BODY and the cookie jar in
# LBE_COOKIES.
lbe_attempt() {
  local label=$1 username=$2 password=$3 client_secret=$4
  local par request_uri_query page login_action
  LBE_COOKIES="$TEST_STATE_DIR/lbe-$label.cookies"
  rm -f "$LBE_COOKIES"
  par=$(curl --fail --silent --show-error \
    --user "account-center:$client_secret" \
    --data-urlencode client_id=account-center \
    --data-urlencode response_type=code \
    --data-urlencode scope=openid \
    --data-urlencode redirect_uri=https://my.yildizskylab.com/api/auth/callback \
    --data-urlencode code_challenge=QWxhZGRpbjpPcGVuU2VzYW1lMTIzNDU2Nzg5MDEyMzQ1Njc \
    --data-urlencode code_challenge_method=S256 \
    "http://localhost:18080/realms/$V2_REALM/protocol/openid-connect/ext/par/request")
  request_uri_query=$(jq -r '.request_uri | @uri' <<<"$par")
  page=$(curl --fail --silent --show-error --location \
    --cookie-jar "$LBE_COOKIES" --cookie "$LBE_COOKIES" \
    "http://localhost:18080/realms/$V2_REALM/protocol/openid-connect/auth?client_id=account-center&request_uri=$request_uri_query")
  login_action=$(grep -Eo '"loginAction"[[:space:]]*:[[:space:]]*"[^"]*"' <<<"$page" \
    | head -n 1 | sed -E 's/^"loginAction"[[:space:]]*:[[:space:]]*//' | jq -r . || true)
  [[ -n $login_action ]] || fail "K4 attempt $label: the login page exposed no login action"
  LBE_STATUS=$(curl --silent --show-error \
    --output "$TEST_STATE_DIR/lbe-$label.body" \
    --write-out '%{http_code}' \
    --cookie-jar "$LBE_COOKIES" --cookie "$LBE_COOKIES" \
    --data-urlencode "username=$username" \
    --data-urlencode "password=$password" \
    --data-urlencode credentialId= \
    "$login_action")
  LBE_BODY=$(cat "$TEST_STATE_DIR/lbe-$label.body")
}

# What the page tells the person: the message summaries and types of its kcContext.
lbe_answer() {
  grep -Eo '"(summary|type)"[[:space:]]*:[[:space:]]*"[^"]*"' <<<"$1" | sort | paste -sd'|' -
}

# A refused attempt: the login page again with the REFERENCE answer (a wrong password's, or the
# username route's for a locked or disabled person), and not a trace of the username of
# anybody the input could name.
lbe_expect_answer() {
  local label=$1 reference=$2
  shift 2
  local hidden
  [[ $LBE_STATUS == 200 ]] || fail "K4 $label: expected the login page again (HTTP 200), got HTTP $LBE_STATUS"
  [[ $(lbe_answer "$LBE_BODY") == "$reference" ]] \
    || fail "K4 $label: the answer '$(lbe_answer "$LBE_BODY")' differs from the expected '$reference'"
  for hidden in "$@"; do
    [[ $LBE_BODY != *"$hidden"* ]] || fail "K4 $label: the page reveals the username $hidden"
  done
}

lbe_expect_signed_in_as() {
  local label=$1 username=$2 client_secret=$3 user_id=$4
  v2_login_account_center "$label" "$LBE_PASSWORD" "$client_secret" "$username"
  json_assert "$V2_ID_PAYLOAD" '.sub == $sub' "K4 $label: '$username' signed in somebody else" --arg sub "$user_id"
}

lbe_failures() {
  kcadm get "attack-detection/brute-force/users/$1" -r "$V2_REALM" -c | jq -r '"\(.numFailures // 0) \(.disabled // false)"'
}

# Keycloak counts failures on its brute-force executor, after the response.
lbe_await_failures() {
  local user_id=$1 wanted=$2 label=$3 attempt
  for attempt in $(seq 1 50); do
    [[ $(lbe_failures "$user_id" | cut -d' ' -f1) == "$wanted" ]] && return 0
    sleep 0.2
  done
  fail "K4 $label: expected $wanted brute-force failure(s), found $(lbe_failures "$user_id")"
}

lbe_create_person() {
  local username=$1 email=$2 password=$3
  shift 3
  local id attribute
  local arguments=(-s "username=$username" -s enabled=true -s emailVerified=true
    -s firstName=K4 -s lastName=Fixture -s "email=$email")
  for attribute in "$@"; do
    arguments+=(-s "attributes.${attribute%%=*}=[\"${attribute#*=}\"]")
  done
  while IFS= read -r id; do
    [[ -n $id ]] && kcadm delete "users/$id" -r "$V2_REALM" >/dev/null
  done < <(kcadm get users -r "$V2_REALM" -c -q "username=$username" -q exact=true | jq -r '.[].id')
  id=$(kcadm create users -r "$V2_REALM" -i "${arguments[@]}")
  kcadm set-password -r "$V2_REALM" --userid "$id" --new-password "$password" --temporary=false >/dev/null
  printf '%s\n' "$id"
}

lbe_link_ytu() {
  kcadm create "users/$1/federated-identity/OBS" -r "$V2_REALM" \
    -b "{\"identityProvider\":\"OBS\",\"userId\":\"ms-$1\",\"userName\":\"$2\"}" >/dev/null
}

stage_login_by_either_email() {
  CURRENT_STAGE='K4 login by username, Primary, School or Personal e-mail'
  local client_secret=$1
  local person other holder unproven_personal unlinked_school locked attempt
  local wrong_password_answer locked_answer reset_url reset_page events
  kcadm delete identity-provider/instances/OBS -r "$V2_REALM" >/dev/null 2>&1 || true
  kcadm create identity-provider/instances -r "$V2_REALM" \
    -s alias=OBS -s providerId=microsoft -s enabled=true \
    -s 'config.clientId=integration-client' -s 'config.clientSecret=integration-secret' >/dev/null

  # Primary = Personal; the School e-mail is stored the way Microsoft may write it (mixed case).
  person=$(lbe_create_person k4-person k4.personal@example.invalid "$LBE_PASSWORD" \
    schoolEmail=K4.School@std.example.edu.tr personalEmail=k4.personal@example.invalid \
    "personalEmailVerifiedAt=$LBE_VERIFIED_AT")
  lbe_link_ytu "$person" K4.School@std.example.edu.tr

  lbe_expect_signed_in_as k4-username k4-person "$client_secret" "$person"
  lbe_expect_signed_in_as k4-primary-personal k4.personal@example.invalid "$client_secret" "$person"
  lbe_expect_signed_in_as k4-school ' k4.school@STD.example.edu.tr ' "$client_secret" "$person"
  # Primary = School: the Personal e-mail now reaches the person only through the SKY LAB lookup.
  kcadm update "users/$person" -r "$V2_REALM" -s email=k4.school@std.example.edu.tr -s emailVerified=true >/dev/null
  lbe_expect_signed_in_as k4-primary-school K4.School@std.example.edu.tr "$client_secret" "$person"
  lbe_expect_signed_in_as k4-personal K4.Personal@Example.invalid "$client_secret" "$person"

  # The reference answer: a wrong password for the person's username.
  lbe_attempt k4-wrong-password k4-person "$LBE_WRONG_PASSWORD" "$client_secret"
  [[ $LBE_STATUS == 200 ]] || fail "K4 wrong password: expected HTTP 200, got $LBE_STATUS"
  wrong_password_answer=$(lbe_answer "$LBE_BODY")
  [[ $wrong_password_answer == *'"type": "error"'* || $wrong_password_answer == *'"type":"error"'* ]] \
    || fail "K4 wrong password: the page carries no error message ($wrong_password_answer)"
  kcadm delete "attack-detection/brute-force/users/$person" -r "$V2_REALM" >/dev/null

  # A wrong password by address: the same answer, the typed address stays what the pages echo
  # (login page, reset-password page), and the username never shows.
  lbe_attempt k4-wrong-password-by-address k4.personal@example.invalid "$LBE_WRONG_PASSWORD" "$client_secret"
  lbe_expect_answer 'wrong password by address' "$wrong_password_answer" k4-person
  reset_url=$(grep -Eo '"loginResetCredentialsUrl"[[:space:]]*:[[:space:]]*"[^"]*"' <<<"$LBE_BODY" \
    | head -n 1 | sed -E 's/^"loginResetCredentialsUrl"[[:space:]]*:[[:space:]]*//' | jq -r . || true)
  [[ -n $reset_url ]] || fail 'K4: the login page offers no reset-password link'
  [[ $reset_url != /* ]] || reset_url="http://localhost:18080$reset_url"
  reset_page=$(curl --fail --silent --show-error --location \
    --cookie-jar "$LBE_COOKIES" --cookie "$LBE_COOKIES" "$reset_url")
  [[ $reset_page != *k4-person* ]] || fail 'K4: the reset-password page reveals the username behind an address'
  [[ $reset_page == *'k4.personal@example.invalid'* ]] \
    || fail 'K4: the reset-password page does not keep the address the person typed'
  kcadm delete "attack-detection/brute-force/users/$person" -r "$V2_REALM" >/dev/null

  lbe_attempt k4-typo k4.persnal@example.invalid "$LBE_PASSWORD" "$client_secret"
  lbe_expect_answer typo "$wrong_password_answer" k4-person

  # One address, two people (one's Primary, the other's School e-mail): it names nobody, even
  # with the right password of either. The attempt is logged like an unknown username; the
  # brute-force note is the typed address, so Keycloak charges it, as for any input, to whoever
  # its own lookup finds (the Primary e-mail's holder) and never to the School e-mail's holder.
  other=$(lbe_create_person k4-other k4.shared@std.example.edu.tr "$LBE_OTHER_PASSWORD")
  holder=$(lbe_create_person k4-holder k4.holder@example.invalid "$LBE_PASSWORD" \
    schoolEmail=K4.Shared@std.example.edu.tr)
  lbe_link_ytu "$holder" K4.Shared@std.example.edu.tr
  lbe_attempt k4-ambiguous-other k4.shared@std.example.edu.tr "$LBE_OTHER_PASSWORD" "$client_secret"
  lbe_expect_answer 'ambiguous address, first person' "$wrong_password_answer" k4-other k4-holder
  lbe_await_failures "$other" 1 'ambiguous address, charged like the stock form'
  kcadm delete "attack-detection/brute-force/users/$other" -r "$V2_REALM" >/dev/null
  lbe_attempt k4-ambiguous-holder K4.SHARED@std.example.edu.tr "$LBE_PASSWORD" "$client_secret"
  lbe_expect_answer 'ambiguous address, second person' "$wrong_password_answer" k4-other k4-holder
  events=$(kcadm get events -r "$V2_REALM" -q type=LOGIN_ERROR -q max=1 -c)
  json_assert "$events" '.[0].error == "user_not_found" and (.[0].userId // null) == null and .[0].details.username == "K4.SHARED@std.example.edu.tr"' \
    'K4: an ambiguous address must be logged like an unknown username'
  lbe_await_failures "$other" 1 'ambiguous address, charged like the stock form'
  [[ $(lbe_failures "$holder") == '0 false' ]] \
    || fail "K4: an ambiguous address charged the School e-mail's holder ($(lbe_failures "$holder"))"
  kcadm delete "attack-detection/brute-force/users/$other" -r "$V2_REALM" >/dev/null
  # Without the second holder the same address is the first person's again.
  kcadm delete "users/$holder" -r "$V2_REALM" >/dev/null
  v2_login_account_center k4-shared-alone "$LBE_OTHER_PASSWORD" "$client_secret" k4.shared@std.example.edu.tr
  json_assert "$V2_ID_PAYLOAD" '.sub == $sub' 'K4: the unshared address signed in somebody else' --arg sub "$other"
  kcadm delete "users/$other" -r "$V2_REALM" >/dev/null

  # Only proven addresses are identifiers.
  unproven_personal=$(lbe_create_person k4-unproven k4.unproven-primary@example.invalid "$LBE_PASSWORD" \
    personalEmail=k4.unproven@example.invalid)
  lbe_attempt k4-unproven-personal k4.unproven@example.invalid "$LBE_PASSWORD" "$client_secret"
  lbe_expect_answer 'Personal e-mail without its proof' "$wrong_password_answer" k4-unproven
  unlinked_school=$(lbe_create_person k4-unlinked k4.unlinked-primary@example.invalid "$LBE_PASSWORD" \
    schoolEmail=k4.unlinked@std.example.edu.tr)
  lbe_attempt k4-unlinked-school k4.unlinked@std.example.edu.tr "$LBE_PASSWORD" "$client_secret"
  lbe_expect_answer 'School e-mail without the YTÜ link' "$wrong_password_answer" k4-unlinked
  kcadm delete "users/$unproven_personal" -r "$V2_REALM" >/dev/null
  kcadm delete "users/$unlinked_school" -r "$V2_REALM" >/dev/null

  # Brute force: every wrong password by address counts once for the person, the realm's failure
  # factor (10) locks the account, and the lock holds for the addresses as for the username.
  CURRENT_STAGE='K4 brute-force protection through the School and Personal e-mail'
  locked=$(lbe_create_person k4-locked k4.locked-personal@example.invalid "$LBE_PASSWORD" \
    schoolEmail=k4.locked@std.example.edu.tr personalEmail=k4.locked-personal@example.invalid \
    "personalEmailVerifiedAt=$LBE_VERIFIED_AT")
  lbe_link_ytu "$locked" k4.locked@std.example.edu.tr
  kcadm update "users/$locked" -r "$V2_REALM" -s email=k4.locked@std.example.edu.tr -s emailVerified=true >/dev/null
  json_assert "$(kcadm get "realms/$V2_REALM" -c)" \
    '.bruteForceProtected == true and .failureFactor == 10 and .permanentLockout == false and .quickLoginCheckMilliSeconds == 1000' \
    'K4: the reconciled brute-force settings are not in place'
  lbe_attempt k4-locked-1 k4.locked-personal@example.invalid "$LBE_WRONG_PASSWORD" "$client_secret"
  lbe_await_failures "$locked" 1 'first wrong password by the Personal e-mail'
  sleep 1.5
  [[ $(lbe_failures "$locked") == '1 false' ]] \
    || fail "K4: one wrong password by address was counted more than once ($(lbe_failures "$locked"))"
  for attempt in $(seq 2 10); do
    # Slower than quickLoginCheckMilliSeconds, so the failure factor is what locks.
    sleep 1.1
    lbe_attempt "k4-locked-$attempt" k4.locked-personal@example.invalid "$LBE_WRONG_PASSWORD" "$client_secret"
    lbe_expect_answer "wrong password $attempt by address" "$wrong_password_answer" k4-locked
    lbe_await_failures "$locked" "$attempt" "wrong password $attempt by the Personal e-mail"
  done
  [[ $(lbe_failures "$locked") == '10 true' ]] \
    || fail "K4: ten wrong passwords by address did not lock the account ($(lbe_failures "$locked"))"
  lbe_attempt k4-locked-username k4-locked "$LBE_PASSWORD" "$client_secret"
  [[ $LBE_STATUS == 200 ]] || fail "K4: a locked account signed in by username (HTTP $LBE_STATUS)"
  locked_answer=$(lbe_answer "$LBE_BODY")
  lbe_attempt k4-locked-personal k4.locked-personal@example.invalid "$LBE_PASSWORD" "$client_secret"
  lbe_expect_answer 'right password by Personal e-mail while locked' "$locked_answer" k4-locked
  lbe_attempt k4-locked-school k4.locked@std.example.edu.tr "$LBE_PASSWORD" "$client_secret"
  lbe_expect_answer 'right password by School e-mail while locked' "$locked_answer" k4-locked
  kcadm delete "attack-detection/brute-force/users/$locked" -r "$V2_REALM" >/dev/null
  lbe_expect_signed_in_as k4-unlocked k4.locked-personal@example.invalid "$client_secret" "$locked"
  kcadm delete "users/$locked" -r "$V2_REALM" >/dev/null

  # A disabled person gets Keycloak's own answer, by address exactly as by username.
  kcadm update "users/$person" -r "$V2_REALM" -s enabled=false >/dev/null
  lbe_attempt k4-disabled-username k4-person "$LBE_PASSWORD" "$client_secret"
  [[ $LBE_STATUS == 200 ]] || fail "K4: a disabled account signed in by username (HTTP $LBE_STATUS)"
  locked_answer=$(lbe_answer "$LBE_BODY")
  lbe_attempt k4-disabled-personal k4.personal@example.invalid "$LBE_PASSWORD" "$client_secret"
  lbe_expect_answer 'disabled account by Personal e-mail' "$locked_answer"
  kcadm update "users/$person" -r "$V2_REALM" -s enabled=true >/dev/null
  kcadm delete "attack-detection/brute-force/users/$person" -r "$V2_REALM" >/dev/null

  stage_password_form_reconciler "$client_secret" "$person"
  kcadm delete "users/$person" -r "$V2_REALM" >/dev/null
  kcadm delete identity-provider/instances/OBS -r "$V2_REALM" >/dev/null
}

# The reconciler side: refusal, interrupted swap, rollback and forward again, each a no-op when
# run twice.
stage_password_form_reconciler() {
  CURRENT_STAGE='K4 password form reconciler: refusal, interrupted swap, rollback'
  local client_secret=$1 person=$2
  local shape_before flow priority parent_path log_file
  shape_before=$(lbe_flow | lbe_flow_shape)
  flow=$(lbe_flow)
  priority=$(jq -r --arg sky "$LBE_SKY_FORM" '.[] | select(.providerId == $sky) | .priority' <<<"$flow")
  # The subflow that holds the form: the nearest subflow one level up before it.
  parent_path=$(jq -r --arg sky "$LBE_SKY_FORM" '
    . as $all | (map(.providerId) | index($sky)) as $at
    | [$all[:$at][] | select(.level == $all[$at].level - 1 and .authenticationFlow == true)] | last | .displayName' <<<"$flow")
  [[ -n $parent_path && $parent_path != null ]] || fail 'K4: the subflow of the password form was not found'
  parent_path="authentication/flows/${parent_path// /%20}/executions/execution"

  # An unknown flag value stops the run before anything is read.
  log_file="$TEST_STATE_DIR/reconcile-password-form-bogus.log"
  if lbe_run_reconciler "$log_file" -e KEYCLOAK_PASSWORD_FORM=bogus-form; then
    fail 'K4: the reconciler accepted an unknown KEYCLOAK_PASSWORD_FORM'
  fi
  grep -Fq 'KEYCLOAK_PASSWORD_FORM must be sky-username-password-form (default) or auth-username-password-form (rollback), not bogus-form' "$log_file" \
    || { cat "$log_file" >&2; fail 'K4: the reconciler did not explain the refused KEYCLOAK_PASSWORD_FORM'; }
  rbe_bogus_flag

  # A second password form in the flow: refused, nothing written.
  kcadm create "$parent_path" -r "$V2_REALM" \
    -b "{\"provider\":\"$LBE_STOCK_FORM\",\"priority\":$((priority + 1000))}" >/dev/null
  flow=$(lbe_flow)
  log_file="$TEST_STATE_DIR/reconcile-password-form-refused.log"
  if lbe_run_reconciler "$log_file"; then
    fail 'K4: the reconciler accepted a browser flow with two password forms'
  fi
  grep -Fq "expected exactly one of $LBE_STOCK_FORM and $LBE_SKY_FORM, found 1 $LBE_STOCK_FORM and 1 $LBE_SKY_FORM" "$log_file" \
    || { cat "$log_file" >&2; fail 'K4: the reconciler did not explain why it refused the flow'; }
  if [[ $(lbe_flow | jq -S -c .) != "$(jq -S -c . <<<"$flow")" ]]; then
    diff <(jq -S . <<<"$flow") <(lbe_flow | jq -S .) >&2 || true
    fail 'K4: a refused reconciliation changed the flow'
  fi
  kcadm delete "authentication/executions/$(jq -r --arg stock "$LBE_STOCK_FORM" '.[] | select(.providerId == $stock) | .id' <<<"$flow")" \
    -r "$V2_REALM" >/dev/null

  # A swap cut between its two writes (both forms side by side, same priority): finished.
  kcadm create "$parent_path" -r "$V2_REALM" \
    -b "{\"provider\":\"$LBE_STOCK_FORM\",\"priority\":$priority}" >/dev/null
  log_file="$TEST_STATE_DIR/reconcile-password-form-finish.log"
  lbe_run_reconciler "$log_file" || { cat "$log_file" >&2; fail 'K4: the reconciler could not finish an interrupted swap'; }
  grep -Fq "[reconcile] password form of flow 'browser plus passkey': updated (finished an interrupted swap: removed $LBE_STOCK_FORM next to $LBE_SKY_FORM)" "$log_file" \
    || { cat "$log_file" >&2; fail 'K4: the reconciler did not report finishing the interrupted swap'; }
  [[ $(lbe_flow | lbe_flow_shape) == "$shape_before" ]] || fail 'K4: finishing the swap left the flow different'

  # Rollback: Keycloak's own form back in the same place; addresses stop signing in, the
  # username does not. The same runs roll K4b's reset step back and forward (one reconciler run
  # takes minutes; tests/reset-by-either-email.sh).
  log_file="$TEST_STATE_DIR/reconcile-password-form-rollback.log"
  lbe_run_reconciler "$log_file" -e "KEYCLOAK_PASSWORD_FORM=$LBE_STOCK_FORM" -e "KEYCLOAK_RESET_CHOOSE_USER=$RBE_STOCK_STEP" \
    || { cat "$log_file" >&2; fail 'K4: the rollback reconciliation failed'; }
  grep -Eq "^\[reconcile\] password form of flow 'browser plus passkey': updated \($LBE_SKY_FORM -> $LBE_STOCK_FORM in subflow '[^']+', priority $priority, REQUIRED\)$" "$log_file" \
    || { cat "$log_file" >&2; fail 'K4: the rollback did not report swapping the form back'; }
  [[ $(lbe_form_census) == "1 0 REQUIRED" ]] || fail "K4: the rollback left $(lbe_form_census)"
  [[ $(lbe_flow | lbe_flow_shape) == "$shape_before" ]] || fail 'K4: the rollback changed the flow beyond the form'
  rbe_after_rollback "$log_file" "$client_secret" "$person"
  log_file="$TEST_STATE_DIR/reconcile-password-form-rollback-again.log"
  lbe_run_reconciler "$log_file" -e "KEYCLOAK_PASSWORD_FORM=$LBE_STOCK_FORM" -e "KEYCLOAK_RESET_CHOOSE_USER=$RBE_STOCK_STEP" \
    || { cat "$log_file" >&2; fail 'K4: the second rollback reconciliation failed'; }
  v2_reconcile_log_must_be_quiet "$log_file"
  lbe_expect_signed_in_as k4-rollback-username k4-person "$client_secret" "$person"
  lbe_attempt k4-rollback-personal k4.personal@example.invalid "$LBE_PASSWORD" "$client_secret"
  [[ $LBE_STATUS == 200 ]] || fail "K4: with the stock form back, a Personal e-mail still signed in (HTTP $LBE_STATUS)"
  kcadm delete "attack-detection/brute-force/users/$person" -r "$V2_REALM" >/dev/null

  # Forward again, then nothing to do.
  log_file="$TEST_STATE_DIR/reconcile-password-form-forward.log"
  lbe_run_reconciler "$log_file" || { cat "$log_file" >&2; fail 'K4: the forward reconciliation failed'; }
  grep -Fq "[reconcile] password form of flow 'browser plus passkey': updated ($LBE_STOCK_FORM -> $LBE_SKY_FORM" "$log_file" \
    || { cat "$log_file" >&2; fail 'K4: the forward reconciliation did not swap the form in'; }
  rbe_after_forward "$log_file" "$client_secret" "$person"
  log_file="$TEST_STATE_DIR/reconcile-password-form-noop.log"
  lbe_run_reconciler "$log_file" || { cat "$log_file" >&2; fail 'K4: the no-op reconciliation failed'; }
  v2_reconcile_log_must_be_quiet "$log_file"
  grep -Fq "[reconcile] password form of flow 'browser plus passkey': unchanged ($LBE_SKY_FORM)" "$log_file" \
    || fail 'K4: the no-op reconciliation did not report the password form unchanged'
  [[ $(lbe_form_census) == "0 1 REQUIRED" && $(lbe_flow | lbe_flow_shape) == "$shape_before" ]] \
    || fail 'K4: the flow did not come back to the SKY LAB form in its place'
  lbe_expect_signed_in_as k4-forward-personal k4.personal@example.invalid "$client_secret" "$person"
}
