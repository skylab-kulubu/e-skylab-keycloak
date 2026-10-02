# shellcheck shell=bash
# Sourced by run-integration.sh after login-by-either-email.sh; uses its COMPOSE, kcadm, fail,
# json_assert, sky_mail_fixture_records, v2_login_account_center, V2_REALM, V2_ID_PAYLOAD and
# TEST_STATE_DIR, and K4's lbe_answer, lbe_create_person and lbe_link_ytu.
#
# K4b: the realm's reset credentials flow ("Şifremi unuttum") starts with
# sky-reset-credentials-choose-user, Keycloak's reset-credentials-choose-user with K4's lookup.
# Keycloak's built-in "reset credentials" flow cannot be edited, so the first reconciliation
# copies it to 'sky reset credentials', swaps the step there and only then binds the realm to the
# copy. The stages prove, on real Keycloak: the copy differs from the built-in flow only by the
# step; a run cut short is finished; the rollback and forward runs (shared with K4's reconciler
# stage) swap the step in place; a School or Personal e-mail produces the reset mail through
# SkyMail, addressed to the Primary e-mail and never to the typed one; the link it carries
# resets the password; an unknown, ambiguous, unproven or disabled address gets the same page
# and no mail.

# jq programs name their arguments ($person, $a) in single quotes on purpose.
# shellcheck disable=SC2016
RBE_SKY_STEP=sky-reset-credentials-choose-user
RBE_STOCK_STEP=reset-credentials-choose-user
RBE_BUILT_IN='reset credentials'
RBE_COPY='sky reset credentials'
RBE_PASSWORD='k4b-reset-fixture-password'
RBE_NEW_PASSWORD='k4b-after-reset-password'
RBE_VERIFIED_AT='2026-09-21T14:13:20Z'
RBE_TEMPLATE=keycloak.reset-password
RBE_STATUS=''
RBE_BODY=''
RBE_COOKIES=''

rbe_flow() {
  kcadm get "authentication/flows/${1// /%20}/executions" -r "$V2_REALM" -c
}

# A flow's executions with the choose-user step made provider-neutral and the copy's own ids
# and subflow names left out: equal for the built-in flow and its copy exactly when the step is
# the only difference.
rbe_flow_shape() {
  jq -S -c --arg sky "$RBE_SKY_STEP" --arg stock "$RBE_STOCK_STEP" '
    [.[] | {providerId: (if (.providerId == $sky or .providerId == $stock) then "choose-user" else .providerId end),
      requirement, level, index, priority, authenticationFlow}]'
}

rbe_bound_flow() {
  kcadm get "realms/$V2_REALM" -c | jq -r '.resetCredentialsFlow'
}

# "<stock count> <sky count> <requirements of both>" in FLOW.
rbe_step_census() {
  rbe_flow "$1" | jq -r --arg sky "$RBE_SKY_STEP" --arg stock "$RBE_STOCK_STEP" '
    "\([.[] | select(.providerId == $stock)] | length) \([.[] | select(.providerId == $sky)] | length) \([.[] | select(.providerId == $stock or .providerId == $sky) | .requirement] | join(","))"'
}

rbe_expect_line() {
  local log_file=$1 line=$2 message=$3
  grep -Fqx -- "$line" "$log_file" || { cat "$log_file" >&2; fail "K4b: $message"; }
}

