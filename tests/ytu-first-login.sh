#!/usr/bin/env bash
# Real-Keycloak contract for the first YTÜ login (eskylab-login-ux ticket 07, ADR-0063 decision 5):
# the SPI step sky-ytu-first-login and the reconciler's first broker login step
# (config/reconcile-account-center.sh, KEYCLOAK_RECONCILE_ONLY=first-broker-login and
# KEYCLOAK_YTU_FIRST_LOGIN). Stand-alone: starts the stock Keycloak image this repository builds on
# (the Dockerfile's KEYCLOAK_IMAGE) in dev mode with docker run --rm and no volume, with this
# repository's SPI jar in /opt/keycloak/providers and config/ mounted read-only.
#
# The SPI jar: YTU_FIRST_LOGIN_SPI_JAR names one already built (mvn -f spi/pom.xml package);
# without it the jar is built from spi/ in the Dockerfile's Maven image (tests skipped: the image
# build runs them).
#
# YTÜ's Microsoft tenant is played by a second realm, ytu-mock, behind an OIDC identity provider
# with the alias OBS and the production settings that matter (trustEmail, sync mode LEGACY, a first
# login flow override naming Keycloak's built-in flow, as an identity provider made before
# Keycloak 24 has). Like Microsoft behind MicrosoftMapper, it hands over no e-mail; schoolEmail
# (from the upn claim) and department are imported with sync mode FORCE, university is fixed. The
# realm e-skylab has the production login settings, verifyEmail=true, the production User Profile
# and the built-in review profile step set to "on" (production's setting). Logins are driven with
# curl through Keycloak's own pages.
#
# What it proves:
#   - before the step (the fixture as production is today): a first YTÜ login shows the review
#     profile page and opens an account without a Primary e-mail;
#   - the step under an identity with exactly the reconciler's realm-management roles: a copy of
#     the built-in flow with the SKY LAB step before review profile, review profile on "missing",
#     link verification DISABLED, the realm bound to it, the built-in flow untouched; OBS is not
#     readable with that identity and is reported, not changed;
#   - an operator session removes OBS's override (it follows the realm binding) and a second run
#     changes nothing;
#   - a new YTÜ identity: no page between Microsoft and the application; email = the School e-mail
#     lowercased (the step also trims; the unit test shows it), emailVerified=true, no required action, schoolEmail/department/
#     university filled, REGISTER and no SEND_VERIFY_EMAIL event;
#   - a linked account signing in again keeps its Personal Primary e-mail; schoolEmail follows
#     Microsoft (FORCE);
#   - a School e-mail that is another account's personalEmail is not written: the review profile
#     page is shown (today's path until ticket 12) and that account is untouched;
#   - a School e-mail that is another account's email: Keycloak's "existing account" path,
#     confirmed by re-authentication (password), no mailed link; one account, linked, its e-mail
#     unchanged;
#   - linking YTÜ to a signed-in account (A6, kc_action=idp_link:OBS): no page, e-mail unchanged;
#   - KEYCLOAK_YTU_FIRST_LOGIN=off binds the built-in flow back (today's page and empty e-mail
#     again); on again reuses the copy.
# Requirements on the host: docker, jq, curl. YTU_FIRST_LOGIN_TEST_PORT (default 18097),
# YTU_FIRST_LOGIN_TEST_CONTAINER (default ytu-first-login-test-<pid>), YTU_FIRST_LOGIN_TEST_MEMORY
# (default 2g).
# shellcheck disable=SC2016  # jq programs name jq variables
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPOSITORY_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
IMAGE=$(sed -n 's/^ARG KEYCLOAK_IMAGE=//p' "$REPOSITORY_ROOT/Dockerfile")
MAVEN_IMAGE=$(sed -n 's/^FROM \(maven:[^ ]*\) AS providers$/\1/p' "$REPOSITORY_ROOT/Dockerfile")
PORT=${YTU_FIRST_LOGIN_TEST_PORT:-18097}
BASE_URL="http://127.0.0.1:$PORT"
CONTAINER=${YTU_FIRST_LOGIN_TEST_CONTAINER:-ytu-first-login-test-$$}
MEMORY=${YTU_FIRST_LOGIN_TEST_MEMORY:-2g}
STATE_DIR=$(mktemp -d)
ADMIN_PASSWORD=harness-admin-password
OPERATOR_PASSWORD=harness-scoped-operator-password
MOCK_PASSWORD=harness-mock-password
LOCAL_PASSWORD=harness-local-password
BROKER_SECRET=harness-broker-secret
ADMIN_CONFIG=/tmp/harness-admin-kcadm.config
SCOPED_CONFIG=/tmp/harness-scoped-kcadm.config
JACKSON_GLOB='/opt/keycloak/lib/lib/main/com.fasterxml.jackson.core.jackson-*.jar'
REALM=e-skylab
MOCK=ytu-mock
APP=ytu-first-login-app
APP_REDIRECT=http://127.0.0.1:9/ytu-first-login-callback
BUILT_IN='first broker login'
COPY='sky first broker login'
STEP=sky-ytu-first-login
CURRENT_STAGE=startup
STATUS=''
LOCATION=''
BODY=''
LANDED=''

