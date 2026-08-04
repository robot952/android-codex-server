#!/usr/bin/env bash
set -euo pipefail

# Static gate for the standalone server helpers. The real app-server smoke test
# needs a logged-in Codex runtime, so the normal local loop validates every
# executable entry point without touching a user's remote installation.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
source "$ROOT_DIR/scripts/workflow-lib.sh"

reuse=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --reuse) reuse=1 ;;
        --force) reuse=0 ;;
        *)
            echo "usage: $0 [--reuse|--force]" >&2
            exit 2
            ;;
    esac
    shift
done
if [[ "${CODEX_WORKFLOW_NO_CACHE:-0}" == 1 ]]; then
    reuse=0
fi

input_hash="$(workflow_repo_hash "$ROOT_DIR" \
    server/bootstrap-daemon.sh \
    server/install-codex-pinned.sh \
    server/codex-app-server-ssh \
    server/smoke-test.mjs \
    protocol/codex-version.txt \
    scripts/test-server.sh \
    scripts/workflow-lib.sh)"
node_identity="$(node --version)"
fingerprint="$(printf 'schema=1\ninputs=%s\nbash=%s\nnode=%s\n' \
    "$input_hash" "${BASH_VERSION%%(*}" "$node_identity" | workflow_sha256)"
cache_dir="$(workflow_cache_dir "$ROOT_DIR")"
stamp_path="$cache_dir/server-scripts.stamp"
mkdir -p "$cache_dir"

exec 9>"$cache_dir/server-tests.lock"
flock 9
if [[ "$reuse" == 1 ]] && workflow_stamp_matches "$stamp_path" "$fingerprint"; then
    echo "Server script gate: cache hit ($node_identity)"
    exit 0
fi

started_seconds="$(date +%s)"
bash -n \
    server/bootstrap-daemon.sh \
    server/install-codex-pinned.sh \
    server/codex-app-server-ssh
node --check server/smoke-test.mjs

workflow_write_stamp "$stamp_path" "$fingerprint"
echo "Server script gate passed in $(workflow_elapsed "$started_seconds")"
