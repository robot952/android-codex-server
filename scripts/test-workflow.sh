#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/workflow-lib.sh"
source "$ROOT_DIR/scripts/apk-lib.sh"

temporary_root="$(mktemp -d /tmp/codex-workflow-test.XXXXXX)"
cleanup() {
    find "$temporary_root" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT

(
    cd "$temporary_root"
    git init --quiet
    printf 'one\n' > tracked.txt
    git add tracked.txt
    printf 'alpha\n' > extra.txt
)

first_hash="$(workflow_repo_hash "$temporary_root" .)"
printf 'two\n' > "$temporary_root/tracked.txt"
second_hash="$(workflow_repo_hash "$temporary_root" .)"
[[ "$first_hash" != "$second_hash" ]] || {
    echo "Repository hash did not change with tracked contents" >&2
    exit 1
}
chmod 0755 "$temporary_root/tracked.txt"
mode_hash="$(workflow_repo_hash "$temporary_root" .)"
[[ "$second_hash" != "$mode_hash" ]] || {
    echo "Repository hash did not change with file permissions" >&2
    exit 1
}

identity_file="$temporary_root/runtime.bin"
printf 'runtime-one\n' > "$identity_file"
identity_sha_one="$(workflow_file_sha256_cached "$temporary_root" "$identity_file")"
identity_sha_cached="$(workflow_file_sha256_cached "$temporary_root" "$identity_file")"
[[ "$identity_sha_one" == "$identity_sha_cached" ]]
printf 'runtime-two\n' > "$identity_file"
identity_sha_two="$(workflow_file_sha256_cached "$temporary_root" "$identity_file")"
[[ "$identity_sha_one" != "$identity_sha_two" ]] || {
    echo "Cached file identity did not change with contents" >&2
    exit 1
}

stamp_path="$temporary_root/cache/test.stamp"
workflow_write_stamp "$stamp_path" "$mode_hash"
workflow_stamp_matches "$stamp_path" "$mode_hash"
if workflow_stamp_matches "$stamp_path" "$first_hash"; then
    echo "Workflow stamp accepted a stale fingerprint" >&2
    exit 1
fi

[[ "$(apk_version_name "$ROOT_DIR")" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]
rg -q 'http://192\.168\.8\.107/agent\.apk' "$ROOT_DIR/scripts/publish-local-apk.sh"
rg -q 'http://frp\.asdb\.top:18080/agent\.apk' "$ROOT_DIR/scripts/publish-local-apk.sh"
runtime_path="$($ROOT_DIR/scripts/ensure-opencode-runtime.sh)"
expected_runtime_version="$(tr -d '[:space:]' < "$ROOT_DIR/protocol/opencode-version.txt")"
[[ "$(workflow_opencode_version "$runtime_path")" == "$expected_runtime_version" ]]
expected_codex_version="$(tr -d '[:space:]' < "$ROOT_DIR/protocol/codex-version.txt")"
expected_node_version="$(tr -d '[:space:]' < "$ROOT_DIR/protocol/node-version.txt")"
rg -Fq "const pinnedCodexVersion = '$expected_codex_version';" \
    "$ROOT_DIR/flutter_app/lib/src/agent/remote_bootstrap.dart"
rg -Fq "const pinnedNodeVersion = '$expected_node_version';" \
    "$ROOT_DIR/flutter_app/lib/src/agent/remote_bootstrap.dart"

# A multi-line producer followed by `rg -q` can return SIGPIPE under pipefail.
# The workflow intentionally captures command output before matching runtime status.
multi_line_status=$'asdb_api34 is running as emulator-5554\nAndroid 14'
rg -q ' is running as ' <<< "$multi_line_status"

bash -n "$ROOT_DIR"/scripts/*.sh
"$ROOT_DIR/scripts/test-server.sh" --force
server_cache_output="$("$ROOT_DIR/scripts/test-server.sh" --reuse)"
rg -q 'cache hit' <<< "$server_cache_output"
echo "Local workflow tests passed"
