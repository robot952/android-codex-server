#!/usr/bin/env bash
set -euo pipefail

# Content-addressed Flutter/Android gate. It deliberately keeps Release work
# out of the normal edit loop and never runs `flutter clean`.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLUTTER_DIR="$ROOT_DIR/flutter_app"
cd "$ROOT_DIR"
source "$ROOT_DIR/scripts/android-sdk.sh"
source "$ROOT_DIR/scripts/workflow-lib.sh"

mode="debug"
reuse="${CODEX_BUILD_REUSE:-0}"
cache_status_only=0
plan_only=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        fast|debug|release|all) mode="$1" ;;
        --reuse) reuse=1 ;;
        --force) reuse=0 ;;
        --cache-status) cache_status_only=1 ;;
        --plan) plan_only=1 ;;
        *)
            echo "usage: $0 {fast|debug|release|all} [--reuse|--force] [--cache-status|--plan]" >&2
            exit 2
            ;;
    esac
    shift
done
if [[ "${CODEX_WORKFLOW_NO_CACHE:-0}" == 1 ]]; then
    reuse=0
fi

resolve_android_sdk "$ROOT_DIR"
FLUTTER_BIN="$(workflow_resolve_flutter "$ROOT_DIR")"
export ANDROID_HOME
export ANDROID_SDK_ROOT="$ANDROID_HOME"

if [[ -z "${GRADLE_USER_HOME:-}" ]]; then
    shared_cache="$ROOT_DIR/../.gradle-cache"
    if [[ -e "$shared_cache" && ! -w "$shared_cache" ]]; then
        export GRADLE_USER_HOME="$HOME/.gradle"
    else
        export GRADLE_USER_HOME="$shared_cache"
    fi
fi
if [[ -z "${PUB_CACHE:-}" ]]; then
    shared_pub_cache="$ROOT_DIR/../.pub-cache"
    if [[ -e "$shared_pub_cache" && ! -w "$shared_pub_cache" ]]; then
        export PUB_CACHE="$HOME/.pub-cache"
    else
        export PUB_CACHE="$shared_pub_cache"
    fi
fi
mkdir -p "$GRADLE_USER_HOME" "$PUB_CACHE"

cache_dir="$(workflow_cache_dir "$ROOT_DIR")"
mkdir -p "$cache_dir"
exec 9>"$cache_dir/android-build.lock"
flock 9

debug_apk="$FLUTTER_DIR/build/app/outputs/flutter-apk/app-debug.apk"
release_apk="$FLUTTER_DIR/build/app/outputs/flutter-apk/app-release.apk"
android_input_hash="$(workflow_repo_hash "$ROOT_DIR" \
    flutter_app/lib \
    flutter_app/test \
    flutter_app/android \
    flutter_app/pubspec.yaml \
    flutter_app/pubspec.lock \
    flutter_app/analysis_options.yaml \
    keystore \
    scripts/android-sdk.sh \
    scripts/build-android.sh \
    scripts/workflow-lib.sh)"
java_identity="$(java -version 2>&1 | head -n 1)"
flutter_identity="$("$FLUTTER_BIN" --version 2>/dev/null | head -n 1)"
build_tools_identity="$(find "$ANDROID_HOME/build-tools" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -V | tail -n 1)"

android_fingerprint() {
    local fingerprint_mode="$1"
    printf 'schema=5\nmode=%s\ninputs=%s\njava=%s\nflutter=%s\nsdk=%s\nbuildTools=%s\n' \
        "$fingerprint_mode" "$android_input_hash" "$java_identity" "$flutter_identity" "$ANDROID_HOME" "$build_tools_identity" |
        workflow_sha256
}