fail() {
  [[ -z ${YTU_FIRST_LOGIN_TEST_PAGE_DUMP:-} ]] || printf '%s\n' "$BODY" >"$YTU_FIRST_LOGIN_TEST_PAGE_DUMP"
  printf 'ytu-first-login failure during %s: %s\n' "$CURRENT_STAGE" "$1" >&2
  exit 1
}
cleanup() {
  docker rm -fv "$CONTAINER" >/dev/null 2>&1 || true
  rm -rf "$STATE_DIR"
}
trap 'status=$?; trap - EXIT; cleanup; exit "$status"' EXIT
on_error() {
  local status=$?
  printf 'ytu-first-login command failed during %s (line %s)\n' "$CURRENT_STAGE" "$1" >&2
  exit "$status"
}
trap 'on_error "$LINENO"' ERR

kcadm() {
  local command=$1
  shift
  docker exec -i "$CONTAINER" /opt/keycloak/bin/kcadm.sh "$command" --config "$ADMIN_CONFIG" "$@" \
    2> >(grep -v -e '^Created new ' -e '^$' >&2 || true)
}

# reconcile CONFIG WANTED_STATUS [ENV=VALUE ...]: the reconciler's first broker login step inside
# the container, with a kcadm session as an operator runs it; prints its output.
reconcile() {
  local config=$1 wanted=$2 output status=0
  shift 2
  local environment=(-e KEYCLOAK_ADMIN_URL=http://localhost:8080 -e "KEYCLOAK_REALM=$REALM"
    -e KEYCLOAK_RECONCILE_ONLY=first-broker-login -e "KEYCLOAK_RECONCILE_KCADM_CONFIG=$config")
  local assignment
  for assignment in "$@"; do
    environment+=(-e "$assignment")
  done
  trap - ERR
  output=$(docker exec "${environment[@]}" "$CONTAINER" bash /opt/keycloak/sky-config/reconcile-account-center.sh 2>&1) \
    || status=$?
  trap 'on_error "$LINENO"' ERR
  [[ $status == "$wanted" ]] || { printf '%s\n' "$output" >&2; fail "the reconciler did not exit $wanted (exit $status)"; }
  printf '%s\n' "$output"
}

expect_line() {
  grep -Fxq -- "$2" <<<"$1" || { printf '%s\n' "$1" >&2; fail "$3: $2"; }
}

# Every [reconcile] line of a run that must change nothing says unchanged.
expect_quiet() {
  if grep -E '^\[reconcile\] ' <<<"$1" | grep -v 'unchanged' >/dev/null; then
    printf '%s\n' "$1" >&2
    fail "$2"
  fi
}

flow() {
  kcadm get "authentication/flows/${1// /%20}/executions" -r "$REALM"
}

bound() {
  kcadm get "realms/$REALM" --fields firstBrokerLoginFlow | jq -r '.firstBrokerLoginFlow // ""'
}

# request JAR URL [curl arguments...]: one request; sets STATUS, LOCATION and BODY.
request() {
  local jar=$1 url=$2
  shift 2
  STATUS=$(curl --silent --show-error --output "$STATE_DIR/body" --dump-header "$STATE_DIR/headers" \
    --write-out '%{http_code}' --cookie "$jar" --cookie-jar "$jar" "$@" "$url")
  LOCATION=$(awk 'tolower($1) == "location:" { print $2 }' "$STATE_DIR/headers" | tr -d '\r' | tail -n 1)
  BODY=$(cat "$STATE_DIR/body")
}

# follow JAR URL [curl arguments...]: the request, then every redirect by hand until a page
# (LANDED=page) or the application's redirect URI (LANDED=app; the code is never redeemed).
follow() {
  local jar=$1 url=$2 hops=0
  shift 2
  request "$jar" "$url" "$@"
  while [[ $STATUS == 30[1237] ]]; do
    if [[ $LOCATION == "$APP_REDIRECT"* ]]; then
      [[ $LOCATION == *'code='* ]] || fail "the application was sent back without a code: ${LOCATION%%\?*}?…"
      LANDED=app
      return 0
    fi
    [[ $LOCATION == http* ]] || LOCATION="$BASE_URL$LOCATION"
    request "$jar" "$LOCATION"
    hops=$((hops + 1))
    ((hops < 25)) || fail 'too many redirects'
  done
  [[ $STATUS == 200 ]] || { printf '%s\n' "$BODY" | head -c 2000 >&2; fail "unexpected HTTP $STATUS"; }
  LANDED=page
}

