#!/usr/bin/env bash
set -euo pipefail

# Unified OpenCode bridge gate. It auto-discovers the persistent pinned runtime
# and skips an already successful, byte-identical input set by default.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
source "$ROOT_DIR/scripts/workflow-lib.sh"

mode="quick"
reuse=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        quick|full) mode="$1" ;;
        --reuse) reuse=1 ;;
        --force) reuse=0 ;;
        *)
            echo "usage: $0 {quick|full} [--reuse|--force]" >&2
            exit 2
            ;;
    esac
    shift
done
if [[ "${CODEX_WORKFLOW_NO_CACHE:-0}" == 1 ]]; then
    reuse=0
fi

open_code_bin="$($ROOT_DIR/scripts/ensure-opencode-runtime.sh)"
open_code_version="$(workflow_opencode_version "$open_code_bin")"
open_code_sha256="$(workflow_file_sha256_cached "$ROOT_DIR" "$open_code_bin")"
input_hash="$(workflow_repo_hash "$ROOT_DIR" \
    app/src/main/assets/opencode-bridge.cjs \
    scripts/test-opencode-bridge.cjs \
    scripts/test-opencode-bridge-scheduling.cjs \
    scripts/test-opencode-bridge-question.cjs \
    scripts/test-opencode-bridge-integration.cjs \
    scripts/test-opencode.sh \
    scripts/ensure-opencode-runtime.sh \
    scripts/workflow-lib.sh \
    protocol/opencode-version.txt)"
fingerprint="$(printf 'schema=3\nmode=%s\ninputs=%s\nruntime=%s\nversion=%s\nruntimeSha256=%s\n' \
    "$mode" "$input_hash" "$open_code_bin" "$open_code_version" "$open_code_sha256" | workflow_sha256)"
cache_dir="$(workflow_cache_dir "$ROOT_DIR")"
stamp_path="$cache_dir/opencode-$mode.stamp"
mkdir -p "$cache_dir"

exec 9>"$cache_dir/opencode-tests.lock"
flock 9
if [[ "$reuse" == 1 ]] && workflow_stamp_matches "$stamp_path" "$fingerprint"; then
    echo "OpenCode $mode gate: cache hit ($open_code_version)"
    exit 0
fi

started_seconds="$(date +%s)"
export OPENCODE_BIN="$open_code_bin"
node --check app/src/main/assets/opencode-bridge.cjs
node scripts/test-opencode-bridge.cjs
node scripts/test-opencode-bridge-scheduling.cjs
node scripts/test-opencode-bridge-question.cjs
if [[ "$mode" == full ]]; then
    node scripts/test-opencode-bridge-integration.cjs
fi

workflow_write_stamp "$stamp_path" "$fingerprint"
if [[ "$mode" == full ]]; then
    quick_fingerprint="$(printf 'schema=3\nmode=quick\ninputs=%s\nruntime=%s\nversion=%s\nruntimeSha256=%s\n' \
        "$input_hash" "$open_code_bin" "$open_code_version" "$open_code_sha256" | workflow_sha256)"
    workflow_write_stamp "$cache_dir/opencode-quick.stamp" "$quick_fingerprint"
fi
echo "OpenCode $mode gate passed in $(workflow_elapsed "$started_seconds")"
