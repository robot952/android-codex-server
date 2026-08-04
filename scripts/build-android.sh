#!/usr/bin/env bash
set -euo pipefail

# One entry point for repeatable Android checks. Keep the release gate separate
# from the fast edit loop so Lint and R8 are not paid for every small change.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
source "$ROOT_DIR/scripts/android-sdk.sh"
source "$ROOT_DIR/scripts/workflow-lib.sh"

mode="debug"
reuse="${CODEX_BUILD_REUSE:-0}"
cache_status_only=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        fast|debug|release|all) mode="$1" ;;
        --reuse) reuse=1 ;;
        --force) reuse=0 ;;
        --cache-status) cache_status_only=1 ;;
        *)
            echo "usage: $0 {fast|debug|release|all} [--reuse|--force] [--cache-status]" >&2
            exit 2
            ;;
    esac
    shift
done
if [[ "${CODEX_WORKFLOW_NO_CACHE:-0}" == 1 ]]; then
    reuse=0
fi

case "$mode" in
    fast)
        tasks=(compileDebugKotlin)
        ;;
    debug)
        tasks=(testDebugUnitTest assembleDebug)
        ;;
    release)
        tasks=(testReleaseUnitTest lintRelease assembleRelease)
        ;;
    all)
        tasks=(testDebugUnitTest testReleaseUnitTest lintDebug lintRelease assembleDebug assembleRelease)
        ;;
esac

resolve_android_sdk "$ROOT_DIR"

# Keep the cache on the same writable, persistent disk as the workspace. This
# also works when HOME is mounted read-only by an agent/container sandbox.
# Override GRADLE_USER_HOME for CI or a different cache location. Fall back to
# the user's cache if an existing shared cache belongs to another build user.
if [[ -z "${GRADLE_USER_HOME:-}" ]]; then
    shared_cache="$ROOT_DIR/../.gradle-cache"
    if [[ -e "$shared_cache" && ! -w "$shared_cache" ]]; then
        export GRADLE_USER_HOME="$HOME/.gradle"
    else
        export GRADLE_USER_HOME="$shared_cache"
    fi
fi
mkdir -p "$GRADLE_USER_HOME"

cache_dir="$(workflow_cache_dir "$ROOT_DIR")"
mkdir -p "$cache_dir"
exec 9>"$cache_dir/android-build.lock"
flock 9

android_input_hash="$(workflow_repo_hash "$ROOT_DIR" \
    app \
    build.gradle.kts \
    settings.gradle.kts \
    gradle.properties \
    gradle \
    gradlew \
    protocol \
    keystore \
    scripts/android-sdk.sh \
    scripts/build-android.sh \
    scripts/workflow-lib.sh)"
java_identity="$(java -version 2>&1 | head -n 1)"
build_tools_identity="$(find "$ANDROID_HOME/build-tools" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -V | tail -n 1)"

android_fingerprint() {
    local fingerprint_mode="$1"
    printf 'schema=3\nmode=%s\ninputs=%s\njava=%s\nsdk=%s\nbuildTools=%s\n' \
        "$fingerprint_mode" "$android_input_hash" "$java_identity" "$ANDROID_HOME" "$build_tools_identity" |
        workflow_sha256
}