# The action of the page's form whose id is $1 (Keycloak's own templates); "" for the first form.
form_action() {
  local action pattern="<form[^>]*id=\"$1\"[^>]*>"
  [[ -n $1 ]] || pattern='<form[^>]*>'
  action=$(tr '\n' ' ' <<<"$BODY" | grep -Eo "$pattern" | grep -Eo 'action="[^"]*"' | head -n 1 \
    | sed -e 's/^action="//' -e 's/"$//' -e 's/&amp;/\&/g')
  [[ -n $action ]] || { printf '%s\n' "$BODY" | head -c 3000 >&2; fail "the page has no form #$1"; }
  printf '%s\n' "$action"
}

auth_url() { # auth_url [extra query]
  printf '%s/realms/%s/protocol/openid-connect/auth?client_id=%s&response_type=code&scope=openid&redirect_uri=%s&state=s%s%s\n' \
    "$BASE_URL" "$REALM" "$APP" "$(jq -rn --arg u "$APP_REDIRECT" '$u | @uri')" "$RANDOM" "${1:-}"
}

# ytu_login LABEL MOCK_USERNAME: starts a fresh browser at the application's sign-in with the YTÜ
# button (kc_idp_hint=OBS), signs in at the mock tenant and follows Keycloak; JAR is the cookie file.
ytu_login() {
  JAR="$STATE_DIR/$1.cookies"
  rm -f "$JAR"
  follow "$JAR" "$(auth_url '&kc_idp_hint=OBS')"
  [[ $LANDED == page ]] || fail "$1: the YTÜ button did not reach the tenant's sign-in page ($(page_summary))"
  follow "$JAR" "$(form_action kc-form-login)" --data-urlencode "username=$2" --data-urlencode "password=$MOCK_PASSWORD" \
    --data-urlencode credentialId=
}

# What the browser is looking at, for a failure message: no address or token, only the page's shape.
page_summary() {
  local title forms errors
  title=$(tr '\n' ' ' <<<"$BODY" | grep -Eo '<title>[^<]*</title>' | head -n 1 | sed -e 's/<[^>]*>//g' || true)
  forms=$(grep -Eo '<form[^>]*id="[^"]*"' <<<"$BODY" | grep -Eo 'id="[^"]*"' | paste -sd, - || true)
  errors=$(grep -Eo 'id="input-error[^"]*"' <<<"$BODY" | paste -sd, - || true)
  printf 'landed=%s HTTP %s title=%s forms=%s errors=%s' "$LANDED" "$STATUS" "${title:-?}" "${forms:-none}" "${errors:-none}"
}

# Whether the browser stands on the review profile page.
on_review_profile() {
  [[ $LANDED == page ]] && grep -Eq 'id="kc-idp-review-profile-form"' <<<"$BODY"
}

# submit_review_profile: sends the review profile page back as it is shown. With the production
# User Profile the names and the e-mail are view-only for the person, so the page holds only the
# username, prefilled.
submit_review_profile() {
  local action username
  action=$(form_action kc-idp-review-profile-form)
  username=$(tr '\n' ' ' <<<"$BODY" | grep -Eo '<input[^>]*name="username"[^>]*>' | grep -Eo 'value="[^"]*"' | head -n 1 \
    | sed -e 's/^value="//' -e 's/"$//')
  follow "$JAR" "$action" --data-urlencode "username=$username"
}

user_by_username() {
  kcadm get users -r "$REALM" -q "username=$1" -q exact=true -q briefRepresentation=false | jq -c '.[0] // empty'
}

events_of() { # events_of TYPE USER_ID
  kcadm get events -r "$REALM" -q "type=$1" -q "user=$2" | jq 'length'
}

# mock_person USERNAME UPN DEPARTMENT -> the mock tenant's object id (the brokered identity's id)
mock_person() {
  local id
  # The tenant's own profile wants an e-mail; the broker client never receives it (no email scope).
  id=$(kcadm create users -r "$MOCK" -i -s "username=$1" -s enabled=true -s firstName=Yeni -s lastName=Öğrenci \
    -s "email=$1@tenant.invalid" -s emailVerified=true \
    -s "attributes.upn=[\"$2\"]" -s "attributes.department=[\"$3\"]")
  kcadm set-password -r "$MOCK" --userid "$id" --new-password "$MOCK_PASSWORD" --temporary=false >/dev/null
  printf '%s\n' "$id"
}

# local_person USERNAME EMAIL [attribute=value ...] -> id; a SKY LAB account with a password.
local_person() {
  local username=$1 email=$2 attribute id
  shift 2
  local arguments=(-s "username=$username" -s enabled=true -s firstName=Yerel -s lastName=Kişi
    -s "email=$email" -s emailVerified=true)
  for attribute in "$@"; do
    arguments+=(-s "attributes.${attribute%%=*}=[\"${attribute#*=}\"]")
  done
  id=$(kcadm create users -r "$REALM" -i "${arguments[@]}")
  kcadm set-password -r "$REALM" --userid "$id" --new-password "$LOCAL_PASSWORD" --temporary=false >/dev/null
  printf '%s\n' "$id"
}

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='SPI jar'
[[ -n $IMAGE ]] || fail 'Dockerfile has no ARG KEYCLOAK_IMAGE'
command -v jq >/dev/null || fail 'jq is required'
SPI_JAR=${YTU_FIRST_LOGIN_SPI_JAR:-}
if [[ -z $SPI_JAR ]]; then
  [[ -n $MAVEN_IMAGE ]] || fail 'Dockerfile has no Maven providers stage'
  mkdir -p "$STATE_DIR/spi"
  docker run --rm -v "$REPOSITORY_ROOT/spi:/src:ro" -v "$STATE_DIR/spi:/out" "$MAVEN_IMAGE" \
    sh -ec 'cp -R /src /build && cd /build && mvn --batch-mode --no-transfer-progress -q -DskipTests package && cp target/e-skylab-spi-*.jar /out/' >&2
  SPI_JAR=$(find "$STATE_DIR/spi" -name 'e-skylab-spi-*.jar' | head -n 1)
