#!/usr/bin/env bash
# Reads changed paths (one per line, relative to the repository root) on stdin and prints the
# ci.yml jobs of the whole suite whose own tests read one of them, as " job job " (leading and
# trailing space, for contains() in ci.yml). A job reads its entry scripts below and, transitively,
# every tests/ path they name ($SCRIPT_DIR/x, ${SCRIPT_DIR}/x, $REPOSITORY_ROOT/tests/x, tests/x, and
# ./x in a Compose file;
# comments included, so a mention errs on the side of running). A named directory covers every
# path under it. ci.yml's scope runs this in a fast run (a pull request into main), so a change to
# a job's harness runs that job there too; integration-group stands for all four groups.
# tests/check-fresh-runner.sh keeps JOB_ENTRIES equal to the scripts ci.yml's jobs run.
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPOSITORY_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)

# The scripts ci.yml's static job runs in every run, fast or full: a change to them is tested
# there, so they neither count as a job's own tests nor lead further.
STATIC_SCRIPTS=(
  tests/check-version-consistency.sh
  tests/check-fresh-runner.sh
  tests/check-theme-contract.sh
  tests/check-welcome-theme.sh
  tests/check-production-preflight.sh
  tests/check-account-center-origin.sh
  tests/check-operator-login-prompts.sh
  tests/check-site-editor-grants-team.sh
)

# job, then the tests/ scripts its steps run (less STATIC_SCRIPTS).
JOB_ENTRIES=(
  'inscribed-cms-roles tests/inscribed-cms-roles.sh'
  'role-groups tests/role-groups.sh'
  'dk-read-only tests/dk-read-only.sh'
  'sandbox-admin-local-client tests/sandbox-admin-local-client.sh'
  'ytu-first-login tests/ytu-first-login.sh'
  'after-sign-up-native tests/after-sign-up.sh'
  'site-clients tests/site-clients.sh'
  'skyapp-cms-editor tests/skyapp-cms-editor.sh'
  'login-clients tests/login-clients.sh'
  'integration-group tests/run-integration.sh'
)

case ${1:-} in
  --entries) printf '%s\n' "${JOB_ENTRIES[@]}"; exit 0 ;;
  --static) printf '%s\n' "${STATIC_SCRIPTS[@]}"; exit 0 ;;
esac
static=" ${STATIC_SCRIPTS[*]} "

# references FILE: the tests/ paths FILE names, one per line.
references() {
  grep -oE '(\$SCRIPT_DIR|\$\{SCRIPT_DIR\}|\$REPOSITORY_ROOT/tests|\$\{REPOSITORY_ROOT\}/tests|tests)/[A-Za-z0-9_./-]+' \
    "$REPOSITORY_ROOT/$1" 2>/dev/null \
    | sed -E 's#^(\$SCRIPT_DIR|\$\{SCRIPT_DIR\}|\$REPOSITORY_ROOT/tests|\$\{REPOSITORY_ROOT\}/tests|tests)/#tests/#; s#[./]+$##' \
    | grep -Ev '^tests(/\.\.?)?$|/\.\.(/|$)' || true
  # A Compose file names its files relative to itself (./fixture-realm.json).
  if [[ $1 == *.yml ]]; then
    grep -oE '\./[A-Za-z0-9_][A-Za-z0-9_./-]*' "$REPOSITORY_ROOT/$1" 2>/dev/null \
      | sed -E "s#^\./#$(dirname -- "$1")/#; s#[./]+\$##" || true
  fi
  return 0
}

# closure ENTRY...: the entry scripts and every tests/ path they reach, one per line.
closure() {
  local seen="$static" queue=("$@") path reference
  while ((${#queue[@]})); do
    path=${queue[0]}
    queue=("${queue[@]:1}")
    [[ $seen == *" $path "* ]] && continue
    seen="$seen$path "
    printf '%s\n' "$path"
    if [[ -f $REPOSITORY_ROOT/$path ]]; then
      while IFS= read -r reference; do
        if [[ -n $reference && $seen != *" $reference "* ]]; then
          queue+=("$reference")
        fi
      done < <(references "$path")
    fi
  done
  return 0
}

changed=$(cat)
affected=' '
for entry in "${JOB_ENTRIES[@]}"; do
  read -r -a words <<<"$entry"
  job=${words[0]}
  reached=$(closure "${words[@]:1}")
  while IFS= read -r path; do
    [[ -n $path ]] || continue
    while IFS= read -r covered; do
      if [[ $path == "$covered" || $path == "$covered"/* ]]; then
        affected="$affected$job "
        continue 3
      fi
    done <<<"$reached"
  done <<<"$changed"
done
printf '%s\n' "$affected"
