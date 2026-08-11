#!/usr/bin/env bash
set -euo pipefail

# Installs only a changed APK, preserves app data, relaunches the app, and
# checks the persistent emulator for an immediate crash/ANR.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
source "$ROOT_DIR/scripts/android-sdk.sh"
source "$ROOT_DIR/scripts/workflow-lib.sh"
resolve_android_sdk "$ROOT_DIR"

variant="debug"
force_install=0
reset_data=0
reuse=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        debug|release) variant="$1" ;;
        --force-install) force_install=1 ;;
        --reset-data) reset_data=1 ;;
        --reuse) reuse=1 ;;
        --force) reuse=0 ;;
        *)
            echo "usage: $0 {debug|release} [--reuse|--force] [--force-install] [--reset-data]" >&2
            exit 2
            ;;
    esac
    shift
done
if [[ "${CODEX_WORKFLOW_NO_CACHE:-0}" == 1 || "$force_install" == 1 || "$reset_data" == 1 ]]; then
    reuse=0
fi

case "$variant" in
    debug) apk_path="$ROOT_DIR/flutter_app/build/app/outputs/flutter-apk/app-debug.apk" ;;
    release) apk_path="$ROOT_DIR/flutter_app/build/app/outputs/flutter-apk/app-release.apk" ;;
esac
[[ -f "$apk_path" ]] || {
    echo "APK is missing: $apk_path" >&2
    exit 1
}

ADB="$ANDROID_HOME/platform-tools/adb"
PACKAGE="${CODEX_SMOKE_PACKAGE:-top.asdb.agent}"
LAUNCHER_COMPONENT="$PACKAGE/.MainActivity"
SERIAL="$($ROOT_DIR/scripts/android-emulator.sh serial)"
CACHE_DIR="$(workflow_cache_dir "$ROOT_DIR")/emulator"
MARKER_PATH="/data/local/tmp/agent-apk.sha256"
apk_sha256="$(sha256sum "$apk_path" | awk '{print $1}')"
installed_marker="$("$ADB" -s "$SERIAL" shell cat "$MARKER_PATH" 2>/dev/null | tr -d '\r' || true)"
package_path="$("$ADB" -s "$SERIAL" shell pm path "$PACKAGE" 2>/dev/null | tr -d '\r' || true)"
app_pid="$("$ADB" -s "$SERIAL" shell pidof "$PACKAGE" 2>/dev/null | tr -d '\r' || true)"
activity_state="$("$ADB" -s "$SERIAL" shell dumpsys activity activities 2>/dev/null || true)"
device_boot_id="$("$ADB" -s "$SERIAL" shell cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d '\r' || true)"
host_boot_id="$(tr -d '\r\n' < /proc/sys/kernel/random/boot_id)"
emulator_pid="$(systemctl show -p MainPID --value "${CODEX_EMULATOR_SERVICE:-codex-remote-android-emulator.service}" 2>/dev/null || true)"
if [[ -z "$emulator_pid" || "$emulator_pid" == 0 ]]; then
    emulator_pid="$(cat "$CACHE_DIR/emulator.pid" 2>/dev/null || true)"
fi
emulator_pid="${emulator_pid:-unknown}"
smoke_input_hash="$(workflow_repo_hash "$ROOT_DIR" \
    scripts/android-emulator.sh \
    scripts/emulator-smoke.sh \
    scripts/workflow-lib.sh)"
smoke_fingerprint="$(printf 'schema=2\nvariant=%s\napk=%s\ninputs=%s\nserial=%s\nhostBoot=%s\nemulatorPid=%s\ndeviceBoot=%s\n' \
    "$variant" "$apk_sha256" "$smoke_input_hash" "$SERIAL" "$host_boot_id" "$emulator_pid" "$device_boot_id" |
    workflow_sha256)"
smoke_stamp="$CACHE_DIR/smoke-$variant.stamp"
minimum_short_edge="${CODEX_EMULATOR_MIN_SHORT_EDGE:-1080}"
minimum_long_edge="${CODEX_EMULATOR_MIN_LONG_EDGE:-2400}"

assert_minimum_portrait_canvas() {
    local screenshot="$1"
    local metadata
    local width
    local height
    metadata="$(file "$screenshot")"
    read -r width height <<< "$(sed -nE 's/.*PNG image data, ([0-9]+) x ([0-9]+),.*/\1 \2/p' <<< "$metadata")"
    if [[ -z "${width:-}" || -z "${height:-}" ]]; then
        echo "$metadata" >&2
        echo "Unable to read emulator screenshot dimensions" >&2
        return 1
    fi
    if (( width < minimum_short_edge || height < minimum_long_edge || width >= height )); then
        echo "$metadata" >&2
        echo "Portrait canvas is too small; use at least ${minimum_short_edge}x${minimum_long_edge}" >&2
        return 1
    fi
}

set_rotation() {
    "$ADB" -s "$SERIAL" shell cmd window user-rotation lock "$1" >/dev/null
}

restore_portrait() {
    set_rotation 0 >/dev/null 2>&1 || true
}

trap restore_portrait EXIT
set_rotation 0

if [[ "$reuse" == 1 ]] &&
    workflow_stamp_matches "$smoke_stamp" "$smoke_fingerprint" &&
    [[ "$installed_marker" == "$apk_sha256" && -n "$package_path" && -n "$app_pid" ]] &&
    rg -q "topResumedActivity=.*${PACKAGE}/\.MainActivity" <<< "$activity_state"; then
    echo "Emulator $variant smoke: cache hit on $SERIAL"
    exit 0