fi
[[ -f $SPI_JAR ]] || fail "no SPI jar at ${SPI_JAR:-(unset)}"
SPI_JAR=$(cd -- "$(dirname -- "$SPI_JAR")" && pwd)/$(basename -- "$SPI_JAR")
spi_listing=$(unzip -l "$SPI_JAR")
grep -q 'com/skylab/authenticator/SkyYtuFirstLogin.class' <<<"$spi_listing" \
  || fail "the SPI jar does not hold the $STEP step"

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='Keycloak start'
docker run --rm -d --name "$CONTAINER" --memory "$MEMORY" -p "127.0.0.1:$PORT:8080" \
  -e KC_BOOTSTRAP_ADMIN_USERNAME=admin -e KC_BOOTSTRAP_ADMIN_PASSWORD="$ADMIN_PASSWORD" \
  -v "$SPI_JAR:/opt/keycloak/providers/e-skylab-spi.jar:ro" \
  -v "$REPOSITORY_ROOT/config:/opt/keycloak/sky-config:ro" \
  "$IMAGE" start-dev >/dev/null
for _ in $(seq 1 120); do
  curl -fsS "$BASE_URL/realms/master" >/dev/null 2>&1 && break
  sleep 2
done
curl -fsS "$BASE_URL/realms/master" >/dev/null || { docker logs "$CONTAINER" 2>&1 | tail -n 40 >&2; fail "Keycloak did not start ($IMAGE)"; }
docker exec "$CONTAINER" /opt/keycloak/bin/kcadm.sh config credentials --config "$ADMIN_CONFIG" \
  --server http://localhost:8080 --realm master --user admin --password "$ADMIN_PASSWORD" >/dev/null 2>&1 \
  || fail 'kcadm login failed'
printf '    stock Keycloak in dev mode with the SPI jar (%s)\n' "$(basename -- "$SPI_JAR")"

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='mock YTÜ tenant'
kcadm create realms -s "realm=$MOCK" -s enabled=true >/dev/null
kcadm get users/profile -r "$MOCK" | jq '.unmanagedAttributePolicy = "ENABLED"' \
  | kcadm update users/profile -r "$MOCK" -n -f - >/dev/null
broker_client=$(kcadm create clients -r "$MOCK" -i -s clientId=skylab-broker -s publicClient=false \
  -s "secret=$BROKER_SECRET" -s standardFlowEnabled=true -s directAccessGrantsEnabled=false \
  -s "redirectUris=[\"$BASE_URL/realms/$REALM/broker/OBS/endpoint\"]")
# No e-mail claim, as MicrosoftMapper leaves none: the client loses the email scope.
email_scope=$(kcadm get client-scopes -r "$MOCK" | jq -r '.[] | select(.name == "email") | .id')
kcadm delete "clients/$broker_client/default-client-scopes/$email_scope" -r "$MOCK" >/dev/null
for claim in upn department; do
  kcadm create "clients/$broker_client/protocol-mappers/models" -r "$MOCK" -b "{
    \"name\": \"$claim\", \"protocol\": \"openid-connect\", \"protocolMapper\": \"oidc-usermodel-attribute-mapper\",
    \"config\": {\"user.attribute\": \"$claim\", \"claim.name\": \"$claim\", \"jsonType.label\": \"String\",
      \"id.token.claim\": \"true\", \"access.token.claim\": \"true\", \"userinfo.token.claim\": \"true\"}}" >/dev/null
done

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='e-skylab fixture'
kcadm create realms -s "realm=$REALM" -s enabled=true -s loginWithEmailAllowed=true -s duplicateEmailsAllowed=false \
  -s verifyEmail=true -s registrationAllowed=false -s eventsEnabled=true -s adminEventsEnabled=true >/dev/null
docker exec "$CONTAINER" bash -c 'jars=('"$JACKSON_GLOB"'); IFS=:; mkdir -p /tmp/rj
  java -m jdk.compiler/com.sun.tools.javac.Main -d /tmp/rj -cp "${jars[*]}" /opt/keycloak/sky-config/ReconcileJson.java' >/dev/null
