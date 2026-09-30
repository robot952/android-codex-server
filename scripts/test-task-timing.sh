#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
timer="$ROOT_DIR/scripts/task-timing.sh"
temporary_root="$(mktemp -d)"
trap 'find "$temporary_root" -depth -delete' EXIT
export CODEX_TASK_TIMING_DIR="$temporary_root/records"

expect_failure() {
    local expected="$1" actual=0
    shift
    "$@" > "$temporary_root/failure.out" 2>&1 || actual=$?
    [[ "$actual" == "$expected" ]] || { echo "expected status $expected, received $actual" >&2; exit 1; }
}
[[ "$("$timer" start unrelated)" == unrelated ]]
[[ "$("$timer" start task)" == task ]]
expect_failure 1 "$timer" start task

# Private ledger permissions must not leak into the measured command.
(
    umask 0027
    cd "$temporary_root"
    printf 'input-value\n' | TASK_TIMING_TEST_VALUE=environment-value ROOT_DIR=caller-root TIMING_DIR=caller-timing \
        STATE_DIR=caller-state LOCK_DIR=caller-lock "$timer" run task command-context -- \
        bash -c '
            [[ "$(umask)" == 0027 && "$PWD" == "$1" ]]
            [[ "$TASK_TIMING_TEST_VALUE" == environment-value && "$2" == "literal * argument" ]]
            [[ "$ROOT_DIR" == caller-root && "$TIMING_DIR" == caller-timing && "$STATE_DIR" == caller-state && "$LOCK_DIR" == caller-lock ]]
            read -r value
            [[ "$value" == input-value ]]
            touch command-file
            printf "output-value\n"
        ' -- "$temporary_root" 'literal * argument' > command-stdout
    [[ "$(stat -c %a command-file)" == 640 ]]
    [[ "$(cat command-stdout)" == output-value ]]
    [[ "$(umask)" == 0027 ]]
)
[[ "$(stat -c %a "$CODEX_TASK_TIMING_DIR/.active/task.tsv")" == 600 ]]

# Repeated labels preserve failed attempts; command arguments/output never enter TSV.
"$timer" run task retry -- bash -c 'printf "command-output\n"; sleep 0.08' > "$temporary_root/command.out"
expect_failure 7 "$timer" run task retry -- bash -c 'exit 7' -- secret-argument
"$timer" run task retry -- true
"$timer" phase task imported 123 2
token="$("$timer" begin task 编码)"
expect_failure 1 "$timer" finish task
"$timer" end task "$token"
expect_failure 1 "$timer" end task "$token"

# Independent concurrent phases execute in parallel and cannot race finalization.
mkdir "$temporary_root/ready"
pids=()
for i in {1..12}; do
    "$timer" run task "parallel-$i" -- bash -c '
        touch "$1/ready/$2"
        for attempt in {1..100}; do
            [[ ! -f "$1/release" ]] || exit 0
            sleep 0.02
        done
        exit 33
    ' -- "$temporary_root" "$i" &
    pids+=("$!")
done
for attempt in {1..100}; do
    [[ "$(find "$temporary_root/ready" -type f | wc -l)" != 12 ]] || break
    sleep 0.02
done
[[ "$(find "$temporary_root/ready" -type f | wc -l)" == 12 ]]
expect_failure 1 "$timer" finish task
touch "$temporary_root/release"
for pid in "${pids[@]}"; do wait "$pid"; done

# All ID-taking commands reject traversal, option-like and hidden names.
for bad in '../outside' '.' '..' '-option' '' 'has space'; do
    expect_failure 2 "$timer" start "$bad"
    expect_failure 2 "$timer" begin "$bad" test
    expect_failure 2 "$timer" end "$bad" token
    expect_failure 2 "$timer" run "$bad" test -- true
    expect_failure 2 "$timer" phase "$bad" test 1
    expect_failure 2 "$timer" finish "$bad"
    expect_failure 2 "$timer" status "$bad"
done
expect_failure 2 "$timer" end task '../outside'
for bad in '-1' '1.2' '08' '999999999999999999999'; do
    expect_failure 2 "$timer" phase task test "$bad"
done
for bad in '-1' '256' '01' 'x' ''; do
    expect_failure 2 "$timer" phase task test 1 "$bad"
    expect_failure 2 "$timer" finish task "$bad"
done
expect_failure 2 "$timer" run task missing-command --
expect_failure 2 "$timer" begin task '   '
"$timer" phase task $'tabs\tand\nlines' 0
"$timer" phase task phase 0
"$timer" status task > "$temporary_root/active.tsv"
record="$("$timer" finish task 7)"
[[ -f "$record" ]]
[[ "$("$timer" status)" == unrelated.tsv ]]
expect_failure 1 "$timer" start task
expect_failure 1 "$timer" phase task late 1
expect_failure 1 "$timer" finish task
expect_failure 1 "$timer" run task late -- true

awk -F '\t' '
    $1 == "phase" && $2 == "status" { header = NR; next }
    header && NF != 6 { exit 1 }
    $1 == "retry" { attempts++; if ($2 == 7) failed++; if ($3 >= 70) duration++ }
    $1 ~ /^parallel-/ { parallel++ }
    $1 == "imported" && $3 == 123 && $4 == "unknown" && $5 == "unknown" && $6 == "imported" { imported++ }
    $6 == "measured" && ($4 !~ /T.*Z$/ || $5 !~ /T.*Z$/ || $3 < 0) { exit 1 }
    $1 == "tabs and lines" { sanitized++ }
    $1 == "totalMs" && $2 >= 70 { total++ }
    $1 == "status" && $2 == 7 { failedTask++ }
    $1 == "phase" && $2 == 0 { phaseLabel++ }
    END { if (attempts != 3 || failed != 1 || duration < 1 || parallel != 12 || imported != 1 || sanitized != 1 || total != 1 || failedTask != 1 || phaseLabel != 1) exit 1 }
' "$record"
if rg -q 'secret-argument|command-output|bash -c' "$record"; then
    echo 'command details leaked into timing record' >&2
    exit 1
fi
[[ ! -e "$temporary_root/outside.tsv" ]]
"$timer" finish unrelated > /dev/null
[[ -z "$("$timer" status)" ]]
echo 'Task timing: isolated success/failure/retry, IDs, timestamps, concurrency and argument isolation passed'