build_stamp_valid() {
    local stamp_mode="$1"
    local stamp_path="$cache_dir/android-$stamp_mode.stamp"
    local expected_sha
    workflow_stamp_matches "$stamp_path" "$(android_fingerprint "$stamp_mode")" || return 1
    case "$stamp_mode" in
        fast)
            [[ -f "$FLUTTER_DIR/.dart_tool/package_config.json" ]]
            ;;
        debug)
            [[ -f "$debug_apk" ]] || return 1
            expected_sha="$(workflow_stamp_value "$stamp_path" debugApkSha256 || true)"
            [[ -n "$expected_sha" && "$(sha256sum "$debug_apk" | awk '{print $1}')" == "$expected_sha" ]]
            ;;
        release)
            [[ -f "$release_apk" ]] || return 1
            expected_sha="$(workflow_stamp_value "$stamp_path" releaseApkSha256 || true)"
            [[ -n "$expected_sha" && "$(sha256sum "$release_apk" | awk '{print $1}')" == "$expected_sha" ]]
            ;;
        all)
            build_stamp_valid debug && build_stamp_valid release
            ;;
    esac
}

write_build_stamp() {
    local stamp_mode="$1"
    local stamp_path="$cache_dir/android-$stamp_mode.stamp"
    local temporary_stamp
    temporary_stamp="$(mktemp "${stamp_path}.XXXXXX")"
    {
        printf 'fingerprint=%s\n' "$(android_fingerprint "$stamp_mode")"
        printf 'completedAt=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        [[ ! -f "$debug_apk" ]] || printf 'debugApkSha256=%s\n' "$(sha256sum "$debug_apk" | awk '{print $1}')"
        [[ ! -f "$release_apk" ]] || printf 'releaseApkSha256=%s\n' "$(sha256sum "$release_apk" | awk '{print $1}')"
    } > "$temporary_stamp"
    mv -f "$temporary_stamp" "$stamp_path"
}

fast_gate_valid=0
debug_gate_valid=0
release_gate_valid=0
plan_reuse="$reuse"
if [[ "$cache_status_only" == 1 ]]; then
    plan_reuse=1
fi
if [[ "$plan_reuse" == 1 && "${CODEX_WORKFLOW_NO_CACHE:-0}" != 1 ]]; then
    build_stamp_valid fast && fast_gate_valid=1
    build_stamp_valid debug && debug_gate_valid=1
    build_stamp_valid release && release_gate_valid=1
fi
workflow_android_gate_plan \
    "$mode" "$plan_reuse" "$fast_gate_valid" "$debug_gate_valid" "$release_gate_valid"

print_build_plan() {
    local validation="run"
    local debug_build="skip"
    local release_build="skip"
    [[ "$WORKFLOW_ANDROID_PLAN_VALIDATE" == 1 ]] || validation="reuse:$WORKFLOW_ANDROID_PLAN_VALIDATION_SOURCE"
    [[ "$WORKFLOW_ANDROID_PLAN_BUILD_DEBUG" == 1 ]] && debug_build="build"
    [[ "$WORKFLOW_ANDROID_PLAN_BUILD_RELEASE" == 1 ]] && release_build="build"
    if [[ "$WORKFLOW_ANDROID_PLAN_CACHE_HIT" == 1 ]]; then
        validation="cached"
    fi
    printf 'Android %s plan: validation=%s debug=%s release=%s cacheHit=%s\n' \
        "$mode" "$validation" "$debug_build" "$release_build" "$WORKFLOW_ANDROID_PLAN_CACHE_HIT"
}

if [[ "$plan_only" == 1 ]]; then
    print_build_plan
    exit 0
fi
if [[ "$cache_status_only" == 1 ]]; then
    if [[ "$WORKFLOW_ANDROID_PLAN_CACHE_HIT" == 1 ]]; then
        echo "Android $mode gate: cache hit"
        exit 0
    fi
    echo "Android $mode gate: cache miss"
    exit 1
fi
if [[ "$WORKFLOW_ANDROID_PLAN_CACHE_HIT" == 1 ]]; then
    echo "Android $mode gate: cache hit"
    echo "Flutter: $flutter_identity"
    echo "Gradle cache: $GRADLE_USER_HOME"
    echo "Pub cache: $PUB_CACHE"
    exit 0