build_stamp_valid() {
    local stamp_mode="$1"
    local stamp_path="$cache_dir/android-$stamp_mode.stamp"
    local expected_fingerprint
    local expected_sha
    expected_fingerprint="$(android_fingerprint "$stamp_mode")"
    workflow_stamp_matches "$stamp_path" "$expected_fingerprint" || return 1
    case "$stamp_mode" in
        fast)
            [[ -d "$ROOT_DIR/app/build/tmp/kotlin-classes/debug" ]]
            ;;
        debug)
            [[ -f "$ROOT_DIR/app/build/outputs/apk/debug/app-debug.apk" ]] || return 1
            expected_sha="$(workflow_stamp_value "$stamp_path" debugApkSha256 || true)"
            [[ -n "$expected_sha" && "$(sha256sum "$ROOT_DIR/app/build/outputs/apk/debug/app-debug.apk" | awk '{print $1}')" == "$expected_sha" ]]
            ;;
        release)
            [[ -f "$ROOT_DIR/app/build/outputs/apk/release/app-release.apk" ]] || return 1
            expected_sha="$(workflow_stamp_value "$stamp_path" releaseApkSha256 || true)"
            [[ -n "$expected_sha" && "$(sha256sum "$ROOT_DIR/app/build/outputs/apk/release/app-release.apk" | awk '{print $1}')" == "$expected_sha" ]]
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
        if [[ -f "$ROOT_DIR/app/build/outputs/apk/debug/app-debug.apk" ]]; then
            printf 'debugApkSha256=%s\n' "$(sha256sum "$ROOT_DIR/app/build/outputs/apk/debug/app-debug.apk" | awk '{print $1}')"
        fi
        if [[ -f "$ROOT_DIR/app/build/outputs/apk/release/app-release.apk" ]]; then
            printf 'releaseApkSha256=%s\n' "$(sha256sum "$ROOT_DIR/app/build/outputs/apk/release/app-release.apk" | awk '{print $1}')"
        fi
    } > "$temporary_stamp"
    mv -f "$temporary_stamp" "$stamp_path"
}

if [[ "$cache_status_only" == 1 ]]; then
    if [[ "${CODEX_WORKFLOW_NO_CACHE:-0}" == 1 ]]; then
        echo "Android $mode gate: cache disabled"
        exit 1
    fi
    if build_stamp_valid "$mode"; then
        echo "Android $mode gate: cache hit"
        exit 0
    fi
    echo "Android $mode gate: cache miss"
    exit 1
fi

if [[ "$reuse" == 1 ]] && build_stamp_valid "$mode"; then
    echo "Android $mode gate: cache hit"
    echo "Gradle cache: $GRADLE_USER_HOME"
    exit 0
fi

gradle_args=(--console=plain --build-cache)
if [[ "${CODEX_BUILD_NO_CONFIG_CACHE:-0}" != 1 ]]; then
    gradle_args+=(--configuration-cache)
else
    gradle_args+=(--no-configuration-cache)
fi

if [[ "${CODEX_BUILD_ONLINE:-0}" == 1 ]]; then
    if (echo >/dev/tcp/127.0.0.1/7890) 2>/dev/null; then
        proxy_opts="-Dhttp.proxyHost=127.0.0.1 -Dhttp.proxyPort=7890 -Dhttps.proxyHost=127.0.0.1 -Dhttps.proxyPort=7890"
        export GRADLE_OPTS="${GRADLE_OPTS:-} $proxy_opts"
        export http_proxy="http://127.0.0.1:7890"
        export https_proxy="http://127.0.0.1:7890"
        export HTTP_PROXY="$http_proxy"
        export HTTPS_PROXY="$https_proxy"
        echo "Using download proxy 127.0.0.1:7890"
    else
        echo "Download proxy 127.0.0.1:7890 is not listening; using configured network settings" >&2
    fi
else
    gradle_args+=(--offline)
fi

printf 'Tasks: %s\n' "${tasks[*]}"
printf 'Gradle cache: %s\n' "$GRADLE_USER_HOME"

start_ns="$(date +%s%N)"
status=0
"$ROOT_DIR/gradlew" "${gradle_args[@]}" "${tasks[@]}" || status=$?
end_ns="$(date +%s%N)"
elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
printf 'Elapsed: %d ms (%d.%03d s)\n' "$elapsed_ms" "$((elapsed_ms / 1000))" "$((elapsed_ms % 1000))"
if [[ "$status" == 0 ]]; then
    write_build_stamp "$mode"
    case "$mode" in
        debug)
            write_build_stamp fast
            ;;
        all)
            write_build_stamp fast
            write_build_stamp debug
            write_build_stamp release
            ;;
    esac
fi
exit "$status"