desired=$(kcadm get users/profile -r "$REALM" | docker exec -i "$CONTAINER" bash -c 'jars=('"$JACKSON_GLOB"'); IFS=:
  java -cp "/tmp/rj:${jars[*]}" ReconcileJson user-profile /opt/keycloak/sky-config/account-center-user-profile.json; [ $? = 3 ]')
kcadm update users/profile -r "$REALM" -n -f - <<<"$desired" >/dev/null
# Production shows the review profile page on every first YTÜ login ("on" in the built-in flow's config).
review_config=$(flow "$BUILT_IN" | jq -r '.[] | select(.providerId == "idp-review-profile") | .authenticationConfig')
kcadm get "authentication/config/$review_config" -r "$REALM" \
  | jq '.config["update.profile.on.first.login"] = "on"' \
  | kcadm update "authentication/config/$review_config" -r "$REALM" -n -f - >/dev/null
kcadm create identity-provider/instances -r "$REALM" -f - >/dev/null <<JSON
{"alias": "OBS", "providerId": "oidc", "enabled": true, "trustEmail": true,
 "firstBrokerLoginFlowAlias": "$BUILT_IN",
 "config": {"clientId": "skylab-broker", "clientSecret": "$BROKER_SECRET", "clientAuthMethod": "client_secret_post",
   "authorizationUrl": "$BASE_URL/realms/$MOCK/protocol/openid-connect/auth",
   "tokenUrl": "http://localhost:8080/realms/$MOCK/protocol/openid-connect/token",
   "defaultScope": "openid profile", "disableUserInfo": "true", "validateSignature": "false",
   "pkceEnabled": "false", "syncMode": "LEGACY"}}
JSON
for mapper in \
  '{"name":"school-email-importer","identityProviderAlias":"OBS","identityProviderMapper":"oidc-user-attribute-idp-mapper","config":{"syncMode":"FORCE","claim":"upn","user.attribute":"schoolEmail"}}' \
  '{"name":"department","identityProviderAlias":"OBS","identityProviderMapper":"oidc-user-attribute-idp-mapper","config":{"syncMode":"FORCE","claim":"department","user.attribute":"department"}}' \
  '{"name":"university","identityProviderAlias":"OBS","identityProviderMapper":"hardcoded-attribute-idp-mapper","config":{"syncMode":"FORCE","attribute":"university","attribute.value":"YTU"}}'; do
  kcadm create identity-provider/instances/OBS/mappers -r "$REALM" -b "$mapper" >/dev/null
done
kcadm create clients -r "$REALM" -s "clientId=$APP" -s publicClient=true -s standardFlowEnabled=true \
  -s directAccessGrantsEnabled=false -s "redirectUris=[\"$APP_REDIRECT\"]" >/dev/null
kcadm update authentication/required-actions/idp_link -r "$REALM" -s enabled=true >/dev/null
# An identity with exactly the reconciler's realm-management roles (config/bootstrap-reconciler.sh).
operator_id=$(kcadm create users -r "$REALM" -i -s username=fbl-scoped-operator -s enabled=true \
  -s firstName=Scoped -s lastName=Operator -s email=fbl-scoped-operator@example.invalid -s emailVerified=true)
kcadm set-password -r "$REALM" --userid "$operator_id" --new-password "$OPERATOR_PASSWORD" --temporary=false >/dev/null
kcadm add-roles -r "$REALM" --uid "$operator_id" --cclientid realm-management \
  --rolename manage-clients --rolename view-clients --rolename manage-realm --rolename view-realm >/dev/null
docker exec "$CONTAINER" /opt/keycloak/bin/kcadm.sh config credentials --config "$SCOPED_CONFIG" \
  --server http://localhost:8080 --realm "$REALM" --user fbl-scoped-operator --password "$OPERATOR_PASSWORD" >/dev/null 2>&1 \
  || fail 'the scoped operator could not log in'
[[ $(bound) == "$BUILT_IN" ]] || fail "the fixture realm is not bound to the built-in '$BUILT_IN' flow"
built_in_before=$(flow "$BUILT_IN" | jq -S -c .)
printf '    ytu-mock tenant, e-skylab with OBS (override %s, review profile on), app client\n' "'$BUILT_IN'"

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='before the step: production today'
mock_person ytu-before Ytu.Before@STD.Yildiz.edu.tr 'Elektrik Mühendisliği' >/dev/null
ytu_login before ytu-before
on_review_profile || fail "the fixture did not show the review profile page like production ($(page_summary))"
submit_review_profile
[[ $LANDED == app ]] || fail "the review profile page did not lead to the application ($(page_summary))"
before_user=$(user_by_username ytu-before)
jq -e '(.email // "") == "" and .attributes.schoolEmail == ["Ytu.Before@STD.Yildiz.edu.tr"]' <<<"$before_user" >/dev/null \
  || fail "the fixture did not reproduce today's account without a Primary e-mail: $before_user"
printf '    before: review profile page, then an account without a Primary e-mail (the bug)\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='step with the reconciler identity'
output=$(reconcile "$SCOPED_CONFIG" 0)
expect_line "$output" "[reconcile] authentication flow '$COPY': created (an editable copy of the built-in '$BUILT_IN')" 'no copy'
expect_line "$output" "[reconcile] first login step of flow '$COPY': updated (added $STEP before the review profile step, priority 9, REQUIRED)" 'step not added'
expect_line "$output" "[reconcile] review profile of flow '$COPY': updated (update.profile.on.first.login=missing)" 'review profile not set'
expect_line "$output" "[reconcile] link verification of flow '$COPY': updated (idp-email-verification ALTERNATIVE -> DISABLED)" 'link verification not disabled'
expect_line "$output" "[reconcile] realm first broker login flow binding: updated ($BUILT_IN -> $COPY)" 'realm not bound'
expect_line "$output" '[reconcile] identity provider OBS first login flow: unchanged (not readable with this identity; an operator checks it with KEYCLOAK_RECONCILE_ONLY=first-broker-login)' \
  'OBS not reported'
[[ $(bound) == "$COPY" ]] || fail "the realm is bound to '$(bound)'"
[[ $(flow "$BUILT_IN" | jq -S -c .) == "$built_in_before" ]] || fail 'the built-in flow changed'
copy=$(flow "$COPY")
jq -e --arg step "$STEP" '
  ([.[] | select(.level == 0)] | sort_by(.priority) | .[0].providerId == $step and .[0].requirement == "REQUIRED")
  and ([.[] | select(.providerId == $step)] | length == 1)
  and ([.[] | select(.providerId == "idp-email-verification") | .requirement] == ["DISABLED"])
  and ([.[] | select(.providerId == "idp-review-profile")] | length == 1)' <<<"$copy" >/dev/null \
  || { printf '%s\n' "$copy" >&2; fail 'the copy is not shaped as planned'; }
# Apart from the three edits, the copy is the built-in flow.
# (Keycloak names the copied configs "<copy> <alias>"; indexes shift by the one added step.)
shape() {
  jq -S -c --arg step "$STEP" --arg prefix "$COPY " '[.[] | select(.providerId != $step)
    | del(.id, .flowId, .authenticationConfig, .displayName, .description, .requirement, .index)
    | if .alias then .alias |= ltrimstr($prefix) else . end]'
}
if [[ $(shape <<<"$copy") != "$(shape <<<"$built_in_before")" ]]; then
  diff <(shape <<<"$built_in_before" | jq .) <(shape <<<"$copy" | jq .) >&2 || true
  fail 'the copy differs from the built-in flow beyond the edits'