fi

configure_proxy() {
    local proxy_opts
    proxy_opts="-Dhttp.proxyHost=127.0.0.1 -Dhttp.proxyPort=7890 -Dhttps.proxyHost=127.0.0.1 -Dhttps.proxyPort=7890"
    export GRADLE_OPTS="${GRADLE_OPTS:-} $proxy_opts"
    export http_proxy="http://127.0.0.1:7890"
    export https_proxy="$http_proxy"
    export HTTP_PROXY="$http_proxy"
    export HTTPS_PROXY="$http_proxy"
    echo "Using download proxy 127.0.0.1:7890"
}

run_timed_build_step() {
    local name="$1"
    shift
    local started_ns
    local ended_ns
    local elapsed_ms
    local status
    started_ns="$(date +%s%N)"
    if "$@"; then
        status=0
    else
        status=$?
    fi
    ended_ns="$(date +%s%N)"
    elapsed_ms=$(( (ended_ns - started_ns) / 1000000 ))
    printf 'Timing: %s = %s (status %d)\n' \
        "$name" "$(workflow_format_duration_ms "$elapsed_ms")" "$status"
    return "$status"
}

resolve_flutter_dependencies() {
    if [[ "${CODEX_BUILD_ONLINE:-0}" == 1 ]]; then
        if (echo >/dev/tcp/127.0.0.1/7890) 2>/dev/null; then
            configure_proxy
        fi
        "$FLUTTER_BIN" pub get
    elif ! "$FLUTTER_BIN" pub get --offline; then
        if (echo >/dev/tcp/127.0.0.1/7890) 2>/dev/null; then
            configure_proxy
            "$FLUTTER_BIN" pub get
        else
            echo "Dependencies are missing and proxy 127.0.0.1:7890 is unavailable" >&2
            return 1
        fi
    fi
}

cd "$FLUTTER_DIR"
printf 'Flutter: %s\n' "$flutter_identity"
printf 'Gradle cache: %s\n' "$GRADLE_USER_HOME"
printf 'Pub cache: %s\n' "$PUB_CACHE"
start_ns="$(date +%s%N)"
run_timed_build_step "Flutter dependencies" resolve_flutter_dependencies

if [[ "$WORKFLOW_ANDROID_PLAN_VALIDATE" == 1 ]]; then
    run_timed_build_step "Flutter analyze" "$FLUTTER_BIN" analyze --no-pub
    if [[ "$mode" != fast ]]; then
        run_timed_build_step "Flutter tests" "$FLUTTER_BIN" test --no-pub
    fi
else
    echo "Reusing analyze/test result from Android $WORKFLOW_ANDROID_PLAN_VALIDATION_SOURCE gate"
fi
if [[ "$WORKFLOW_ANDROID_PLAN_BUILD_DEBUG" == 1 ]]; then
    run_timed_build_step "Debug APK build" "$FLUTTER_BIN" build apk --debug --no-pub
fi
if [[ "$WORKFLOW_ANDROID_PLAN_BUILD_RELEASE" == 1 ]]; then
    run_timed_build_step "Release APK build" "$FLUTTER_BIN" build apk --release --no-pub
fi

end_ns="$(date +%s%N)"
elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
printf 'Elapsed: %d ms (%d.%03d s)\n' "$elapsed_ms" "$((elapsed_ms / 1000))" "$((elapsed_ms % 1000))"
if [[ "$WORKFLOW_ANDROID_PLAN_VALIDATE" == 1 ]]; then
    write_build_stamp fast
fi
if [[ "$WORKFLOW_ANDROID_PLAN_BUILD_DEBUG" == 1 ]]; then
    write_build_stamp debug
fi
if [[ "$WORKFLOW_ANDROID_PLAN_BUILD_RELEASE" == 1 ]]; then
    write_build_stamp release
fi
