#!/usr/bin/env bash
# Native signup continuation, using the same pinned disposable broker/PG bootstrap as B12/B24.
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export B10_AFTER_SIGN_UP_ONLY=1
export B12_TRANSACTION_ONLY=1
export B12_PG_IMAGE=postgres:18-alpine@sha256:77f585114c32fbca283dc835b0596f4e52b51b4c6662d7810b2f4084f60a1873
export B12_PG_TMPFS=/var/lib/postgresql
exec "$SCRIPT_DIR/existing-account-link.sh" "$@"
