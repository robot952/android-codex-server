#!/usr/bin/env bash
set -euo pipefail

# Run inside the existing 1200s APK stage. Do not execute an additional build,
# patch Flutter itself, change Wrapper identity, or send a build scan remotely.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
variant="${1:?build variant required}"
shift
[[ "$variant" == debug || "$variant" == release ]]
android="$root/flutter_app/android"
wrapper="$android/gradlew"
[[ ! -L "$wrapper" ]] || { echo '[CI] Refusing a redirected Gradle launcher' >&2; exit 1; }
original="$(mktemp "$android/.ci-original-gradlew.XXXXXX")"
had_wrapper=0
installed=0
cleanup() {
    local status=$?
    trap - EXIT
    if [[ "$installed" == 1 ]]; then
        if [[ "$had_wrapper" == 1 ]]; then cp -p -- "$original" "$wrapper"; else rm -f -- "$wrapper"; fi
    fi
    rm -f -- "$original"
    return "$status"
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP
if [[ -f "$wrapper" ]]; then
    had_wrapper=1
    cp -p -- "$wrapper" "$original"
else
    # Flutter's precache prepared this pinned SDK artifact. Flutter will copy
    # the remaining Wrapper files as usual when it sees our existing launcher.
    cp -- "${FLUTTER_ROOT:?}/bin/cache/artifacts/gradle_wrapper/gradlew" "$original"
fi
installed=1
install -m 0755 "$root/scripts/ci-gradle-profile-wrapper.sh" "$wrapper"
export CODEX_CI_ORIGINAL_GRADLEW="$original"
started_ms="$(date +%s%3N)"
status=0
"$@" || status=$?
# Profiling is diagnostic: collection failure must never hide the build result.
if ! node "$root/scripts/collect-ci-build-diagnostics.cjs" "$root" "$started_ms" "$variant" "$status"; then
    echo '[CI] Build diagnostics unavailable; preserving the APK build result' >&2
fi
exit "$status"
