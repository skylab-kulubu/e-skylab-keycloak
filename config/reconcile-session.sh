# shellcheck shell=bash
# The reconciliation session (config/ReconcileSession.java): every kcadm read and every ReconcileJson
# call of a run in one JVM. A kcadm.sh call starts a JVM of its own: a whole reconciliation made some
# two hundred of them (about 8.5 minutes in production, 2026-10-27), app-assignments.sh --check two a
# role (18 minutes in production, 2026-10-31). The session runs each call as that JVM's main would,
# and session_call gives back the same bytes on stdout and stderr, in the same order, and the same
# exit status, so every line, warning, dry run line and exit status of a run stays the same (the tests
# compare whole runs both ways: tests/run-integration.sh, tests/role-groups.sh, tests/dk-read-only.sh,
# tests/master-console.sh). Writes (create, update, delete and every other kcadm command) still start
# kcadm.sh, one JVM a call: whether a write reached Keycloak is then never in doubt, and a lost session
# cannot leave a write half sent.
#
# Sourced by config/reconcile-account-center.sh and by the operator scripts that read many times
# (config/app-assignments.sh, role-groups.sh, dk-read-only.sh, master-console.sh, and those of kcadm
# reads alone: site-clients.sh and the others that source this file). Such a script:
#   - sets SESSION_MODE=${KEYCLOAK_RECONCILE_SESSION:-on} at its top and checks it before its login
#     (session_mode_valid): on (the default; a JVM per call when the session cannot start, with one
#     line on stderr), off (a JVM per call: as before, the rollback and the comparison base) or
#     required (on, but the run stops when the session cannot start; the tests). With a KCADM_BIN (the
#     tests' injected kcadm failures) every call keeps its own JVM, whatever SESSION_MODE says;
#   - has KCADM, KCADM_CONFIG, CONFIG_DIR, WORK_DIR (the run's own 0700 directory) and, when it has
#     ReconcileJson, JSON_TOOL_CLASSPATH once it has compiled config/ReconcileJson.java into
#     $WORK_DIR/classes (with config/ReconcileSession.java in the same javac call when session_wanted);
#     a script without ReconcileJson leaves JSON_TOOL_CLASSPATH unset or empty, and start_session
#     compiles config/ReconcileSession.java alone (a session of kcadm reads);
#   - calls start_session once, at its top level after its login and before its reads, sends its kcadm
#     calls through session_kcadm and its ReconcileJson calls to session_call json when
#     session_takes json, and calls stop_session in its EXIT trap.
# SESSION_ERR_FD is the run's own stderr, where session_lost writes (a call's redirection does not
# reach it): the reconciler's CHECK_FD, or a copy start_session opens.

SESSION_DIR=''
SESSION_PID=''
SESSION_FD=''
SESSION_PWD=''
SESSION_ERR_FD=''

# session_mode_valid: whether SESSION_MODE is on, off or required (the error on stderr otherwise).
session_mode_valid() {
  case $SESSION_MODE in
    on | off | required) return 0 ;;
  esac
  printf 'KEYCLOAK_RECONCILE_SESSION must be on (default), off or required, not %s\n' "$SESSION_MODE" >&2
  return 1
}

# Stops the session JVM (start_session), if one runs; the EXIT trap and session_unavailable.
stop_session() {
  if [[ -n $SESSION_FD ]]; then
    exec {SESSION_FD}>&-
    SESSION_FD=''
  fi
  if [[ -n $SESSION_PID ]]; then
    kill "$SESSION_PID" 2>/dev/null || true
    wait "$SESSION_PID" 2>/dev/null || true
    SESSION_PID=''
  fi
}

# Whether this run starts the session (see SESSION_MODE above; a KCADM_BIN is not the image's own
# kcadm.sh, whose classes the session runs).
session_wanted() {
  [[ $SESSION_MODE != off && -z ${KCADM_BIN:-} ]]
}

# session_unavailable REASON: the session does not run; with required, the run stops here. With on,
# one line on stderr says so and every call starts its own JVM (the same output, slower). The line has
# no "[reconcile] " prefix (nor any other script's), so that the lines the release wizards count stay
# the same; it comes before every read and write and is never the last line of a run.
session_unavailable() {
  stop_session
  if [[ $SESSION_MODE == required ]]; then
    printf 'KEYCLOAK_RECONCILE_SESSION=required, but the session cannot start: %s\n' "$1" >&2
    if [[ -s $SESSION_DIR/log ]]; then
      cat -- "$SESSION_DIR/log" >&2
    fi
    exit 1
  fi
  printf 'Reconciliation session not started (%s); every kcadm and ReconcileJson call starts its own JVM (the same output, slower)\n' "$1" >&2
}

# The kcadm versions whose classes the session was checked against (Globals.main, the static state of
# Globals, HttpUtil and FileConfigHandler, the System.exit paths; config/ReconcileSession.java): 26.4
# (a whole dry run compared byte for byte) and 26.7 (the image; the tests compare whole runs). Another
# version runs without the session until it is checked and added here and to the case in
# start_session; the tests (required) stop on it.
SESSION_KCADM_VERSIONS='26.4.* | 26.7.*'