fi

dump_window() {
    local destination="$1"
    local remote_path="/sdcard/codex-remote-window.xml"
    local attempt
    for attempt in 1 2 3; do
        if "$ADB" -s "$SERIAL" shell uiautomator dump "$remote_path" >/dev/null 2>&1 &&
            "$ADB" -s "$SERIAL" pull "$remote_path" "$destination" >/dev/null 2>&1 &&
            [[ -s "$destination" ]]; then
            return 0
        fi
        sleep 1
    done
    return 1
}

dismiss_existing_error_dialogs() {
    local xml_path="$CACHE_DIR/preflight-window.xml"
    local bounds
    local x1 y1 x2 y2
    local attempt
    for attempt in 1 2 3 4 5 6; do
        dump_window "$xml_path" || return 0
        if ! rg -q "isn't responding|is not responding|keeps stopping" "$xml_path"; then
            return 0
        fi
        bounds="$(rg -o 'resource-id="android:id/aerr_wait"[^>]*bounds="\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]"' "$xml_path" |
            sed -nE 's/.*bounds="\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]"/\1 \2 \3 \4/p' |
            head -n 1)"
        if [[ -z "$bounds" ]]; then
            return 1
        fi
        read -r x1 y1 x2 y2 <<< "$bounds"
        "$ADB" -s "$SERIAL" shell input tap "$(( (x1 + x2) / 2 ))" "$(( (y1 + y2) / 2 ))"
        sleep 2
    done
    return 1
}

mkdir -p "$CACHE_DIR"
"$ADB" -s "$SERIAL" shell settings put global hide_error_dialogs 1 >/dev/null
"$ADB" -s "$SERIAL" shell settings put global anr_show_background 0 >/dev/null
if ! dismiss_existing_error_dialogs; then
    echo "The emulator has a persistent system error dialog; restart it before testing" >&2
    exit 1
fi

if [[ "$reset_data" == 1 ]]; then
    "$ADB" -s "$SERIAL" shell pm clear "$PACKAGE" >/dev/null 2>&1 || true
    package_path=""
fi
if [[ "$force_install" == 1 || "$installed_marker" != "$apk_sha256" || -z "$package_path" ]]; then
    echo "Installing $variant APK on $SERIAL"
    "$ADB" -s "$SERIAL" install -r "$apk_path" >/dev/null
    "$ADB" -s "$SERIAL" shell "printf '%s' '$apk_sha256' > '$MARKER_PATH'"
else
    echo "Reusing installed $variant APK on $SERIAL"
fi

"$ADB" -s "$SERIAL" logcat -c
"$ADB" -s "$SERIAL" shell am force-stop "$PACKAGE"
launch_output="$("$ADB" -s "$SERIAL" shell am start -W -n "$LAUNCHER_COMPONENT")"
if ! rg -q '^Status: ok$' <<< "$launch_output"; then
    printf '%s\n' "$launch_output" >&2
    echo "App launch did not report success" >&2
    exit 1
fi

sleep "${CODEX_EMULATOR_SETTLE_SECONDS:-3}"
if [[ -z "$("$ADB" -s "$SERIAL" shell pidof "$PACKAGE" 2>/dev/null | tr -d '\r')" ]]; then
    "$ADB" -s "$SERIAL" logcat -d -v brief >&2
    echo "$PACKAGE is not running after launch" >&2
    exit 1
fi

log_path="$CACHE_DIR/latest-logcat.txt"
screen_path="$CACHE_DIR/latest-$variant.png"
window_path="$CACHE_DIR/latest-window.xml"
"$ADB" -s "$SERIAL" exec-out screencap -p > "$screen_path"
if ! dump_window "$window_path"; then
    echo "Unable to capture the emulator UI hierarchy" >&2
    exit 1
fi
assert_minimum_portrait_canvas "$screen_path"
"$ADB" -s "$SERIAL" logcat -d -v brief > "$log_path"

if awk -v package="$PACKAGE" '
    /FATAL EXCEPTION/ { fatal_window = 20 }
    fatal_window > 0 && index($0, "Process: " package) { bad = 1 }
    index($0, "ANR in " package) { bad = 1 }
    index($0, "Process: " package) && /has died/ { bad = 1 }
    { if (fatal_window > 0) fatal_window-- }
    END { exit bad ? 0 : 1 }
' "$log_path"; then
    rg -n -C 8 'FATAL EXCEPTION|ANR in |Process: ' "$log_path" >&2 || true
    echo "Crash or ANR detected after launch" >&2
    exit 1
fi
if rg -q "isn't responding|is not responding|keeps stopping" "$window_path"; then
    rg -o 'text="[^"]+"[^>]*resource-id="android:id/alertTitle"' "$window_path" >&2 || true
    echo "An Android error dialog is covering the app" >&2
    exit 1
fi
if ! rg -q "package=\"$PACKAGE\"" "$window_path"; then
    echo "The foreground UI does not belong to $PACKAGE" >&2
    exit 1
fi
{
    printf 'variant=%s\n' "$variant"
    printf 'apkSha256=%s\n' "$apk_sha256"
    printf 'serial=%s\n' "$SERIAL"
    printf 'completedAt=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$CACHE_DIR/latest-smoke.txt"
workflow_write_stamp "$smoke_stamp" "$smoke_fingerprint"

echo "Emulator smoke passed on $SERIAL"
echo "Portrait screenshot: $screen_path"