fi
copy_config=$(jq -r '.[] | select(.providerId == "idp-review-profile") | .authenticationConfig' <<<"$copy")
kcadm get "authentication/config/$copy_config" -r "$REALM" | jq -e '.config["update.profile.on.first.login"] == "missing"' >/dev/null \
  || fail 'the copy review profile config is not missing'
kcadm get "authentication/config/$review_config" -r "$REALM" | jq -e '.config["update.profile.on.first.login"] == "on"' >/dev/null \
  || fail "the built-in flow's review profile config changed"
[[ $(kcadm get identity-provider/instances/OBS -r "$REALM" | jq -r '.firstBrokerLoginFlowAlias // ""') == "$BUILT_IN" ]] \
  || fail 'the reconciler identity changed OBS'
printf '%s\n' "$output" | grep '^\[reconcile\]' | sed 's/^/      /'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='operator session: OBS follows the realm binding'
output=$(reconcile "$ADMIN_CONFIG" 0)
expect_line "$output" '[reconcile] identity provider OBS first login flow: updated (its override is removed; it follows the realm binding)' \
  'OBS override not removed'
grep '^\[reconcile\]' <<<"$output" | grep -v 'identity provider OBS' | grep -qv 'unchanged' \
  && { printf '%s\n' "$output" >&2; fail 'the operator run changed more than OBS'; }
kcadm get identity-provider/instances/OBS -r "$REALM" \
  | jq -e '(.firstBrokerLoginFlowAlias // "") == "" and .trustEmail == true and .config.clientSecret == "**********"' >/dev/null \
  || fail 'OBS is not as it was apart from the override'
output=$(reconcile "$ADMIN_CONFIG" 0)
expect_quiet "$output" 'a second run changed something'
expect_line "$output" '[reconcile] identity provider OBS first login flow: unchanged (follows the realm binding)' 'OBS not reported as following'
printf '    operator run removed the override; a second run changed nothing\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='a new YTÜ identity'
mock_person ytu-new Yeni.Ogrenci@STD.Yildiz.edu.tr 'Bilgisayar Mühendisliği' >/dev/null
ytu_login new ytu-new
[[ $LANDED == app ]] || { on_review_profile && fail 'the review profile page was shown'; fail 'a page stood between Microsoft and the application'; }
new_user=$(user_by_username ytu-new)
[[ -n $new_user ]] || fail 'no account was opened'
jq -e '.email == "yeni.ogrenci@std.yildiz.edu.tr" and .emailVerified == true and (.requiredActions | length) == 0
  and .attributes.schoolEmail == ["Yeni.Ogrenci@STD.Yildiz.edu.tr"] and .attributes.department == ["Bilgisayar Mühendisliği"]
  and .attributes.university == ["YTU"]' <<<"$new_user" >/dev/null \
  || { printf '%s\n' "$new_user" >&2; fail 'the new account is not as expected'; }
