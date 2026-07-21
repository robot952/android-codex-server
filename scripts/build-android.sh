#!/usr/bin/env bash
set -euo pipefail

# One entry point for repeatable Android checks. Keep the release gate separate
# from the fast edit loop so Lint and R8 are not paid for every small change.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

mode="${1:-debug}"
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
    *)
        echo "usage: $0 {fast|debug|release|all}" >&2
        exit 2
        ;;
esac

if [[ -z "${ANDROID_HOME:-}" && -n "${ANDROID_SDK_ROOT:-}" ]]; then
    export ANDROID_HOME="$ANDROID_SDK_ROOT"
elif [[ -z "${ANDROID_HOME:-}" && -d /var/lib/docker/volumes/android-sdk/_data ]]; then
    export ANDROID_HOME=/var/lib/docker/volumes/android-sdk/_data
fi
if [[ -n "${ANDROID_HOME:-}" && -z "${ANDROID_SDK_ROOT:-}" ]]; then
    export ANDROID_SDK_ROOT="$ANDROID_HOME"
fi

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
exit "$status"
