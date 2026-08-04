#!/usr/bin/env bash
set -euo pipefail

# Starts one persistent headless AVD and leaves it running for the next task.
# App data, server profiles, imported keys, and quick-boot state are retained.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/android-sdk.sh"
source "$ROOT_DIR/scripts/workflow-lib.sh"
resolve_android_sdk "$ROOT_DIR"

ADB="$ANDROID_HOME/platform-tools/adb"
EMULATOR="$ANDROID_HOME/emulator/emulator"
AVD_NAME="${CODEX_EMULATOR_AVD:-Codex_API_34}"
EMULATOR_PORT="${CODEX_EMULATOR_PORT:-5554}"
SERIAL="emulator-$EMULATOR_PORT"
CACHE_DIR="$(workflow_cache_dir "$ROOT_DIR")/emulator"
PID_PATH="$CACHE_DIR/emulator.pid"
LOG_PATH="$CACHE_DIR/emulator.log"
SERVICE_NAME="${CODEX_EMULATOR_SERVICE:-codex-remote-android-emulator.service}"
COMMAND="${1:-start}"
mkdir -p "$CACHE_DIR"

running_avd() {
    "$ADB" -s "$SERIAL" emu avd name 2>/dev/null | tr -d '\r' | head -n 1
}

is_running() {
    [[ "$("$ADB" -s "$SERIAL" get-state 2>/dev/null || true)" == device ]] &&
        [[ "$(running_avd)" == "$AVD_NAME" ]]
}

wait_for_boot() {
    local deadline=$(( $(date +%s) + ${CODEX_EMULATOR_BOOT_TIMEOUT:-240} ))
    while (( $(date +%s) < deadline )); do
        if [[ "$("$ADB" -s "$SERIAL" get-state 2>/dev/null || true)" == device ]] &&
            [[ "$("$ADB" -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == 1 ]]; then
            return 0
        fi
        if [[ -f "$PID_PATH" ]] && ! kill -0 "$(cat "$PID_PATH")" 2>/dev/null; then
            echo "Emulator exited before boot; see $LOG_PATH" >&2
            return 1
        fi
        sleep 2
    done
    echo "Timed out waiting for $SERIAL; see $LOG_PATH" >&2
    return 1
}

start_emulator() {
    local available_avds
    "$ADB" start-server >/dev/null
    if is_running; then
        printf '%s\n' "$SERIAL"
        return 0
    fi
    if [[ "$("$ADB" -s "$SERIAL" get-state 2>/dev/null || true)" == device ]]; then
        echo "$SERIAL is already used by a different AVD: $(running_avd)" >&2
        return 1
    fi
    available_avds="$("$EMULATOR" -list-avds)"
    if ! rg -Fxq "$AVD_NAME" <<< "$available_avds"; then
        echo "AVD $AVD_NAME is missing. Install API 34 once, then create it with avdmanager." >&2
        return 1
    fi

    exec 9>"$CACHE_DIR/start.lock"
    flock 9
    if is_running; then
        printf '%s\n' "$SERIAL"
        return 0
    fi

    echo "Starting reusable AVD $AVD_NAME on $SERIAL" >&2
    : > "$LOG_PATH"
    if command -v systemd-run >/dev/null 2>&1 && [[ "$(id -u)" == 0 ]]; then
        systemctl reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true
        systemd-run \
            --unit "$SERVICE_NAME" \
            --collect \
            --property=Type=simple \
            --property=Restart=on-failure \
            --property=RestartSec=2 \
            --property=StandardOutput="append:$LOG_PATH" \
            --property=StandardError="append:$LOG_PATH" \
            --setenv=ANDROID_HOME="$ANDROID_HOME" \
            --setenv=ANDROID_SDK_ROOT="$ANDROID_HOME" \
            "$EMULATOR" \
                -avd "$AVD_NAME" \
                -port "$EMULATOR_PORT" \
                -no-window \
                -no-audio \
                -no-boot-anim \
                -gpu "${CODEX_EMULATOR_GPU:-swiftshader_indirect}" \
                >/dev/null
        systemctl show -p MainPID --value "$SERVICE_NAME" > "$PID_PATH"
    else
        nohup "$EMULATOR" \
            -avd "$AVD_NAME" \
            -port "$EMULATOR_PORT" \
            -no-window \
            -no-audio \
            -no-boot-anim \
            -gpu "${CODEX_EMULATOR_GPU:-swiftshader_indirect}" \
            > "$LOG_PATH" 2>&1 < /dev/null &
        printf '%s\n' "$!" > "$PID_PATH"
    fi
    wait_for_boot
    "$ADB" -s "$SERIAL" shell settings put global window_animation_scale 0 >/dev/null
    "$ADB" -s "$SERIAL" shell settings put global transition_animation_scale 0 >/dev/null
    "$ADB" -s "$SERIAL" shell settings put global animator_duration_scale 0 >/dev/null
    "$ADB" -s "$SERIAL" shell settings put global hide_error_dialogs 1 >/dev/null
    "$ADB" -s "$SERIAL" shell settings put global anr_show_background 0 >/dev/null
    "$ADB" -s "$SERIAL" shell input keyevent 82 >/dev/null 2>&1 || true
    printf '%s\n' "$SERIAL"
}

stop_emulator() {
    if ! is_running; then
        if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
            echo "Stopping emulator service without an active ADB device"
            systemctl stop "$SERVICE_NAME"
            return 0
        fi
        echo "$AVD_NAME is not running"
        return 0
    fi
    echo "Stopping $SERIAL and saving quick-boot state"
    "$ADB" -s "$SERIAL" emu kill >/dev/null 2>&1 || true
    local deadline=$(( $(date +%s) + 60 ))
    while (( $(date +%s) < deadline )); do
        if [[ "$("$ADB" -s "$SERIAL" get-state 2>/dev/null || true)" != device ]]; then
            systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
            return 0
        fi
        sleep 1
    done
    echo "$SERIAL did not stop within 60 seconds" >&2
    return 1
}

case "$COMMAND" in
    start|serial)
        start_emulator
        ;;
    stop)
        stop_emulator
        ;;
    restart)
        stop_emulator
        start_emulator
        ;;
    status)
        if is_running; then
            echo "$AVD_NAME is running as $SERIAL"
            "$ADB" -s "$SERIAL" shell getprop ro.build.version.release | tr -d '\r' | sed 's/^/Android /'
        else
            echo "$AVD_NAME is stopped"
            systemctl is-failed "$SERVICE_NAME" >/dev/null 2>&1 &&
                echo "Service failed; run $0 log" || true
        fi
        ;;
    log)
        tail -n "${CODEX_EMULATOR_LOG_LINES:-120}" "$LOG_PATH" 2>/dev/null || true
        ;;
    *)
        echo "usage: $0 {start|serial|stop|restart|status|log}" >&2
        exit 2
        ;;
esac