# Called right after the first reconciliation with the built-in flow captured before it.
stage_reset_choose_user_after_first_reconciliation() {
  CURRENT_STAGE='K4b choose-user step swapped in a copy of the reset credentials flow'
  local built_in_before=$1 log_file="$TEST_STATE_DIR/reconcile-first.log"
  [[ $(rbe_flow "$RBE_BUILT_IN" | jq -S -c .) == "$(jq -S -c . <<<"$built_in_before")" ]] \
    || fail "K4b: the built-in '$RBE_BUILT_IN' flow changed"
  [[ $(rbe_bound_flow) == "$RBE_COPY" ]] || fail "K4b: the realm is not bound to '$RBE_COPY' ($(rbe_bound_flow))"
  [[ $(rbe_step_census "$RBE_COPY") == "0 1 REQUIRED" ]] \
    || fail "K4b: '$RBE_COPY' does not hold exactly one REQUIRED $RBE_SKY_STEP: $(rbe_step_census "$RBE_COPY")"
  [[ $(rbe_flow "$RBE_COPY" | rbe_flow_shape) == "$(rbe_flow_shape <<<"$built_in_before")" ]] \
    || fail "K4b: '$RBE_COPY' differs from '$RBE_BUILT_IN' beyond the choose-user step"
  rbe_expect_line "$log_file" "[reconcile] authentication flow '$RBE_COPY': created (an editable copy of the built-in '$RBE_BUILT_IN')" \
    'the first reconciliation did not report the copy'
  rbe_expect_line "$log_file" "[reconcile] choose-user step of flow '$RBE_COPY': updated ($RBE_STOCK_STEP -> $RBE_SKY_STEP in subflow '$RBE_COPY', priority 10, REQUIRED)" \
    'the first reconciliation did not report the swap'
  rbe_expect_line "$log_file" "[reconcile] realm reset credentials flow binding: updated ($RBE_BUILT_IN -> $RBE_COPY)" \
    'the first reconciliation did not report the binding'
}

# A run cut short after the copy: the realm is back on the built-in flow and the copy holds
# Keycloak's step again. The second reconciliation must reuse the copy, not make another.
stage_reset_choose_user_inject_drift() {
  CURRENT_STAGE='K4b reset credentials flow drift'
  local sky_id
  kcadm update "realms/$V2_REALM" -s "resetCredentialsFlow=$RBE_BUILT_IN" >/dev/null
  sky_id=$(rbe_flow "$RBE_COPY" | jq -r --arg sky "$RBE_SKY_STEP" '.[] | select(.providerId == $sky) | .id')
  kcadm create "authentication/flows/${RBE_COPY// /%20}/executions/execution" -r "$V2_REALM" \
    -b "{\"provider\":\"$RBE_STOCK_STEP\",\"priority\":10}" >/dev/null
  kcadm delete "authentication/executions/$sky_id" -r "$V2_REALM" >/dev/null
  [[ $(rbe_bound_flow) == "$RBE_BUILT_IN" && $(rbe_step_census "$RBE_COPY") == "1 0 REQUIRED" ]] \
    || fail 'K4b: the reset credentials drift was not injected'
}

stage_reset_choose_user_after_second_reconciliation() {
  CURRENT_STAGE='K4b reset credentials flow repaired by the second reconciliation'
  local log_file="$TEST_STATE_DIR/reconcile-second.log"
  if grep -Fq "authentication flow '$RBE_COPY': created" "$log_file"; then
    fail "K4b: the second reconciliation made another copy instead of reusing '$RBE_COPY'"
  fi
  [[ $(kcadm get authentication/flows -r "$V2_REALM" -c | jq --arg copy "$RBE_COPY" '[.[] | select(.alias == $copy)] | length') == 1 ]] \
    || fail "K4b: there is not exactly one '$RBE_COPY' flow"
  rbe_expect_line "$log_file" "[reconcile] choose-user step of flow '$RBE_COPY': updated ($RBE_STOCK_STEP -> $RBE_SKY_STEP in subflow '$RBE_COPY', priority 10, REQUIRED)" \
    'the second reconciliation did not swap the step in the reused copy'
  rbe_expect_line "$log_file" "[reconcile] realm reset credentials flow binding: updated ($RBE_BUILT_IN -> $RBE_COPY)" \
    'the second reconciliation did not bind the realm to the copy again'
  [[ $(rbe_bound_flow) == "$RBE_COPY" && $(rbe_step_census "$RBE_COPY") == "0 1 REQUIRED" ]] \
    || fail 'K4b: the second reconciliation left the reset credentials flow unrepaired'
}

