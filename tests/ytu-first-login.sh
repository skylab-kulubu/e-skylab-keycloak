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
# Keycloak 24 has). Like Keycloak's Microsoft provider behind MicrosoftMapper, it hands over the
# address as the username and no e-mail; schoolEmail (from the upn claim, as production imports
# Graph userPrincipalName) and department are imported with sync mode FORCE, university is fixed.
# The realm e-skylab has the production login settings, verifyEmail=true, the production User
# Profile and the built-in review profile step set to "on" (production's setting). Logins are
# driven with curl through Keycloak's own pages; every stage starts with fresh kcadm sessions.
#
# What it proves:
#   - before the step (the fixture as production is today): a first YTÜ login shows the review
#     profile page and opens an account without a Primary e-mail;
#   - the default (KEYCLOAK_YTU_FIRST_LOGIN=keep) turns nothing on;
#   - on, under an identity with exactly the reconciler's realm-management roles: a copy of the
#     built-in flow with the SKY LAB step before review profile, review profile on "missing", link
#     verification DISABLED, the realm bound to it, the built-in flow untouched; OBS is not
#     readable with that identity and is reported, not changed;
#   - an operator session removes OBS's override; second runs (on, keep) change nothing; a
#     disabled step is put back to REQUIRED;
#   - a new YTÜ identity: no page between Microsoft and the application; email = the School e-mail
#     lowercased (the step also trims; the unit test shows it), emailVerified=true, no required
#     action, schoolEmail/department/university filled, REGISTER and no SEND_VERIFY_EMAIL event;
#   - a linked account signing in again keeps its Personal Primary e-mail; schoolEmail follows
#     Microsoft (FORCE);
#   - a School e-mail that is another account's personalEmail is not written: the review profile
#     page is shown (today's path until ticket 12) and that account is untouched;
#   - a School e-mail that is another account's verified email: Keycloak's "existing account"
#     path, confirmed by re-authentication (password), no mailed link; one account, linked, its
#     e-mail unchanged; another account's unverified email does not lock the owner out;
#   - with OBS on sync mode FORCE the operator run warns, and linking a holder keeps its Primary
#     e-mail;
#   - linking YTÜ to a signed-in account (A6, kc_action=idp_link:OBS): no page, e-mail unchanged;
#   - KEYCLOAK_YTU_FIRST_LOGIN=off binds the built-in flow back and removes an OBS override that
#     names the copy (today's page and empty e-mail again); keep leaves it off; on reuses the copy;
#   - production's OBS override, its own duplicate of the built-in flow ('first broker login for
#     obs', review profile "on"; eskylab-login-ux 22): with it the step never runs (the bug of
#     2026-10-13); keep never touches it; a duplicate of another shape is refused with a WARNING and
#     nothing on OBS changes; on removes the override (OBS follows the realm binding, the step runs,
#     the duplicate stays unused) and notes it on OBS; off writes it back and empties the note;
#     second runs change nothing;
#   - the Personal e-mail offer (ticket 21, required action sky-personal-email-offer, the SPI's own
#     page as no SKY LAB theme runs here; KEYCLOAK_PERSONAL_EMAIL_OFFER): keep registers nothing,
#     on registers and enables it, second runs change nothing; a new YTÜ identity sees the page once
#     and "Şimdilik geç" reaches the application and is remembered; a code mailed to the typed
#     address (Keycloak's SMTP into Mailpit; SkyMail is off) adds a verified personalEmail, keeps
#     the School e-mail primary and reaches the application; five wrong codes kill the code; an
#     address another account uses (username, email, or personalEmail stored in capitals) is
#     refused and nothing is mailed; the own school address and any address on the university's
#     domain (email_school_domain) are refused; the sign-in session's send budget runs out; no page for a
#     linked account, A6, a School e-mail another account holds or a password login; off disables
#     it and a new identity goes straight to the application (the expired code is a unit test);
#   - "Bu cihazda oturumum açık kalsın mı?" (required action sky-stay-signed-in, the SPI's own page;
#     KEYCLOAK_STAY_SIGNED_IN; the realm with production's remember-me settings): keep registers
#     nothing, on registers and enables it after every other required action (the offer comes
#     first), puts it last again when moved, second runs change nothing; a new YTÜ identity sees it
#     after the offer and "Evet, açık kalsın" makes a remember-me session with a persistent identity
#     cookie, after which the browser signs in without a page; a linked account is asked again and
#     "Hayır" leaves an ordinary session with a browser-session cookie; a password login with
#     "Beni hatırla" is never asked and still gets a remember-me session; a re-authentication
#     (prompt=login) inside a live session and a passive login (prompt=none forwarded to the tenant)
#     are not asked; off disables it and a YTÜ login goes straight to the application;
#   - a realm bound to another flow is refused.
# Requirements on the host: docker, jq, curl. YTU_FIRST_LOGIN_TEST_PORT (default 18097),
# YTU_FIRST_LOGIN_TEST_MAIL_PORT (default 18098, Mailpit's API),
# YTU_FIRST_LOGIN_TEST_CONTAINER (default ytu-first-login-test-<pid>), YTU_FIRST_LOGIN_TEST_MEMORY
# (default 2g).
# shellcheck disable=SC2016  # jq programs name jq variables
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPOSITORY_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
IMAGE=$(sed -n 's/^ARG KEYCLOAK_IMAGE=//p' "$REPOSITORY_ROOT/Dockerfile")
MAVEN_IMAGE=$(sed -n 's/^FROM \(maven:[^ ]*\) AS providers$/\1/p' "$REPOSITORY_ROOT/Dockerfile")
# The same digest-pinned mail sink as the integration harness.
MAILPIT_IMAGE=$(sed -n 's/^ *image: \(axllent\/mailpit:[^ ]*\)$/\1/p' "$SCRIPT_DIR/docker-compose.integration.yml")
PORT=${YTU_FIRST_LOGIN_TEST_PORT:-18097}
MAIL_PORT=${YTU_FIRST_LOGIN_TEST_MAIL_PORT:-18098}
BASE_URL="http://127.0.0.1:$PORT"
MAIL_URL="http://127.0.0.1:$MAIL_PORT"
CONTAINER=${YTU_FIRST_LOGIN_TEST_CONTAINER:-ytu-first-login-test-$$}
MAIL_CONTAINER="$CONTAINER-mail"
NETWORK="$CONTAINER-net"
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
OFFER=sky-personal-email-offer
STAY=sky-stay-signed-in
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
  docker rm -fv "$CONTAINER" "$MAIL_CONTAINER" >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
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

# sessions_login: fresh kcadm sessions (the administrator, and the scoped operator once it exists).
# A dev-mode session can expire within a run; every stage starts with new ones.
SCOPED_READY=''
sessions_login() {
  docker exec "$CONTAINER" /opt/keycloak/bin/kcadm.sh config credentials --config "$ADMIN_CONFIG" \
    --server http://localhost:8080 --realm master --user admin --password "$ADMIN_PASSWORD" >/dev/null 2>&1 \
    || fail 'kcadm login failed'
  [[ -n $SCOPED_READY ]] || return 0
  docker exec "$CONTAINER" /opt/keycloak/bin/kcadm.sh config credentials --config "$SCOPED_CONFIG" \
    --server http://localhost:8080 --realm "$REALM" --user fbl-scoped-operator --password "$OPERATOR_PASSWORD" >/dev/null 2>&1 \
    || fail 'the scoped operator could not log in'
}

