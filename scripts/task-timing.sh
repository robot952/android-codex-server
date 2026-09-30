#!/usr/bin/env bash
set -euo pipefail
command_umask="$(umask)"
umask 077

# Labels are caller supplied. Never store command arguments or command output.
task_timing_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
task_timing_directory="${CODEX_TASK_TIMING_DIR:-$task_timing_root/.workflow-cache/task-timings}"
task_timing_active="$task_timing_directory/.active"
task_timing_locks="$task_timing_directory/.locks"

usage() {
    echo 'usage: task-timing.sh start [TASK] | begin TASK PHASE | end TASK TOKEN [STATUS] | run TASK PHASE -- COMMAND... | phase TASK PHASE ELAPSED_MS [STATUS] | finish TASK [STATUS] | status [TASK]' >&2
    exit 2
}
fail() { echo "$1" >&2; exit "${2:-1}"; }
valid_id() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || fail 'invalid task or phase token' 2; }
valid_status() { [[ "$1" =~ ^(0|[1-9][0-9]{0,2})$ ]] && (( $1 <= 255 )) || fail 'status must be 0..255' 2; }
valid_duration() { [[ "$1" =~ ^(0|[1-9][0-9]{0,12})$ ]] || fail 'elapsed milliseconds must be a nonnegative integer' 2; }
now_ms() { date +%s%3N; }
utc_now() { date -u +%Y-%m-%dT%H:%M:%S.%3NZ; }
tick_ms() { awk '{ printf "%.0f\n", $1 * 1000 }' /proc/uptime; }
phase_label() {
    local label
    label="$(printf '%s' "$1" | tr '\t\r\n' '   ' | LC_ALL=C tr -d '\000-\010\013\014\016-\037\177')"
    [[ -n "${label// /}" && ${#label} -le 128 ]] || fail 'phase label must contain 1..128 characters' 2
    printf '%s' "$label"
}
lock_task() {
    valid_id "$1"
    mkdir -p "$task_timing_active" "$task_timing_locks"
    exec 9> "$task_timing_locks/$1.lock"
    flock -x 9
    state="$task_timing_active/$1.tsv"
    steps="$task_timing_active/$1.steps"
    output="$task_timing_directory/$1.tsv"
}
active_task() { [[ -f "$state" && ! -e "$output" ]] || fail 'active task not found'; }

start_task() {
    local task_id="$1" tmp
    lock_task "$task_id"
    [[ ! -e "$state" && ! -e "$output" ]] || fail 'task id already exists'
    tmp="$(mktemp "$task_timing_active/$task_id.tmp.XXXXXX")"
    {
        printf 'taskId\t%s\nstartedAt\t%s\nstartedMs\t%s\n' "$task_id" "$(utc_now)" "$(now_ms)"
        printf 'phase\tstatus\telapsedMs\tstartedAt\tcompletedAt\tmeasurement\n'
    } > "$tmp"
    mv -- "$tmp" "$state"
    echo "$task_id"
}

begin_phase() {
    local label token marker
    label="$(phase_label "$2")"
    lock_task "$1"
    active_task
    mkdir -p "$steps"
    marker="$(mktemp "$steps/phase.XXXXXXXXXX")"
    token="${marker##*/}"
    printf '%s\t%s\t%s\n' "$label" "$(utc_now)" "$(tick_ms)" > "$marker"
    echo "$token"
}

end_phase() {
    local task_id="$1" token="$2" status="$3" label started_at started_tick elapsed completed_at
    valid_id "$token"
    valid_status "$status"
    lock_task "$task_id"
    active_task
    [[ -f "$steps/$token" ]] || fail 'active phase not found'
    IFS=$'\t' read -r label started_at started_tick < "$steps/$token"
    completed_at="$(utc_now)"
    elapsed=$(( $(tick_ms) - started_tick ))
    (( elapsed >= 0 )) || fail 'monotonic clock reset; phase cannot be measured'
    printf '%s\t%s\t%s\t%s\t%s\tmeasured\n' "$label" "$status" "$elapsed" "$started_at" "$completed_at" >> "$state"
    rm -- "$steps/$token"
}

import_phase() {
    local label
    label="$(phase_label "$2")"
    valid_duration "$3"
    valid_status "$4"
    lock_task "$1"
    active_task
    # This duration was measured elsewhere; do not invent its UTC boundaries.
    printf '%s\t%s\t%s\tunknown\tunknown\timported\n' "$label" "$4" "$3" >> "$state"
}

run_phase() {
    local task_id="$1" label="$2" token status=0 record_status=0
    shift 2
    token="$(begin_phase "$task_id" "$label")"
    # begin_phase runs in a subshell, so no lock is held while COMMAND executes.
    # An interrupted/killed wrapper leaves its marker, preventing false finish.
    (umask "$command_umask"; "$@") || status=$?
    (end_phase "$task_id" "$token" "$status") || record_status=$?
    (( status == 0 )) || return "$status"
    return "$record_status"
}

finish_task() {
    local status="$2" started_ms completed_ms tmp marker
    valid_status "$status"
    lock_task "$1"
    active_task
    for marker in "$steps"/*; do
        [[ ! -e "$marker" ]] || fail 'task has unfinished phases; end them before finishing'
    done
    started_ms="$(awk -F '\t' '$1 == "startedMs" { print $2; exit }' "$state")"
    valid_duration "$started_ms"
    completed_ms="$(now_ms)"
    (( completed_ms >= started_ms )) || fail 'wall clock moved before task start'
    tmp="$(mktemp "$task_timing_directory/$1.tmp.XXXXXX")"
    {
        awk -F '\t' '$1 == "phase" { exit } { print }' "$state"
        printf 'completedAt\t%s\nstatus\t%s\ntotalMs\t%s\n' "$(utc_now)" "$status" "$((completed_ms - started_ms))"
        awk -F '\t' 'found { print; next } $1 == "phase" { found = 1; print }' "$state"
    } > "$tmp"
    mv -- "$tmp" "$output"
    rm -- "$state"
    [[ ! -d "$steps" ]] || rmdir -- "$steps"
    echo "$output"
}

case "${1:-}" in
    start) (( $# <= 2 )) || usage; start_task "${2-task-$(date -u +%Y%m%dT%H%M%SZ)-$$}" ;;
    begin) (( $# == 3 )) || usage; begin_phase "$2" "$3" ;;
    end) (( $# == 3 || $# == 4 )) || usage; end_phase "$2" "$3" "${4-0}" ;;
    run) (( $# >= 5 )) && [[ "$4" == -- ]] || usage; shift; task_id="$1"; label="$2"; shift 3; run_phase "$task_id" "$label" "$@" ;;
    phase) (( $# == 4 || $# == 5 )) || usage; import_phase "$2" "$3" "$4" "${5-0}" ;;
    finish) (( $# == 2 || $# == 3 )) || usage; finish_task "$2" "${3-0}" ;;
    status)
        (( $# <= 2 )) || usage
        if (( $# == 2 )); then
            lock_task "$2"
            active_task
            cat -- "$state"
        elif [[ -d "$task_timing_active" ]]; then
            find "$task_timing_active" -maxdepth 1 -type f -name '*.tsv' -printf '%f\n' | sort
        fi
        ;;
    *) usage ;;
esac