stage_reset_choose_user_after_noop_reconciliation() {
  local log_file="$TEST_STATE_DIR/reconcile-noop.log"
  rbe_expect_line "$log_file" "[reconcile] choose-user step of flow '$RBE_COPY': unchanged ($RBE_SKY_STEP)" \
    'the no-op reconciliation did not report the choose-user step unchanged'
  rbe_expect_line "$log_file" "[reconcile] realm reset credentials flow binding: unchanged ($RBE_COPY)" \
    'the no-op reconciliation did not report the binding unchanged'
}

# One reset-password request with account-center, the way a browser makes it: the login page,
# its "Şifremi unuttum" link, the username field. Leaves the HTTP status and page of the
# submission in RBE_STATUS and RBE_BODY, and the cookie jar (which the mailed link continues)
# in RBE_COOKIES.
rbe_reset() {
  local label=$1 username=$2 client_secret=$3
  local par request_uri_query page reset_url action
  RBE_COOKIES="$TEST_STATE_DIR/rbe-$label.cookies"
  rm -f "$RBE_COOKIES"
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
    --cookie-jar "$RBE_COOKIES" --cookie "$RBE_COOKIES" \
    "http://localhost:18080/realms/$V2_REALM/protocol/openid-connect/auth?client_id=account-center&request_uri=$request_uri_query")
  reset_url=$(rbe_context_url loginResetCredentialsUrl "$page")
  [[ -n $reset_url ]] || fail "K4b $label: the login page offers no reset-password link"
  page=$(curl --fail --silent --show-error --location \
    --cookie-jar "$RBE_COOKIES" --cookie "$RBE_COOKIES" "$reset_url")
  action=$(rbe_context_url loginAction "$page")
  [[ -n $action ]] || fail "K4b $label: the reset-password page exposed no form action"
  RBE_STATUS=$(curl --silent --show-error --location \
    --output "$TEST_STATE_DIR/rbe-$label.body" \
    --write-out '%{http_code}' \
    --cookie-jar "$RBE_COOKIES" --cookie "$RBE_COOKIES" \
    --data-urlencode "username=$username" \
    "$action")
  RBE_BODY=$(cat "$TEST_STATE_DIR/rbe-$label.body")
}

