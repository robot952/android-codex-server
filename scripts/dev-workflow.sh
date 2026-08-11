#!/usr/bin/env bash
set -euo pipefail

# One command for the normal edit, validation, emulator, and local-publish loop.
# Each underlying gate owns a content-addressed cache, so broad workflows remain
# cheap when only one subsystem changed.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
source "$ROOT_DIR/scripts/workflow-lib.sh"

mode="${1:-quick}"
[[ $# -gt 0 ]] && shift
force=0
run_emulator=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force) force=1 ;;
        --reuse) force=0 ;;
        --no-emulator) run_emulator=0 ;;
        --online) export CODEX_BUILD_ONLINE=1 ;;
        *)
            echo "usage: $0 {quick|check|full|publish|status} [--force|--reuse] [--no-emulator] [--online]" >&2
            exit 2
            ;;
    esac
    shift
done

cache_flag="--reuse"
[[ "$force" == 1 ]] && cache_flag="--force"
android_build_ran=0
workflow_started_ns="$(date +%s%N)"
workflow_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
declare -a workflow_stage_names=()
declare -a workflow_stage_statuses=()
declare -a workflow_stage_elapsed_ms=()

finish_workflow() {
    local status=$?
    local ended_ns
    local total_ms
    local stage_total_ms=0
    local overhead_ms
    local index
    local timing_dir
    local timing_path
    local latest_path
    local temporary_path
    trap - EXIT
    set +e
    ended_ns="$(date +%s%N)"
    total_ms=$(( (ended_ns - workflow_started_ns) / 1000000 ))
    for ((index = 0; index < ${#workflow_stage_elapsed_ms[@]}; index++)); do
        stage_total_ms=$((stage_total_ms + workflow_stage_elapsed_ms[index]))
    done
    overhead_ms=$((total_ms - stage_total_ms))

    echo
    echo "==> Workflow timing summary ($mode)"
    for ((index = 0; index < ${#workflow_stage_names[@]}; index++)); do
        printf '%-42s %12s  status=%s\n' \
            "${workflow_stage_names[index]}" \
            "$(workflow_format_duration_ms "${workflow_stage_elapsed_ms[index]}")" \
            "${workflow_stage_statuses[index]}"
    done
    printf '%-42s %12s\n' "Orchestration/cache lookup" "$(workflow_format_duration_ms "$overhead_ms")"
    printf '%-42s %12s  status=%s\n' "Total" "$(workflow_format_duration_ms "$total_ms")" "$status"

    timing_dir="$(workflow_cache_dir "$ROOT_DIR")/workflow-timings"
    latest_path="$(workflow_cache_dir "$ROOT_DIR")/latest-workflow-timing.tsv"
    mkdir -p "$timing_dir"
    timing_path="$timing_dir/$(date -u +%Y%m%dT%H%M%SZ)-${mode//[^A-Za-z0-9_-]/_}-$$.tsv"
    temporary_path="$(mktemp "${timing_path}.XXXXXX")"
    {
        printf 'mode\t%s\n' "$mode"
        printf 'startedAt\t%s\n' "$workflow_started_at"
        printf 'completedAt\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'status\t%s\n' "$status"
        printf 'totalMs\t%s\n' "$total_ms"
        printf 'orchestrationMs\t%s\n' "$overhead_ms"
        printf 'stage\tstatus\telapsedMs\n'
        for ((index = 0; index < ${#workflow_stage_names[@]}; index++)); do
            printf '%s\t%s\t%s\n' \
                "${workflow_stage_names[index]}" \
                "${workflow_stage_statuses[index]}" \
                "${workflow_stage_elapsed_ms[index]}"
        done
    } > "$temporary_path"
    mv -f "$temporary_path" "$timing_path"
    cp -f "$timing_path" "$latest_path"
    ls -1t "$timing_dir"/*.tsv 2>/dev/null | tail -n +101 | xargs -r rm -f --
    echo "Timing record: $timing_path"
    exit "$status"
}
trap finish_workflow EXIT

run_stage() {
    local name="$1"
    shift
    local started_ns
    local ended_ns
    local elapsed_ms
    local status
    started_ns="$(date +%s%N)"
    echo
    echo "==> $name"
    if "$@"; then
        status=0
    else
        status=$?
    fi
    ended_ns="$(date +%s%N)"
    elapsed_ms=$(( (ended_ns - started_ns) / 1000000 ))
    workflow_stage_names+=("$name")
    workflow_stage_statuses+=("$status")
    workflow_stage_elapsed_ms+=("$elapsed_ms")
    echo "<== $name ($(workflow_format_duration_ms "$elapsed_ms"), status $status)"
    return "$status"
}

run_android_gate() {
    local stage_name="$1"
    local android_mode="$2"
    local emulator_status
    if [[ "$force" == 0 ]] && "$ROOT_DIR/scripts/build-android.sh" "$android_mode" --cache-status; then
        echo "Android $android_mode inputs are unchanged; keeping the emulator running"
        android_build_ran=0
        return 0
    fi
    emulator_status="$("$ROOT_DIR/scripts/android-emulator.sh" status)"
    if rg -q ' is running as ' <<< "$emulator_status"; then
        run_stage "Pause emulator for Android build" "$ROOT_DIR/scripts/android-emulator.sh" stop
    fi
    run_stage "$stage_name" "$ROOT_DIR/scripts/build-android.sh" "$android_mode" "$cache_flag"
    android_build_ran=1
}

prepare_emulator() {
    local emulator_status
    if [[ "$android_build_ran" != 1 ]]; then
        emulator_status="$("$ROOT_DIR/scripts/android-emulator.sh" status)"
        if rg -q ' is running as ' <<< "$emulator_status"; then
            return 0
        fi
    fi
    local gradle_home="${GRADLE_USER_HOME:-$ROOT_DIR/../.gradle-cache}"
    if [[ -d "$gradle_home" ]]; then
        if [[ -x "$ROOT_DIR/flutter_app/android/gradlew" ]]; then
            run_stage "Release Gradle memory for emulator" env GRADLE_USER_HOME="$gradle_home" "$ROOT_DIR/flutter_app/android/gradlew" --stop
        fi
    fi
}

sync_codegraph() {
    if [[ -d "$ROOT_DIR/.codegraph" ]] && command -v codegraph >/dev/null 2>&1; then
        run_stage "CodeGraph incremental sync" codegraph sync
    fi
}

show_status() {
    git status --short --branch
    echo
    "$ROOT_DIR/scripts/android-emulator.sh" status
    echo
    local runtime_path
    local runtime_version
    runtime_version="$(tr -d '[:space:]' < "$ROOT_DIR/protocol/opencode-version.txt")"
    if runtime_path="$(workflow_find_opencode "$ROOT_DIR" "$runtime_version")"; then
        echo "OpenCode: $runtime_path ($(workflow_opencode_version "$runtime_path"))"
    else
        echo "OpenCode: pinned $runtime_version runtime is missing"
    fi
    echo "Workflow cache: $(workflow_cache_dir "$ROOT_DIR")"
    find "$(workflow_cache_dir "$ROOT_DIR")" -maxdepth 1 -type f -name '*.stamp' \
        -printf '%TY-%Tm-%Td %TH:%TM:%TS %f\n' 2>/dev/null | sort || true
    for apk_path in \
        flutter_app/build/app/outputs/flutter-apk/app-debug.apk \
        flutter_app/build/app/outputs/flutter-apk/app-release.apk \
        /var/www/html/codex.apk \
        /var/www/html/agent.apk; do
        [[ -f "$apk_path" ]] && sha256sum "$apk_path"
    done
}

case "$mode" in
    quick)
        run_stage "Server script gate" "$ROOT_DIR/scripts/test-server.sh" "$cache_flag"
        run_stage "OpenCode bridge quick gate" "$ROOT_DIR/scripts/test-opencode.sh" quick "$cache_flag"
        run_android_gate "Android incremental compile" fast
        ;;
    check)
        run_stage "Server script gate" "$ROOT_DIR/scripts/test-server.sh" "$cache_flag"
        run_stage "OpenCode bridge full gate" "$ROOT_DIR/scripts/test-opencode.sh" full "$cache_flag"
        run_android_gate "Android debug gate" debug
        if [[ "$run_emulator" == 1 ]]; then
            prepare_emulator
            run_stage "Persistent emulator debug smoke" "$ROOT_DIR/scripts/emulator-smoke.sh" debug "$cache_flag"
        fi
        sync_codegraph
        ;;
    full|publish)
        run_stage "Server script gate" "$ROOT_DIR/scripts/test-server.sh" "$cache_flag"
        run_stage "OpenCode bridge full gate" "$ROOT_DIR/scripts/test-opencode.sh" full "$cache_flag"
        run_android_gate "Android full gate" all
        if [[ "$run_emulator" == 1 ]]; then
            prepare_emulator
            run_stage "Persistent emulator release smoke" "$ROOT_DIR/scripts/emulator-smoke.sh" release "$cache_flag"
        fi
        sync_codegraph
        if [[ "$mode" == publish ]]; then
            run_stage "Local APK publish" "$ROOT_DIR/scripts/publish-local-apk.sh" --reuse
        fi
        ;;
    status)
        show_status
        ;;
    *)
        echo "usage: $0 {quick|check|full|publish|status} [--force|--reuse] [--no-emulator] [--online]" >&2
        exit 2
        ;;
esac
