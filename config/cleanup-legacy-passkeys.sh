#!/usr/bin/env bash
# Deletes passwordless WebAuthn credentials that were registered before the relying party id
# switched to yildizskylab.com. Such passkeys are bound to the old relying party id and can
# never verify again, so removing them keeps the login page from offering dead passkeys.
#
# The cutover is the moment the reconciler changed the relying party id. The reconciler records
# it in the realm attribute skylab.passkeyRpIdSwitchedAt (ISO-8601 UTC) and this script uses it
# by default. An explicit --cutover may only be equal to or earlier than the recorded moment: a
# later cutover would delete passkeys registered after the switch, which are valid.
#
# Usage (inside the Keycloak image, after the reconciler has applied the new relying party id):
#   cleanup-legacy-passkeys.sh                                        # dry run (default)
#   cleanup-legacy-passkeys.sh --apply                                # deletes
#   cleanup-legacy-passkeys.sh --cutover 2026-10-01T00:00:00Z [--apply]   # earlier cutover only
#
# Environment:
#   KEYCLOAK_ADMIN_URL               Keycloak base URL (default http://keycloak:8080)
#   KEYCLOAK_REALM                   target realm (default e-skylab)
#   KEYCLOAK_ADMIN_REALM             realm of the administrator (default master)
#   KEYCLOAK_CLEANUP_ADMIN_USERNAME  administrator with view-users/manage-users (required)
#   KEYCLOAK_CLEANUP_ADMIN_PASSWORD  accepted only with SKY_HARNESS=1 (test harness); in
#                                    production kcadm prompts for the password on its own
#                                    terminal so it never appears in argv or process lists
#
# The script prints counts only: no usernames, no credential ids, no secrets. Deletions that
# fail are counted, the summary is still printed and the exit status is non-zero at the end.
set -Eeuo pipefail
shopt -s inherit_errexit

umask 077

