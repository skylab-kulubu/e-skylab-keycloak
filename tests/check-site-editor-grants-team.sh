#!/usr/bin/env bash
# config/site-editor-grants.sh --team takes a top team only (/UYELER/<area>/<team>): a Sub-team's
# Leader groups never get cms:access (ADR-0065 addendum of 2026-10-12). A deeper or shallower path
# is refused with exit 2 before anything is read; a top team gets past the argument check. Needs no
# Keycloak: the script stops at its kcadm config, which does not exist here. Needs bash 4+.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GRANTS="$SCRIPT_DIR/../config/site-editor-grants.sh"
NO_CONFIG=/nonexistent/site-grants-kcadm.config
status=0

# run_team SITE=PATH: the script's output and exit status ("<status> <output>").
run_team() {
  local output code=0
  output=$(KEYCLOAK_REALM=e-skylab KCADM_BIN=/nonexistent/kcadm.sh \
    bash "$GRANTS" --kcadm-config "$NO_CONFIG" --check --site artlab --team "$1" 2>&1) || code=$?
  printf '%s %s' "$code" "$output"
}

for team in \
  artlab=/UYELER/ARGE/ALGOLAB/AGC \
  artlab=/UYELER/ARGE/WEBLAB/FRONT/BACK \
  main=/UYELER/ARGE/ALGOLAB/AGC \
  artlab=/UYELER/ARGE \
  artlab=/ARGE/WEBLAB/FRONT; do
  got=$(run_team "$team")
  if [[ $got != "2 refusing --team $team: only a top team"* ]]; then
    printf 'site-editor-grants --team check failed: %s was not refused before a login: %s\n' "$team" "$got" >&2
    status=1
  fi
done
for team in artlab=/UYELER/ARGE/GAMELAB yildizjam=/UYELER/ORGANIZASYON/YILDIZJAM; do
  got=$(run_team "$team")
  if [[ $got != "2 kcadm config $NO_CONFIG is not readable"* ]]; then
    printf 'site-editor-grants --team check failed: the top team %s was not accepted: %s\n' "$team" "$got" >&2
    status=1
  fi
done
[[ $status == 0 ]] && printf 'site-editor-grants.sh --team takes top teams only.\n'
exit "$status"
