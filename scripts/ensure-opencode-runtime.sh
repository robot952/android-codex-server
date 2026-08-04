#!/usr/bin/env bash
set -euo pipefail

# Resolves one persistent pinned OpenCode runtime for all local integration
# tests. Installation is paid only once and uses the domestic npm mirror.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/workflow-lib.sh"

version="$(tr -d '[:space:]' < "$ROOT_DIR/protocol/opencode-version.txt")"
if runtime_path="$(workflow_find_opencode "$ROOT_DIR" "$version")"; then
    printf '%s\n' "$runtime_path"
    exit 0
fi

runtime_root="${CODEX_OPENCODE_RUNTIME_DIR:-$(workflow_cache_dir "$ROOT_DIR")/opencode/$version}"
runtime_path="$runtime_root/node_modules/.bin/opencode"
mkdir -p "$runtime_root"

exec 9>"$runtime_root/.install.lock"
flock 9
if [[ -x "$runtime_path" ]]; then
    readlink -f "$runtime_path"
    exit 0
fi

if ! command -v npm >/dev/null 2>&1; then
    echo "OpenCode runtime is missing and npm is unavailable" >&2
    exit 1
fi

echo "Installing reusable OpenCode $version into $runtime_root" >&2
printf '%s\n' \
    '{' \
    '  "private": true,' \
    '  "dependencies": {' \
    '    "jsonc-parser": "3.3.1",' \
    "    \"opencode-ai\": \"$version\"" \
    '  }' \
    '}' > "$runtime_root/package.json"

export npm_config_registry="${CODEX_NPM_REGISTRY:-https://registry.npmmirror.com}"
if (echo >/dev/tcp/127.0.0.1/7890) 2>/dev/null; then
    export HTTP_PROXY="${HTTP_PROXY:-http://127.0.0.1:7890}"
    export HTTPS_PROXY="${HTTPS_PROXY:-http://127.0.0.1:7890}"
    export http_proxy="${http_proxy:-$HTTP_PROXY}"
    export https_proxy="${https_proxy:-$HTTPS_PROXY}"
    echo "Using download proxy 127.0.0.1:7890" >&2
fi

(
    cd "$runtime_root"
    npm install --no-audit --no-fund --prefer-offline
)

if [[ ! -x "$runtime_path" ]]; then
    echo "OpenCode installation completed without an executable: $runtime_path" >&2
    exit 1
fi
readlink -f "$runtime_path"
