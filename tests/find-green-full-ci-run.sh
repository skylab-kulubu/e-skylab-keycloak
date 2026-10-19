#!/usr/bin/env bash
# Prints the id of the newest successful ci.yml run that tested TREE in full, or exits 1.
#
# Evidence is a push, schedule or workflow_dispatch run: those run head_sha's own tree. A
# pull_request run tests GitHub's merge commit, not its head, so it never counts. The run must have
# passed its job "scope (full)" and every other job (a fast run always skips some). Used by ci.yml
# (a pull request into production and a push to production whose tree main already tested in full
# run the fast set) and by release.yml (keycloak-build promotes that run's tested image).
#
# The run's artifacts must still exist: keycloak-ci-candidate and a keycloak-ci-tested-<group>
# receipt for every group of tests/run-integration.sh (this tree's list), none expired; a run
# whose candidate has expired is no evidence (the release could not promote it).
#
# Needs GH_TOKEN (actions: read) and GITHUB_REPOSITORY. CI_EVIDENCE_DAYS (default 14, the
# retention of ci.yml's candidate artifact) bounds the search.
set -Eeuo pipefail

tree=${1:-}
if [[ ! $tree =~ ^[0-9a-f]{40}$ ]]; then
  printf 'usage: %s TREE (a 40-hex git tree id)\n' "$0" >&2
  exit 2
fi
repository=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY names the repository}
days=${CI_EVIDENCE_DAYS:-14}
[[ $days =~ ^[0-9]+$ ]] || { printf 'CI_EVIDENCE_DAYS must be a number\n' >&2; exit 2; }
# GNU date on the runners; BSD date (macOS) for a local check.
since=$(date -u -d "$days days ago" +%Y-%m-%d 2>/dev/null || date -u -v-"$days"d +%Y-%m-%d)

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
groups=$(sed -n 's/^INTEGRATION_GROUPS=(\([^)]*\))$/\1/p' "$SCRIPT_DIR/run-integration.sh")
read -r -a group_list <<<"$groups"
if [[ ${#group_list[@]} -eq 0 ]]; then
  printf 'tests/run-integration.sh lists no INTEGRATION_GROUPS.\n' >&2
  exit 2
fi
required_artifacts=(keycloak-ci-candidate)
for group in "${group_list[@]}"; do
  required_artifacts+=("keycloak-ci-tested-$group")
done

runs=$(gh api --paginate -X GET "repos/$repository/actions/workflows/ci.yml/runs" \
  -f status=success -f "created=>=$since" -f per_page=100 \
  --jq '.workflow_runs[] | select(.event == "push" or .event == "schedule" or .event == "workflow_dispatch") | "\(.id) \(.head_sha)"')

# head_sha -> tree, as "sha:tree " (a nightly run repeats main's head; bash 3.2 has no maps).
tree_cache=' '
while read -r run_id head_sha; do
  [[ $run_id =~ ^[0-9]+$ && $head_sha =~ ^[0-9a-f]{40}$ ]] || continue
  if [[ $tree_cache == *" $head_sha:"* ]]; then
    head_tree=${tree_cache#* "$head_sha":}
    head_tree=${head_tree%% *}
  else
    head_tree=$(gh api "repos/$repository/git/commits/$head_sha" --jq .tree.sha)
    tree_cache="$tree_cache$head_sha:$head_tree "
  fi
  [[ $head_tree == "$tree" ]] || continue
  jobs=$(gh api --paginate "repos/$repository/actions/runs/$run_id/jobs?per_page=100" \
    --jq '.jobs[] | "\(.conclusion) \(.name)"')
  grep -qxF 'success scope (full)' <<<"$jobs" && ! grep -qv '^success ' <<<"$jobs" || continue
  live=$(gh api --paginate "repos/$repository/actions/runs/$run_id/artifacts?per_page=100" \
    --jq '.artifacts[] | select(.expired == false) | .name')
  missing=''
  for artifact in "${required_artifacts[@]}"; do
    grep -qxF "$artifact" <<<"$live" || missing="$missing $artifact"
  done
  if [[ -n $missing ]]; then
    printf 'CI run %s tested tree %s in full, but its artifacts are gone:%s\n' "$run_id" "$tree" "$missing" >&2
    continue
  fi
  printf 'CI run %s (%s) tested tree %s in full; every job passed.\n' "$run_id" "$head_sha" "$tree" >&2
  printf '%s\n' "$run_id"
  exit 0
done <<<"$runs"

printf 'No fully green full ci.yml run (push, schedule or workflow_dispatch) of tree %s since %s.\n' \
  "$tree" "$since" >&2
exit 1
