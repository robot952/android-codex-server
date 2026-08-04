#!/usr/bin/env bash
set -euo pipefail

# Prepares one local SSH-only account for the Android emulator. The account,
# password, workspace, and any Agent runtime installed through the app are kept
# across tasks. This script intentionally has no automatic cleanup path.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/workflow-lib.sh"

COMMAND="${1:-status}"
TEST_USER="${CODEX_TEST_HOST_USER:-codexemu}"
TEST_PASSWORD="${CODEX_TEST_HOST_PASSWORD:-codexemu}"
TEST_WORKSPACE="${CODEX_TEST_HOST_WORKSPACE:-/home/$TEST_USER/workspace}"
CACHE_DIR="$(workflow_cache_dir "$ROOT_DIR")/test-host"
PROFILE_PATH="$CACHE_DIR/profile.txt"
MARKER_PATH="$CACHE_DIR/prepared"
mkdir -p "$CACHE_DIR"

write_profile() {
    local fingerprint
    fingerprint="$(ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub -E sha256 2>/dev/null |
        awk '{print $2}' || true)"
    {
        printf 'name=Local emulator host\n'
        printf 'host=10.0.2.2\n'
        printf 'port=22\n'
        printf 'username=%s\n' "$TEST_USER"
        printf 'password=%s\n' "$TEST_PASSWORD"
        printf 'workspace=%s\n' "$TEST_WORKSPACE"
        printf 'fingerprint=%s\n' "$fingerprint"
    } > "$PROFILE_PATH"
}

prepare_host() {
    if [[ "$(id -u)" != 0 ]]; then
        echo "prepare must run as root" >&2
        exit 1
    fi
    if ! id "$TEST_USER" >/dev/null 2>&1; then
        useradd --create-home --shell /bin/bash "$TEST_USER"
        printf '%s:%s\n' "$TEST_USER" "$TEST_PASSWORD" | chpasswd
    elif [[ ! -f "$MARKER_PATH" || "${CODEX_TEST_HOST_RESET_PASSWORD:-0}" == 1 ]]; then
        printf '%s:%s\n' "$TEST_USER" "$TEST_PASSWORD" | chpasswd
    fi
    install -d -m 0755 -o "$TEST_USER" -g "$TEST_USER" "$TEST_WORKSPACE"
    write_profile
    printf 'preparedAt=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARKER_PATH"
    echo "Reusable SSH host is ready. Keep this profile in the emulator:"
    cat "$PROFILE_PATH"
}

show_status() {
    local listening_sockets
    if id "$TEST_USER" >/dev/null 2>&1; then
        write_profile
        echo "Reusable SSH user exists: $TEST_USER"
        cat "$PROFILE_PATH"
        listening_sockets="$(ss -ltn)"
        if rg -q '(^|:)22[[:space:]]' <<< "$listening_sockets"; then
            echo "SSH port 22 is listening"
        else
            echo "SSH port 22 is not listening"
        fi
    else
        echo "Reusable SSH user is not prepared"
        echo "Run: $0 prepare"
    fi
}

case "$COMMAND" in
    prepare) prepare_host ;;
    status|info) show_status ;;
    *)
        echo "usage: $0 {prepare|status|info}" >&2
        exit 2
        ;;
esac
