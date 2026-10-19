# shellcheck shell=bash
# Sourced by the test scripts that run kcadm.sh in a Keycloak container.
#
# kcadm.sh starts a JVM for every call, and a test makes hundreds of calls (docker exec), each a
# short CLI run: most of its time is the JVM starting up. kcadm.sh passes KC_OPTS to that JVM (and
# so does kcreg.sh); kc.sh, Keycloak's server, does not read it. C1 alone (no C2 compiler threads
# competing with the server for the runner's cores) and the Serial collector start the CLI faster
# and change nothing it does. KEYCLOAK_TEST_KC_OPTS overrides the options; set to the empty string,
# it turns them off. Production sets no KC_OPTS.
KCADM_JVM_OPTS=${KEYCLOAK_TEST_KC_OPTS--XX:TieredStopAtLevel=1 -XX:+UseSerialGC -Xshare:auto}

# The integration harness (run-integration.sh) also writes an AppCDS archive of kcadm's classes once
# (kcadm_jvm_archive_options dump) into a directory every container of the run mounts, and every
# later kcadm call maps it (kcadm_jvm_archive_options use). A missing or unusable archive (another
# JDK, a half-written file) is ignored without a word: -Xshare:auto, and the CDS log is off, since the
# JVM logs to stdout, where kcadm writes its JSON. Writing the archive is a separate call whose status
# is ignored, because a JVM that cannot write it exits with status 1 after a successful call.
KCADM_JVM_ARCHIVE=/opt/kcadm-cds/kcadm.jsa
kcadm_jvm_archive_options() {
  [[ -n $KCADM_JVM_OPTS ]] || return 0
  case $1 in
    dump) printf '%s -XX:ArchiveClassesAtExit=%s -Xlog:cds=off -Xlog:cds+dynamic=off' "$KCADM_JVM_OPTS" "$KCADM_JVM_ARCHIVE" ;;
    use) printf '%s -XX:SharedArchiveFile=%s -Xlog:cds=off -Xlog:cds+dynamic=off' "$KCADM_JVM_OPTS" "$KCADM_JVM_ARCHIVE" ;;
  esac
}
