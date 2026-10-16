#!/usr/bin/env bash
# Real PostgreSQL 17 + Keycloak 26.7.4 first-broker link and callback-transaction contract.
# Test-only Microsoft transport and transaction barriers live in a separate fixture jar.
# No fixture enters the production SPI or image. Default-off, native/A6 and code proof paths
# share this harness; all containers are disposable and images are pulled only by the operator.
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPOSITORY_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
IMAGE=$(sed -n 's/^ARG KEYCLOAK_IMAGE=//p' "$REPOSITORY_ROOT/Dockerfile")
MAILPIT_IMAGE=$(sed -n 's/^ *image: \(axllent\/mailpit:[^ ]*\)$/\1/p' "$SCRIPT_DIR/docker-compose.integration.yml")
PG_IMAGE=${B12_PG_IMAGE:-postgres:17-alpine@sha256:b0f9560a2de083e2cc7382e75f808c7381a32852a7ec49117deedb300e552b24}
PORT=${B12_TEST_PORT:-18131}
MAIL_PORT=${B12_MAIL_PORT:-18132}
BASE_URL="http://127.0.0.1:$PORT"
MAIL_URL="http://127.0.0.1:$MAIL_PORT"
CONTAINER=${B12_TEST_CONTAINER:-broker-link-test-$$}
MAIL_CONTAINER="$CONTAINER-mail"
PG_CONTAINER="$CONTAINER-pg"
NETWORK="$CONTAINER-net"
mkdir -p "$REPOSITORY_ROOT/.scratch-tests"
STATE_DIR=$(mktemp -d "$REPOSITORY_ROOT/.scratch-tests/broker-link.XXXXXXXX")
ADMIN_PASSWORD=harness-admin-password
MOCK_PASSWORD=harness-mock-password
LOCAL_PASSWORD=harness-local-password
BROKER_SECRET=harness-broker-secret
ADMIN_CONFIG=/tmp/harness-admin-kcadm.config
REALM=e-skylab
MOCK=ytu-mock
APP=b12-app
APP_REDIRECT=http://127.0.0.1:9/ytu-first-login-callback
BROWSER_REDIRECT="http://localhost:$PORT/b12-browser-callback"
CURRENT_STAGE=startup
STATUS=''
LOCATION=''
BODY=''
LANDED=''
fail() {
  printf 'existing-account failure during %s: %s\n' "$CURRENT_STAGE" "$1" >&2
  # Keep diagnostics to exception classes/counts: no browser tokens, addresses or IPs.
  docker logs "$CONTAINER" 2>&1 | grep -Eo '[A-Za-z][A-Za-z0-9.$]*(Exception|Error)(:|$)' \
    | sort | uniq -c | tail -n 15 >&2 || true
  exit 1
}
cleanup() {
  docker rm -fv "$CONTAINER" "$MAIL_CONTAINER" "$PG_CONTAINER" >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
  if [[ ${B12_KEEP_STATE:-0} != 1 ]]; then rm -rf "$STATE_DIR"; fi
}
trap 'status=$?; trap - EXIT; cleanup; exit "$status"' EXIT
on_error() { printf 'existing-account command failed during %s at line %s\n' "$CURRENT_STAGE" "$1" >&2; }
trap 'on_error "$LINENO"' ERR
kcadm() {
  local command=$1
  shift
  docker exec -i "$CONTAINER" /opt/keycloak/bin/kcadm.sh "$command" --config "$ADMIN_CONFIG" "$@" \
    2> >(grep -v -e '^Created new ' -e '^$' >&2 || true)
}

# A dev-mode administrator session can expire within a run; start each stage fresh.
sessions_login() {
  docker exec "$CONTAINER" /opt/keycloak/bin/kcadm.sh config credentials --config "$ADMIN_CONFIG" \
    --server http://localhost:8080 --realm master --user admin --password "$ADMIN_PASSWORD" >/dev/null 2>&1 \
    || fail 'kcadm login failed'
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
      [[ $LOCATION == *'code='* ]] || fail 'the application was sent back without a code'
      LANDED=app
      return 0
    fi
    [[ $LOCATION == http* ]] || LOCATION="$BASE_URL$LOCATION"
    request "$jar" "$LOCATION"
    hops=$((hops + 1))
    ((hops < 25)) || fail 'too many redirects'
  done
  [[ $STATUS == 200 ]] || fail "unexpected HTTP $STATUS"
  LANDED=page
}

