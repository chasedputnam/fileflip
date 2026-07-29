#!/bin/bash
# Relocate an already-built FileFlip.app and prove packaged audio/video activation.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# -lt 1 || $# -gt 2 ]]; then
    printf 'usage: %s /absolute/FileFlip.app [/absolute/fixtures/manifest.json]\n' "$0" >&2
    exit 64
fi
APP=$1
FIXTURES=${2:-"$ROOT/Tests/Fixtures/Media/manifest.json"}
[[ "$APP" = /* && "$FIXTURES" = /* ]] || {
    printf 'smoke-installed-media.sh: app and fixture paths must be absolute\n' >&2
    exit 64
}

exec swift run --package-path "$ROOT" packaged-media-smoke \
    --app "$APP" \
    --fixtures "$FIXTURES"
