#!/usr/bin/env bash
# Prints the id of the newest successful ci.yml run that tested TREE in full, or exits 1.
#
# Evidence is a push, schedule or workflow_dispatch run: those run head_sha's own tree. A
# pull_request run tests GitHub's merge commit, not its head, so it never counts. The run must have
# passed its job "scope (full)" and every other job (a fast run always skips some). Used by ci.yml
# (a pull request into production and a push to production whose tree main already tested in full
# run the fast set) and by release.yml (keycloak-build promotes that run's tested image).
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

runs=$(gh api --paginate -X GET "repos/$repository/actions/workflows/ci.yml/runs" \
  -f status=success -f "created=>=$since" -f per_page=100 \
  --jq '.workflow_runs[] | select(.event == "push" or .event == "schedule" or .event == "workflow_dispatch") | "\(.id) \(.head_sha)"')

while read -r run_id head_sha; do
  [[ $run_id =~ ^[0-9]+$ && $head_sha =~ ^[0-9a-f]{40}$ ]] || continue
  head_tree=$(gh api "repos/$repository/git/commits/$head_sha" --jq .tree.sha)
  [[ $head_tree == "$tree" ]] || continue
  jobs=$(gh api --paginate "repos/$repository/actions/runs/$run_id/jobs?per_page=100" \
    --jq '.jobs[] | "\(.conclusion) \(.name)"')
  if grep -qxF 'success scope (full)' <<<"$jobs" && ! grep -qv '^success ' <<<"$jobs"; then
    printf 'CI run %s (%s) tested tree %s in full; every job passed.\n' "$run_id" "$head_sha" "$tree" >&2
    printf '%s\n' "$run_id"
    exit 0
  fi
done <<<"$runs"

printf 'No fully green full ci.yml run (push, schedule or workflow_dispatch) of tree %s since %s.\n' \
  "$tree" "$since" >&2
exit 1
