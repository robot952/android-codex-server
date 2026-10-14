#!/usr/bin/env bash
set -euo pipefail

# Keep shell expansion here: Gitee also expands ${...} in inline YAML commands.
if [[ -n "${WORKSPACE:-}" ]]; then cd "$WORKSPACE"; fi
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
export CODEX_RELEASE_BRANCH="${1:-release}"
source "$ROOT_DIR/scripts/prepare-ci-environment.sh"
prepare_ci_environment "$ROOT_DIR"
"$ROOT_DIR/scripts/publish-gitee-release.sh"
ls -lh dist
