#!/usr/bin/env bash
# Sourced inside the throwaway B12 bootstrap. No production account, tenant or mail is used.
AFTER_SIGN_UP_ASSERTIONS=0
b10_pass() { AFTER_SIGN_UP_ASSERTIONS=$((AFTER_SIGN_UP_ASSERTIONS + 1)); }
b10_flow() { kcadm get "authentication/flows/$(jq -rn --arg f "$1" '$f|@uri')/executions" -r "$REALM"; }
b10_exec() {
  local flow=$1 provider=$2 priority=$3 requirement=$4 id
  kcadm create "authentication/flows/$(jq -rn --arg f "$flow" '$f|@uri')/executions/execution" -r "$REALM" -s "provider=$provider" >/dev/null
  id=$(b10_flow "$flow" | jq -r --arg p "$provider" '.[]|select(.providerId==$p)|.id')
  kcadm update "authentication/flows/$(jq -rn --arg f "$flow" '$f|@uri')/executions" -r "$REALM" \
    -b "{\"id\":\"$id\",\"priority\":$priority,\"requirement\":\"$requirement\"}" >/dev/null
}
b10_subflow() {
  local parent=$1 name=$2 priority=$3 requirement=$4 id
  kcadm create "authentication/flows/$(jq -rn --arg f "$parent" '$f|@uri')/executions/flow" -r "$REALM" \
    -b "{\"alias\":\"$name\",\"type\":\"basic-flow\",\"priority\":$priority}" >/dev/null
  id=$(b10_flow "$parent" | jq -r --arg n "$name" '.[]|select(.displayName==$n)|.id')
  kcadm update "authentication/flows/$(jq -rn --arg f "$parent" '$f|@uri')/executions" -r "$REALM" \
    -b "{\"id\":\"$id\",\"priority\":$priority,\"requirement\":\"$requirement\"}" >/dev/null
}
b10_reconcile() {
  local wanted=$1 output result=0; shift
  local environment=(-e KEYCLOAK_ADMIN_URL=http://localhost:8080 -e "KEYCLOAK_REALM=$REALM"
    -e KEYCLOAK_RECONCILE_ONLY=email-code-login -e "KEYCLOAK_RECONCILE_KCADM_CONFIG=$ADMIN_CONFIG")
  for assignment in "$@"; do environment+=(-e "$assignment"); done
  trap - ERR
  output=$(docker exec "${environment[@]}" "$CONTAINER" bash /opt/keycloak/sky-config/reconcile-account-center.sh 2>&1) || result=$?
  trap 'on_error "$LINENO"' ERR
  [[ $result == "$wanted" ]] || { printf '%s\n' "$output" >&2; fail "B10 reconcile exited$result, expected$wanted"; }
  printf '%s\n' "$output"
}
b10_flag() { kcadm get "realms/$REALM" --fields 'attributes(*)' | jq -r '.attributes.skyAfterSignUpEnabled//"missing"'; }

stage 'B10 native fixture and production-shaped email flow'
[[ $(kcadm get identity-provider/instances/OBS -r "$REALM" | jq -r '.providerId') == microsoft ]] \
  || fail 'B10 fixture must create the Microsoft provider type'
kcadm update "realms/$REALM" -s loginTheme=e-skylab-theme -s internationalizationEnabled=true \
  -s attributes.b10KeepSentinel=retained \
  -s 'supportedLocales=["tr","en"]' -s rememberMe=true -s 'passwordPolicy=length(12) and digits(1)' \
  -s webAuthnPolicyPasswordlessRpId=localhost -s webAuthnPolicyPasswordlessPasskeysEnabled=true \
  -s webAuthnPolicyPasswordlessResidentKey=required -s webAuthnPolicyPasswordlessUserVerificationRequirement=required >/dev/null
for action in UPDATE_PASSWORD webauthn-register-passwordless idp_link; do
  kcadm update "authentication/required-actions/$action" -r "$REALM" -s enabled=true -s defaultAction=false >/dev/null