new_id=$(jq -r .id <<<"$new_user")
[[ $(kcadm get "users/$new_id/federated-identity" -r "$REALM" | jq -r '.[].identityProvider') == OBS ]] || fail 'not linked to OBS'
[[ $(events_of REGISTER "$new_id") == 1 ]] || fail 'no REGISTER event'
[[ $(events_of SEND_VERIFY_EMAIL "$new_id") == 0 ]] || fail 'a verification mail was sent'
[[ $(events_of UPDATE_PROFILE "$new_id") == 0 ]] || fail 'the profile was updated through a page'
printf '    new identity: no page, email = school address (lowercased), verified, no mail\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='a linked account signs in again'
linked_object=$(mock_person ytu-linked Linked.Student@std.yildiz.edu.tr 'Fizik')
linked_id=$(local_person linked-person linked.person@example.org schoolEmail=old.address@std.yildiz.edu.tr \
  personalEmail=linked.person@example.org personalEmailVerifiedAt=2026-09-01T12:00:00Z)
kcadm create "users/$linked_id/federated-identity/OBS" -r "$REALM" \
  -b "{\"identityProvider\":\"OBS\",\"userId\":\"$linked_object\",\"userName\":\"ytu-linked\"}" >/dev/null
ytu_login linked ytu-linked
[[ $LANDED == app ]] || fail 'the linked account saw a page'
linked_user=$(kcadm get "users/$linked_id" -r "$REALM")
jq -e '.email == "linked.person@example.org" and .attributes.schoolEmail == ["Linked.Student@std.yildiz.edu.tr"]
  and .attributes.department == ["Fizik"]' <<<"$linked_user" >/dev/null \
  || { printf '%s\n' "$linked_user" >&2; fail 'the linked account changed its Primary e-mail or kept an old School e-mail'; }
[[ -z $(user_by_username ytu-linked) ]] || fail 'a second account was opened'
printf '    linked account: Primary e-mail kept, schoolEmail follows Microsoft\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE="School e-mail that is another account's personalEmail"
holder_personal=$(local_person holder-personal holder.personal@example.org personalEmail=shared.personal@std.yildiz.edu.tr \
  personalEmailVerifiedAt=2026-09-01T12:00:00Z)
holder_before=$(kcadm get "users/$holder_personal" -r "$REALM" | jq -S -c .)
mock_person ytu-shared-personal Shared.Personal@std.yildiz.edu.tr 'Kimya' >/dev/null
ytu_login shared-personal ytu-shared-personal
on_review_profile || fail "the review profile page was not shown ($(page_summary))"
[[ -z $(user_by_username ytu-shared-personal) ]] || fail 'an account was opened silently'
submit_review_profile
[[ $LANDED == app ]] || fail "the review profile page did not lead to the application ($(page_summary))"
jq -e '(.email // "") == ""' <<<"$(user_by_username ytu-shared-personal)" >/dev/null || fail 'the address was written'
[[ $(kcadm get "users/$holder_personal" -r "$REALM" | jq -S -c .) == "$holder_before" ]] || fail 'the holder changed'
printf '    personalEmail of another account: not written, review profile page (until ticket 12)\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE="School e-mail that is another account's email"
holder_email=$(local_person holder-email shared.primary@std.yildiz.edu.tr)
mock_person ytu-shared-primary Shared.Primary@STD.yildiz.edu.tr 'Matematik' >/dev/null
ytu_login shared-primary ytu-shared-primary
[[ $LANDED == page ]] || fail 'no page for an existing account'
if ! grep -q 'id="kc-register-form"' <<<"$BODY" || ! grep -q 'linkAccount' <<<"$BODY"; then
  fail "not the confirm link page ($(page_summary))"
fi
follow "$JAR" "$(form_action kc-register-form)" --data-urlencode submitAction=linkAccount
[[ $LANDED == page ]] || fail 'linking went through without re-authentication'
grep -q 'name="password"' <<<"$BODY" || { printf '%s\n' "$BODY" | head -c 3000 >&2; fail 'not a re-authentication page'; }
if grep -qi 'An email with instructions to link' <<<"$BODY"; then fail 'a mailed link was offered'; fi
follow "$JAR" "$(form_action kc-form-login)" --data-urlencode username=holder-email --data-urlencode "password=$LOCAL_PASSWORD" \
  --data-urlencode credentialId=
[[ $LANDED == app ]] || fail 're-authentication did not lead to the application'
[[ -z $(user_by_username ytu-shared-primary) ]] || fail 'a second account was opened'
jq -e '.email == "shared.primary@std.yildiz.edu.tr"' <<<"$(kcadm get "users/$holder_email" -r "$REALM")" >/dev/null \
  || fail "the holder's e-mail changed"