KCADM=${KCADM_BIN:-/opt/keycloak/bin/kcadm.sh}
ADMIN_URL=${KEYCLOAK_ADMIN_URL:-http://keycloak:8080}
ADMIN_REALM=${KEYCLOAK_ADMIN_REALM:-master}
TARGET_REALM=${KEYCLOAK_REALM:-e-skylab}
CREDENTIAL_TYPE=webauthn-passwordless
SWITCH_ATTRIBUTE=skylab.passkeyRpIdSwitchedAt
PAGE_SIZE=100
KCADM_CONFIG=$(mktemp /tmp/legacy-passkey-cleanup-kcadm.XXXXXX)
CUTOVER=''
CUTOVER_SOURCE=''
MODE=dry-run

cleanup() {
  rm -f "$KCADM_CONFIG"
}
trap cleanup EXIT

usage() {
  printf 'usage: %s [--cutover YYYY-MM-DDTHH:MM:SSZ] [--apply]\n' "${BASH_SOURCE[0]##*/}" >&2
  exit 2
}

# Seconds since the epoch for an ISO-8601 UTC timestamp (GNU date, then BSD date).
iso_to_seconds() {
  local timestamp=$1 seconds
  if [[ ! $timestamp =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    return 1
  fi
  if seconds=$(date -u -d "$timestamp" +%s 2>/dev/null); then
    printf '%s\n' "$seconds"
  elif seconds=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$timestamp" +%s 2>/dev/null); then
    printf '%s\n' "$seconds"
  else
    return 1
  fi
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --cutover)
      [[ $# -ge 2 ]] || usage
      CUTOVER=$2
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

if [[ -n $CUTOVER ]] && ! cutover_seconds=$(iso_to_seconds "$CUTOVER"); then
  printf 'The cutover must be an ISO-8601 UTC timestamp such as 2026-10-01T00:00:00Z\n' >&2
  exit 2
fi

if [[ -z ${KEYCLOAK_CLEANUP_ADMIN_USERNAME:-} ]]; then
  printf 'Missing required environment variable: KEYCLOAK_CLEANUP_ADMIN_USERNAME\n' >&2
  exit 1
fi

kcadm() {
  local command=$1
  shift
  "$KCADM" "$command" --config "$KCADM_CONFIG" "$@"
}

credential_arguments=(
  --config "$KCADM_CONFIG"
  --server "$ADMIN_URL"
  --realm "$ADMIN_REALM"
  --user "$KEYCLOAK_CLEANUP_ADMIN_USERNAME"
)
if [[ -n ${KEYCLOAK_CLEANUP_ADMIN_PASSWORD:-} ]]; then
  if [[ ${SKY_HARNESS:-} != 1 ]]; then
    printf 'KEYCLOAK_CLEANUP_ADMIN_PASSWORD is accepted only by the test harness (SKY_HARNESS=1); unset it and type the password into the kcadm prompt\n' >&2
    exit 2
  fi
  credential_arguments+=(--password "$KEYCLOAK_CLEANUP_ADMIN_PASSWORD")
fi
"$KCADM" config credentials "${credential_arguments[@]}" >/dev/null

relying_party_id=$(kcadm get "realms/$TARGET_REALM" \
  --fields webAuthnPolicyPasswordlessRpId \
  --format csv \
  --noquotes 2>/dev/null)
if [[ -z $relying_party_id ]]; then
  printf 'The passwordless relying party id of realm %s is still empty; run the reconciler first\n' \
    "$TARGET_REALM" >&2
  exit 1
fi

# The realm attributes arrive as pretty-printed JSON (the image has no jq; kcadm needs the
# "attributes(*)" field selector to print the map's entries); the value has a fixed timestamp
# shape, so one line-oriented extraction is exact.
switched_at=$(kcadm get "realms/$TARGET_REALM" --fields 'attributes(*)' 2>/dev/null \
  | sed -n 's/.*"skylab\.passkeyRpIdSwitchedAt"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
  | head -n 1)
if [[ -n $switched_at ]] && ! switched_seconds=$(iso_to_seconds "$switched_at"); then
  printf 'Realm attribute %s is not an ISO-8601 UTC timestamp; fix it before running the cleanup\n' \
    "$SWITCH_ATTRIBUTE" >&2
  exit 1
fi

if [[ -z $CUTOVER ]]; then
  if [[ -z $switched_at ]]; then
    printf 'Realm %s has no %s attribute: the reconciler has not switched the relying party id yet, so there is no cutover to apply (pass --cutover only for a switch made before this attribute existed)\n' \
      "$TARGET_REALM" "$SWITCH_ATTRIBUTE" >&2
    exit 2
  fi
  CUTOVER=$switched_at
  cutover_seconds=$switched_seconds
  CUTOVER_SOURCE=realmAttribute
else
  CUTOVER_SOURCE=argument
  if [[ -n $switched_at ]] && (( cutover_seconds > switched_seconds )); then
    printf -- '--cutover %s is later than the recorded relying party id switch %s (realm attribute %s); passkeys registered after the switch are valid and must not be deleted. Omit --cutover to use the recorded moment.\n' \
      "$CUTOVER" "$switched_at" "$SWITCH_ATTRIBUTE" >&2
    exit 2
  fi
fi
now_seconds=$(date -u +%s)
if (( cutover_seconds > now_seconds )); then
  printf 'The cutover must not be in the future; every passkey would be deleted\n' >&2
  exit 2
fi
cutover_millis=$((cutover_seconds * 1000))

printf 'realm=%s relyingPartyId=%s cutover=%s cutoverSource=%s mode=%s\n' \
  "$TARGET_REALM" "$relying_party_id" "$CUTOVER" "$CUTOVER_SOURCE" "$MODE"

users_scanned=0
users_with_passkeys=0
users_with_legacy_passkeys=0
users_left_without_passkeys=0
passkeys_total=0
passkeys_legacy=0
passkeys_deleted=0
passkeys_delete_failed=0
first=0

while :; do
  page=$(kcadm get users -r "$TARGET_REALM" \
    -q "first=$first" \
    -q "max=$PAGE_SIZE" \
    -q briefRepresentation=true \
    --fields id \
    --format csv \
    --noquotes 2>/dev/null)
  page_count=0
  while IFS= read -r user_id; do
    [[ -n $user_id ]] || continue
    page_count=$((page_count + 1))
    users_scanned=$((users_scanned + 1))
    credentials=$(kcadm get "users/$user_id/credentials" -r "$TARGET_REALM" \
      --fields id,type,createdDate \
      --format csv \
      --noquotes 2>/dev/null)
    user_passkeys=0
    user_legacy=0
    while IFS=, read -r credential_id credential_type created_date; do
      [[ -n $credential_id && $credential_type == "$CREDENTIAL_TYPE" ]] || continue
      user_passkeys=$((user_passkeys + 1))
      passkeys_total=$((passkeys_total + 1))
      if [[ $created_date =~ ^[0-9]+$ ]] && (( created_date < cutover_millis )); then
        user_legacy=$((user_legacy + 1))
        passkeys_legacy=$((passkeys_legacy + 1))
        if [[ $MODE == apply ]]; then
          # kcadm's error text names the user and credential ids; only the count is reported.
          if kcadm delete "users/$user_id/credentials/$credential_id" -r "$TARGET_REALM" >/dev/null 2>&1; then
            passkeys_deleted=$((passkeys_deleted + 1))
          else
            passkeys_delete_failed=$((passkeys_delete_failed + 1))
          fi
        fi
      fi
    done <<<"$credentials"
    if (( user_passkeys > 0 )); then
      users_with_passkeys=$((users_with_passkeys + 1))
    fi
    if (( user_legacy > 0 )); then
      users_with_legacy_passkeys=$((users_with_legacy_passkeys + 1))
      if (( user_legacy == user_passkeys )); then
        users_left_without_passkeys=$((users_left_without_passkeys + 1))
      fi
    fi
  done <<<"$page"
  if (( page_count < PAGE_SIZE )); then
    break
  fi
  first=$((first + PAGE_SIZE))
done

printf 'usersScanned=%s usersWithPasskeys=%s usersWithLegacyPasskeys=%s usersLeftWithoutPasskeys=%s\n' \
  "$users_scanned" "$users_with_passkeys" "$users_with_legacy_passkeys" "$users_left_without_passkeys"
printf 'passkeysTotal=%s passkeysBeforeCutover=%s passkeysDeleted=%s passkeysDeleteFailed=%s\n' \
  "$passkeys_total" "$passkeys_legacy" "$passkeys_deleted" "$passkeys_delete_failed"
if [[ $MODE == dry-run ]]; then
  printf 'Dry run: nothing was deleted. Re-run with --apply after the database backup and restore test.\n'
elif (( passkeys_delete_failed > 0 )); then
  printf 'Legacy passkey cleanup is incomplete: %s deletion(s) failed. Check that the administrator holds manage-users for realm %s and re-run with --apply; already deleted passkeys are not counted again.\n' \
    "$passkeys_delete_failed" "$TARGET_REALM" >&2
  exit 1
else
  printf 'Legacy passkey cleanup applied.\n'
fi
