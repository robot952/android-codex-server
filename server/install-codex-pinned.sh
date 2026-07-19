#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
VERSION=${CODEX_VERSION:-$(tr -d '[:space:]' < "$PROJECT_DIR/protocol/codex-version.txt")}
INSTALL_ROOT=${CODEX_INSTALL_ROOT:-"$HOME/.local/share/codex-remote"}
BIN_DIR=${CODEX_BIN_DIR:-"$HOME/.local/bin"}
RELEASE_DIR="$INSTALL_ROOT/releases/$VERSION"
CODEX_BIN="$RELEASE_DIR/bin/codex"

command -v npm >/dev/null 2>&1 || {
    echo "npm is required to install the pinned Codex CLI" >&2
    exit 1
}

mkdir -p "$RELEASE_DIR" "$BIN_DIR"
npm install --global --prefix "$RELEASE_DIR" \
    "@openai/codex@$VERSION" --omit=dev --no-audit --no-fund

ACTUAL_VERSION=$($CODEX_BIN --version)
EXPECTED_VERSION="codex-cli $VERSION"
if [[ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]]; then
    echo "Codex version mismatch: expected '$EXPECTED_VERSION', got '$ACTUAL_VERSION'" >&2
    exit 1
fi

$CODEX_BIN app-server --help >/dev/null
ln -sfn "$CODEX_BIN" "$BIN_DIR/codex-remote"

SCHEMA_DIR="$SCRIPT_DIR/generated-schema"
rm -rf "$SCHEMA_DIR"
$CODEX_BIN app-server generate-json-schema --out "$SCHEMA_DIR"

echo "Installed $ACTUAL_VERSION" >&2
echo "Binary: $BIN_DIR/codex-remote" >&2
echo "Schema: $SCHEMA_DIR" >&2
