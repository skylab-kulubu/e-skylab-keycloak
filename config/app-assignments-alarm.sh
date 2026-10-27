#!/usr/bin/env bash
# The nightly drift alarm's run (ekip-yetkileri ticket 07): the reconciler's operator step
# KEYCLOAK_RECONCILE_ONLY=app-assignments with KEYCLOAK_APP_ASSIGNMENTS_ALARM=true, its output as it
# is, and an exit status a scheduler can trust:
#   0  the summary line "[app-assignments] SAPMA: …, alarm=0" was printed and the step exited 0;
#   1  the summary line says alarm=<n> above 0 and the step exited 1 (drift);
#   2  anything else: no summary line (the reconciler stopped before config/app-assignments.sh ran,
#      at its login or its realm read, say, where a failure is exit 1 too), more than one, or a status
#      that does not match it. Nothing was measured; never read as drift.
# It reads only (the step does) and takes the step's environment as it is (KEYCLOAK_REALM,
# KEYCLOAK_ADMIN_URL, KEYCLOAK_RECONCILE_KCADM_CONFIG, KEYCLOAK_APP_ASSIGNMENTS_REALM_ROLES);
# KEYCLOAK_RECONCILE_ONLY and KEYCLOAK_APP_ASSIGNMENTS_ALARM are set here.
#
# Usage:
#   KEYCLOAK_REALM=<realm> KEYCLOAK_RECONCILE_KCADM_CONFIG=<file> app-assignments-alarm.sh
set -Eeuo pipefail
shopt -s inherit_errexit

umask 077

CONFIG_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ $# == 0 ]] || { printf 'usage: KEYCLOAK_REALM=<realm> KEYCLOAK_RECONCILE_KCADM_CONFIG=<file> %s\n' "${0##*/}" >&2; exit 2; }

OUTPUT=$(mktemp /tmp/app-assignments-alarm.XXXXXX)
trap 'rm -f "$OUTPUT"' EXIT

status=0
KEYCLOAK_RECONCILE_ONLY=app-assignments KEYCLOAK_APP_ASSIGNMENTS_ALARM=true \
  bash "$CONFIG_DIR/reconcile-account-center.sh" >"$OUTPUT" 2>&1 || status=$?
cat "$OUTPUT"

summaries=0 alarm=''
while IFS= read -r line; do
  if [[ $line =~ ^\[app-assignments\]\ SAPMA:\ .*,\ alarm=([0-9]+)$ ]]; then
    summaries=$((summaries + 1))
    alarm=${BASH_REMATCH[1]}
  fi
done <"$OUTPUT"

if [[ $summaries == 1 && $status == 0 && $alarm == 0 ]]; then
  exit 0
fi
if [[ $summaries == 1 && $status == 1 && $alarm -gt 0 ]]; then
  exit 1
fi
printf '[app-assignments-alarm] not measured: exit %s, %s summary line(s) (one "[app-assignments] SAPMA: …, alarm=<n>" was expected); counted as 2, never as drift\n' \
  "$status" "$summaries" >&2
exit 2