# Starts the session JVM as kcadm.sh starts its own (its java, KC_OPTS, class path and options, with
# the compiled classes after the kcadm jar) and waits until it is ready. kcadm.sh's own launch line
# must be one this function knows; otherwise, or when the session cannot start, every call starts
# its own JVM (SESSION_MODE on) or the run stops (required).
start_session() {
  local kcadm_path kcadm_dir launch jar version java native=() ready_fd line='' waited=0
  if ! session_wanted; then
    return 0
  fi
  SESSION_DIR="$WORK_DIR/session"
  if [[ -z $SESSION_ERR_FD ]]; then
    exec {SESSION_ERR_FD}>&2
  fi
  kcadm_path=$(readlink -f -- "$KCADM")
  kcadm_dir=$(dirname -- "$kcadm_path")
  launch=$(grep -E '^exec "\$JAVA" ' "$kcadm_path" || true)
  # The patterns are kcadm.sh's own line, its variables unexpanded.
  # shellcheck disable=SC2016
  case $launch in
    'exec "$JAVA" $KC_OPTS -cp $DIRNAME/client/keycloak-admin-cli-'*'.jar --add-opens=java.base/java.security=ALL-UNNAMED -Dkc.lib.dir=$DIRNAME/client/lib org.keycloak.client.admin.cli.KcAdmMain "$@"') ;;
    'exec "$JAVA" $KC_OPTS -cp $DIRNAME/client/keycloak-admin-cli-'*'.jar --add-opens=java.base/java.security=ALL-UNNAMED --enable-native-access=ALL-UNNAMED -Dkc.lib.dir=$DIRNAME/client/lib org.keycloak.client.admin.cli.KcAdmMain "$@"')
      native=(--enable-native-access=ALL-UNNAMED)
      ;;
    *)
      session_unavailable "$kcadm_path starts its JVM in a way this script does not know"
      return 0
      ;;
  esac
  # shellcheck disable=SC2016
  jar=${launch#*' -cp $DIRNAME/'}
  jar="$kcadm_dir/${jar%%' '*}"
  if [[ ! -f $jar ]]; then
    session_unavailable "the kcadm jar $jar does not exist"
    return 0
  fi
  version=${jar##*/keycloak-admin-cli-}
  version=${version%.jar}
  case $version in
    26.4.* | 26.7.*) ;;
    *)
      session_unavailable "kcadm $version is not a version the session was checked against ($SESSION_KCADM_VERSIONS)"
      return 0
      ;;
  esac
  if [[ -n ${JAVA:-} ]]; then
    java=$JAVA
  elif [[ -n ${JAVA_HOME:-} ]]; then
    java="$JAVA_HOME/bin/java"
  else
    java=java
  fi
  mkdir "$SESSION_DIR"
  # A script without ReconcileJson: the session's class alone, with the JDK that runs it.
  if [[ ! -f $WORK_DIR/classes/ReconcileSession.class ]]; then
    mkdir -p "$WORK_DIR/classes"
    if ! "$java" -XX:TieredStopAtLevel=1 -XX:+UseSerialGC -m jdk.compiler/com.sun.tools.javac.Main \
      -d "$WORK_DIR/classes" "$CONFIG_DIR/ReconcileSession.java" >"$SESSION_DIR/log" 2>&1; then
      session_unavailable 'config/ReconcileSession.java did not compile'
      return 0
    fi
  fi
  mkfifo "$SESSION_DIR/requests" "$SESSION_DIR/ready"
  exec {SESSION_FD}<>"$SESSION_DIR/requests" {ready_fd}<>"$SESSION_DIR/ready"
  # KC_OPTS is split into options as kcadm.sh splits it. The JVM keeps none of this shell's other
  # files open (SESSION_ERR_FD is this run's stderr).
  # shellcheck disable=SC2086
  "$java" ${KC_OPTS:-} -cp "$jar:$WORK_DIR/classes" --add-opens=java.base/java.security=ALL-UNNAMED "${native[@]}" \
    "-Dkc.lib.dir=$kcadm_dir/client/lib" ReconcileSession "$SESSION_DIR" "${JSON_TOOL_CLASSPATH:-}" \
    </dev/null >"$SESSION_DIR/log" 2>&1 {SESSION_ERR_FD}>&- {SESSION_FD}>&- {ready_fd}>&- &
  SESSION_PID=$!
  until IFS= read -r -t 1 -u "$ready_fd" line; do
    if ! kill -0 "$SESSION_PID" 2>/dev/null || ((++waited >= 120)); then
      break
    fi
  done
  exec {ready_fd}<&-
  if [[ $line != ready ]]; then
    session_unavailable "${line:-the session JVM did not answer}"
    return 0
  fi
  SESSION_PWD=$PWD
  # session_lost stops the run from a command substitution through this signal.
  trap 'exit 1' USR1
}

