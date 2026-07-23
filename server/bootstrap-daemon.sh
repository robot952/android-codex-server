#!/usr/bin/env bash
set -euo pipefail
export PATH="/usr/local/bin:/usr/bin:/bin"

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)

# `app-server daemon` is managed by the official standalone installer. The npm release made by
# install-codex-pinned.sh supports the Android app's private Unix socket/proxy transport, but is not
# accepted by the daemon command. Note that a successful daemon bootstrap also launches Codex's
# detached updater; it is not a strict fixed-version mode.
CODEX_HOME=${CODEX_REMOTE_CODEX_HOME:-${CODEX_HOME:-$HOME/.codex}}
STANDALONE_BIN=${CODEX_REMOTE_STANDALONE_BIN:-"$CODEX_HOME/packages/standalone/current/codex"}
DIRECT_BIN=${CODEX_REMOTE_BIN:-"$HOME/.local/bin/codex-remote"}
EXPECTED_VERSION=$(tr -d '[:space:]' < "$PROJECT_DIR/protocol/codex-version.txt")

if [[ "${CODEX_REMOTE_ALLOW_DAEMON_BOOTSTRAP:-0}" != "1" ]]; then
    cat >&2 <<'EOF'
Refusing to bootstrap the Codex daemon by default.

The daemon bootstrap installs a managed standalone updater and can change the CLI after this
version check. Use the Android app's repository-managed private Unix socket/proxy mode for a
durable version pin; it starts the pinned npm CLI automatically.

To opt into the standalone daemon experiment, set CODEX_REMOTE_ALLOW_DAEMON_BOOTSTRAP=1 and
continue to monitor its managed version yourself.
EOF
    exit 78
fi

if [[ ! -x "$STANDALONE_BIN" ]]; then
    cat >&2 <<EOF
Standalone Codex daemon mode is unavailable for this installation.

The repository installer uses npm. The Android app can use its private Unix socket/proxy mode;
manual direct stdio remains available with:
  $DIRECT_BIN app-server --listen stdio://

The current Codex daemon command requires the official standalone install at:
  $STANDALONE_BIN

Install and verify a standalone Codex CLI separately, or leave CODEX_REMOTE_MODE=direct. The
standalone daemon may update itself after bootstrap and is not a long-term version pin.
You can override the standalone path with CODEX_REMOTE_STANDALONE_BIN.
EOF
    exit 78
fi

ACTUAL_VERSION=$("$STANDALONE_BIN" --version 2>/dev/null || true)
if [[ "$ACTUAL_VERSION" != "codex-cli $EXPECTED_VERSION" ]]; then
    cat >&2 <<EOF
Standalone Codex version mismatch: expected codex-cli $EXPECTED_VERSION, got:
  ${ACTUAL_VERSION:-<unable to execute>}

Refusing to bootstrap until the initial standalone version matches the repository pin.
EOF
    exit 78
fi

CODEX_HOME="$CODEX_HOME" "$STANDALONE_BIN" app-server daemon bootstrap
CODEX_HOME="$CODEX_HOME" "$STANDALONE_BIN" app-server daemon start
CODEX_HOME="$CODEX_HOME" "$STANDALONE_BIN" app-server daemon version

cat >&2 <<'EOF'
Warning: daemon bootstrap starts Codex's detached updater, which may replace the managed CLI later.
Use the Android app's managed private Unix socket/proxy mode when a strict fixed Codex version is required.
EOF
