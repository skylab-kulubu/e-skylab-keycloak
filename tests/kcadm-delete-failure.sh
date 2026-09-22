#!/usr/bin/env bash
set -Eeuo pipefail

# Injected into cleanup-legacy-passkeys.sh as KCADM_BIN: every credential DELETE fails the way
# a missing manage-users permission would, everything else passes through to kcadm.
if [[ ${1:-} == delete && " $* " == *'/credentials/'* ]]; then
  printf 'Injected credential delete failure\n' >&2
  exit 42
fi

exec /opt/keycloak/bin/kcadm.sh "$@"