# session_takes kcadm|json ARG...: whether the session runs this call (status 1: a JVM of its own).
# kcadm's own help ends its JVM (System.exit), -x prints the session's stack, and --v2 is another
# command line; the session takes paths relative to the directory it started in.
session_takes() {
  local tool=$1 argument
  shift
  [[ -n $SESSION_PID && $PWD == "$SESSION_PWD" ]] || return 1
  if [[ $tool == json && -z ${JSON_TOOL_CLASSPATH:-} ]]; then
    return 1
  fi
  if [[ $tool == kcadm ]]; then
    for argument in "$@"; do
      case ${argument,,} in
        --v2 | --help | -h | -x) return 1 ;;
      esac
    done
  fi
  return 0
}

# session_reads_stdin kcadm|json ARG...: whether the call reads stdin (kcadm: -f -; ReconcileJson:
# every sub-command but these three, which read files). Only then does session_call pass it on.
session_reads_stdin() {
  local tool=$1 previous='' argument
  shift
  if [[ $tool == json ]]; then
    case ${1:-} in
      '' | merge | role-groups | app-assignments) return 1 ;;
    esac
    return 0
  fi
  for argument in "$@"; do
    if [[ $argument == --file=- ]] || [[ $argument == - && ( $previous == -f || $previous == --file ) ]]; then
      return 0
    fi
    previous=$argument
  done
  return 1
}

# session_guard: after session_lost the run is ending (its own shell exits at once, or at the end of
# the command substitution it waits for); a call from a subshell that is still running then sends
# nothing, read or write, and that subshell ends too (status 1, no more output: the reason stays the
# run's last line).
session_guard() {
  if [[ -n $SESSION_DIR && -e $SESSION_DIR/lost ]]; then
    exit 1
  fi
}

# session_kcadm COMMAND ARG...: kcadm COMMAND --config KCADM_CONFIG ARG...: a read (get) in the session
# when it runs, anything else (and every call without the session) in kcadm.sh's own JVM.
session_kcadm() {
  local command=$1
  shift
  session_guard
  if [[ $command == get ]] && session_takes kcadm "$@"; then
    session_call kcadm "$command" --config "$KCADM_CONFIG" "$@"
    return
  fi
  "$KCADM" "$command" --config "$KCADM_CONFIG" "$@"
}

# session_call kcadm|json ARG...: runs the call in the session (protocol: config/ReconcileSession.java),
# then prints what it printed (each segment on stdout or stderr, in order) and returns its status.
session_call() {
  local tool=$1 request done_fd status='' segment
  shift
  session_guard
  kill -0 "$SESSION_PID" 2>/dev/null || session_lost 'the session JVM is gone'
  # A call written in part (a full disk) is never sent.
  request=$(mktemp -d "$SESSION_DIR/call.XXXXXX") || session_lost 'the call directory could not be made'
  if (($#)); then
    printf '%s\0' "$@" >"$request/args" || session_lost 'the arguments could not be written'
  else
    : >"$request/args" || session_lost 'the arguments could not be written'
  fi
  if session_reads_stdin "$tool" "$@"; then
    cat >"$request/stdin" || session_lost 'stdin could not be written'
  fi
  mkfifo "$request/done" || session_lost 'mkfifo failed'
  exec {done_fd}<>"$request/done"
  printf '%s %s\n' "$tool" "$request" >&"$SESSION_FD"
  until IFS= read -r -t 1 -u "$done_fd" status; do
    kill -0 "$SESSION_PID" 2>/dev/null || session_lost 'the session JVM exited during the call'
  done
  exec {done_fd}<&-
  [[ $status =~ ^[0-9]+$ ]] || session_lost "$status"
  for segment in "$request"/[0-9]*; do
    case $segment in
      *.o) cat -- "$segment" ;;
      *.e) cat -- "$segment" >&2 ;;
    esac
  done
  rm -rf -- "$request"
  return "$status"
}

# session_lost REASON: the session can no longer answer; whether its last call reached Keycloak is
# not known, so nothing more is sent (session_guard) and the run stops (status 1), from a command
# substitution too. It writes on the run's own stderr (SESSION_ERR_FD), which a call's redirection
# does not reach: the session JVM's log first, then the reason as the run's last line (the release
# wizards show it).
session_lost() {
  : >"$SESSION_DIR/lost" 2>/dev/null || true
  {
    printf 'Reconciliation session log:\n'
    cat -- "$SESSION_DIR/log" || true
    printf 'The reconciliation session stopped during a kcadm or ReconcileJson call (%s); the run stops here. KEYCLOAK_RECONCILE_SESSION=off runs it without the session.\n' "$1"
  } >&"$SESSION_ERR_FD"
  if [[ $BASHPID != "$$" ]]; then
    kill -USR1 "$$" 2>/dev/null || true
  fi
  exit 1
}
