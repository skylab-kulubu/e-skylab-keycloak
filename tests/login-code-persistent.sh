#!/usr/bin/env bash
# Real PostgreSQL + two independent Keycloak instances; separate from the full login regression.
# The common harness supplies only its pinned images, throwaway realm, mail fixtures and helpers.
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export LOGIN_BY_EMAIL_CODE_PERSISTENT_ONLY=1
export LOGIN_BY_EMAIL_CODE_POSTGRES_IMAGE=postgres:18-alpine@sha256:77f585114c32fbca283dc835b0596f4e52b51b4c6662d7810b2f4084f60a1873
exec "$SCRIPT_DIR/login-by-email-code.sh" "$@"
