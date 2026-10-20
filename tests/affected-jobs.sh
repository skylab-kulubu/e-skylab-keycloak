#!/usr/bin/env bash
# Affected tests for ci.yml's fast runs. Reads changed paths (one per line, relative to the
# repository root) on stdin and prints the jobs of the whole suite (JOB_ENTRIES) a fast run must
# also run, as " job job " (leading and trailing space, for contains() in ci.yml).
#
# A job reaches its entry scripts and, transitively, every tests/ and config/ path they read or
# run on a code line (comment lines do not count): $SCRIPT_DIR/x (the file's own directory),
# tests/x, config/x, $CONFIG_DIR/x, /opt/keycloak/config/x, /opt/keycloak/sky-config/x,
# $IN_CONTAINER_CONFIG/x, ./x in a Compose file, and EXTRA_EDGES (calls no pattern sees); the
# harness's Playwright specs under theme/tests/ count too (a theme/ path is never unknown). A named
# directory covers every path under it; binding the whole config/ directory is not reading it.
# A changed tests/ or config/ path runs every whole-suite job that reaches it. A path no job of any
# workflow reaches (and not in LOCAL_ONLY) runs every whole-suite job: unknown means everything.
# Scripts the static job runs are tested in every run and do not lead into the whole suite.
# tests/check-fresh-runner.sh keeps these lists equal to the workflows and requires every tracked
# tests/ and config/ file to be reached or listed in LOCAL_ONLY (--unreached).
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPOSITORY_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)

# The scripts ci.yml's static job runs in every run, fast or full.
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

# The whole suite: job, then the tests/ scripts its steps run (less STATIC_SCRIPTS).
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

# Every other ci.yml job that runs tests/ scripts: the fast set's jobs (they run in a fast run
# whenever their area changes), and mode and gate (every run; the finder of a tree's full run).
# Job, then scripts.
FAST_ENTRIES=(
  'mode tests/find-green-full-ci-run.sh'
  'sandbox-site-clients tests/sandbox-site-clients.sh'
  'place-client tests/place-client.sh'
  'forms-skymail-grants tests/forms-skymail-grants.sh'
  'fill-missing-primary-from-school tests/fill-missing-primary-from-school.sh'
  'login-by-email-code tests/login-by-email-code.sh'
  'email-code-persistent-counter tests/existing-account-counter.sh tests/login-code-persistent.sh'
  'microsoft-reauthentication tests/microsoft-reauthentication.sh'
  'sign-up-by-email-code tests/sign-up-by-email-code.sh'
  'existing-account-link tests/existing-account-link.sh'
  'welcome-page tests/welcome-page.sh'
  'gate tests/find-green-full-ci-run.sh'
)

# Scripts other workflows run that no ci.yml job runs (release.yml).
OTHER_SCRIPTS=(
  tests/check-physical-webauthn-release.sh
)

# Calls no pattern sees, from the test that makes them: tests/role-groups.sh runs the operator
# steps KEYCLOAK_RECONCILE_ONLY=role-groups and leader-app-roles (the reconciler execs
# "$CONFIG_DIR/$RECONCILE_ONLY.sh") and its scripts as "$IN_CONTAINER_CONFIG/$script";
# tests/login-clients.sh runs operator scripts as "/tmp/config/$script".
EXTRA_EDGES=(
  'tests/role-groups.sh config/role-groups.sh config/leader-app-roles.sh'
  'tests/login-clients.sh config/inscribed-cms-roles.sh config/sandbox-site-clients.sh config/site-clients.sh config/skyapp-cms-editor.sh'
)

# Tracked files no workflow runs: local acceptance only (docs/sudo-email-code-test-plan.md) and
# this script (ci.yml's scope runs it; static checks it through check-fresh-runner.sh).
LOCAL_ONLY=(
  tests/sudo-email-code.sh
  tests/sudo-email-code-clock.mjs
  tests/fixtures/SudoEmailClockProbe.java
  tests/affected-jobs.sh
)

case ${1:-} in
  --entries) printf '%s\n' "${JOB_ENTRIES[@]}"; exit 0 ;;
  --fast) printf '%s\n' "${FAST_ENTRIES[@]}"; exit 0 ;;
  --static) printf '%s\n' "${STATIC_SCRIPTS[@]}"; exit 0 ;;
  --other) printf '%s\n' ${OTHER_SCRIPTS[@]+"${OTHER_SCRIPTS[@]}"}; exit 0 ;;
  --edges) printf '%s\n' ${EXTRA_EDGES[@]+"${EXTRA_EDGES[@]}"}; exit 0 ;;
esac

# references FILE: the tests/ and config/ paths FILE reads or runs, one per line. The harness runs
# Playwright from theme/, so a tests/x that exists only as theme/tests/x is that file.
references() {
  local reference
  raw_references "$1" | while IFS= read -r reference; do
    if [[ ! -e $REPOSITORY_ROOT/$reference && -e $REPOSITORY_ROOT/theme/$reference ]]; then
      reference=theme/$reference
    fi
    printf '%s\n' "$reference"
  done
  return 0
}

# code_lines FILE: FILE without its comment lines (# in shell, YAML and the like; //, /* and *
# in Java, JavaScript and TypeScript).
code_lines() {
  case $1 in
    *.java | *.js | *.mjs | *.ts) grep -vE '^[[:space:]]*(//|/\*|\*)' "$REPOSITORY_ROOT/$1" || true ;;
    *) grep -v '^[[:space:]]*#' "$REPOSITORY_ROOT/$1" || true ;;
  esac
}