# The first "NAME": "…" literal of a page's kcContext, absolute.
rbe_context_url() {
  local value
  value=$(grep -Eo "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" <<<"$2" \
    | head -n 1 | sed -E "s/^\"$1\"[[:space:]]*:[[:space:]]*//" | jq -r . || true)
  [[ -z $value || $value != /* ]] || value="http://localhost:18080$value"
  printf '%s\n' "$value"
}

# A submission must end on the page every other submission ends on, never showing the
# username of anybody the input could name.
rbe_expect_answer() {
  local label=$1 reference=$2
  shift 2
  local hidden
  [[ $RBE_STATUS == 200 ]] || fail "K4b $label: expected the page after the request (HTTP 200), got HTTP $RBE_STATUS"
  [[ $(lbe_answer "$RBE_BODY") == "$reference" ]] \
    || fail "K4b $label: the answer '$(lbe_answer "$RBE_BODY")' differs from the expected '$reference'"
  for hidden in "$@"; do
    [[ $RBE_BODY != *"$hidden"* ]] || fail "K4b $label: the page reveals the username $hidden"
  done
}

# The newest reset-password event of TYPE, as JSON.
rbe_last_event() {
  kcadm get events -r "$V2_REALM" -q "type=$1" -q max=1 -c | jq -c '.[0] // {}'
}

# The reconciler side, run inside K4's reconciler stage (tests/login-by-either-email.sh): the
# rollback and forward runs there carry both flags. Called after the rollback run with its log
# and the K4 person, whose Personal e-mail is not their Primary e-mail at that point.
rbe_after_rollback() {
  local log_file=$1 client_secret=$2 person=$3 event
  rbe_expect_line "$log_file" "[reconcile] choose-user step of flow '$RBE_COPY': updated ($RBE_SKY_STEP -> $RBE_STOCK_STEP in subflow '$RBE_COPY', priority 10, REQUIRED)" \
    'the rollback did not swap Keycloak'"'"'s step back'
  rbe_expect_line "$log_file" "[reconcile] realm reset credentials flow binding: unchanged ($RBE_COPY)" \
    'the rollback changed the realm binding'
  [[ $(rbe_step_census "$RBE_COPY") == "1 0 REQUIRED" && $(rbe_bound_flow) == "$RBE_COPY" ]] \
    || fail "K4b: the rollback left $(rbe_step_census "$RBE_COPY") bound to $(rbe_bound_flow)"
  # Keycloak's own step again: the Personal e-mail names nobody, the username still does.
  rbe_reset k4b-rollback-personal k4.personal@example.invalid "$client_secret"
  event=$(rbe_last_event RESET_PASSWORD_ERROR)
  json_assert "$event" '.error == "user_not_found" and .details.username == "k4.personal@example.invalid"' \
    'K4b: after the rollback a Personal e-mail still found the person'
  rbe_reset k4b-rollback-username k4-person "$client_secret"
  event=$(rbe_last_event SEND_RESET_PASSWORD)
  json_assert "$event" '.userId == $person and .details.username == "k4-person"' \
    'K4b: after the rollback the username no longer starts a reset' --arg person "$person"
}

rbe_after_forward() {
  local log_file=$1 client_secret=$2 person=$3 event
  rbe_expect_line "$log_file" "[reconcile] choose-user step of flow '$RBE_COPY': updated ($RBE_STOCK_STEP -> $RBE_SKY_STEP in subflow '$RBE_COPY', priority 10, REQUIRED)" \
    'the forward run did not swap the SKY LAB step back in'
  rbe_reset k4b-forward-personal K4.Personal@example.invalid "$client_secret"
  event=$(rbe_last_event SEND_RESET_PASSWORD)
  json_assert "$event" '.userId == $person and .details.username == "K4.Personal@example.invalid" and .details.email == "k4.school@std.example.edu.tr"' \
    'K4b: forward again, a Personal e-mail did not start a reset mailed to the Primary e-mail' --arg person "$person"
}

# An unknown flag value stops the run before anything is read.
rbe_bogus_flag() {
  local log_file="$TEST_STATE_DIR/reconcile-reset-choose-user-bogus.log"
  if lbe_run_reconciler "$log_file" -e KEYCLOAK_RESET_CHOOSE_USER=bogus-step; then
    fail 'K4b: the reconciler accepted an unknown KEYCLOAK_RESET_CHOOSE_USER'
  fi
  rbe_expect_line "$log_file" "KEYCLOAK_RESET_CHOOSE_USER must be $RBE_SKY_STEP (default) or $RBE_STOCK_STEP (rollback), not bogus-step" \
    'the reconciler did not explain the refused KEYCLOAK_RESET_CHOOSE_USER'
}

# The reset mails SkyMail received for this stage's people, oldest first, one JSON per line.
rbe_mail_tasks() {
  sky_mail_fixture_records \
    | jq -c --arg template "$RBE_TEMPLATE" \
      'select(.event == "mail_task" and .template_key == $template and ((.recipient_email // "") | startswith("k4b.")))'
}

# Runs after the K5 stage: the realm's mails then leave through SkyMail, as in production.
stage_reset_by_either_email() {
  CURRENT_STAGE='K4b reset password by School or Personal e-mail'
  local client_secret=$1
  local a b c d e f reference event tasks attempt link page action status location
  kcadm delete identity-provider/instances/OBS -r "$V2_REALM" >/dev/null 2>&1 || true
  kcadm create identity-provider/instances -r "$V2_REALM" \
    -s alias=OBS -s providerId=microsoft -s enabled=true \
    -s 'config.clientId=integration-client' -s 'config.clientSecret=integration-secret' >/dev/null

  # A: Primary = Personal; the School e-mail stored the way Microsoft may write it.
  a=$(lbe_create_person k4b-a k4b.a-personal@example.invalid "$RBE_PASSWORD" \
    schoolEmail=K4b.A-School@std.example.edu.tr personalEmail=k4b.a-personal@example.invalid \
    "personalEmailVerifiedAt=$RBE_VERIFIED_AT")
  lbe_link_ytu "$a" K4b.A-School@std.example.edu.tr
  # B: Primary = School; the Personal e-mail is proven.
  b=$(lbe_create_person k4b-b k4b.b-school@std.example.edu.tr "$RBE_PASSWORD" \
    schoolEmail=k4b.b-school@std.example.edu.tr personalEmail=k4b.b-personal@example.invalid \
    "personalEmailVerifiedAt=$RBE_VERIFIED_AT")
  lbe_link_ytu "$b" k4b.b-school@std.example.edu.tr
  # C and D: one address, two people (C's Primary, D's School e-mail).
  c=$(lbe_create_person k4b-c k4b.shared@std.example.edu.tr "$RBE_PASSWORD")
  d=$(lbe_create_person k4b-d k4b.d@example.invalid "$RBE_PASSWORD" schoolEmail=K4b.Shared@std.example.edu.tr)
  lbe_link_ytu "$d" K4b.Shared@std.example.edu.tr
  # E: a Personal e-mail without its proof; F: a School e-mail without the YTÜ link.
  e=$(lbe_create_person k4b-e k4b.e@example.invalid "$RBE_PASSWORD" personalEmail=k4b.e-unproven@example.invalid)
  f=$(lbe_create_person k4b-f k4b.f@example.invalid "$RBE_PASSWORD" schoolEmail=k4b.f-unlinked@std.example.edu.tr)
  [[ -z $(rbe_mail_tasks) ]] || fail 'K4b: SkyMail already holds reset mails for this stage'

  # The reference page: an address nobody has.
  rbe_reset k4b-unknown k4b.nobody@example.invalid "$client_secret"
  [[ $RBE_STATUS == 200 ]] || fail "K4b unknown address: expected HTTP 200, got $RBE_STATUS"
  reference=$(lbe_answer "$RBE_BODY")
  [[ $reference == *'"type": "success"'* || $reference == *'"type":"success"'* ]] \
    || fail "K4b: the page after a reset request carries no success message ($reference)"

  rbe_reset k4b-school ' k4b.a-school@STD.example.edu.tr ' "$client_secret"
  rbe_expect_answer 'School e-mail' "$reference" k4b-a
  event=$(rbe_last_event SEND_RESET_PASSWORD)
  json_assert "$event" '.userId == $a and .details.username == "k4b.a-school@STD.example.edu.tr" and .details.email == "k4b.a-personal@example.invalid"' \
    'K4b: a School e-mail did not start a reset mailed to the Primary e-mail' --arg a "$a"
  cp "$RBE_COOKIES" "$TEST_STATE_DIR/rbe-k4b-school.kept-cookies"

  rbe_reset k4b-personal K4B.B-Personal@Example.invalid "$client_secret"
  rbe_expect_answer 'Personal e-mail' "$reference" k4b-b

  rbe_reset k4b-ambiguous K4B.SHARED@std.example.edu.tr "$client_secret"
  rbe_expect_answer 'address of two people' "$reference" k4b-c k4b-d
  event=$(rbe_last_event RESET_PASSWORD_ERROR)
  json_assert "$event" '.error == "user_not_found" and (.userId // null) == null and .details.username == "K4B.SHARED@std.example.edu.tr"' \
    'K4b: an address of two people must be logged like an unknown username'

  rbe_reset k4b-unproven k4b.e-unproven@example.invalid "$client_secret"
  rbe_expect_answer 'Personal e-mail without its proof' "$reference" k4b-e
  rbe_reset k4b-unlinked k4b.f-unlinked@std.example.edu.tr "$client_secret"
  rbe_expect_answer 'School e-mail without the YTÜ link' "$reference" k4b-f

  kcadm update "users/$a" -r "$V2_REALM" -s enabled=false >/dev/null
  rbe_reset k4b-disabled k4b.a-school@std.example.edu.tr "$client_secret"
  rbe_expect_answer 'disabled account by School e-mail' "$reference" k4b-a
  event=$(rbe_last_event RESET_PASSWORD_ERROR)
  json_assert "$event" '.error == "user_disabled" and .userId == $a and .details.username == "k4b.a-school@std.example.edu.tr"' \
    'K4b: a disabled account found by address must be logged as Keycloak logs a disabled username' --arg a "$a"
  kcadm update "users/$a" -r "$V2_REALM" -s enabled=true >/dev/null

  # Keycloak's own route still works: B's username, mailed to B's Primary e-mail.
  rbe_reset k4b-username k4b-b "$client_secret"
  rbe_expect_answer username "$reference"

  # SkyMail got exactly the three mails, in order, each to the Primary e-mail. Every request
  # above returned after its mail was handed over, so once the last one is in, all are.
  for attempt in $(seq 1 45); do
    tasks=$(rbe_mail_tasks)
    [[ $(jq -s length <<<"$tasks") -ge 3 ]] && break
    sleep 1
  done
  json_assert "$(jq -s -c '[.[].recipient_email]' <<<"$tasks")" \
    '. == ["k4b.a-personal@example.invalid", "k4b.b-school@std.example.edu.tr", "k4b.b-school@std.example.edu.tr"]' \
    "K4b: SkyMail did not receive exactly the three reset mails to the Primary e-mails: $(jq -s -c '[.[].recipient_email]' <<<"$tasks")"
  json_assert "$(jq -s -c . <<<"$tasks")" \
    'all(.[]; .missing_variables == [] and .azp == "keycloak-mailer" and (.body_variables.link | contains("/login-actions/action-token")))' \
    'K4b: a reset mail lacks a variable, the action link or the keycloak-mailer service account'
  json_assert "$(head -n 1 <<<"$tasks")" '.body_variables.username == "k4b-a" and .body_variables.firstName == "K4"' \
    'K4b: the reset mail does not greet its owner'

  # The link from the mail resets A's password, in the browser that asked for it.
  link=$(head -n 1 <<<"$tasks" | jq -r '.body_variables.link')
  page=$(curl --fail --silent --show-error --location \
    --cookie-jar "$TEST_STATE_DIR/rbe-k4b-school.kept-cookies" --cookie "$TEST_STATE_DIR/rbe-k4b-school.kept-cookies" \
    "$link")
  action=$(rbe_context_url loginAction "$page")
  [[ -n $action ]] || fail 'K4b: the reset link did not lead to the new-password page'
  status=$(curl --silent --show-error \
    --output /dev/null \
    --dump-header "$TEST_STATE_DIR/rbe-new-password.headers" \
    --write-out '%{http_code}' \
    --cookie-jar "$TEST_STATE_DIR/rbe-k4b-school.kept-cookies" --cookie "$TEST_STATE_DIR/rbe-k4b-school.kept-cookies" \
    --data-urlencode "password-new=$RBE_NEW_PASSWORD" \
    --data-urlencode "password-confirm=$RBE_NEW_PASSWORD" \
    "$action")
  location=$(awk 'tolower($1) == "location:" { sub(/^[^:]*:[[:space:]]*/, ""); sub(/\r$/, ""); print }' \
    "$TEST_STATE_DIR/rbe-new-password.headers")
  [[ $status == 302 && $location == https://my.yildizskylab.com/api/auth/callback?* ]] \
    || fail "K4b: setting the new password did not finish the sign-in (HTTP $status)"
  v2_login_account_center k4b-after-reset "$RBE_NEW_PASSWORD" "$client_secret" k4b.a-school@std.example.edu.tr
  json_assert "$V2_ID_PAYLOAD" '.sub == $a' 'K4b: the new password signed in somebody else' --arg a "$a"
  json_assert "$(kcadm get "users/$a" -r "$V2_REALM" -c)" \
    '.email == "k4b.a-personal@example.invalid" and .emailVerified == true and .attributes.schoolEmail == ["K4b.A-School@std.example.edu.tr"]' \
    'K4b: the reset changed the e-mail addresses of the person'

  for attempt in "$a" "$b" "$c" "$d" "$e" "$f"; do
    kcadm delete "users/$attempt" -r "$V2_REALM" >/dev/null
  done
  kcadm delete identity-provider/instances/OBS -r "$V2_REALM" >/dev/null
}