[[ $(kcadm get "users/$holder_email/federated-identity" -r "$REALM" | jq -r '.[].identityProvider') == OBS ]] || fail 'the holder was not linked'
[[ $(events_of SEND_IDENTITY_PROVIDER_LINK "$holder_email") == 0 ]] || fail 'a link verification mail was sent'
printf '    email of another account: confirm, re-authenticate with the password, linked; no mail\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='A6: linking YTÜ to a signed-in account'
a6_id=$(local_person a6-person a6.person@example.org)
mock_person ytu-a6 A6.Student@std.yildiz.edu.tr 'Biyoloji' >/dev/null
JAR="$STATE_DIR/a6.cookies"
rm -f "$JAR"
follow "$JAR" "$(auth_url '&kc_action=idp_link:OBS')"
[[ $LANDED == page ]] || fail 'no sign-in page'
follow "$JAR" "$(form_action kc-form-login)" --data-urlencode username=a6-person --data-urlencode "password=$LOCAL_PASSWORD" \
  --data-urlencode credentialId=
# Keycloak's own idp_link confirmation ("Do you want to link your account with OBS?"), as in A6.
[[ $LANDED == page && $BODY == *'name="continue"'* ]] || fail "idp_link did not ask to link ($(page_summary))"
follow "$JAR" "$(form_action '')" --data-urlencode continue=
[[ $LANDED == page && $BODY == *"Sign in to $MOCK"* ]] || fail "idp_link did not reach the tenant ($(page_summary))"
follow "$JAR" "$(form_action kc-form-login)" --data-urlencode username=ytu-a6 --data-urlencode "password=$MOCK_PASSWORD" \
  --data-urlencode credentialId=
[[ $LANDED == app ]] || { on_review_profile && fail 'A6 showed the review profile page'; fail 'A6 did not lead back to the application'; }
jq -e '.email == "a6.person@example.org"' <<<"$(kcadm get "users/$a6_id" -r "$REALM")" >/dev/null || fail 'A6 changed the e-mail'
[[ $(kcadm get "users/$a6_id/federated-identity" -r "$REALM" | jq -r '.[].identityProvider') == OBS ]] || fail 'A6 did not link'
[[ -z $(user_by_username ytu-a6) ]] || fail 'A6 opened a second account'
printf '    A6: linked, no page, e-mail unchanged\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='rollback and forward again'
output=$(reconcile "$SCOPED_CONFIG" 0 KEYCLOAK_YTU_FIRST_LOGIN=off)
expect_line "$output" "[reconcile] realm first broker login flow binding: updated ($COPY -> $BUILT_IN)" 'rollback did not rebind'
[[ $(bound) == "$BUILT_IN" ]] || fail 'the rollback left the realm on the copy'
mock_person ytu-rollback Ytu.Rollback@std.yildiz.edu.tr 'Fizik' >/dev/null
ytu_login rollback ytu-rollback
on_review_profile || fail "the rollback did not bring today's review profile page back ($(page_summary))"
submit_review_profile
jq -e '(.email // "") == ""' <<<"$(user_by_username ytu-rollback)" >/dev/null || fail 'the rollback still wrote the address'
output=$(reconcile "$SCOPED_CONFIG" 0 KEYCLOAK_YTU_FIRST_LOGIN=off)
expect_quiet "$output" 'a second rollback changed something'
output=$(reconcile "$SCOPED_CONFIG" 0)
expect_line "$output" "[reconcile] realm first broker login flow binding: updated ($BUILT_IN -> $COPY)" 'forward did not rebind'
grep -Fq 'created' <<<"$output" && fail 'forward made another copy'
[[ $(kcadm get authentication/flows -r "$REALM" | jq --arg copy "$COPY" '[.[] | select(.alias == $copy)] | length') == 1 ]] \
  || fail 'there is not exactly one copy'
reconcile "$SCOPED_CONFIG" 1 KEYCLOAK_YTU_FIRST_LOGIN=maybe >/dev/null
printf '    off: built-in flow and today'"'"'s page again; on: the same copy bound again\n'

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='a realm bound to another flow'
kcadm create "authentication/flows/${BUILT_IN// /%20}/copy" -r "$REALM" -s 'newName=someone else first login' >/dev/null
kcadm update "realms/$REALM" -s 'firstBrokerLoginFlow=someone else first login' >/dev/null
output=$(reconcile "$SCOPED_CONFIG" 1)
grep -Fq "The realm's first broker login flow is 'someone else first login', neither Keycloak's built-in '$BUILT_IN' nor '$COPY'; nothing was changed" <<<"$output" \
  || { printf '%s\n' "$output" >&2; fail 'another flow was not refused'; }
[[ $(bound) == 'someone else first login' ]] || fail 'the refused run rebound the realm'
printf '    a realm bound to another editable flow is refused\n'

printf 'ytu-first-login: all checks passed\n'