done
output=$(reconcile "$ADMIN_CONFIG" 0 KEYCLOAK_STAY_SIGNED_IN=on)
FLOW='browser plus passkey'
FORMS='browser plus passkey forms'
kcadm create authentication/flows -r "$REALM" -s "alias=$FLOW" -s providerId=basic-flow -s topLevel=true -s builtIn=false >/dev/null
b10_exec "$FLOW" auth-cookie 10 ALTERNATIVE
b10_exec "$FLOW" identity-provider-redirector 20 ALTERNATIVE
b10_subflow "$FLOW" "$FORMS" 30 ALTERNATIVE
b10_subflow "$FORMS" 'password flow' 10 ALTERNATIVE
b10_exec 'password flow' sky-username-password-form 10 REQUIRED
b10_exec 'password flow' passkey-offer-authenticator 20 REQUIRED
b10_exec "$FORMS" webauthn-authenticator-passwordless 20 ALTERNATIVE
kcadm update "realms/$REALM" -s "browserFlow=$FLOW" >/dev/null
output=$(b10_reconcile 0 KEYCLOAK_EMAIL_CODE_LOGIN=on KEYCLOAK_EMAIL_CODE_SIGN_UP=on)
[[ $(b10_flag) == missing ]] || fail 'default keep wrote the B10 feature'
b10_pass
old_password_shape=$(b10_flow 'password flow' | jq -Sc 'map({id,providerId,requirement,priority})')
output=$(b10_reconcile 0 KEYCLOAK_AFTER_SIGN_UP=on)
[[ $(b10_flag) == true ]] || fail 'B10 on did not activate after readback'
b10_pass
[[ $(kcadm get "realms/$REALM" --fields 'attributes(*)' | jq -r '.attributes.b10KeepSentinel') == retained ]] \
  || fail 'B10 flag write removed an unrelated realm attribute'
b10_pass
printf '  B10 ON: actual realm flag/readback and unrelated realm attributes preserved\n'
first_shape=$(b10_flow "$FLOW" | jq -Sc .)
output=$(b10_reconcile 0 KEYCLOAK_AFTER_SIGN_UP=on)
[[ $output == *'registration continuation: unchanged (on; native action order verified)'* \
  && $(b10_flow "$FLOW" | jq -Sc .) == "$first_shape" ]] || fail 'B10 second on was not idempotent'
b10_pass
output=$(b10_reconcile 0)
[[ $(b10_flow 'password flow' | jq -Sc 'map({id,providerId,requirement,priority})') == "$old_password_shape" ]] \
  || fail 'B10 changed the ordinary password branch'
b10_pass
actions=$(kcadm get authentication/required-actions -r "$REALM")
jq -e 'first(.[]|select(.alias=="sky-sign-up-credentials")) as $offer |
  $offer.providerId=="sky-sign-up-credentials" and $offer.enabled and ($offer.defaultAction|not) and
  all(.[]|select(.alias=="UPDATE_PASSWORD" or .alias=="webauthn-register-passwordless" or .alias=="sky-stay-signed-in"); .priority>$offer.priority)' <<<"$actions" >/dev/null \
  || fail 'session credential/native/stay order is wrong'
b10_pass
printf '  B10 ON/KEEP: stable flow IDs, ordinary password branch and native RA order preserved\n'

stage 'B10 actual disabled half-swap recovery and duplicate refusal'
output=$(b10_reconcile 0 KEYCLOAK_AFTER_SIGN_UP=off)
[[ $(b10_flag) == false ]] || fail 'off did not close the feature'
b10_pass
subflow_id=$(b10_flow "$FLOW" | jq -r '.[]|select(.displayName=="sky email code")|.id')
subflow_priority=$(b10_flow "$FLOW" | jq -r '.[]|select(.id=="'"$subflow_id"'")|.priority')
kcadm update "authentication/flows/$(jq -rn --arg f "$FLOW" '$f|@uri')/executions" -r "$REALM" \
  -b "{\"id\":\"$subflow_id\",\"priority\":$subflow_priority,\"requirement\":\"DISABLED\"}" >/dev/null
