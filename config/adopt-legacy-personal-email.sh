#!/usr/bin/env bash
# One-off, idempotent operator script for A1c: a legacy primary becomes the Personal e-mail.
#
# A legacy primary is a Keycloak email set before v2 that is neither the School e-mail
# (schoolEmail, case-insensitively) nor a Personal e-mail: the person has no personalEmail at all.
# When Keycloak had already verified it by link (emailVerified=true) this script records it as
# the person's Personal e-mail exactly as sky-account's email/confirm does, through the same Java
# code (com.skylab.account.PersonalEmailProof in the SKY LAB SPI of this image):
#   personalEmail           = the address, trimmed and lowercased (Locale.ROOT)
#   personalEmailVerifiedAt = the moment of the write, ISO-8601 UTC in whole seconds
# Keycloak email and emailVerified are left as they are, so the address stays the Primary e-mail
# and GET identity reads primary=personal. Nothing else on the account changes.
#
# Never adopted, only counted:
#   - an unverified legacy primary: the person proves it with the code on my./email (K3c flow);
#   - an address on yildiz.edu.tr or any of its subdomains: a school address is not personal;
#   - an address another person already holds (as email, schoolEmail or personalEmail), or that
#     would become the Personal e-mail of two people: both are skipped for a manual decision;
#   - service accounts.
# A second run finds nothing to adopt and writes nothing.
#
# Usage (inside the Keycloak image, as an operator):
#   adopt-legacy-personal-email.sh --admin-user <admin>            # dry run (default): counts only
#   adopt-legacy-personal-email.sh --admin-user <admin> --apply    # writes
#
# The output is counts only: never an address, a username or an id. The administrator password
# is typed into kcadm's own prompt and never passes through this script. Environment:
# KEYCLOAK_ADMIN_URL (default http://keycloak:8080), KEYCLOAK_REALM (default e-skylab),
# KEYCLOAK_ADMIN_REALM (default master), KEYCLOAK_LEGACY_EMAIL_ADMIN_USERNAME (or --admin-user).
# KEYCLOAK_LEGACY_EMAIL_ADMIN_PASSWORD is accepted only together with SKY_HARNESS=1 (the
# integration harness); anywhere else the script refuses it, because kcadm would receive the
# password on its command line.
set -Eeuo pipefail
shopt -s inherit_errexit

umask 077

KCADM=${KCADM_BIN:-/opt/keycloak/bin/kcadm.sh}
JAVA_BIN=${JAVA_BIN:-java}
KEYCLOAK_LIB_DIR=${KEYCLOAK_LIB_DIR:-/opt/keycloak/lib/lib/main}
KEYCLOAK_PROVIDERS_DIR=${KEYCLOAK_PROVIDERS_DIR:-/opt/keycloak/providers}
ADMIN_URL=${KEYCLOAK_ADMIN_URL:-http://keycloak:8080}
ADMIN_REALM=${KEYCLOAK_ADMIN_REALM:-master}
TARGET_REALM=${KEYCLOAK_REALM:-e-skylab}
ADMIN_USER=${KEYCLOAK_LEGACY_EMAIL_ADMIN_USERNAME:-}
ADOPTION_CLASS=com.skylab.account.LegacyPersonalEmailAdoption
PAGE_SIZE=100
# Every file below holds addresses and ids; the directory is private (umask) and removed on exit.
WORK_DIR=$(mktemp -d /tmp/adopt-legacy-personal-email.XXXXXX)
KCADM_CONFIG="$WORK_DIR/kcadm.config"
MODE=dry-run

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

usage() {
  printf 'usage: %s --admin-user <administrator> [--apply]\n' "${BASH_SOURCE[0]##*/}" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --admin-user)
      [[ $# -ge 2 ]] || usage
      ADMIN_USER=$2
      shift 2
      ;;
    --apply)
      MODE=apply
      shift
      ;;
    --dry-run)
      MODE=dry-run
      shift
      ;;
    *)
      usage
      ;;
  esac
