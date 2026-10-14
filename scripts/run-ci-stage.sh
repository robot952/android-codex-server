#!/usr/bin/env bash
set -euo pipefail

# The top-level supervisor stays outside its worker group. Nested deadlines
# share that group, so cancellation does not strand a second timeout group.
# Never print command arguments: they may contain credentials.
label="${1:?stage label required}"
limit="${2:?timeout seconds required}"
shift 2
if [[ ! "$limit" =~ ^[1-9][0-9]{0,4}$ ]] || (( limit > 86400 )) || (( $# == 0 )); then
    echo 'CI stage requires a command and a timeout between 1 and 86400 seconds' >&2
    exit 2
fi
command -v timeout >/dev/null || { echo 'CI requires GNU timeout; refusing an unbounded stage' >&2; exit 127; }
shared_group="${CODEX_CI_PROCESS_GROUP:-}"
if [[ -n "$shared_group" && ! "$shared_group" =~ ^[1-9][0-9]*$ ]]; then
    echo 'Invalid CI process group' >&2
    exit 2
fi
if [[ -n "$shared_group" ]]; then
    actual_group="$(ps -o pgid= -p "$$" | tr -d '[:space:]')"
    if [[ "$shared_group" != "$actual_group" ]]; then
        echo 'CI process group does not match this stage; refusing unsafe cancellation' >&2
        exit 2
    fi
fi

timeout_pid=
cleanup() {
    trap - EXIT TERM INT HUP
    if [[ -n "$timeout_pid" ]]; then
        # Also reap descendants left behind when their immediate parent exits.
        if [[ -z "$shared_group" ]]; then
            kill -KILL -- "-$timeout_pid" 2>/dev/null || true
        else
            kill -KILL "$timeout_pid" 2>/dev/null || true
        fi
        wait "$timeout_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT
trap 'echo "[CI] $label cancelled (TERM)" >&2; exit 143' TERM
trap 'echo "[CI] $label cancelled (INT)" >&2; exit 130' INT
trap 'echo "[CI] $label cancelled (HUP)" >&2; exit 129' HUP
started=$SECONDS
echo "[CI] Starting $label (timeout ${limit}s; TERM then KILL after at most 30s)" >&2
if [[ -z "$shared_group" ]]; then
    timeout --signal=TERM --kill-after=30s "${limit}s" \
        bash -c 'export CODEX_CI_PROCESS_GROUP=$PPID; exec "$@"' ci-stage "$@" <&0 &
else
    timeout --foreground --signal=TERM --kill-after=30s "${limit}s" "$@" <&0 &
fi
timeout_pid=$!
status=0
wait "$timeout_pid" || status=$?
case "$status" in
    0) echo "[CI] Finished $label in $((SECONDS - started))s" >&2 ;;
    124|137) echo "[CI] $label timed out or was killed (limit ${limit}s, exit $status); stopping pipeline" >&2 ;;
    *) echo "[CI] $label failed (exit $status); stopping pipeline" >&2 ;;
esac
if [[ -n "$shared_group" && ( "$status" == 124 || "$status" == 137 ) ]]; then
    echo "[CI] Stopping shared CI process group after $label timeout" >&2
    kill -KILL -- "-$shared_group" 2>/dev/null || true
fi
exit "$status"
