#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
node --check flutter_app/assets/claude-code-bridge.cjs
node scripts/test-claude-code-bridge.cjs
CLAUDE_CODE_TEST_BIN="${CLAUDE_CODE_TEST_BIN:-$(command -v claude || true)}"
if [[ -n "$CLAUDE_CODE_TEST_BIN" ]]; then
  export CLAUDE_CODE_TEST_BIN
  node scripts/test-claude-code-cli.cjs
else
  echo "Claude Code real CLI integration skipped: no installed claude executable"
fi