stage() {
  CURRENT_STAGE=$1
  sessions_login
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

# submit_review_profile [USERNAME]: sends the review profile page back as it is shown, or with
# another username. With the production User Profile the names and the e-mail are view-only for
# the person, so the page holds only the username, prefilled.
submit_review_profile() {
  local action username=${1:-}
  action=$(form_action kc-idp-review-profile-form)
  if [[ -z $username ]]; then
    username=$(tr '\n' ' ' <<<"$BODY" | grep -Eo '<input[^>]*name="username"[^>]*>' | grep -Eo 'value="[^"]*"' | head -n 1 \
      | sed -e 's/^value="//' -e 's/"$//')
  fi
  follow "$JAR" "$action" --data-urlencode "username=$username"
}

user_by_username() {
  kcadm get users -r "$REALM" -q "username=$1" -q exact=true -q briefRepresentation=false | jq -c '.[0] // empty'
}

events_of() { # events_of TYPE USER_ID
  kcadm get events -r "$REALM" -q "type=$1" -q "user=$2" | jq 'length'
}

# mock_person UPN DEPARTMENT: a person of the tenant. As with Keycloak's Microsoft provider, the
# brokered username is the address (Graph mail, or the UPN without one; here both are the same
# address, which Keycloak lowercases) and the School e-mail comes from the UPN as written (the
# production importer maps Graph userPrincipalName). The tenant's own profile wants an e-mail; the
# broker client never receives it (no email scope). Sets MOCK_USERNAME and MOCK_ID (the tenant's
# object id: the brokered identity's id).
mock_person() {
  MOCK_USERNAME=$(tr '[:upper:]' '[:lower:]' <<<"$1")
  MOCK_ID=$(kcadm create users -r "$MOCK" -i -s "username=$MOCK_USERNAME" -s enabled=true -s firstName=Yeni \
    -s lastName=Öğrenci -s "email=$MOCK_USERNAME" -s emailVerified=true \
    -s "attributes.upn=[\"$1\"]" -s "attributes.department=[\"$2\"]")
  kcadm set-password -r "$MOCK" --userid "$MOCK_ID" --new-password "$MOCK_PASSWORD" --temporary=false >/dev/null
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
grep -q 'com/skylab/account/PersonalEmailOffer.class' <<<"$spi_listing" \
  || fail "the SPI jar does not hold the $OFFER required action"
grep -q 'com/skylab/authenticator/SkyStaySignedIn.class' <<<"$spi_listing" \
  || fail "the SPI jar does not hold the $STAY required action"

# ---------------------------------------------------------------------------------------------------
CURRENT_STAGE='Keycloak start'
[[ -n $MAILPIT_IMAGE ]] || fail 'tests/docker-compose.integration.yml has no Mailpit image'
docker network create "$NETWORK" >/dev/null
docker run --rm -d --name "$MAIL_CONTAINER" --network "$NETWORK" --memory 256m -p "127.0.0.1:$MAIL_PORT:8025" \
  "$MAILPIT_IMAGE" >/dev/null
docker run --rm -d --name "$CONTAINER" --network "$NETWORK" --memory "$MEMORY" -p "127.0.0.1:$PORT:8080" \
  -e KC_BOOTSTRAP_ADMIN_USERNAME=admin -e KC_BOOTSTRAP_ADMIN_PASSWORD="$ADMIN_PASSWORD" \
  -v "$SPI_JAR:/opt/keycloak/providers/e-skylab-spi.jar:ro" \
  -v "$REPOSITORY_ROOT/config:/opt/keycloak/sky-config:ro" \
  "$IMAGE" start-dev >/dev/null
for _ in $(seq 1 120); do
  curl -fsS "$BASE_URL/realms/master" >/dev/null 2>&1 && break
  sleep 2
done
curl -fsS "$BASE_URL/realms/master" >/dev/null || { docker logs "$CONTAINER" 2>&1 | tail -n 40 >&2; fail "Keycloak did not start ($IMAGE)"; }
sessions_login
printf '    stock Keycloak in dev mode with the SPI jar (%s)\n' "$(basename -- "$SPI_JAR")"

# ---------------------------------------------------------------------------------------------------
stage 'mock YTÜ tenant'
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
stage 'e-skylab fixture'
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
SCOPED_READY=1
sessions_login
[[ $(bound) == "$BUILT_IN" ]] || fail "the fixture realm is not bound to the built-in '$BUILT_IN' flow"
built_in_before=$(flow "$BUILT_IN" | jq -S -c .)
printf '    ytu-mock tenant, e-skylab with OBS (override %s, review profile on), app client\n' "'$BUILT_IN'"

# ---------------------------------------------------------------------------------------------------
# ReconcileJson same-shape on the real built-in flow and edited variants of it (the reconciler's
# shape checks of eskylab-login-ux 22). shape_status VARIANT_JSON [STEP] -> exit status; stderr kept.
CURRENT_STAGE='ReconcileJson same-shape'
docker exec -i "$CONTAINER" sh -c 'cat >/tmp/rj/built-in.json' <<<"$built_in_before"
shape_status() {
  local status=0
  docker exec -i "$CONTAINER" bash -c 'jars=('"$JACKSON_GLOB"'); IFS=:
    java -cp "/tmp/rj:${jars[*]}" ReconcileJson same-shape /tmp/rj/built-in.json "$@"' _ "${@:2}" <<<"$1" \
    2>"$STATE_DIR/shape.err" || status=$?
  printf '%s\n' "$status"
}
expect_shape() { # expect_shape LABEL WANTED_STATUS STDERR_PATTERN VARIANT_JSON [STEP]
  local got
  got=$(shape_status "$4" "${@:5}")
  [[ $got == "$2" ]] || { cat "$STATE_DIR/shape.err" >&2; fail "same-shape $1: exit $got, not $2"; }
  [[ -z $3 ]] || grep -q -- "$3" "$STATE_DIR/shape.err" || { cat "$STATE_DIR/shape.err" >&2; fail "same-shape $1: no '$3' in the difference"; }
}
expect_shape identical 0 '' "$built_in_before"
expect_shape 'ids, names, priorities, configs' 0 '' "$(jq -c 'map(.id = "x" | .displayName = "y" | .priority = 999 | del(.authenticationConfig))' <<<"$built_in_before")"
expect_shape 'a requirement' 4 'REQUIRED' "$(jq -c 'map(if .providerId == "idp-email-verification" then .requirement = "REQUIRED" else . end)' <<<"$built_in_before")"
expect_shape 'a missing step' 4 'nothing' "$(jq -c '.[:-1]' <<<"$built_in_before")"
expect_shape 'an inserted idp-auto-link' 4 'idp-auto-link' \
  "$(jq -c '.[:3] + [{providerId: "idp-auto-link", level: 1, index: 0, requirement: "ALTERNATIVE"}] + .[3:]' <<<"$built_in_before")"
# The copy of eskylab-login-ux 07: the step on top (indexes shift), link verification DISABLED.
copy_like=$(jq -c --arg step "$STEP" '[{providerId: $step, level: 0, index: 0, requirement: "REQUIRED"}]
  + map(if .level == 0 then .index += 1 else . end | if .providerId == "idp-email-verification" then .requirement = "DISABLED" else . end)' \
  <<<"$built_in_before")
expect_shape 'the copy, as a copy' 0 '' "$copy_like" "$STEP"
expect_shape 'the copy, as a duplicate' 4 '' "$copy_like"
expect_shape 'the copy with an idp-auto-link' 4 'idp-auto-link' \
  "$(jq -c '. + [{providerId: "idp-auto-link", level: 0, index: 9, requirement: "ALTERNATIVE"}]' <<<"$copy_like")" "$STEP"
expect_shape 'the copy with another requirement' 4 'REQUIRED' \
  "$(jq -c 'map(if .providerId == "idp-review-profile" then .requirement = "DISABLED" else . end)' <<<"$copy_like")" "$STEP"
printf '    same-shape: ids/names/priorities/configs ignored; a requirement, a missing step, an extra idp-auto-link refused; copy mode\n'

# ---------------------------------------------------------------------------------------------------
stage 'before the step: production today'
mock_person Ytu.Before@STD.Yildiz.edu.tr 'Elektrik Mühendisliği'
ytu_login before "$MOCK_USERNAME"
on_review_profile || fail "the fixture did not show the review profile page like production ($(page_summary))"
submit_review_profile
[[ $LANDED == app ]] || fail "the review profile page did not lead to the application ($(page_summary))"
before_user=$(user_by_username ytu.before@std.yildiz.edu.tr)
jq -e '(.email // "") == "" and .attributes.schoolEmail == ["Ytu.Before@STD.Yildiz.edu.tr"]' <<<"$before_user" >/dev/null \
  || fail "the fixture did not reproduce today's account without a Primary e-mail: $before_user"
printf '    before: review profile page, then an account without a Primary e-mail (the bug)\n'

# ---------------------------------------------------------------------------------------------------
stage 'a full reconciliation keeps the binding'
output=$(reconcile "$SCOPED_CONFIG" 0)
expect_line "$output" "[reconcile] realm first broker login flow binding: unchanged ($BUILT_IN; KEYCLOAK_YTU_FIRST_LOGIN=on or off changes it)" \
  'the default did not keep the binding'
expect_quiet "$output" 'the default changed something'
[[ $(bound) == "$BUILT_IN" ]] || fail 'the default bound the realm'
[[ $(kcadm get authentication/flows -r "$REALM" | jq --arg copy "$COPY" '[.[] | select(.alias == $copy)] | length') == 0 ]] \
  || fail 'the default made the copy'
printf '    default (keep): nothing turned on\n'

# ---------------------------------------------------------------------------------------------------
stage 'on, with the reconciler identity'
output=$(reconcile "$SCOPED_CONFIG" 0 KEYCLOAK_YTU_FIRST_LOGIN=on)
expect_line "$output" "[reconcile] authentication flow '$COPY': created (an editable copy of the built-in '$BUILT_IN')" 'no copy'
expect_line "$output" "[reconcile] first login step of flow '$COPY': updated (added $STEP before the review profile step, priority 9, REQUIRED)" 'step not added'
expect_line "$output" "[reconcile] review profile of flow '$COPY': updated (update.profile.on.first.login=missing)" 'review profile not set'
expect_line "$output" "[reconcile] link verification of flow '$COPY': updated (idp-email-verification ALTERNATIVE -> DISABLED)" 'link verification not disabled'
expect_line "$output" "[reconcile] realm first broker login flow binding: updated ($BUILT_IN -> $COPY)" 'realm not bound'
expect_line "$output" "[reconcile] shape of flow '$COPY': unchanged (the built-in '$BUILT_IN' plus the SKY LAB edits)" 'copy shape not checked'
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
stage 'operator session: OBS follows the realm binding'
output=$(reconcile "$ADMIN_CONFIG" 0 KEYCLOAK_YTU_FIRST_LOGIN=on)
expect_line "$output" '[reconcile] identity provider OBS first login flow: updated (its override is removed; it follows the realm binding)' \
  'OBS override not removed'
if grep '^\[reconcile\]' <<<"$output" | grep -v 'identity provider OBS' | grep -qv 'unchanged'; then
  printf '%s\n' "$output" >&2
  fail 'the operator run changed more than OBS'
fi
kcadm get identity-provider/instances/OBS -r "$REALM" \
  | jq -e '(.firstBrokerLoginFlowAlias // "") == "" and .trustEmail == true and .config.clientSecret == "**********"' >/dev/null \
  || fail 'OBS is not as it was apart from the override'
output=$(reconcile "$ADMIN_CONFIG" 0 KEYCLOAK_YTU_FIRST_LOGIN=on)
expect_quiet "$output" 'a second run changed something'
expect_line "$output" '[reconcile] identity provider OBS first login flow: unchanged (follows the realm binding)' 'OBS not reported as following'
output=$(reconcile "$SCOPED_CONFIG" 0)
expect_quiet "$output" 'a full reconciliation after on changed something'
expect_line "$output" "[reconcile] realm first broker login flow binding: unchanged ($COPY; KEYCLOAK_YTU_FIRST_LOGIN=on or off changes it)" \
  'keep did not keep the copy'
# A step someone disabled is put back by the next run, even with keep.
step_execution=$(flow "$COPY" | jq -c --arg step "$STEP" '.[] | select(.providerId == $step) | {id, priority, requirement: "DISABLED"}')
kcadm update "authentication/flows/${COPY// /%20}/executions" -r "$REALM" -n -b "$step_execution" >/dev/null
[[ $(flow "$COPY" | jq -r --arg step "$STEP" '.[] | select(.providerId == $step) | .requirement') == DISABLED ]] \
  || fail 'the step could not be disabled for the drift check'
output=$(reconcile "$SCOPED_CONFIG" 0)
expect_line "$output" "[reconcile] first login step of flow '$COPY': updated ($STEP DISABLED -> REQUIRED)" 'a disabled step was not repaired'
[[ $(flow "$COPY" | jq -r --arg step "$STEP" '.[] | select(.providerId == $step) | .requirement') == REQUIRED ]] \
  || fail 'the step is not REQUIRED again'
printf '    operator run removed the override; second runs changed nothing; a disabled step is repaired\n'

# ---------------------------------------------------------------------------------------------------
stage 'a new YTÜ identity'
mock_person Yeni.Ogrenci@STD.Yildiz.edu.tr 'Bilgisayar Mühendisliği'
ytu_login new "$MOCK_USERNAME"
[[ $LANDED == app ]] || { on_review_profile && fail 'the review profile page was shown'; fail "a page stood between Microsoft and the application ($(page_summary))"; }
new_user=$(user_by_username yeni.ogrenci@std.yildiz.edu.tr)
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
stage 'a linked account signs in again'
mock_person Linked.Student@std.yildiz.edu.tr 'Fizik'
linked_id=$(local_person linked-person linked.person@example.org schoolEmail=old.address@std.yildiz.edu.tr \
  personalEmail=linked.person@example.org personalEmailVerifiedAt=2026-09-01T12:00:00Z)
kcadm create "users/$linked_id/federated-identity/OBS" -r "$REALM" \
  -b "{\"identityProvider\":\"OBS\",\"userId\":\"$MOCK_ID\",\"userName\":\"$MOCK_USERNAME\"}" >/dev/null
ytu_login linked "$MOCK_USERNAME"
[[ $LANDED == app ]] || fail "the linked account saw a page ($(page_summary))"
linked_user=$(kcadm get "users/$linked_id" -r "$REALM")
jq -e '.email == "linked.person@example.org" and .attributes.schoolEmail == ["Linked.Student@std.yildiz.edu.tr"]
  and .attributes.department == ["Fizik"]' <<<"$linked_user" >/dev/null \
  || { printf '%s\n' "$linked_user" >&2; fail 'the linked account changed its Primary e-mail or kept an old School e-mail'; }
[[ -z $(user_by_username "$MOCK_USERNAME") ]] || fail 'a second account was opened'
printf '    linked account: Primary e-mail kept, schoolEmail follows Microsoft\n'

# ---------------------------------------------------------------------------------------------------
stage "School e-mail that is another account's personalEmail"
holder_personal=$(local_person holder-personal holder.personal@example.org personalEmail=shared.personal@std.yildiz.edu.tr \
  personalEmailVerifiedAt=2026-09-01T12:00:00Z)
holder_before=$(kcadm get "users/$holder_personal" -r "$REALM" | jq -S -c .)
mock_person Shared.Personal@std.yildiz.edu.tr 'Kimya'
ytu_login shared-personal "$MOCK_USERNAME"
on_review_profile || fail "the review profile page was not shown ($(page_summary))"
[[ -z $(user_by_username "$MOCK_USERNAME") ]] || fail 'an account was opened silently'
submit_review_profile
[[ $LANDED == app ]] || fail "the review profile page did not lead to the application ($(page_summary))"
jq -e '(.email // "") == ""' <<<"$(user_by_username "$MOCK_USERNAME")" >/dev/null || fail 'the address was written'
[[ $(kcadm get "users/$holder_personal" -r "$REALM" | jq -S -c .) == "$holder_before" ]] || fail 'the holder changed'
printf '    personalEmail of another account: not written, review profile page (until ticket 12)\n'

# ---------------------------------------------------------------------------------------------------
# link_by_password LABEL HOLDER_USERNAME: on Keycloak's confirm link page, link and re-authenticate
# as the holder; the person must end in the application, linked to the holder.
link_by_password() {
  if ! grep -q 'id="kc-register-form"' <<<"$BODY" || ! grep -q 'linkAccount' <<<"$BODY"; then
    fail "$1: not the confirm link page ($(page_summary))"
  fi
  follow "$JAR" "$(form_action kc-register-form)" --data-urlencode submitAction=linkAccount
  [[ $LANDED == page ]] || fail "$1: linking went through without re-authentication"
  grep -q 'name="password"' <<<"$BODY" || fail "$1: not a re-authentication page ($(page_summary))"
  if grep -qi 'An email with instructions to link' <<<"$BODY"; then fail "$1: a mailed link was offered"; fi
  follow "$JAR" "$(form_action kc-form-login)" --data-urlencode "username=$2" --data-urlencode "password=$LOCAL_PASSWORD" \
    --data-urlencode credentialId=
  [[ $LANDED == app ]] || fail "$1: re-authentication did not lead to the application ($(page_summary))"
}

stage "School e-mail that is another account's verified email"
holder_email=$(local_person holder-email shared.primary@std.yildiz.edu.tr)
mock_person Shared.Primary@STD.yildiz.edu.tr 'Matematik'
ytu_login shared-primary "$MOCK_USERNAME"
[[ $LANDED == page ]] || fail 'no page for an existing account'
link_by_password 'verified email holder' holder-email
[[ -z $(user_by_username "$MOCK_USERNAME") ]] || fail 'a second account was opened'
jq -e '.email == "shared.primary@std.yildiz.edu.tr"' <<<"$(kcadm get "users/$holder_email" -r "$REALM")" >/dev/null \
  || fail "the holder's e-mail changed"
[[ $(kcadm get "users/$holder_email/federated-identity" -r "$REALM" | jq -r '.[].identityProvider') == OBS ]] || fail 'the holder was not linked'
[[ $(events_of SEND_IDENTITY_PROVIDER_LINK "$holder_email") == 0 ]] || fail 'a link verification mail was sent'
printf '    verified email of another account: confirm, re-authenticate with the password, linked; no mail\n'

# ---------------------------------------------------------------------------------------------------
stage "School e-mail that is another account's unverified email"
squatter=$(local_person squatter squatted.owner@std.yildiz.edu.tr)
kcadm update "users/$squatter" -r "$REALM" -s emailVerified=false >/dev/null
squatter_before=$(kcadm get "users/$squatter" -r "$REALM" | jq -S -c .)
mock_person Squatted.Owner@std.yildiz.edu.tr 'Fizik'
ytu_login squatted "$MOCK_USERNAME"
on_review_profile || fail "the owner was not given the review profile page ($(page_summary))"
# Today's way out: another username on the review profile page.
submit_review_profile squatted-owner
[[ $LANDED == app ]] || fail "the owner was kept out ($(page_summary))"
jq -e '(.email // "") == "" and .attributes.schoolEmail == ["Squatted.Owner@std.yildiz.edu.tr"]' \
  <<<"$(user_by_username squatted-owner)" >/dev/null || fail 'the owner has no account of their own, or got the address'
[[ $(kcadm get "users/$squatter" -r "$REALM" | jq -S -c .) == "$squatter_before" ]] || fail 'the unverified holder changed'
printf '    unverified email of another account: not written, the owner gets out through the review profile page\n'

# ---------------------------------------------------------------------------------------------------
stage 'sync mode FORCE never changes the Primary e-mail of a linked account'
kcadm update identity-provider/instances/OBS -r "$REALM" -s config.syncMode=FORCE >/dev/null
output=$(reconcile "$ADMIN_CONFIG" 0 KEYCLOAK_YTU_FIRST_LOGIN=on)
grep -Fq '[reconcile] WARNING: identity provider OBS syncs with FORCE' <<<"$output" \
  || { printf '%s\n' "$output" >&2; fail 'the operator run did not warn about FORCE'; }
# A holder whose username is the address (the review's probe): Keycloak finds it by the brokered
# username. Under FORCE the step writes nothing, so the link cannot copy the address onto it.
mock_person Force.Owner@std.yildiz.edu.tr 'Fizik'
holder_force=$(local_person "$MOCK_USERNAME" force.personal@example.org)
ytu_login force "$MOCK_USERNAME"
on_review_profile || fail "FORCE: the review profile page was not shown ($(page_summary))"
submit_review_profile
link_by_password 'FORCE username holder' "$MOCK_USERNAME"
jq -e '.email == "force.personal@example.org"' <<<"$(kcadm get "users/$holder_force" -r "$REALM")" >/dev/null \
  || fail "FORCE: linking changed the holder's Primary e-mail"
[[ $(kcadm get "users/$holder_force/federated-identity" -r "$REALM" | jq -r '.[].identityProvider') == OBS ]] || fail 'FORCE: the holder was not linked'
kcadm update identity-provider/instances/OBS -r "$REALM" -s config.syncMode=LEGACY >/dev/null
printf '    FORCE: operator warning; a linked holder keeps its Primary e-mail\n'

# ---------------------------------------------------------------------------------------------------
stage 'A6: linking YTÜ to a signed-in account'
a6_id=$(local_person a6-person a6.person@example.org)
mock_person A6.Student@std.yildiz.edu.tr 'Biyoloji'
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
follow "$JAR" "$(form_action kc-form-login)" --data-urlencode "username=$MOCK_USERNAME" --data-urlencode "password=$MOCK_PASSWORD" \
  --data-urlencode credentialId=
[[ $LANDED == app ]] || { on_review_profile && fail 'A6 showed the review profile page'; fail 'A6 did not lead back to the application'; }
jq -e '.email == "a6.person@example.org"' <<<"$(kcadm get "users/$a6_id" -r "$REALM")" >/dev/null || fail 'A6 changed the e-mail'
[[ $(kcadm get "users/$a6_id/federated-identity" -r "$REALM" | jq -r '.[].identityProvider') == OBS ]] || fail 'A6 did not link'
[[ -z $(user_by_username "$MOCK_USERNAME") ]] || fail 'A6 opened a second account'
printf '    A6: linked, no page, e-mail unchanged\n'

# ---------------------------------------------------------------------------------------------------
stage 'rollback and forward again'
# An override that names the copy (what binding OBS to it by hand would leave) is rolled back too.
kcadm update identity-provider/instances/OBS -r "$REALM" -s "firstBrokerLoginFlowAlias=$COPY" >/dev/null
output=$(reconcile "$ADMIN_CONFIG" 0 KEYCLOAK_YTU_FIRST_LOGIN=off)
expect_line "$output" "[reconcile] realm first broker login flow binding: updated ($COPY -> $BUILT_IN)" 'rollback did not rebind'
expect_line "$output" '[reconcile] identity provider OBS first login flow: updated (its override is removed; it follows the realm binding)' \
  'rollback left the OBS override on the copy'
[[ $(bound) == "$BUILT_IN" ]] || fail 'the rollback left the realm on the copy'
mock_person Ytu.Rollback@std.yildiz.edu.tr 'Fizik'
ytu_login rollback "$MOCK_USERNAME"
on_review_profile || fail "the rollback did not bring today's review profile page back ($(page_summary))"
submit_review_profile
jq -e '(.email // "") == ""' <<<"$(user_by_username "$MOCK_USERNAME")" >/dev/null || fail 'the rollback still wrote the address'
output=$(reconcile "$SCOPED_CONFIG" 0 KEYCLOAK_YTU_FIRST_LOGIN=off)
expect_quiet "$output" 'a second rollback changed something'
output=$(reconcile "$SCOPED_CONFIG" 0)
expect_quiet "$output" 'keep after the rollback changed something'
[[ $(bound) == "$BUILT_IN" ]] || fail 'keep turned the feature back on'
output=$(reconcile "$SCOPED_CONFIG" 0 KEYCLOAK_YTU_FIRST_LOGIN=on)
expect_line "$output" "[reconcile] realm first broker login flow binding: updated ($BUILT_IN -> $COPY)" 'forward did not rebind'
grep -Fq 'created' <<<"$output" && fail 'forward made another copy'
[[ $(kcadm get authentication/flows -r "$REALM" | jq --arg copy "$COPY" '[.[] | select(.alias == $copy)] | length') == 1 ]] \
  || fail 'there is not exactly one copy'
reconcile "$SCOPED_CONFIG" 1 KEYCLOAK_YTU_FIRST_LOGIN=maybe >/dev/null
printf '    off: built-in flow, OBS override on the copy removed, today'"'"'s page again; keep stays off; on: the same copy\n'

# ---------------------------------------------------------------------------------------------------
# Production's OBS overrides the first login flow with its own hand-made duplicate of the built-in
# flow, 'first broker login for obs' (review profile "on"; eskylab-login-ux 22). Here it is a
# Keycloak copy of the built-in flow under that name, with its copied review profile config "on".
stage "production's OBS: its own duplicate of the built-in flow"
LEGACY='first broker login for obs'
NOTE=skyFirstLoginFlowBeforeYtuStep
kcadm create "authentication/flows/${BUILT_IN// /%20}/copy" -r "$REALM" -s "newName=$LEGACY" >/dev/null
legacy_review=$(flow "$LEGACY" | jq -r '.[] | select(.providerId == "idp-review-profile") | .authenticationConfig')
kcadm get "authentication/config/$legacy_review" -r "$REALM" | jq -e '.config["update.profile.on.first.login"] == "on"' >/dev/null \
  || fail "the duplicate's review profile config is not on"
kcadm update identity-provider/instances/OBS -r "$REALM" -s "firstBrokerLoginFlowAlias=$LEGACY" >/dev/null
legacy_before=$(flow "$LEGACY" | jq -S -c .)
obs_note() {
  kcadm get identity-provider/instances/OBS -r "$REALM" | jq -r --arg note "$NOTE" '"\(.firstBrokerLoginFlowAlias // "")|\(.config[$note] // "")"'
}
[[ $(bound) == "$COPY" ]] || fail "the realm is bound to '$(bound)', not the copy"
# The bug of 2026-10-13: the realm runs the copy, OBS runs its own flow, the step never runs.
mock_person Legacy.Before@std.yildiz.edu.tr 'Fizik'
ytu_login legacy-before "$MOCK_USERNAME"
on_review_profile || fail "OBS's own flow did not show the review profile page ($(page_summary))"
submit_review_profile
jq -e '(.email // "") == ""' <<<"$(user_by_username "$MOCK_USERNAME")" >/dev/null || fail "OBS's own flow ran the step"
# A full reconciliation (keep) never touches OBS, even in an operator session.
output=$(reconcile "$ADMIN_CONFIG" 0)
expect_quiet "$output" 'keep changed something'
grep -q 'identity provider OBS' <<<"$output" && { printf '%s\n' "$output" >&2; fail 'keep reported on OBS'; }
[[ $(obs_note) == "$LEGACY|" ]] || fail "keep changed OBS: $(obs_note)"
# Review F2: the copy itself is checked against the built-in flow on every run; an execution added
# by hand is reported (a WARNING) and left alone.
copy_extra=$(kcadm create "authentication/flows/${COPY// /%20}/executions/execution" -r "$REALM" -i -b '{"provider":"idp-auto-link"}')
output=$(reconcile "$SCOPED_CONFIG" 0)
grep -Fq "[reconcile] WARNING: flow '$COPY' is not shaped like the built-in '$BUILT_IN' apart from the SKY LAB edits: " <<<"$output" \
  || { printf '%s\n' "$output" >&2; fail 'an execution added to the copy was not reported'; }
grep -q 'idp-auto-link' <<<"$output" || { printf '%s\n' "$output" >&2; fail 'the copy warning does not name the difference'; }
[[ $(flow "$COPY" | jq --arg id "$copy_extra" '[.[] | select(.id == $id)] | length') == 1 ]] || fail 'the reconciler removed the execution'
kcadm delete "authentication/executions/$copy_extra" -r "$REALM" >/dev/null
output=$(reconcile "$SCOPED_CONFIG" 0)
expect_line "$output" "[reconcile] shape of flow '$COPY': unchanged (the built-in '$BUILT_IN' plus the SKY LAB edits)" 'the copy is not reported as in shape again'
# A duplicate that is not shaped like the built-in flow (here an extra automatic link step) is refused.
extra=$(kcadm create "authentication/flows/${LEGACY// /%20}/executions/execution" -r "$REALM" -i -b '{"provider":"idp-auto-link"}')
output=$(reconcile "$ADMIN_CONFIG" 0 KEYCLOAK_YTU_FIRST_LOGIN=on)
grep -Fq "[reconcile] WARNING: identity provider OBS: first login flow binding refused (its override '$LEGACY' is not shaped like the built-in '$BUILT_IN': " <<<"$output" \
  || { printf '%s\n' "$output" >&2; fail 'a duplicate of another shape was not refused'; }
grep -q 'idp-auto-link' <<<"$output" || { printf '%s\n' "$output" >&2; fail 'the refusal does not name the difference'; }
expect_quiet "$(grep -v 'WARNING' <<<"$output")" 'the refused run changed something'
[[ $(obs_note) == "$LEGACY|" ]] || fail "the refused run changed OBS: $(obs_note)"
kcadm delete "authentication/executions/$extra" -r "$REALM" >/dev/null
[[ $(flow "$LEGACY" | jq -S -c .) == "$legacy_before" ]] || fail 'the duplicate is not as before after removing the extra step'
# ... and so is one with another requirement (link verification REQUIRED instead of ALTERNATIVE).
set_legacy_verification() {
  local body
  body=$(flow "$LEGACY" | jq -c --arg r "$1" '.[] | select(.providerId == "idp-email-verification") | {id, priority, requirement: $r}')
  kcadm update "authentication/flows/${LEGACY// /%20}/executions" -r "$REALM" -n -b "$body" >/dev/null
}
set_legacy_verification REQUIRED
output=$(reconcile "$ADMIN_CONFIG" 0 KEYCLOAK_YTU_FIRST_LOGIN=on)
grep -Fq "[reconcile] WARNING: identity provider OBS: first login flow binding refused (its override '$LEGACY' is not shaped like the built-in '$BUILT_IN': " <<<"$output" \
  && grep -q 'idp-email-verification (level [0-9]*, index [0-9]*, REQUIRED)' <<<"$output" \
  || { printf '%s\n' "$output" >&2; fail 'a duplicate with another requirement was not refused'; }
[[ $(obs_note) == "$LEGACY|" ]] || fail "the refused run changed OBS: $(obs_note)"
set_legacy_verification ALTERNATIVE
[[ $(flow "$LEGACY" | jq -S -c .) == "$legacy_before" ]] || fail 'the duplicate is not as before after its requirement was put back'
# Shaped like the built-in flow: OBS follows the realm binding; the duplicate stays, unused.
output=$(reconcile "$ADMIN_CONFIG" 0 KEYCLOAK_YTU_FIRST_LOGIN=on)
expect_line "$output" "[reconcile] identity provider OBS: first login flow binding removed (follows realm binding '$COPY'; previous '$LEGACY' kept, unused)" \
  "OBS's duplicate override was not removed"
if grep '^\[reconcile\]' <<<"$output" | grep -v 'identity provider OBS' | grep -qv 'unchanged'; then
  printf '%s\n' "$output" >&2
  fail 'the operator run changed more than OBS'
fi
grep -q 'WARNING' <<<"$output" && { printf '%s\n' "$output" >&2; fail 'the operator run warned'; }
[[ $(obs_note) == "|$LEGACY" ]] || fail "OBS does not follow the realm binding with a note of its previous flow: $(obs_note)"
kcadm get identity-provider/instances/OBS -r "$REALM" | jq -e '.trustEmail == true and .config.syncMode == "LEGACY"' >/dev/null \
  || fail 'OBS changed beyond its override'
[[ $(flow "$LEGACY" | jq -S -c .) == "$legacy_before" ]] || fail 'the duplicate changed'
kcadm get "authentication/config/$legacy_review" -r "$REALM" | jq -e '.config["update.profile.on.first.login"] == "on"' >/dev/null \
  || fail "the duplicate's review profile config changed"
mock_person Legacy.After@STD.yildiz.edu.tr 'Kimya'
ytu_login legacy-after "$MOCK_USERNAME"
[[ $LANDED == app ]] || fail "after removing the duplicate override a page stood before the application ($(page_summary))"
jq -e '.email == "legacy.after@std.yildiz.edu.tr" and .emailVerified == true' <<<"$(user_by_username "$MOCK_USERNAME")" >/dev/null \
  || fail 'the step did not run for OBS'
output=$(reconcile "$ADMIN_CONFIG" 0 KEYCLOAK_YTU_FIRST_LOGIN=on)
expect_quiet "$output" 'a second on changed something'
expect_line "$output" '[reconcile] identity provider OBS first login flow: unchanged (follows the realm binding)' 'OBS not reported as following'
# off gives back exactly the state before on: the built-in binding and OBS's own duplicate.
output=$(reconcile "$ADMIN_CONFIG" 0 KEYCLOAK_YTU_FIRST_LOGIN=off)
expect_line "$output" "[reconcile] realm first broker login flow binding: updated ($COPY -> $BUILT_IN)" 'off did not rebind'
expect_line "$output" "[reconcile] identity provider OBS: first login flow binding restored ('$LEGACY', as before KEYCLOAK_YTU_FIRST_LOGIN=on)" \
  "off did not give OBS its duplicate back"
[[ $(obs_note) == "$LEGACY|" ]] || fail "off left OBS at $(obs_note)"
mock_person Legacy.Rollback@std.yildiz.edu.tr 'Fizik'
ytu_login legacy-rollback "$MOCK_USERNAME"
on_review_profile || fail "off did not bring OBS's review profile page back ($(page_summary))"
submit_review_profile
jq -e '(.email // "") == ""' <<<"$(user_by_username "$MOCK_USERNAME")" >/dev/null || fail 'off still ran the step for OBS'
output=$(reconcile "$ADMIN_CONFIG" 0 KEYCLOAK_YTU_FIRST_LOGIN=off)
expect_quiet "$output" 'a second off changed something'
expect_line "$output" "[reconcile] identity provider OBS first login flow: unchanged (keeps its own first login flow '$LEGACY', as before KEYCLOAK_YTU_FIRST_LOGIN=on)" \
  'a second off did not report the restored duplicate'
grep -q 'WARNING' <<<"$output" && { printf '%s\n' "$output" >&2; fail 'a second off warned'; }
# Forward again: the same removal; the later stages run with OBS following the copy.
output=$(reconcile "$ADMIN_CONFIG" 0 KEYCLOAK_YTU_FIRST_LOGIN=on)
expect_line "$output" "[reconcile] realm first broker login flow binding: updated ($BUILT_IN -> $COPY)" 'forward did not rebind'
expect_line "$output" "[reconcile] identity provider OBS: first login flow binding removed (follows realm binding '$COPY'; previous '$LEGACY' kept, unused)" \
  'forward did not remove the duplicate override'
[[ $(obs_note) == "|$LEGACY" ]] || fail "forward left OBS at $(obs_note)"
# Review F1: off writes back only a known earlier flow that still has the built-in shape.
# (a) The unused duplicate was edited after on: not restored, OBS follows the built-in binding.
extra=$(kcadm create "authentication/flows/${LEGACY// /%20}/executions/execution" -r "$REALM" -i -b '{"provider":"idp-auto-link"}')
output=$(reconcile "$ADMIN_CONFIG" 0 KEYCLOAK_YTU_FIRST_LOGIN=off)
expect_line "$output" "[reconcile] realm first broker login flow binding: updated ($COPY -> $BUILT_IN)" 'off did not rebind'
grep -Fq "[reconcile] WARNING: identity provider OBS: first login flow binding not restored (the flow '$LEGACY' is not shaped like the built-in '$BUILT_IN' any more: " <<<"$output" \
  && grep -Fq "OBS follows the realm binding '$BUILT_IN'" <<<"$output" \
  || { printf '%s\n' "$output" >&2; fail 'off restored an edited duplicate'; }
grep -q 'binding restored' <<<"$output" && { printf '%s\n' "$output" >&2; fail 'off reported a restore'; }
[[ $(obs_note) == "|$LEGACY" ]] || fail "off with an edited duplicate left OBS at $(obs_note)"
kcadm delete "authentication/executions/$extra" -r "$REALM" >/dev/null
output=$(reconcile "$ADMIN_CONFIG" 0 KEYCLOAK_YTU_FIRST_LOGIN=on)
expect_line "$output" '[reconcile] identity provider OBS first login flow: unchanged (follows the realm binding)' 'on after a refused restore'
# (b) A note naming the copy (with OBS overriding with the copy): not restored, the copy override
# is cleared, OBS follows the built-in binding.
kcadm update identity-provider/instances/OBS -r "$REALM" -s "firstBrokerLoginFlowAlias=$COPY" -s "config.$NOTE=$COPY" >/dev/null
output=$(reconcile "$ADMIN_CONFIG" 0 KEYCLOAK_YTU_FIRST_LOGIN=off)
expect_line "$output" "[reconcile] realm first broker login flow binding: updated ($COPY -> $BUILT_IN)" 'off did not rebind'
grep -Fq "[reconcile] WARNING: identity provider OBS: first login flow binding not restored (its note names '$COPY', not one of the known earlier flows; OBS follows the realm binding '$BUILT_IN'" <<<"$output" \
  || { printf '%s\n' "$output" >&2; fail 'off restored a note naming the copy'; }
[[ $(obs_note) == "|$COPY" ]] || fail "off with a note naming the copy left OBS at $(obs_note)"
kcadm update identity-provider/instances/OBS -r "$REALM" -s "config.$NOTE=$LEGACY" >/dev/null
output=$(reconcile "$ADMIN_CONFIG" 0 KEYCLOAK_YTU_FIRST_LOGIN=on)
expect_line "$output" "[reconcile] realm first broker login flow binding: updated ($BUILT_IN -> $COPY)" 'forward did not rebind'
[[ $(obs_note) == "|$LEGACY" ]] || fail "forward left OBS at $(obs_note)"
printf '    OBS on its own duplicate: keep leaves it; another shape or requirement is refused; on removes it (noted), the step runs; off restores it; second runs change nothing\n'
printf '    off restores only a known earlier flow still shaped like the built-in one; the copy is checked against the built-in flow\n'

# ---------------------------------------------------------------------------------------------------
# The Personal e-mail offer (ticket 21). No SKY LAB theme runs here, so the page is the SPI's own
# fallback template: the same form fields, buttons and error codes (data-sky-offer-error) as the
# theme's page.

# offer_state: "enabled,defaultAction" of the realm's offer, or "" while it is not registered.
offer_state() {
  kcadm get authentication/required-actions -r "$REALM" \
    | jq -r --arg alias "$OFFER" '.[] | select(.alias == $alias) | "\(.enabled),\(.defaultAction)"'
}

on_offer() {
  [[ $LANDED == page ]] && grep -q 'id="kc-personal-email-offer-form"' <<<"$BODY"
}

# offer_post ACTION [NAME=VALUE]: one button of the offer page, with its one field.
offer_post() {
  local action
  action=$(form_action kc-personal-email-offer-form)
  if [[ $# -gt 1 ]]; then
    follow "$JAR" "$action" --data-urlencode "sky-offer-action=$1" --data-urlencode "$2"
  else
    follow "$JAR" "$action" --data-urlencode "sky-offer-action=$1"
  fi
}

# The error code the offer page shows, or "".
offer_error() {
  grep -Eo 'data-sky-offer-error="[a-z_]*"' <<<"$BODY" | head -n 1 | sed -e 's/^data-sky-offer-error="//' -e 's/"$//' || true
}

expect_offer_error() { # expect_offer_error CODE LABEL
  on_offer || fail "$2: not the offer page ($(page_summary))"
  [[ $(offer_error) == "$1" ]] || fail "$2: the page shows error '$(offer_error)', not '$1'"
}

# mail_count ADDRESS: how many mails Mailpit holds for the address.
mail_count() {
  curl -fsS "$MAIL_URL/api/v1/messages?limit=200" \
    | jq --arg to "$1" '[.messages[]? | select(any(.To[]?; .Address == $to))] | length'
}

# mail_code ADDRESS: the six-digit code of the newest mail to the address. The mail must carry no
# link (ADR-0044: a code works only in the session that asked for it). Neither is printed.
mail_code() {
  local id message code
  for _ in $(seq 1 30); do
    id=$(curl -fsS "$MAIL_URL/api/v1/messages?limit=200" \
      | jq -r --arg to "$1" 'first(.messages[]? | select(any(.To[]?; .Address == $to)) | .ID) // empty')
    [[ -n $id ]] && break
    sleep 1
  done
  [[ -n $id ]] || fail 'no code reached the typed address'
  message=$(curl -fsS "$MAIL_URL/api/v1/message/$id")
  jq -e '((.Text // "") + (.HTML // "")) | test("https?://[^ ]*(login-actions|email)") | not' <<<"$message" >/dev/null \
    || fail 'the code mail carries a link'
  code=$(jq -r '.Text // "" | split("\n")[] | select(test("^\\s*[0-9]{6}\\s*$")) | gsub("\\s"; "")' <<<"$message" | head -n 1)
  [[ $code =~ ^[0-9]{6}$ ]] || fail 'the code mail carries no six-digit code'
  printf '%s\n' "$code"
}

offer_events() { # offer_events USER_ID WHAT: CUSTOM_REQUIRED_ACTION events of the offer with that detail
  kcadm get events -r "$REALM" -q type=CUSTOM_REQUIRED_ACTION -q "user=$1" \
    | jq --arg what "$2" '[.[] | select(.details.sky_personal_email_offer == $what)] | length'
}

stage 'personal e-mail offer: reconciler'
# Keycloak's own SMTP sender delivers to Mailpit (SkyMail is off in this harness).
kcadm update "realms/$REALM" -s "smtpServer.host=$MAIL_CONTAINER" -s smtpServer.port=1025 \
  -s smtpServer.from=keycloak@example.invalid >/dev/null
output=$(reconcile "$SCOPED_CONFIG" 0)
expect_line "$output" '[reconcile] personal e-mail offer required action: unchanged (not registered; KEYCLOAK_PERSONAL_EMAIL_OFFER=on registers and enables it)' \
  'keep did not report the unregistered offer'
[[ -z $(offer_state) ]] || fail 'keep registered the offer'
output=$(reconcile "$SCOPED_CONFIG" 0 KEYCLOAK_PERSONAL_EMAIL_OFFER=on)
expect_line "$output" '[reconcile] personal e-mail offer required action: updated (registered and enabled)' 'on did not register the offer'
[[ $(offer_state) == true,false ]] || fail "the offer is '$(offer_state)' after on"
output=$(reconcile "$SCOPED_CONFIG" 0 KEYCLOAK_PERSONAL_EMAIL_OFFER=on)
expect_quiet "$output" 'a second on changed something'
expect_line "$output" '[reconcile] personal e-mail offer required action: unchanged (enabled)' 'a second on did not report the offer'
output=$(reconcile "$SCOPED_CONFIG" 0)
expect_line "$output" '[reconcile] personal e-mail offer required action: unchanged (enabled=true; KEYCLOAK_PERSONAL_EMAIL_OFFER=on or off changes it)' \
  'keep did not keep the offer'
reconcile "$SCOPED_CONFIG" 1 KEYCLOAK_PERSONAL_EMAIL_OFFER=maybe >/dev/null
printf '    keep registers nothing; on registers and enables (reconciler identity); second runs change nothing\n'

# ---------------------------------------------------------------------------------------------------
stage 'personal e-mail offer: shown once, skip'
mock_person Offer.Skip@STD.Yildiz.edu.tr 'Fizik'
ytu_login offer-skip "$MOCK_USERNAME"
on_offer || fail "a new YTÜ identity did not see the offer ($(page_summary))"
grep -q 'name="address"' <<<"$BODY" || fail 'the offer page has no address field'
[[ -z $(offer_error) ]] || fail 'the offer page opens with an error'
offer_post skip
[[ $LANDED == app ]] || fail "Şimdilik geç did not reach the application ($(page_summary))"
skip_user=$(user_by_username offer.skip@std.yildiz.edu.tr)
jq -e '.email == "offer.skip@std.yildiz.edu.tr" and .emailVerified == true and (.attributes.personalEmail // []) == []
  and (.attributes.personalEmailOfferSkippedAt // [] | length) == 1 and (.requiredActions | length) == 0' <<<"$skip_user" >/dev/null \
  || { printf '%s\n' "$skip_user" >&2; fail 'the skipped account is not as expected'; }
skip_id=$(jq -r .id <<<"$skip_user")
[[ $(offer_events "$skip_id" shown) == 1 && $(offer_events "$skip_id" skip) == 1 ]] || fail 'the shown and skip events were not written once'
ytu_login offer-skip-again "$MOCK_USERNAME"
[[ $LANDED == app ]] || fail "the offer came back on the next login ($(page_summary))"
printf '    a new identity sees the offer once; Şimdilik geç reaches the application and is remembered\n'

# ---------------------------------------------------------------------------------------------------
stage 'personal e-mail offer: a code adds the personal e-mail'
mock_person Offer.Add@std.yildiz.edu.tr 'Kimya'
ytu_login offer-add "$MOCK_USERNAME"
on_offer || fail "no offer ($(page_summary))"
offer_post send 'address=  Offer.Personal@Example.org '
if ! on_offer || ! grep -q 'name="code"' <<<"$BODY"; then fail "no code page after sending ($(page_summary))"; fi
[[ -z $(offer_error) ]] || fail "sending showed error '$(offer_error)'"
code=$(mail_code offer.personal@example.org)
offer_post verify "code=${code:0:3} ${code:3}"
[[ $LANDED == app ]] || fail "the right code did not reach the application ($(page_summary))"
add_user=$(user_by_username offer.add@std.yildiz.edu.tr)
jq -e '.email == "offer.add@std.yildiz.edu.tr" and .emailVerified == true
  and .attributes.personalEmail == ["offer.personal@example.org"]
  and (.attributes.personalEmailVerifiedAt[0] | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
  and (.attributes.personalEmailOfferSkippedAt // []) == []' <<<"$add_user" >/dev/null \
  || { printf '%s\n' "$add_user" >&2; fail 'the personal e-mail was not added as proven, or the primary changed'; }
[[ $(offer_events "$(jq -r .id <<<"$add_user")" added) == 1 ]] || fail 'no added event'
printf '    a code mailed to the typed address adds a proven personalEmail; the School e-mail stays primary\n'

# ---------------------------------------------------------------------------------------------------
stage 'personal e-mail offer: five wrong codes'
local_person offer.old.address@example.org offer.username.holder@example.org >/dev/null
mock_person Offer.Wrong@std.yildiz.edu.tr 'Kimya'
ytu_login offer-wrong "$MOCK_USERNAME"
# Another account's username (a legacy account whose old address is its username) is taken too.
offer_post send address=Offer.Old.Address@example.org
expect_offer_error email_taken "another account's username"
offer_post send address=offer.wrong@example.org
code=$(mail_code offer.wrong@example.org)
wrong=$(printf '%06d' $(((10#$code + 1) % 1000000)))
for left in 4 3 2 1; do
  offer_post verify "code=$wrong"
  expect_offer_error wrong_code "wrong code ($left left)"
  grep -q 'name="code"' <<<"$BODY" || fail 'a wrong code left the code page'
done
offer_post verify "code=$wrong"
expect_offer_error too_many_tries 'the fifth wrong code'
offer_post verify "code=$code"
expect_offer_error code_expired 'the right code after five wrong ones'
offer_post skip
[[ $LANDED == app ]] || fail 'skip after a dead code did not reach the application'
jq -e '(.attributes.personalEmail // []) == []' <<<"$(user_by_username offer.wrong@std.yildiz.edu.tr)" >/dev/null \
  || fail 'a dead code still added the address'
printf '    another account'"'"'s username is taken; five wrong codes kill the code; the right one no longer works\n'

# ---------------------------------------------------------------------------------------------------
stage 'personal e-mail offer: taken and own addresses, the send budget'
# The held Personal e-mail is stored in capitals: the taken check ignores case in the real store.
local_person offer-holder offer.holder@example.org personalEmail=Offer.Held@Example.org \
  personalEmailVerifiedAt=2026-09-01T12:00:00Z >/dev/null
mock_person Offer.Taken@std.yildiz.edu.tr 'Fizik'
ytu_login offer-taken "$MOCK_USERNAME"
offer_post send address=Offer.Holder@example.org
expect_offer_error email_taken "another account's email"
offer_post send address=offer.held@example.org
expect_offer_error email_taken "another account's personalEmail"
offer_post send address=Offer.Taken@STD.yildiz.edu.tr
expect_offer_error own_address 'the own school address'
offer_post send address=Someone.Else@CE.Yildiz.EDU.tr
expect_offer_error email_school_domain 'an address on a university subdomain'
# Keycloak's validator accepts ideographic full stops; the SMTP sender would deliver to yildiz.edu.tr.
offer_post send "address=someone.else@yildiz$(printf '\343\200\202')edu$(printf '\343\200\202')tr"
expect_offer_error email_school_domain 'a Unicode look-alike of the university domain'
[[ $(mail_count someone.else@ce.yildiz.edu.tr) == 0 ]] || fail 'a code was mailed to a university address'
offer_post send 'address=not an address'
expect_offer_error invalid_address 'not an address'
[[ $(mail_count offer.holder@example.org) == 0 && $(mail_count offer.held@example.org) == 0 ]] \
  || fail 'a code was mailed to a taken address'
# Two of the session's three sends went to the taken probes.
offer_post send address=offer.budget1@example.org
grep -q 'name="code"' <<<"$BODY" || fail "the third send did not send ($(page_summary))"
offer_post change
grep -q 'name="address"' <<<"$BODY" || fail 'change did not go back to the address'
offer_post send address=offer.budget2@example.org
expect_offer_error rate_limited 'the fourth send of one sign-in session'
[[ $(mail_count offer.budget2@example.org) == 0 ]] || fail 'the fourth send was mailed'
offer_post skip
[[ $LANDED == app ]] || fail 'skip did not reach the application'
printf '    taken (email, personalEmail in capitals), own and university addresses refused, nothing mailed; three sends per sign-in session\n'

# ---------------------------------------------------------------------------------------------------
stage 'personal e-mail offer: not for linked accounts, A6, a held address or a password login'
ytu_login offer-linked "$(jq -r '.attributes.schoolEmail[0]' <<<"$(kcadm get "users/$linked_id" -r "$REALM")" | tr '[:upper:]' '[:lower:]')"
[[ $LANDED == app ]] || fail "a linked account saw a page ($(page_summary))"
offer_a6=$(local_person offer-a6 offer.a6@example.org)
mock_person Offer.A6@std.yildiz.edu.tr 'Biyoloji'
JAR="$STATE_DIR/offer-a6.cookies"
rm -f "$JAR"
follow "$JAR" "$(auth_url '&kc_action=idp_link:OBS')"
follow "$JAR" "$(form_action kc-form-login)" --data-urlencode username=offer-a6 --data-urlencode "password=$LOCAL_PASSWORD" \
  --data-urlencode credentialId=
follow "$JAR" "$(form_action '')" --data-urlencode continue=
follow "$JAR" "$(form_action kc-form-login)" --data-urlencode "username=$MOCK_USERNAME" --data-urlencode "password=$MOCK_PASSWORD" \
  --data-urlencode credentialId=
[[ $LANDED == app ]] || { on_offer && fail 'A6 showed the offer'; fail "A6 did not lead back to the application ($(page_summary))"; }
[[ $(kcadm get "users/$offer_a6/federated-identity" -r "$REALM" | jq -r '.[].identityProvider') == OBS ]] || fail 'A6 did not link'
local_person offer-held-school offer.held.school@example.org personalEmail=offer.shared@std.yildiz.edu.tr \
  personalEmailVerifiedAt=2026-09-01T12:00:00Z >/dev/null
mock_person Offer.Shared@std.yildiz.edu.tr 'Kimya'
ytu_login offer-shared "$MOCK_USERNAME"
on_review_profile || fail "a held School e-mail did not give the review profile page ($(page_summary))"
submit_review_profile
[[ $LANDED == app ]] || { on_offer && fail 'the offer came without a School primary'; fail "no application ($(page_summary))"; }
JAR="$STATE_DIR/offer-password.cookies"
rm -f "$JAR"
follow "$JAR" "$(auth_url)"
follow "$JAR" "$(form_action kc-form-login)" --data-urlencode username=offer-a6 --data-urlencode "password=$LOCAL_PASSWORD" \
  --data-urlencode credentialId=
[[ $LANDED == app ]] || fail "a password login saw a page ($(page_summary))"
printf '    no offer for a linked account, A6, a School e-mail another account holds or a password login\n'

# ---------------------------------------------------------------------------------------------------
stage 'personal e-mail offer: off'
output=$(reconcile "$SCOPED_CONFIG" 0 KEYCLOAK_PERSONAL_EMAIL_OFFER=off)
expect_line "$output" '[reconcile] personal e-mail offer required action: updated (enabled=true -> disabled)' 'off did not disable the offer'
[[ $(offer_state) == false,false ]] || fail "the offer is '$(offer_state)' after off"
mock_person Offer.Off@std.yildiz.edu.tr 'Fizik'
ytu_login offer-off "$MOCK_USERNAME"
[[ $LANDED == app ]] || fail "the offer still showed after off ($(page_summary))"
jq -e '.email == "offer.off@std.yildiz.edu.tr"' <<<"$(user_by_username offer.off@std.yildiz.edu.tr)" >/dev/null \
  || fail 'off changed the first YTÜ login itself'
output=$(reconcile "$SCOPED_CONFIG" 0 KEYCLOAK_PERSONAL_EMAIL_OFFER=off)
expect_line "$output" '[reconcile] personal e-mail offer required action: unchanged (disabled)' 'a second off changed something'
output=$(reconcile "$SCOPED_CONFIG" 0)
expect_line "$output" '[reconcile] personal e-mail offer required action: unchanged (enabled=false; KEYCLOAK_PERSONAL_EMAIL_OFFER=on or off changes it)' \
  'keep turned the offer back on'
printf '    off disables the offer; a new identity goes straight to the application; keep stays off\n'

# ---------------------------------------------------------------------------------------------------
# "Bu cihazda oturumum açık kalsın mı?" after every YTÜ login (required action sky-stay-signed-in).
# No SKY LAB theme runs here, so the page is the SPI's own fallback template (the same form id and
# buttons as the theme's page). The realm gets production's session settings
# (config/account-center-realm.json); this harness runs only the reconciler's first broker login step.

# stay_state: "enabled,defaultAction,priority" of the realm's question, or "" while it is not registered.
stay_state() {
  kcadm get authentication/required-actions -r "$REALM" \
    | jq -r --arg alias "$STAY" '.[] | select(.alias == $alias) | "\(.enabled),\(.defaultAction),\(.priority)"'
}

# Whether the question runs after every other required action of the realm.
stay_is_last() {
  kcadm get authentication/required-actions -r "$REALM" | jq -e --arg alias "$STAY" '
    ([.[] | select(.alias == $alias) | .priority][0]) as $mine
    | $mine != null and ([.[] | select(.alias != $alias) | .priority] | all(. < $mine))' >/dev/null
}

on_stay() {
  [[ $LANDED == page ]] && grep -q 'id="kc-stay-signed-in-form"' <<<"$BODY"
}

stay_post() { # stay_post yes|no
  follow "$JAR" "$(form_action kc-stay-signed-in-form)" --data-urlencode "sky-stay-signed-in=$1"
}

# end_sessions USER_ID: signs the person out everywhere, so the next login is the only session.
end_sessions() {
  local sid
  for sid in $(kcadm get "users/$1/sessions" -r "$REALM" | jq -r '.[].id'); do
    kcadm delete "sessions/$sid" -r "$REALM" >/dev/null
  done
}

# session_remember_me USER_ID: the rememberMe flag of the person's only user session.
session_remember_me() {
  kcadm get "users/$1/sessions" -r "$REALM" \
    | jq -r 'if length == 1 then (.[0].rememberMe // false | tostring) else "\(length) sessions" end'
}

# identity_cookie_expiry: when the browser drops Keycloak's SSO cookie (KEYCLOAK_IDENTITY of this
# realm in JAR); 0 is a browser-session cookie.
identity_cookie_expiry() {
  awk -F '\t' -v path="/realms/$REALM/" '$3 == path && $6 == "KEYCLOAK_IDENTITY" { print $5 }' "$JAR" | tail -n 1
}

stay_events() { # stay_events USER_ID yes|no: the question's CUSTOM_REQUIRED_ACTION events with that answer
  kcadm get events -r "$REALM" -q type=CUSTOM_REQUIRED_ACTION -q "user=$1" \
    | jq --arg answer "$2" '[.[] | select(.details.sky_stay_signed_in == $answer)] | length'
}

stage 'stay signed in: reconciler'
kcadm update "realms/$REALM" -s rememberMe=true -s ssoSessionIdleTimeout=7200 -s ssoSessionMaxLifespan=28800 \
  -s ssoSessionIdleTimeoutRememberMe=604800 -s ssoSessionMaxLifespanRememberMe=2592000 \
  -s clientSessionIdleTimeout=0 -s clientSessionMaxLifespan=0 >/dev/null
output=$(reconcile "$SCOPED_CONFIG" 0)
expect_line "$output" '[reconcile] stay signed in required action: unchanged (not registered; KEYCLOAK_STAY_SIGNED_IN=on registers and enables it)' \
  'keep did not report the unregistered question'
[[ -z $(stay_state) ]] || fail 'keep registered the question'
# The offer back on (registered before the question): the question comes after it.
output=$(reconcile "$SCOPED_CONFIG" 0 KEYCLOAK_PERSONAL_EMAIL_OFFER=on KEYCLOAK_STAY_SIGNED_IN=on)
expect_line "$output" '[reconcile] stay signed in required action: updated (registered and enabled)' 'on did not register the question'
# Keycloak registers an action after the last one; the reconciler moves it there if it is not.
grep -Eq '^\[reconcile\] stay signed in required action order: (unchanged \(priority|updated \(priority ->) [0-9]+, after every other required action\)$' <<<"$output" \
  || { printf '%s\n' "$output" >&2; fail 'on did not report the order'; }
[[ $(stay_state) == true,false,* ]] || fail "the question is '$(stay_state)' after on"
stay_is_last || fail 'the question does not run after every other required action'
# Moved in front by hand: keep only warns, on puts it last again.
kcadm update "authentication/required-actions/$STAY" -r "$REALM" -s priority=0 >/dev/null
output=$(reconcile "$SCOPED_CONFIG" 0)
grep -Fq '[reconcile] WARNING: the stay signed in question runs before another required action (priority 0,' <<<"$output" \
  || { printf '%s\n' "$output" >&2; fail 'keep did not warn about the order'; }
[[ $(stay_state) == true,false,0 ]] || fail 'keep changed the question'
output=$(reconcile "$SCOPED_CONFIG" 0 KEYCLOAK_STAY_SIGNED_IN=on)
grep -Eq '^\[reconcile\] stay signed in required action order: updated \(priority -> [0-9]+, after every other required action\)$' <<<"$output" \
  || { printf '%s\n' "$output" >&2; fail 'on did not put the question last again'; }
stay_is_last || fail 'the question is not last after on'
output=$(reconcile "$SCOPED_CONFIG" 0 KEYCLOAK_STAY_SIGNED_IN=on)
expect_quiet "$output" 'a second on changed something'
expect_line "$output" '[reconcile] stay signed in required action: unchanged (enabled)' 'a second on did not report the question'
output=$(reconcile "$SCOPED_CONFIG" 0)
expect_line "$output" '[reconcile] stay signed in required action: unchanged (enabled=true; KEYCLOAK_STAY_SIGNED_IN=on or off changes it)' \
  'keep did not keep the question'
reconcile "$SCOPED_CONFIG" 1 KEYCLOAK_STAY_SIGNED_IN=maybe >/dev/null
printf '    keep registers nothing; on registers and enables it last (after the offer), puts it last again; second runs change nothing\n'

# ---------------------------------------------------------------------------------------------------
stage 'stay signed in: a first YTÜ login says yes'
mock_person Stay.Yes@std.yildiz.edu.tr 'Fizik'
ytu_login stay-yes "$MOCK_USERNAME"
on_offer || fail "the personal e-mail offer did not come first ($(page_summary))"
offer_post skip
on_stay || fail "no stay signed in question after the offer ($(page_summary))"
if ! grep -q 'name="sky-stay-signed-in" value="yes"' <<<"$BODY" || ! grep -q 'name="sky-stay-signed-in" value="no"' <<<"$BODY"; then
  fail 'the question has no yes and no buttons'
fi
if ! grep -q 'for up to 30 days' <<<"$BODY" || ! grep -q 'use it for 7 days' <<<"$BODY"; then
  fail "the question does not word the realm's remember-me lifetimes"
fi
grep -q 'On a shared or someone else' <<<"$BODY" || fail 'the question has no shared computer warning'
stay_post yes
[[ $LANDED == app ]] || fail "Evet, açık kalsın did not reach the application ($(page_summary))"
stay_yes_id=$(jq -r .id <<<"$(user_by_username stay.yes@std.yildiz.edu.tr)")
[[ $(session_remember_me "$stay_yes_id") == true ]] || fail "yes did not make a remember-me session ($(session_remember_me "$stay_yes_id"))"
expiry=$(identity_cookie_expiry)
if [[ ! $expiry =~ ^[0-9]+$ ]] || ((expiry <= $(date +%s) + 29 * 86400)); then
  fail "yes did not make the identity cookie last the remember-me lifespan (expiry '${expiry}')"
fi
[[ $(stay_events "$stay_yes_id" yes) == 1 ]] || fail 'no yes event'
[[ $(kcadm get events -r "$REALM" -q type=LOGIN -q "user=$stay_yes_id" | jq '[.[] | select(.details.remember_me == "true")] | length') -ge 1 ]] \
  || fail 'the login event does not say remember_me'
# The same browser signs in again from the SSO session alone.
follow "$JAR" "$(auth_url)"
[[ $LANDED == app ]] || fail "the remembered browser saw a page ($(page_summary))"
printf '    a new identity: the offer, then the question; yes: remember-me session, persistent cookie, SSO without a page\n'

# ---------------------------------------------------------------------------------------------------
stage 'stay signed in: a linked account says no'
end_sessions "$linked_id"
ytu_login stay-no linked.student@std.yildiz.edu.tr
on_stay || fail "a linked account signing in again was not asked ($(page_summary))"
stay_post no
[[ $LANDED == app ]] || fail "Hayır did not reach the application ($(page_summary))"
[[ $(session_remember_me "$linked_id") == false ]] || fail "no did not leave an ordinary session ($(session_remember_me "$linked_id"))"
[[ $(identity_cookie_expiry) == 0 ]] || fail "no left a persistent identity cookie ($(identity_cookie_expiry))"
[[ $(stay_events "$linked_id" no) == 1 ]] || fail 'no no event'
printf '    a linked account: asked again; no: an ordinary session with a browser-session cookie\n'

# ---------------------------------------------------------------------------------------------------
stage 'stay signed in: not for a password login, a re-authentication or a passive login'
stay_password_id=$(local_person stay-password stay.password@example.org)
JAR="$STATE_DIR/stay-password.cookies"
rm -f "$JAR"
follow "$JAR" "$(auth_url)"
follow "$JAR" "$(form_action kc-form-login)" --data-urlencode username=stay-password --data-urlencode "password=$LOCAL_PASSWORD" \
  --data-urlencode rememberMe=on --data-urlencode credentialId=
[[ $LANDED == app ]] || fail "a password login saw a page ($(page_summary))"
[[ $(session_remember_me "$stay_password_id") == true ]] || fail 'the Beni hatırla box no longer makes a remember-me session'
# prompt=login through YTÜ in the remembered browser: Keycloak keeps the live session, so no question.
JAR="$STATE_DIR/stay-yes.cookies"
follow "$JAR" "$(auth_url '&kc_idp_hint=OBS&prompt=login')"
if [[ $LANDED == page ]] && grep -q 'id="kc-form-login"' <<<"$BODY"; then
  follow "$JAR" "$(form_action kc-form-login)" --data-urlencode username=stay.yes@std.yildiz.edu.tr \
    --data-urlencode "password=$MOCK_PASSWORD" --data-urlencode credentialId=
fi
[[ $LANDED == app ]] || { on_stay && fail 'a re-authentication inside a live session was asked'; fail "no application ($(page_summary))"; }
[[ $(session_remember_me "$stay_yes_id") == true ]] || fail 'the re-authentication changed the session'
# prompt=none forwarded to the tenant (signed in there, not here): a required action would turn the
# passive login into interaction_required.
kcadm update identity-provider/instances/OBS -r "$REALM" -s config.acceptsPromptNoneForwardFromClient=true >/dev/null
JAR="$STATE_DIR/stay-passive.cookies"
grep -v -F "/realms/$REALM/" "$STATE_DIR/stay-yes.cookies" >"$JAR"
end_sessions "$stay_yes_id"
follow "$JAR" "$(auth_url '&kc_idp_hint=OBS&prompt=none')"
[[ $LANDED == app ]] || fail "the passive login did not reach the application ($(page_summary))"
kcadm update identity-provider/instances/OBS -r "$REALM" -s config.acceptsPromptNoneForwardFromClient=false >/dev/null
[[ $(stay_events "$stay_yes_id" yes) == 1 && $(stay_events "$stay_yes_id" no) == 0 ]] || fail 'a later login was asked'
printf '    not asked: a password login (Beni hatırla still works), prompt=login in a live session, prompt=none\n'

# ---------------------------------------------------------------------------------------------------
stage 'stay signed in: off'
output=$(reconcile "$SCOPED_CONFIG" 0 KEYCLOAK_STAY_SIGNED_IN=off)
expect_line "$output" '[reconcile] stay signed in required action: updated (enabled=true -> disabled)' 'off did not disable the question'
[[ $(stay_state) == false,false,* ]] || fail "the question is '$(stay_state)' after off"
end_sessions "$linked_id"
ytu_login stay-off linked.student@std.yildiz.edu.tr
[[ $LANDED == app ]] || fail "the question still showed after off ($(page_summary))"
[[ $(session_remember_me "$linked_id") == false ]] || fail 'off left a remember-me session'
output=$(reconcile "$SCOPED_CONFIG" 0 KEYCLOAK_STAY_SIGNED_IN=off)
expect_line "$output" '[reconcile] stay signed in required action: unchanged (disabled)' 'a second off changed something'
output=$(reconcile "$SCOPED_CONFIG" 0)
expect_line "$output" '[reconcile] stay signed in required action: unchanged (enabled=false; KEYCLOAK_STAY_SIGNED_IN=on or off changes it)' \
  'keep turned the question back on'
printf '    off disables the question; a YTÜ login goes straight to the application; keep stays off\n'

# ---------------------------------------------------------------------------------------------------
stage 'a realm bound to another flow'
kcadm create "authentication/flows/${BUILT_IN// /%20}/copy" -r "$REALM" -s 'newName=someone else first login' >/dev/null
kcadm update "realms/$REALM" -s 'firstBrokerLoginFlow=someone else first login' >/dev/null
output=$(reconcile "$SCOPED_CONFIG" 1 KEYCLOAK_YTU_FIRST_LOGIN=on)
grep -Fq "The realm's first broker login flow is 'someone else first login', neither Keycloak's built-in '$BUILT_IN' nor '$COPY'; nothing was changed" <<<"$output" \
  || { printf '%s\n' "$output" >&2; fail 'another flow was not refused'; }
[[ $(bound) == 'someone else first login' ]] || fail 'the refused run rebound the realm'
printf '    a realm bound to another editable flow is refused\n'

printf 'ytu-first-login: all checks passed\n'
