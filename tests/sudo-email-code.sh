#!/usr/bin/env bash
# Isolated Sudo email-code runtime: existing pinned images only, no image pull or production calls.
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
IMAGE=$(sed -n 's/^ARG KEYCLOAK_IMAGE=//p' "$ROOT/Dockerfile")
NODE_IMAGE=$(sed -n 's/^ARG NODE_IMAGE=//p' "$ROOT/Dockerfile")
MAIL_IMAGE=$(sed -n 's/^ *image: \(axllent\/mailpit:[^ ]*\)$/\1/p' "$SCRIPT_DIR/docker-compose.integration.yml")
PORT=${SUDO_EMAIL_TEST_PORT:-18371}
MAIL_PORT=${SUDO_EMAIL_TEST_MAIL_PORT:-18372}
NAME=${SUDO_EMAIL_TEST_CONTAINER:-sudo-email-code-$$}
MAIL="$NAME-mail"
SKYMAIL="$NAME-skymail"
NETWORK="$NAME-net"
STATE=$(mktemp -d "$ROOT/.sudo-email-runtime-XXXXXX")
SPI_JAR=${SUDO_EMAIL_SPI_JAR:-$ROOT/spi/target/e-skylab-spi-1.24.0.jar}
cleanup() {
  docker rm -fv "$NAME" "$MAIL" "$SKYMAIL" >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
  rm -rf "$STATE"
}
trap 'status=$?; trap - EXIT; cleanup; exit "$status"' EXIT
for image in "$IMAGE" "$NODE_IMAGE" "$MAIL_IMAGE"; do docker image inspect "$image" >/dev/null; done
[[ -f $SPI_JAR ]] || { printf 'Build spi 1.24.0 first.\n' >&2; exit 1; }
if unzip -l "$SPI_JAR" | grep -E 'SudoEmailClockProbe|EmailAddressOwnershipProbe' >/dev/null; then
  printf 'Test-only provider leaked into the production jar.\n' >&2
  exit 1
fi
mkdir -p "$STATE/clock"
docker run --rm --pull never --memory 512m --user "$(id -u):$(id -g)" --entrypoint bash \
  -v "$SCRIPT_DIR/fixtures/SudoEmailClockProbe.java:/fixture/SudoEmailClockProbe.java:ro" \
  -v "$STATE/clock:/out" "$IMAGE" -ec '
    jars=(/opt/keycloak/lib/lib/main/*.jar); IFS=:
    java -m jdk.compiler/com.sun.tools.javac.Main -proc:none -cp "${jars[*]}" -d /out /fixture/SudoEmailClockProbe.java
    mkdir -p /out/META-INF/services
    printf "%s\n" com.skylab.account.SudoEmailClockProbe > /out/META-INF/services/org.keycloak.services.resource.RealmResourceProviderFactory
    java -m jdk.jartool/sun.tools.jar.Main --create --file /out/clock.jar -C /out com -C /out META-INF
  '
docker network create "$NETWORK" >/dev/null
docker run --rm --pull never -d --name "$MAIL" --network "$NETWORK" --memory 256m \
  --tmpfs /tmp:rw,size=64m,mode=1777 -p "127.0.0.1:$MAIL_PORT:8025" "$MAIL_IMAGE" >/dev/null
docker run --rm --pull never -d --name "$SKYMAIL" --network "$NETWORK" --memory 128m --read-only \
  -e SKYMAIL_HTTP_PORT=8080 -e SKYMAIL_SMTP_PORT=1025 \
  -v "$SCRIPT_DIR/skymail-server.mjs:/fixture/skymail-server.mjs:ro" "$NODE_IMAGE" node /fixture/skymail-server.mjs >/dev/null
docker run --rm --pull never -d --name "$NAME" --network "$NETWORK" --memory 2g \
  --tmpfs /opt/keycloak/data:rw,size=512m,mode=1777 -p "127.0.0.1:$PORT:$PORT" \
  -e KC_BOOTSTRAP_ADMIN_USERNAME=admin -e KC_BOOTSTRAP_ADMIN_PASSWORD=sudo-harness-admin \
  -e SKY_HARNESS=1 -e SKY_MAIL_ENABLED=true -e "SKY_MAIL_BASE_URL=http://$SKYMAIL:8080" \
  -e SKY_MAIL_CLIENT_ID=keycloak-mailer -e SKY_MAIL_CLIENT_SECRET=sudo-harness-mailer-secret \
  -e SKY_MAIL_TIMEOUT_MILLISECONDS=3000 \
  -v "$SPI_JAR:/opt/keycloak/providers/e-skylab-spi.jar:ro" \
  -v "$STATE/clock/clock.jar:/opt/keycloak/providers/sudo-email-clock.jar:ro" \
  "$IMAGE" start-dev --http-port "$PORT" >/dev/null
for _ in $(seq 1 120); do
  curl -fsS "http://127.0.0.1:$PORT/realms/master" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS "http://127.0.0.1:$PORT/realms/master" >/dev/null || { printf 'Local Keycloak did not start.\n' >&2; exit 1; }
SUDO_EMAIL_BASE_URL="http://127.0.0.1:$PORT" SUDO_EMAIL_MAIL_URL="http://127.0.0.1:$MAIL_PORT" \
  SUDO_EMAIL_CLOCK_PROBE_MODULE="$SCRIPT_DIR/sudo-email-code-clock.mjs" \
  SUDO_EMAIL_MAIL_CONTAINER="$MAIL" SUDO_EMAIL_SKYMAIL_CONTAINER="$SKYMAIL" SUDO_EMAIL_KEYCLOAK_CONTAINER="$NAME" node "$SCRIPT_DIR/sudo-email-code.mjs"
printf 'Sudo e-mail runtime complete; owned containers and tmpfs data will be removed.\n'