raw_references() {
  local file=$1 directory
  directory=$(dirname -- "$file")
  [[ -f $REPOSITORY_ROOT/$file ]] || return 0
  code_lines "$file" \
    | grep -oE '(\$SCRIPT_DIR|\$\{SCRIPT_DIR\}|\$CONFIG_DIR|\$\{CONFIG_DIR\}|\$IN_CONTAINER_CONFIG|\$\{IN_CONTAINER_CONFIG\}|tests|config)/[A-Za-z0-9_][A-Za-z0-9_./-]*' \
    | sed -E "s#^(\\\$SCRIPT_DIR|\\\$\\{SCRIPT_DIR\\})/#$directory/#; s#^(\\\$CONFIG_DIR|\\\$\\{CONFIG_DIR\\}|\\\$IN_CONTAINER_CONFIG|\\\$\\{IN_CONTAINER_CONFIG\\})/#config/#; s#[./]+\$##" \
    | grep -Ev '/\.\.(/|$)' || true
  if [[ $file == *.yml ]]; then
    code_lines "$file" \
      | grep -oE '\./[A-Za-z0-9_][A-Za-z0-9_./-]*' \
      | sed -E "s#^\\./#$directory/#; s#[./]+\$##" || true
  fi
  local edge
  for edge in ${EXTRA_EDGES[@]+"${EXTRA_EDGES[@]}"}; do
    read -r -a words <<<"$edge"
    [[ ${words[0]} == "$file" ]] && printf '%s\n' "${words[@]:1}"
  done
  return 0
}

# closure STOP ENTRY...: the entries and every path they reach, one per line; paths in STOP (a
# space-delimited list) are neither listed nor followed.
closure() {
  local seen=$1 queue path reference
  shift
  queue=("$@")
  while ((${#queue[@]})); do
    path=${queue[0]}
    queue=("${queue[@]:1}")
    [[ $seen == *" $path "* ]] && continue
    seen="$seen$path "
    printf '%s\n' "$path"
    while IFS= read -r reference; do
      if [[ -n $reference && $seen != *" $reference "* ]]; then
        queue+=("$reference")
      fi
    done < <(references "$path")
  done
  return 0
}

# covers LIST PATH: true when PATH is in LIST (one per line) or under a directory in it.
covers() {
  local covered
  while IFS= read -r covered; do
    [[ -n $covered && ( $2 == "$covered" || $2 == "$covered"/* ) ]] && return 0
  done <<<"$1"
  return 1
}

static=" ${STATIC_SCRIPTS[*]} "
words_first() {
  local entry
  for entry in "$@"; do
    printf '%s ' "${entry%% *}"
  done
}
words_after_first() {
  local entry words
  for entry in "$@"; do
    read -r -a words <<<"$entry"
    printf '%s\n' "${words[@]:1}"
  done
}
# Everything any workflow reaches, static scripts followed.
mapfile_reached() {
  # shellcheck disable=SC2046
  closure ' ' "${STATIC_SCRIPTS[@]}" "${OTHER_SCRIPTS[@]}" \
    $(words_after_first "${FAST_ENTRIES[@]}" "${JOB_ENTRIES[@]}")
}

if [[ ${1:-} == --reached ]]; then
  mapfile_reached
  exit 0
fi
if [[ ${1:-} == --unreached ]]; then
  reached=$(mapfile_reached)
  local_only=$(printf '%s\n' "${LOCAL_ONLY[@]}")
  while IFS= read -r path; do
    [[ -n $path ]] || continue
    covers "$reached" "$path" || covers "$local_only" "$path" || printf '%s\n' "$path"
  done < <(git -C "$REPOSITORY_ROOT" ls-files -- tests config)
  exit 0
fi

job_reach=()
for entry in "${JOB_ENTRIES[@]}"; do
  read -r -a words <<<"$entry"
  job_reach+=("$(closure "$static" "${words[@]:1}")")
done
reached=''
local_only=$(printf '%s\n' "${LOCAL_ONLY[@]}")
everything=" $(words_first "${JOB_ENTRIES[@]}") "

# affected_by PATH: the whole-suite jobs PATH runs, space-delimited (empty when none).
affected_by() {
  local path=$1 index jobs=''
  [[ $path == tests/* || $path == config/* || $path == theme/tests/* ]] || return 0
  for index in "${!JOB_ENTRIES[@]}"; do
    if covers "${job_reach[$index]}" "$path"; then
      jobs="$jobs${JOB_ENTRIES[$index]%% *} "
    fi
  done
  if [[ -z $jobs && $path != theme/* ]]; then
    [[ -n $reached ]] || reached=$(mapfile_reached)
    if ! covers "$reached" "$path" && ! covers "$local_only" "$path"; then
      jobs=$everything
    fi
  fi
  printf '%s' "$jobs"
}

# --each: one line per changed path, "path: job job" (check-fresh-runner.sh's samples).
if [[ ${1:-} == --each ]]; then
  while IFS= read -r path; do
    [[ -n $path ]] && printf '%s: %s\n' "$path" "$(affected_by "$path")"
  done
  exit 0
fi

affected=' '
while IFS= read -r path; do
  [[ -n $path ]] || continue
  for job in $(affected_by "$path"); do
    [[ $affected == *" $job "* ]] || affected="$affected$job "
  done
done
printf '%s\n' "$affected"