# The action of the page's form whose id is $1 (Keycloak's own templates); "" for the first form.
form_action() {
  local action pattern="<form[^>]*id=\"$1\"[^>]*>"
  [[ -n $1 ]] || pattern='<form[^>]*>'
  action=$(tr '\n' ' ' <<<"$BODY" | grep -Eo "$pattern" | grep -Eo 'action="[^"]*"' | head -n 1 \
    | sed -e 's/^action="//' -e 's/"$//' -e 's/&amp;/\&/g')
  [[ -n $action ]] || fail "the page has no form #$1"
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

user_by_username() {
  kcadm get users -r "$REALM" -q "username=$1" -q exact=true -q briefRepresentation=false | jq -c '.[0] // empty'
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


CURRENT_STAGE='fixture compile'
SPI_JAR=${B12_SPI_JAR:?Build spi/ first and set B12_SPI_JAR to its absolute jar path}
mkdir -p "$STATE_DIR/fixture"
docker run --pull=never --rm --memory 512m --user "$(id -u):$(id -g)" --entrypoint bash \
  -v "$SPI_JAR:/fixture/spi.jar:ro" \
  -v "$SCRIPT_DIR/fixtures/BrokerMicrosoftFixture.java:/fixture/BrokerMicrosoftFixture.java:ro" \
  -v "$SCRIPT_DIR/fixtures/BrokerLinkRuntimeProbe.java:/fixture/BrokerLinkRuntimeProbe.java:ro" \
  -v "$STATE_DIR/fixture:/out" "$IMAGE" -ec '
    jars=(/opt/keycloak/lib/lib/main/*.jar); IFS=:
    java -m jdk.compiler/com.sun.tools.javac.Main -proc:none -cp "/fixture/spi.jar:${jars[*]}" -d /out /fixture/BrokerMicrosoftFixture.java /fixture/BrokerLinkRuntimeProbe.java
    mkdir -p /out/META-INF/services
    printf "%s\n" com.skylab.broker.BrokerMicrosoftFixture > /out/META-INF/services/org.keycloak.broker.social.SocialIdentityProviderFactory
    printf "%s\n" com.skylab.account.BrokerLinkRuntimeProbe > /out/META-INF/services/org.keycloak.services.resource.RealmResourceProviderFactory
    java -m jdk.jartool/sun.tools.jar.Main --create --file /out/fixture.jar -C /out com -C /out META-INF
  '
CURRENT_STAGE='PostgreSQL17 and Keycloak startup'
docker network create "$NETWORK" >/dev/null
docker run --pull=never --rm -d --name "$PG_CONTAINER" --network "$NETWORK" --memory 384m \
  --tmpfs /var/lib/postgresql/data:rw,size=512m,mode=1777 \
  -e POSTGRES_USER=keycloak -e POSTGRES_PASSWORD=harness-db-password -e POSTGRES_DB=keycloak "$PG_IMAGE" >/dev/null
docker run --pull=never --rm -d --name "$MAIL_CONTAINER" --network "$NETWORK" --memory 128m \
  -p "127.0.0.1:$MAIL_PORT:8025" "$MAILPIT_IMAGE" >/dev/null
docker run --pull=never --rm -d --name "$CONTAINER" --network "$NETWORK" --memory 2g \
  --tmpfs /opt/keycloak/data:rw,size=256m,mode=1777 -p "127.0.0.1:$PORT:8080" \
  -e KC_BOOTSTRAP_ADMIN_USERNAME=admin -e "KC_BOOTSTRAP_ADMIN_PASSWORD=$ADMIN_PASSWORD" \
  -e SKY_HARNESS=1 -e SKY_MAIL_ENABLED=false \
  -v "$SPI_JAR:/opt/keycloak/providers/e-skylab-spi.jar:ro" \
  -v "$STATE_DIR/fixture/fixture.jar:/opt/keycloak/providers/broker-fixture.jar:ro" \
  -v "$REPOSITORY_ROOT/config:/opt/keycloak/sky-config:ro" \
  "$IMAGE" start-dev --db=postgres --db-url-host="$PG_CONTAINER" --db-username=keycloak --db-password=harness-db-password >/dev/null
for _ in $(seq 1 90); do
  curl -fsS "$BASE_URL/realms/master" >/dev/null 2>&1 && break
  sleep 2
done
curl -fsS "$BASE_URL/realms/master" >/dev/null || fail 'Keycloak did not start'
sessions_login
stage 'local realms'
kcadm create realms -s "realm=$REALM" -s enabled=true -s loginWithEmailAllowed=true -s duplicateEmailsAllowed=false \
  -s registrationAllowed=false -s verifyEmail=true -s eventsEnabled=true -s defaultLocale=tr >/dev/null
docker exec "$CONTAINER" bash -c 'jars=(/opt/keycloak/lib/lib/main/com.fasterxml.jackson.core.jackson-*.jar); IFS=:; mkdir -p /tmp/rj
  java -m jdk.compiler/com.sun.tools.javac.Main -d /tmp/rj -cp "${jars[*]}" /opt/keycloak/sky-config/ReconcileJson.java' >/dev/null
desired=$(kcadm get users/profile -r "$REALM" | docker exec -i "$CONTAINER" bash -c '
  jars=(/opt/keycloak/lib/lib/main/com.fasterxml.jackson.core.jackson-*.jar); IFS=:
  java -cp "/tmp/rj:${jars[*]}" ReconcileJson user-profile /opt/keycloak/sky-config/account-center-user-profile.json; [ $? = 3 ]')
kcadm update users/profile -r "$REALM" -n -f - <<<"$desired" >/dev/null
kcadm update "realms/$REALM" -s "smtpServer.host=$MAIL_CONTAINER" -s smtpServer.port=1025 -s smtpServer.from=keycloak@example.invalid >/dev/null
kcadm create clients -r "$REALM" -s "clientId=$APP" -s enabled=true -s publicClient=true -s standardFlowEnabled=true \
  -s "redirectUris=[\"$APP_REDIRECT\",\"$BROWSER_REDIRECT\"]" >/dev/null
kcadm create realms -s "realm=$MOCK" -s enabled=true -s registrationAllowed=false \
  -s "attributes.frontendUrl=$BASE_URL" >/dev/null
kcadm get users/profile -r "$MOCK" | jq '.unmanagedAttributePolicy="ENABLED"' | kcadm update users/profile -r "$MOCK" -n -f - >/dev/null
kcadm create clients -r "$MOCK" -s clientId=ytu-broker -s enabled=true -s publicClient=false -s "secret=$BROKER_SECRET" \
  -s standardFlowEnabled=true -s 'redirectUris=["http://localhost:8080/realms/e-skylab/broker/OBS/endpoint","http://localhost:'"$PORT"'/realms/e-skylab/broker/OBS/endpoint","http://127.0.0.1:'"$PORT"'/realms/e-skylab/broker/OBS/endpoint"]' >/dev/null
mock_client=$(kcadm get clients -r "$MOCK" -q clientId=ytu-broker | jq -r '.[0].id')
for claim in upn department; do
  kcadm create "clients/$mock_client/protocol-mappers/models" -r "$MOCK" -b "{\"name\":\"$claim\",\"protocol\":\"openid-connect\",\"protocolMapper\":\"oidc-usermodel-attribute-mapper\",\"config\":{\"user.attribute\":\"$claim\",\"claim.name\":\"$claim\",\"jsonType.label\":\"String\",\"userinfo.token.claim\":\"true\",\"id.token.claim\":\"true\",\"access.token.claim\":\"true\"}}" >/dev/null
done
# Front-channel URLs reach the published port; token/profile calls stay inside the same container.
kcadm create identity-provider/instances -r "$REALM" -f - >/dev/null <<JSON
{"alias":"OBS","providerId":"sky-test-microsoft","enabled":true,"trustEmail":true,"config":{
"clientId":"ytu-broker","clientSecret":"$BROKER_SECRET","syncMode":"LEGACY",
"authorizationUrl":"$BASE_URL/realms/$MOCK/protocol/openid-connect/auth",
"tokenUrl":"http://localhost:8080/realms/$MOCK/protocol/openid-connect/token",
"userInfoUrl":"http://localhost:8080/realms/$MOCK/protocol/openid-connect/userinfo"}}
JSON
for mapper in \
  '{"name":"school","identityProviderAlias":"OBS","identityProviderMapper":"oidc-user-attribute-idp-mapper","config":{"syncMode":"FORCE","claim":"upn","user.attribute":"schoolEmail"}}' \
  '{"name":"department","identityProviderAlias":"OBS","identityProviderMapper":"oidc-user-attribute-idp-mapper","config":{"syncMode":"FORCE","claim":"department","user.attribute":"department"}}' \
  '{"name":"university","identityProviderAlias":"OBS","identityProviderMapper":"hardcoded-attribute-idp-mapper","config":{"syncMode":"FORCE","attribute":"university","attribute.value":"Yıldız Teknik Üniversitesi"}}'; do
  kcadm create identity-provider/instances/OBS/mappers -r "$REALM" -b "$mapper" >/dev/null
done
stage 'default off and explicit on'
output=$(reconcile "$ADMIN_CONFIG" 0 KEYCLOAK_YTU_FIRST_LOGIN=on)
grep -Fq 'explicit KEYCLOAK_EXISTING_ACCOUNT_PROMPT=on' <<<"$output" || fail 'default enabled protection'
if [[ ${B12_TRANSACTION_ONLY:-0} != 1 ]]; then
  mock_person default-off@std.yildiz.edu.tr 'Fizik'
  ytu_login default-off "$MOCK_USERNAME"
  [[ $LANDED == app ]] || fail 'default-off native first login changed'
fi
output=$(reconcile "$ADMIN_CONFIG" 0 KEYCLOAK_EXISTING_ACCOUNT_PROMPT=on)
output2=$(reconcile "$ADMIN_CONFIG" 0 KEYCLOAK_EXISTING_ACCOUNT_PROMPT=on)
if grep -Fq 'existing-account protection: updated' <<<"$output2"; then fail 'second on was not idempotent'; fi
printf '  on/keep default and idempotent configuration passed\n'

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


link_action() {
  local action=$1
  shift
  follow "$JAR" "$(form_action '')" --data-urlencode "sky-existing-account-action=$action" "$@"
}
on_link_stage() { [[ $LANDED == page && $BODY == *"data-sky-existing-account-stage=\"$1\""* ]]; }
links() { kcadm get "users/$1/federated-identity" -r "$REALM" | jq 'length'; }

PROBE="$BASE_URL/realms/$REALM/broker-link-probe"
if [[ ${B12_TRANSACTION_ONLY:-0} != 1 ]]; then
stage 'real first Microsoft login and existing-account code proof'
existing=$(local_person existing-person primary.b12@example.invalid personalEmail=personal.b12@example.invalid personalEmailVerifiedAt=2026-10-01T00:00:00Z)
kcadm get "users/$existing" -r "$REALM" | jq -e '.attributes.personalEmail | length == 1' >/dev/null \
  || fail 'production User Profile dropped the personal-email alias fixture'
mock_person link-one@std.yildiz.edu.tr 'Bilgisayar'
ytu_login link-one "$MOCK_USERNAME"
on_link_stage question || fail "question missing ($(page_summary))"
link_action existing
link_action send --data-urlencode username=personal.b12@example.invalid
on_link_stage code || fail 'code stage missing'
code=$(mail_code primary.b12@example.invalid)
link_action verify --data-urlencode "code=$code"
[[ $LANDED == app ]] || fail "code link did not reach app ($(page_summary))"
[[ $(links "$existing") == 1 ]] || fail 'code link did not preserve one account'
kcadm get "users/$existing" -r "$REALM" | jq -e '.email=="primary.b12@example.invalid" and .emailVerified==true and .firstName=="Yeni" and .lastName=="Öğrenci" and .attributes.schoolEmail[0]=="link-one@std.yildiz.edu.tr"' >/dev/null || fail 'primary, Microsoft name or school profile was wrong'
ytu_login linked-again "$MOCK_USERNAME"
[[ $LANDED == app ]] || fail 'a linked account saw the question'
printf '  real code proof: one account, current primary preserved, trusted Microsoft name, repeat login passed\n'

stage 'unknown identifier and explicit new-account escape'
mock_person link-unknown@std.yildiz.edu.tr 'Fizik'
ytu_login unknown "$MOCK_USERNAME"
link_action existing
link_action send --data-urlencode username=nobody.b12@example.invalid
on_link_stage code || fail 'unknown identifier page differs'
[[ $(mail_count nobody.b12@example.invalid) == 0 ]] || fail 'an unknown account was mailed'
link_action new-account
[[ $LANDED == app ]] || fail "explicit new account failed ($(page_summary))"
user_by_username "$MOCK_USERNAME" | jq -e '.email=="link-unknown@std.yildiz.edu.tr" and .emailVerified==true' >/dev/null || fail 'new account school primary is wrong'
printf '  unknown identifier: same page, no mail, explicit new-account escape passed\n'

stage 'native password proof'
kcadm update "realms/$REALM" -s bruteForceProtected=true -s failureFactor=20 >/dev/null
password_id=$(local_person proof-password password.b12@example.invalid personalEmail=password.alias.b12@example.invalid personalEmailVerifiedAt=2026-10-01T00:00:00Z)
mock_person link-password@std.yildiz.edu.tr 'Kimya'
ytu_login password "$MOCK_USERNAME"
link_action existing
link_action password --data-urlencode username=password.alias.b12@example.invalid
[[ $BODY == *'id="kc-form-login"'* ]] || fail 'native password form missing'
[[ $BODY != *'value="proof-password"'* ]] || fail 'native password form exposed the canonical username'
follow "$JAR" "$(form_action kc-form-login)" --data-urlencode username=password.alias.b12@example.invalid \
  --data-urlencode password=wrong-fixture-password --data-urlencode credentialId=
[[ $BODY == *'id="kc-form-login"'* && $(links "$password_id") == 0 ]] || fail 'wrong alias password authenticated'
counted=''
for _ in $(seq 1 6); do
  if kcadm get "attack-detection/brute-force/users/$password_id" -r "$REALM" | jq -e '.numFailures>=1' >/dev/null; then counted=1; break; fi
  sleep 0.2
done
[[ $counted == 1 ]] || fail 'native wrong-password brute-force accounting lost the alias target'
follow "$JAR" "$(form_action kc-form-login)" --data-urlencode username=password.alias.b12@example.invalid --data-urlencode "password=$LOCAL_PASSWORD" --data-urlencode credentialId=
[[ $LANDED == app && $(links "$password_id") == 1 ]] || fail 'native password proof failed'
kcadm update "realms/$REALM" -s bruteForceProtected=false >/dev/null
printf '  native password via personalEmail alias: hidden canonical username, wrong-password BF count, correct proof passed\n'

stage 'school address held as a personal alias is suggested without proving the account'
candidate_id=$(local_person school-candidate candidate.primary.b12@example.invalid \
  personalEmail=school-candidate@std.yildiz.edu.tr personalEmailVerifiedAt=2026-10-01T00:00:00Z)
mock_person school-candidate@std.yildiz.edu.tr 'İstatistik'
ytu_login school-candidate "$MOCK_USERNAME"
[[ $BODY == *'data-sky-existing-account-candidate="true"'* && $(links "$candidate_id") == 0 ]] || fail 'school candidate was not safely suggested'
link_action existing
[[ $BODY == *'value="school-candidate@std.yildiz.edu.tr"'* && $BODY != *'candidate.primary.b12@example.invalid'* ]] \
  || fail 'school candidate identifier prefill exposed its primary'
link_action send --data-urlencode username=school-candidate@std.yildiz.edu.tr
code=$(mail_code candidate.primary.b12@example.invalid)
link_action verify --data-urlencode "code=$code"
[[ $LANDED == app && $(links "$candidate_id") == 1 ]] || fail 'school candidate proof did not link'
printf '  Microsoft-proven school personalEmail candidate: suggestion only, primary code proof required passed\n'

stage 'TOTP cannot be bypassed after the code or password'
PROBE="$BASE_URL/realms/$REALM/broker-link-probe"
otp_code() {
  local encoded
  encoded=$(node -e '
    const alphabet="ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"; let bits=0,value=0,out="";
    for (const byte of Buffer.from("b12-fixed-fixture-secret-0123456789")) {
      value=((value<<8)|byte)&65535; bits+=8;
      while(bits>=5) { out+=alphabet[(value>>>(bits-5))&31]; bits-=5; }
    }
    if(bits>0)out+=alphabet[(value<<(5-bits))&31]; process.stdout.write(out);')
  node "$SCRIPT_DIR/totp-code.mjs" "$encoded"
}
for method in code password; do
  otp_id=$(local_person "otp-$method" "otp.$method.b12@example.invalid")
  curl -fsS -X POST "$PROBE/otp-$method/factor?user=otp-$method" >/dev/null
  mock_person "link-otp-$method@std.yildiz.edu.tr" 'Matematik'
  ytu_login "otp-$method" "$MOCK_USERNAME"
  link_action existing
  if [[ $method == code ]]; then
    link_action send --data-urlencode "username=otp-$method"
    code=$(mail_code "otp.$method.b12@example.invalid")
    link_action verify --data-urlencode "code=$code"
  else
    link_action password --data-urlencode "username=otp-$method"
    follow "$JAR" "$(form_action kc-form-login)" --data-urlencode "username=otp-$method" \
      --data-urlencode password=wrong-fixture-password --data-urlencode credentialId=
    [[ $LANDED == page && $(links "$otp_id") == 0 ]] || fail 'wrong password linked an account'
    follow "$JAR" "$(form_action kc-form-login)" --data-urlencode "username=otp-$method" \
      --data-urlencode "password=$LOCAL_PASSWORD" --data-urlencode credentialId=
  fi
  [[ $BODY == *'id="kc-otp-login-form"'* && $(links "$otp_id") == 0 ]] || fail 'TOTP was bypassed'
  follow "$JAR" "$(form_action kc-otp-login-form)" --data-urlencode otp=not-a-code
  [[ $BODY == *'id="kc-otp-login-form"'* && $(links "$otp_id") == 0 ]] || fail 'wrong TOTP linked an account'
  follow "$JAR" "$(form_action kc-otp-login-form)" --data-urlencode "otp=$(otp_code)"
  [[ $LANDED == app && $(links "$otp_id") == 1 ]] || fail 'valid second factor failed'
done
printf '  code/password followed by native TOTP, wrong password/OTP refusals passed\n'

stage 'A6 native link with feature on'
a6=$(local_person b12-a6 a6.b12@example.invalid)
mock_person link-a6@std.yildiz.edu.tr 'Biyoloji'
JAR="$STATE_DIR/a6.cookies"
follow "$JAR" "$(auth_url '&kc_action=idp_link:OBS')"
follow "$JAR" "$(form_action kc-form-login)" --data-urlencode username=b12-a6 --data-urlencode "password=$LOCAL_PASSWORD" --data-urlencode credentialId=
follow "$JAR" "$(form_action '')" --data-urlencode continue=
follow "$JAR" "$(form_action kc-form-login)" --data-urlencode "username=$MOCK_USERNAME" --data-urlencode "password=$MOCK_PASSWORD" --data-urlencode credentialId=
[[ $LANDED == app && $(links "$a6") == 1 ]] || fail 'feature-on A6 link failed'
kcadm get "users/$a6" -r "$REALM" | jq -e '.email=="a6.b12@example.invalid"' >/dev/null || fail 'A6 primary changed'
printf '  feature-on A6 native link passed\n'

stage 'native resident passkey proof with explicit mediation'
passkey_id=$(local_person b12-passkey passkey.b12@example.invalid)
other_passkey_id=$(local_person b12-other-passkey other.passkey.b12@example.invalid)
mock_person passkey-wrong-target@std.yildiz.edu.tr 'Fizik'
first_passkey_mock=$MOCK_USERNAME
mock_person passkey-right-target@std.yildiz.edu.tr 'Fizik'
second_passkey_mock=$MOCK_USERNAME
kcadm update "realms/$REALM" -s webAuthnPolicyPasswordlessRpId=localhost \
  -s webAuthnPolicyPasswordlessPasskeysEnabled=true -s webAuthnPolicyPasswordlessMediation=conditional \
  -s webAuthnPolicyPasswordlessResidentKey=required -s webAuthnPolicyPasswordlessUserVerificationRequirement=required >/dev/null
jq -n --arg baseUrl "http://localhost:$PORT" --arg realm "$REALM" --arg clientId "$APP" \
  --arg callbackUrl "$BROWSER_REDIRECT" --arg username b12-passkey --arg otherUsername b12-other-passkey \
  --arg password "$LOCAL_PASSWORD" --arg mockUsername "$first_passkey_mock" --arg secondMockUsername "$second_passkey_mock" \
  --arg mockPassword "$MOCK_PASSWORD" \
  '{baseUrl:$baseUrl,realm:$realm,clientId:$clientId,callbackUrl:$callbackUrl,username:$username,
    otherUsername:$otherUsername,password:$password,mockUsername:$mockUsername,
    secondMockUsername:$secondMockUsername,mockPassword:$mockPassword}' >"$STATE_DIR/passkey.json"
chmod 600 "$STATE_DIR/passkey.json"
(
  cd "$REPOSITORY_ROOT/theme"
  B12_PASSKEY_CONFIG="$STATE_DIR/passkey.json" npx --no-install playwright test \
    --config=playwright.integration.config.ts tests/integration/broker-existing-account.spec.ts
)
[[ $(links "$passkey_id") == 1 && $(links "$other_passkey_id") == 0 ]] || fail 'native passkey proof switched the chosen account'
printf '  native resident passkey: wrong target refused, selected target linked passed\n'
fi

prepare() { local label=$1 user=$2 subject=$3; shift 3; curl -fsS -X POST "$PROBE/$label/prepare?user=$user&subject=$subject$*" >/dev/null; }
wait_state() {
  local label=$1 field=$2 found=''
  for _ in $(seq 1 80); do
    if curl -fsS "$PROBE/$label" | jq -e --arg field "$field" '.[$field]==true' >/dev/null; then found=1; break; fi
    sleep 0.1
  done
  [[ $found == 1 ]] || fail "probe $label did not reach $field"
}
release() { curl -fsS -X POST "$PROBE/$1/release" >/dev/null; }
complete_background() {
  curl -sS -o "$STATE_DIR/$1.body" -w '%{http_code}' -X POST "$PROBE/$1/complete" >"$STATE_DIR/$1.status" &
  PROBE_PID=$!
}
check_managed_entity() {
  stage 'managed callback entity preserves concurrent administrative fields'
  id=$(local_person probe-orm probe.orm.b12@example.invalid)
  prepare orm probe-orm subject-orm '&pause=before'
  complete_background orm; waiter=$PROBE_PID
  wait_state orm waiting
  # Admin REST intentionally ignores notBefore updates; use the same native model methods as
  # administration/account operations, then assert all three committed scalar columns.
  curl -fsS -X POST "$PROBE/orm/admin-fields" >/dev/null
  curl -fsS "$PROBE/orm/admin-fields" >"$STATE_DIR/orm.fields-before.json"
  jq -e 'all(.[]; .==true)' "$STATE_DIR/orm.fields-before.json" >/dev/null \
    || fail 'the concurrent admin fixture did not commit its fields'
  release orm; wait "$waiter"
  [[ $(cat "$STATE_DIR/orm.status") == 200 && $(links "$id") == 1 ]] || fail 'unrelated admin changes rejected the valid proof'
  curl -fsS "$PROBE/orm/admin-fields" >"$STATE_DIR/orm.fields-after.json"
  jq -e 'all(.[]; .==true)' "$STATE_DIR/orm.fields-after.json" >/dev/null \
    || fail 'trusted-name ORM flush overwrote concurrent admin fields'
  printf '  managed callback entity: concurrent verification/username/notBefore preserved passed\n'
}
if [[ ${B12_ORM_ONLY:-0} == 1 ]]; then check_managed_entity; exit; fi

stage 'callback stale primary, disabled, factor and fixed TTL rollback'
for scenario in primary disabled factor rotate remove ttl flow override; do
  id=$(local_person "probe-$scenario" "probe.$scenario.b12@example.invalid")
  if [[ $scenario == rotate || $scenario == remove ]]; then curl -fsS -X POST "$PROBE/$scenario/factor?user=probe-$scenario" >/dev/null; fi
  if [[ $scenario == ttl ]]; then ttl='&ttl=2'; else ttl=''; fi
  prepare "$scenario" "probe-$scenario" "subject-$scenario" "&pause=before$ttl"
  complete_background "$scenario"; waiter=$PROBE_PID
  wait_state "$scenario" waiting
  case $scenario in
    primary) kcadm update "users/$id" -r "$REALM" -s email=changed.b12@example.invalid >/dev/null ;;
    disabled) kcadm update "users/$id" -r "$REALM" -s enabled=false >/dev/null ;;
    factor) curl -fsS -X POST "$PROBE/$scenario/factor?user=probe-$scenario" >/dev/null ;;
    rotate) curl -fsS -X POST "$PROBE/$scenario/factor?user=probe-$scenario&rotate=true" >/dev/null ;;
    remove) curl -fsS -X POST "$PROBE/$scenario/factor?user=probe-$scenario&remove=true" >/dev/null ;;
    ttl) sleep 3 ;;
    flow) reconcile "$ADMIN_CONFIG" 0 KEYCLOAK_EXISTING_ACCOUNT_PROMPT=off >/dev/null ;;
    override) kcadm update identity-provider/instances/OBS -r "$REALM" -s 'firstBrokerLoginFlowAlias=first broker login' >/dev/null ;;
  esac
  release "$scenario"; wait "$waiter"
  [[ $(cat "$STATE_DIR/$scenario.status") == 409 ]] || fail "$scenario callback did not return the fixed refusal"
  [[ $(links "$id") == 0 ]] || fail "$scenario callback committed a refused link"
  if [[ $scenario == primary ]]; then
    kcadm update "users/$id" -r "$REALM" -s email=probe.primary.b12@example.invalid >/dev/null
    replay_status=$(curl -sS -o "$STATE_DIR/replay.body" -w '%{http_code}' -X POST "$PROBE/$scenario/complete")
    [[ $replay_status == 409 && $(links "$id") == 0 ]] || fail 'restoring primary replayed a consumed proof'
  fi
  if [[ $scenario == flow ]]; then reconcile "$ADMIN_CONFIG" 0 KEYCLOAK_EXISTING_ACCOUNT_PROMPT=on >/dev/null; fi
  if [[ $scenario == override ]]; then kcadm update identity-provider/instances/OBS -r "$REALM" -s firstBrokerLoginFlowAlias= >/dev/null; fi
done
id=$(local_person probe-prepare-ttl prepare.ttl.b12@example.invalid)
prepare prepare-ttl probe-prepare-ttl subject-prepare-ttl '&pause=guard&ttl=2'
complete_background prepare-ttl; waiter=$PROBE_PID
wait_state prepare-ttl guarded
sleep 3
release prepare-ttl; wait "$waiter"
[[ $(cat "$STATE_DIR/prepare-ttl.status") == 500 ]] || fail 'pre-commit TTL did not veto transaction preparation'
[[ $(links "$id") == 0 ]] || fail 'TTL expired after hook but before JPA commit was accepted'
printf '  actual callback transactions: primary/disabled/factor/rotation/operator off/override/TTL rollback passed\n'

check_managed_entity

stage 'post-snapshot OTP insert, update and delete stay bounded'
for mutation in add rotate remove; do
  id=$(local_person "hold-$mutation" "hold.$mutation.b12@example.invalid")
  if [[ $mutation != add ]]; then curl -fsS -X POST "$PROBE/hold-$mutation/factor?user=hold-$mutation" >/dev/null; fi
  prepare "hold-$mutation" "hold-$mutation" "subject-hold-$mutation" '&pause=guard'
  complete_background "hold-$mutation"; waiter=$PROBE_PID
  wait_state "hold-$mutation" guarded
  option=''
  [[ $mutation != add ]] && option="&$mutation=true"
  locked_status=$(curl -sS -o "$STATE_DIR/hold-$mutation.factor" -w '%{http_code}' -X POST \
    "$PROBE/hold-$mutation/factor?user=hold-$mutation&bounded=true$option")
  [[ $locked_status == 500 ]] || fail "post-snapshot OTP $mutation bypassed the row locks"
  release "hold-$mutation"; wait "$waiter"
  [[ $(cat "$STATE_DIR/hold-$mutation.status") == 200 && $(links "$id") == 1 ]] || fail 'a blocked OTP mutation broke the valid callback'
  curl -fsS -X POST "$PROBE/hold-$mutation/factor?user=hold-$mutation$option" >/dev/null
done
printf '  post-snapshot OTP insert/update/delete: lock timeout, no deadlock, retry after commit passed\n'

stage 'same subject across proof and native callbacks'
a=$(local_person race-proof race.proof.b12@example.invalid)
b=$(local_person race-native race.native.b12@example.invalid)
prepare race-a race-proof shared-subject '&pause=guard'
prepare race-b race-native shared-subject '&pause=insert&native=true'
complete_background race-a; first=$PROBE_PID
wait_state race-a guarded
complete_background race-b; second=$PROBE_PID
wait_state race-b inserted
release race-b; wait "$second"
[[ $(cat "$STATE_DIR/race-b.status") == 409 ]] || fail 'busy subject did not fail closed immediately'
release race-a; wait "$first"
[[ $(links "$a") == 1 && $(links "$b") == 0 ]] || fail 'same Microsoft subject was linked to two targets'
printf '  proof/native subject race: one committed owner, busy callback rolled back passed\n'

stage 'rollback removes only the new steps'
reconcile "$ADMIN_CONFIG" 0 KEYCLOAK_EXISTING_ACCOUNT_PROMPT=off >/dev/null
reconcile "$ADMIN_CONFIG" 0 KEYCLOAK_EXISTING_ACCOUNT_PROMPT=off >/dev/null
printf 'existing-account-link: all checks passed\n'
