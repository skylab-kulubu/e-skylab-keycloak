#!/usr/bin/env bash
set -Eeuo pipefail

# Injected into the core-roles step as KCADM_BIN (tests/core-roles.sh): every read whose arguments
# contain KCADM_INJECT_FAIL fails the way a dropped connection or a server error would (nothing
# says "not found"), everything else passes through to kcadm.
if [[ ${1:-} == get && -n ${KCADM_INJECT_FAIL:-} && " $* " == *"$KCADM_INJECT_FAIL"* ]]; then
  printf 'Injected read failure\n' >&2
  exit 42
fi

exec /opt/keycloak/bin/kcadm.sh "$@"
