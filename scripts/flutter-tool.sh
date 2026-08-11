#!/usr/bin/env bash
set -euo pipefail

# Stable local entry point for targeted Flutter and Dart commands. It shares
# the same toolchain and Pub cache selection as the Android build gate.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/workflow-lib.sh"

FLUTTER_BIN="$(workflow_resolve_flutter "$ROOT_DIR")"
if [[ -z "${PUB_CACHE:-}" ]]; then
    shared_pub_cache="$ROOT_DIR/../.pub-cache"
    if [[ -e "$shared_pub_cache" && ! -w "$shared_pub_cache" ]]; then
        export PUB_CACHE="$HOME/.pub-cache"
    else
        export PUB_CACHE="$shared_pub_cache"
    fi
fi
mkdir -p "$PUB_CACHE"
cd "$ROOT_DIR/flutter_app"

if [[ "${1:-}" == dart ]]; then
    shift
    exec "$(dirname "$FLUTTER_BIN")/dart" "$@"
fi
exec "$FLUTTER_BIN" "$@"