offer_id=$(b10_flow 'sky email code' | jq -r '.[]|select(.providerId=="passkey-offer-authenticator")|.id')
kcadm delete "authentication/executions/$offer_id" -r "$REALM" >/dev/null
output=$(b10_reconcile 1 KEYCLOAK_AFTER_SIGN_UP=on)
[[ $(b10_flag) == false ]] || fail 'partial swap activated the feature'
b10_pass
output=$(b10_reconcile 0 KEYCLOAK_EMAIL_CODE_LOGIN=on KEYCLOAK_AFTER_SIGN_UP=on)
[[ $(b10_flag) == true ]] || fail 'explicit half-swap repair did not finish'
b10_pass
b10_exec 'sky email code' passkey-offer-authenticator 40 DISABLED
output=$(b10_reconcile 1 KEYCLOAK_AFTER_SIGN_UP=on)
duplicate=$(b10_flow 'sky email code' | jq -r '.[]|select(.providerId=="passkey-offer-authenticator")|.id')
[[ -n $duplicate ]] || fail 'duplicate refusal mutated the flow'
b10_pass
kcadm delete "authentication/executions/$duplicate" -r "$REALM" >/dev/null
output=$(b10_reconcile 0 KEYCLOAK_AFTER_SIGN_UP=on)
[[ $(b10_flow 'password flow' | jq -Sc 'map({id,providerId,requirement,priority})') == "$old_password_shape" ]] || fail 'repair changed password login'
b10_pass
printf '  B10 closed half-swap repair and duplicate refusal passed\n'

stage 'B10 native Microsoft fixtures and browser package'
mock_person b10-linked@std.yildiz.edu.tr 'Fizik'
linked_mock=$MOCK_USERNAME
mock_person b10-conflict@std.yildiz.edu.tr 'Fizik'
conflict_mock=$MOCK_USERNAME
# This account only owns the conflicting identity; it needs no password. Create it directly so
# failure is checked by the caller rather than hidden by a multi-command substitution helper.
holder=$(kcadm create users -r "$REALM" -i -s username=b10-holder -s enabled=true \
  -s firstName=Yerel -s lastName=Kişi -s email=b10.holder@example.invalid -s emailVerified=true)
[[ -n $holder ]] || fail 'no holder account was created for the conflict fixture'
kcadm create "users/$holder/federated-identity/OBS" -r "$REALM" \
  -b "{\"identityProvider\":\"OBS\",\"userId\":\"$MOCK_ID\",\"userName\":\"$MOCK_USERNAME\"}" >/dev/null
jq -n --arg baseUrl "http://localhost:$PORT" --arg mailUrl "$MAIL_URL" --arg realm "$REALM" \
  --arg clientId "$APP" --arg callbackUrl "$BROWSER_REDIRECT" --arg linkedMock "$linked_mock" \
  --arg conflictMock "$conflict_mock" --arg mockPassword "$MOCK_PASSWORD" \
  '{baseUrl:$baseUrl,mailUrl:$mailUrl,realm:$realm,clientId:$clientId,callbackUrl:$callbackUrl,
    linkedMock:$linkedMock,conflictMock:$conflictMock,mockPassword:$mockPassword}' >"$STATE_DIR/b10-browser.json"
chmod 600 "$STATE_DIR/b10-browser.json"
(
  cd "$REPOSITORY_ROOT/theme"
  B10_BROWSER_CONFIG="$STATE_DIR/b10-browser.json" npx --no-install playwright test \
    --config=playwright.integration.config.ts tests/integration/after-sign-up.spec.ts
)
output=$(b10_reconcile 0 KEYCLOAK_AFTER_SIGN_UP=off)
[[ $(b10_flag) == false ]] || fail 'final off failed'
b10_pass
output=$(b10_reconcile 0 KEYCLOAK_AFTER_SIGN_UP=off)
[[ $(b10_flag) == false ]] || fail 'second off failed'
b10_pass
printf '  B10 keep/on/off, native action order, disabled half-swap recovery and ordinary-login isolation passed\n'
