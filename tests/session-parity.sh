# shellcheck shell=bash
# Sourced by the stand-alone tests that run operator scripts inside a Keycloak container
# (tests/role-groups.sh, dk-read-only.sh, master-console.sh, site-clients.sh, inscribed-cms-roles.sh,
# skyapp-cms-editor.sh, sandbox-admin-local-client.sh, sandbox-site-clients.sh, place-client.sh,
# forms-skymail-grants.sh): a whole run of a script with a JVM per kcadm and ReconcileJson call
# (KEYCLOAK_RECONCILE_SESSION=off) and with the reconciliation session (required;
# config/reconcile-session.sh) must print the same bytes, in the same order, and end with the same
# status: the release wizards read these lines. The test runs its container with
# KEYCLOAK_RECONCILE_SESSION=required, so that every other run of a script uses the session too (and a
# session that cannot start stops it); a run with KCADM_BIN (an injected kcadm failure) keeps a JVM
# per call.
#
# Needs CONTAINER (the test's container), fail and SESSION_PARITY_DIR (a directory of the host the
# test removes).
#
#   session_parity LABEL SETUP EXEC_OPTION... -- COMMAND...
# runs COMMAND in the container (docker exec with the options) once with off and once with required,
# SETUP (a function of the test, or :) before each run: a run that writes gets the same drift both
# times. The two logs hold stdout and stderr as one stream, merged inside the container in the order
# written, and a last line "exit STATUS"; their bytes must be equal. Prints both times and the status;
# SESSION_PARITY_LOG is the log of the run with the session.

SESSION_PARITY_COUNT=0
SESSION_PARITY_LOG=''

# session_files_to_tmp: the session's two files into the container's /tmp, for a test that copies the
# scripts it runs there one by one (a script finds its session next to it; one copied alone has none
# and keeps a JVM per call). Needs REPOSITORY_ROOT.
session_files_to_tmp() {
  docker exec -i "$CONTAINER" sh -c 'cat > /tmp/reconcile-session.sh' <"$REPOSITORY_ROOT/config/reconcile-session.sh"
  docker exec -i "$CONTAINER" sh -c 'cat > /tmp/ReconcileSession.java' <"$REPOSITORY_ROOT/config/ReconcileSession.java"
}

# session_parity_run MODE LOG EXEC_OPTION... -- COMMAND...: one run; SESSION_PARITY_SECONDS its time.
session_parity_run() {
  local mode=$1 log=$2 started=$SECONDS options=()
  shift 2
  while [[ $1 != -- ]]; do
    options+=("$1")
    shift
  done
  shift
  docker exec ${options[@]+"${options[@]}"} -e "KEYCLOAK_RECONCILE_SESSION=$mode" "$CONTAINER" \
    bash -c '"$@" 2>&1; printf "exit %s\n" "$?"' session-parity "$@" >"$log" \
    || fail "docker exec of the session parity run ($mode) failed"
  SESSION_PARITY_SECONDS=$((SECONDS - started))
}

session_parity() {
  local label=$1 setup=$2 off on off_seconds
  shift 2
  SESSION_PARITY_COUNT=$((SESSION_PARITY_COUNT + 1))
  off="$SESSION_PARITY_DIR/parity-$SESSION_PARITY_COUNT-off.log"
  on="$SESSION_PARITY_DIR/parity-$SESSION_PARITY_COUNT-session.log"
  "$setup"
  session_parity_run off "$off" "$@"
  off_seconds=$SESSION_PARITY_SECONDS
  "$setup"
  session_parity_run required "$on" "$@"
  if ! cmp -s "$off" "$on"; then
    diff "$off" "$on" >&2 || true
    fail "$label printed other bytes with the reconciliation session than with a JVM per call"
  fi
  SESSION_PARITY_LOG=$on
  printf '    session parity: %s: the same %s line(s), %s; %ds with a JVM per call, %ds with the session\n' \
    "$label" "$(($(wc -l <"$on") - 1))" "$(tail -n 1 "$on")" "$off_seconds" "$SESSION_PARITY_SECONDS"
}