done

if [[ -z $ADMIN_USER ]]; then
  if [[ -t 0 ]]; then
    read -r -p "Keycloak administrator username: " ADMIN_USER
  fi
  [[ -n $ADMIN_USER ]] || usage
fi

log() {
  printf '[adopt-legacy-personal-email] %s\n' "$1"
}

kcadm() {
  local command=$1
  shift
  "$KCADM" "$command" --config "$KCADM_CONFIG" "$@"
}

# The selection and the record live in the SKY LAB SPI jar of this image, next to email/confirm,
# and run with the image's JDK and Keycloak's own Jackson libraries: the image has no jq.
spi_jars=("$KEYCLOAK_PROVIDERS_DIR"/e-skylab-spi-*.jar)
if [[ ${#spi_jars[@]} != 1 || ! -f ${spi_jars[0]} ]]; then
  printf 'Expected exactly one SKY LAB SPI jar under %s\n' "$KEYCLOAK_PROVIDERS_DIR" >&2
  exit 1
fi
jackson_jars=("$KEYCLOAK_LIB_DIR"/com.fasterxml.jackson.core.jackson-*.jar)
if [[ ! -f ${jackson_jars[0]} ]]; then
  printf 'Jackson libraries were not found under %s\n' "$KEYCLOAK_LIB_DIR" >&2
  exit 1
fi
classpath=${spi_jars[0]}
for jar in "${jackson_jars[@]}"; do
  classpath="$classpath:$jar"
done

adoption() {
  "$JAVA_BIN" -XX:TieredStopAtLevel=1 -XX:+UseSerialGC -cp "$classpath" "$ADOPTION_CLASS" "$@"
}

# Fails before the login when the image lacks the adoption code (an SPI older than 1.13.2).
if [[ $(adoption count <<<'[]') != 0 ]]; then
  printf 'The SKY LAB SPI of this image cannot run %s; release the Keycloak version that carries it first\n' \
    "$ADOPTION_CLASS" >&2
  exit 1
fi

credential_arguments=(
  --config "$KCADM_CONFIG"
  --server "$ADMIN_URL"
  --realm "$ADMIN_REALM"
  --user "$ADMIN_USER"
)
if [[ -n ${KEYCLOAK_LEGACY_EMAIL_ADMIN_PASSWORD:-} ]]; then
  if [[ ${SKY_HARNESS:-} != 1 ]]; then
    printf 'KEYCLOAK_LEGACY_EMAIL_ADMIN_PASSWORD is accepted only by the test harness (SKY_HARNESS=1); unset it and type the password into the kcadm prompt\n' >&2
    exit 2
  fi
  credential_arguments+=(--password "$KEYCLOAK_LEGACY_EMAIL_ADMIN_PASSWORD")
fi
# No redirection: kcadm asks for the password only when stdout is a terminal ("Console is not
# active" otherwise). Its "Logging into" line goes to stderr, so stdout stays clean either way.
"$KCADM" config credentials "${credential_arguments[@]}"
log "realm=$TARGET_REALM mode=$MODE"

# Reads every user of the realm (full representations, attributes included) into $1/page-*.json.
scan_users() {
  local directory=$1 first=0 page count
  mkdir -p "$directory"
  while :; do
    page="$directory/page-$first.json"
    if ! kcadm get users -r "$TARGET_REALM" \
      -q "first=$first" \
      -q "max=$PAGE_SIZE" \
      -q briefRepresentation=false >"$page" 2>"$WORK_DIR/scan.stderr"; then
      cat "$WORK_DIR/scan.stderr" >&2
      printf 'Failed to read the users of realm %s\n' "$TARGET_REALM" >&2
      return 1
    fi
    count=$(adoption count <"$page")
    if (( count < PAGE_SIZE )); then
      return 0
    fi
    first=$((first + PAGE_SIZE))
  done
}

# Plans from a scan: writes "id<TAB>address" per adoption to $2 and sets the counts below.
plan_adoptions() {
  local directory=$1 adoptions=$2 counts line pair
  counts=$(adoption plan "$adoptions" "$directory"/page-*.json)
  scanned='' service_accounts='' legacy='' adopt='' unverified='' school_domain='' duplicate='' taken=''
  for line in $counts; do
    pair=${line%%=*}
    case $pair in
      scanned) scanned=${line#*=} ;;
      serviceAccounts) service_accounts=${line#*=} ;;
      legacyPrimaries) legacy=${line#*=} ;;
      adopt) adopt=${line#*=} ;;
      unverified) unverified=${line#*=} ;;
      schoolDomain) school_domain=${line#*=} ;;
      duplicate) duplicate=${line#*=} ;;
      taken) taken=${line#*=} ;;
    esac
  done
  [[ -n $scanned && -n $adopt && -n $taken ]] || {
    printf 'The adoption plan could not be read\n' >&2
    return 1
  }
}

report_plan() {
  log "users scanned=$scanned (service accounts skipped=$service_accounts) legacyPrimaries=$legacy"
  log "legacy primaries: adopt=$adopt unverified=$unverified schoolDomain=$school_domain duplicate=$duplicate taken=$taken"
}

scan_users "$WORK_DIR/before"
plan_adoptions "$WORK_DIR/before" "$WORK_DIR/adoptions.tsv"
report_plan
planned=$adopt

applied=0
failed=0
changed=0
if [[ $MODE == apply ]]; then
  while IFS=$'\t' read -r user_id address; do
    [[ -n $user_id && -n $address ]] || continue
    # Read again right before the write: the account is adopted only if it still has this
    # verified legacy primary. kcadm's error text would name the user, so only counts are kept.
    if ! kcadm get "users/$user_id" -r "$TARGET_REALM" >"$WORK_DIR/user.json" 2>/dev/null; then
      failed=$((failed + 1))
      continue
    fi
    status=0
    adoption adopt "$address" <"$WORK_DIR/user.json" >"$WORK_DIR/adopted.json" 2>/dev/null || status=$?
    if [[ $status == 3 ]]; then
      changed=$((changed + 1))
      continue
    elif [[ $status != 0 ]]; then
      failed=$((failed + 1))
      continue
    fi
    if kcadm update "users/$user_id" -r "$TARGET_REALM" -n -f "$WORK_DIR/adopted.json" >/dev/null 2>&1; then
      applied=$((applied + 1))
    else
      failed=$((failed + 1))
    fi
  done <"$WORK_DIR/adoptions.tsv"
  rm -f "$WORK_DIR/user.json" "$WORK_DIR/adopted.json"

  # Read back: every adoption must have persisted, so a new scan finds nothing left to adopt.
  scan_users "$WORK_DIR/after"
  plan_adoptions "$WORK_DIR/after" "$WORK_DIR/adoptions-after.tsv"
  log "applied $applied adoption(s); failed=$failed changedSinceScan=$changed"
  log "after: legacy primaries still to adopt=$adopt"
fi

if (( unverified > 0 )); then
  log "$unverified unverified legacy primary address(es) stay as they are; the person proves them with the code on my./email"
fi
if (( duplicate + taken > 0 )); then
  log "$((duplicate + taken)) legacy primary address(es) were skipped because another person holds the address or would get it too; they need a manual decision"
fi
if [[ $MODE == apply ]]; then
  if (( failed > 0 || adopt > 0 )); then
    printf 'The adoption is incomplete: %s write(s) failed and %s verified legacy primary address(es) are still to adopt. Check that the administrator holds manage-users for realm %s and rerun with --apply; adopted accounts are not written again.\n' \
      "$failed" "$adopt" "$TARGET_REALM" >&2
    exit 1
  fi
else
  log "dry run: $planned adoption(s) pending; rerun with --apply to execute them"
fi
