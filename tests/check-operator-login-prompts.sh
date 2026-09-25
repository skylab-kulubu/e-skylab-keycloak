#!/usr/bin/env bash
# The operator scripts log in with kcadm and let it prompt for the password on the operator's
# terminal. kcadm only prompts when its stdout is a terminal, so redirecting that login's stdout
# makes the script unusable in production ("Console is not active, but password is required").
# The harness never saw it because it passes the password through SKY_HARNESS=1.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONFIG_DIR="$SCRIPT_DIR/../config"
status=0
for script in create-mailer-client.sh cleanup-legacy-passkeys.sh identity-guardrails.sh; do
  if grep -nE '^[[:space:]]*"\$KCADM" config credentials "\$\{credential_arguments\[@\]\}".*>' "$CONFIG_DIR/$script"; then
    printf 'operator login prompt check failed: %s redirects the interactive kcadm login\n' "$script" >&2
    status=1
  fi
  grep -qE '^[[:space:]]*"\$KCADM" config credentials "\$\{credential_arguments\[@\]\}"[[:space:]]*$' "$CONFIG_DIR/$script" \
    || { printf 'operator login prompt check failed: %s has no interactive kcadm login line\n' "$script" >&2; status=1; }
done
[[ $status == 0 ]] && printf 'Operator scripts leave the kcadm password prompt on the terminal.\n'
exit "$status"
