#!/usr/bin/env bash
# config/app-assignments.json (ekip-yetkileri tickets 03 and 15) against a copy of core's app roles
# (tests/fixtures/core-app-roles.json, core-backend internal/authz/role_classes.go AppRoles). The
# panel assigns exactly core's app roles; an admin role never reaches the catalogue, and an app role
# core knows is never missing from it. Also: every client once, a name, assignmentRequired a boolean,
# every role once, the suggested roles among the roles, and the one-time initial assignments name
# only roles of their app and a known target (top-teams, top-team-leaders or one top team's path).
# Needs no Keycloak: jq only.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CATALOGUE="$SCRIPT_DIR/../config/app-assignments.json"
CORE_COPY="$SCRIPT_DIR/fixtures/core-app-roles.json"
status=0

check() {
  local message=$1
  shift
  if ! jq -e "$@" >/dev/null; then
    printf 'app-assignments check failed: %s\n' "$message" >&2
    status=1
  fi
}

jq -e 'type == "object"' "$CATALOGUE" >/dev/null || { printf 'app-assignments check failed: %s is not a JSON object\n' "$CATALOGUE" >&2; exit 1; }
check 'apps must be a non-empty array' '(.apps | type) == "array" and (.apps | length) > 0' "$CATALOGUE"
check 'every app needs a client, a name, a boolean assignmentRequired and at least one role' \
  '.apps | all((.client | type) == "string" and (.client | length) > 0 and (.name | type) == "string" and (.name | length) > 0
    and (.assignmentRequired | type) == "boolean" and (.roles | type) == "array" and (.roles | length) > 0)' "$CATALOGUE"
check 'a client is named twice' '[.apps[].client] | length == (unique | length)' "$CATALOGUE"
check 'an app names a role twice' '.apps | all((.roles | length) == (.roles | unique | length))' "$CATALOGUE"
check 'a suggested role is not among the roles of its app' \
  '.apps | all(. as $app | (.suggestedRoles // []) | all(. as $r | $app.roles | index($r) != null))' "$CATALOGUE"
check 'a role name is empty or holds a space, a tab, a quote or a backslash' \
  '[.apps[].roles[]] | all(test("^[^\\s\"\\\\]+$"))' "$CATALOGUE"

catalogue_pairs=$(jq -c '[.apps[] | .client as $c | .roles[] | {client: $c, role: .}] | sort' "$CATALOGUE")
core_pairs=$(jq -c '[.roles[] | {client, role}] | sort' "$CORE_COPY")
if [[ $catalogue_pairs != "$core_pairs" ]]; then
  printf 'app-assignments check failed: the catalogue is not exactly core'"'"'s app roles (%s)\n' "$(jq -r .source "$CORE_COPY")" >&2
  jq -rn --argjson a "$catalogue_pairs" --argjson c "$core_pairs" \
    '($a - $c | map("  only in config/app-assignments.json: \(.client)/\(.role)")[]), ($c - $a | map("  only in core: \(.client)/\(.role)")[])' >&2
  status=1
fi

check 'initialAssignments must be an array' '(.initialAssignments | type) == "array"' "$CATALOGUE"
check 'an initial assignment names a role its app does not assign' \
  '(.apps | map({(.client): .roles}) | add) as $roles
    | .initialAssignments | all(($roles[.client] // null) as $app | $app != null and (.roles | type) == "array" and (.roles | length) > 0
      and (.roles | all(. as $r | $app | index($r) != null)))' "$CATALOGUE"
check 'an initial assignment has a target other than top-teams, top-team-leaders or one top team (/UYELER/<area>/<team>)' \
  '.initialAssignments | all(.target == "top-teams" or .target == "top-team-leaders" or (.target | type == "string" and test("^/UYELER/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")))' "$CATALOGUE"

[[ $status == 0 ]] && printf 'config/app-assignments.json assigns exactly core'"'"'s app roles.\n'
exit "$status"
