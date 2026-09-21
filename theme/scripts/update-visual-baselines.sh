#!/usr/bin/env bash
# Renders (or checks) the Playwright screenshot baselines of every Keycloak page
# inside the official Playwright Linux image, so the committed PNGs match the
# CI runner regardless of the developer's machine.
#
#   theme/scripts/update-visual-baselines.sh          # rewrite tests/browser/visual.spec.ts-snapshots
#   theme/scripts/update-visual-baselines.sh --check  # compare only; diffs land in theme/test-results
#
# The committed baselines are replaced only when every screenshot was captured.
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
THEME_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
SNAPSHOT_DIR="$THEME_DIR/tests/browser/visual.spec.ts-snapshots"
RESULTS_DIR="$THEME_DIR/test-results"

mode=update
case ${1:-} in
  '') ;;
  --check) mode=check ;;
  *)
    printf 'usage: %s [--check]\n' "$0" >&2
    exit 64
    ;;
esac

command -v docker >/dev/null 2>&1 || {
  printf 'docker is required to render the visual baselines\n' >&2
  exit 1
}

playwright_version=$(node -p "require('$THEME_DIR/package.json').devDependencies['@playwright/test']")
[[ $playwright_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  printf '@playwright/test must be pinned to an exact version, found %s\n' "$playwright_version" >&2
  exit 1
}
image="mcr.microsoft.com/playwright:v${playwright_version}-jammy"
# The GitHub runner is amd64; Apple Silicon hosts emulate it (slower, identical output).
platform=${VISUAL_BASELINE_PLATFORM:-linux/amd64}

mkdir -p "$SNAPSHOT_DIR" "$RESULTS_DIR"
printf 'Rendering SKY LAB theme baselines with %s (%s, %s)\n' "$image" "$platform" "$mode"

# The theme sources are mounted read-only and copied into a tmpfs work tree, so the
# Linux npm install never touches the host's node_modules; only the snapshot and
# test-results directories are written back. tests/browser/fonts.conf pins the
# generic font families exactly as the CI theme job does.
docker run --rm \
  --platform "$platform" \
  --user "$(id -u):$(id -g)" \
  --env HOME=/tmp/home \
  --env CI=1 \
  --env SL_VISUAL_BASELINE_ENV=1 \
  --env MODE="$mode" \
  --env npm_config_cache=/tmp/npm-cache \
  --tmpfs /work:rw,exec,size=3g,mode=1777 \
  --volume "$THEME_DIR:/src:ro" \
  --volume "$SNAPSHOT_DIR:/snapshots" \
  --volume "$RESULTS_DIR:/results" \
  --workdir /work \
  "$image" \
  bash -Eeuo pipefail -c '
    mkdir -p /tmp/home/.config/fontconfig /work/theme
    cp /src/tests/browser/fonts.conf /tmp/home/.config/fontconfig/fonts.conf
    cd /work/theme
    tar -C /src \
      --exclude=./node_modules --exclude=./dist --exclude=./dist_keycloak \
      --exclude=./test-results --exclude=./playwright-report \
      --exclude=./public/keycloakify-dev-resources \
      -cf - . | tar -C /work/theme -xf -
    npm ci --ignore-scripts --no-audit --no-fund
    mkdir -p tests/browser/visual.spec.ts-snapshots
    playwright_args=(test tests/browser/visual.spec.ts)
    if [[ $MODE == check ]]; then
      cp /snapshots/*.png tests/browser/visual.spec.ts-snapshots/ 2>/dev/null || true
    else
      playwright_args+=(--update-snapshots)
    fi
    set +e
    npx playwright "${playwright_args[@]}"
    status=$?
    set -e
    if [[ $MODE == update && $status == 0 ]]; then
      rm -f /snapshots/*.png
      cp tests/browser/visual.spec.ts-snapshots/*.png /snapshots/
    fi
    rm -rf /results/*
    if [[ -d test-results ]]; then
      cp -r test-results/. /results/
    fi
    exit "$status"
  '
