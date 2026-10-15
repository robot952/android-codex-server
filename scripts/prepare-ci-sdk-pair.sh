#!/usr/bin/env bash
set -euo pipefail

# Invoked only through run-ci-stage. Both workers stay in its process group:
# any failure is returned immediately to the outer supervisor, which kills
# surviving descendants. No detached sessions or independent timeout groups.
root="${1:?repository root required}"
prepared_paths="${2:?private output directory required}"
ci_prepare_deadline="${3:?shared preparation deadline required}"
[[ "$ci_prepare_deadline" =~ ^[1-9][0-9]*$ && -d "$prepared_paths" ]]
[[ "${CODEX_CI_PROCESS_GROUP:-}" == "$(ps -o pgid= -p "$$" | tr -d '[:space:]')" ]]
source "$root/scripts/prepare-ci-environment.sh"

echo '[CI] Preparing SDKs in two lanes: Flutter | Android then Gradle' >&2
(
    trap 'printf "%s\n" "$?" > "$prepared_paths/flutter.status"' EXIT
    ci_prepare_stage 'Flutter SDK' 1200 bash "$root/scripts/prepare-ci-flutter.sh" \
        "$HOME/.cache/codex/flutter-$FLUTTER_VERSION" "$FLUTTER_VERSION" "$FLUTTER_REVISION" \
        "$FLUTTER_STORAGE_BASE_URL/flutter_infra_release/releases/stable/linux/flutter_linux_$FLUTTER_VERSION-stable.tar.xz" \
        672089e001571a9fbb209a495c583580c0c6c73ef98999264ba07fa93ace332d > "$prepared_paths/flutter"
) &
flutter_pid=$!
(
    trap 'printf "%s\n" "$?" > "$prepared_paths/android.status"' EXIT
    ci_prepare_stage 'Android SDK' 1800 bash "$root/scripts/prepare-ci-android.sh" \
        "$HOME/.cache/codex/android-sdk" > "$prepared_paths/android"
    export ANDROID_HOME="$(<"$prepared_paths/android")"
    export ANDROID_SDK_ROOT="$ANDROID_HOME"
    ci_prepare_stage 'Gradle distribution' 2400 env CODEX_CI_GRADLE_BOUNDED=1 bash "$root/scripts/prepare-ci-gradle.sh" \
        "$HOME/.cache/codex/gradle" "$root/flutter_app/android/gradle/wrapper/gradle-wrapper.properties" >&2
) &
android_pid=$!
# Completion files also cover workers that finish before the first wait.
# Poll only these two tiny files; the enclosing stage bounds the entire wait.
while :; do
    completed=0
    for lane in flutter android; do
        if [[ -s "$prepared_paths/$lane.status" ]]; then
            status="$(<"$prepared_paths/$lane.status")"
            [[ "$status" == 0 ]] || exit "$status"
            completed=$((completed + 1))
        fi
    done
    (( completed < 2 )) || break
    sleep 0.1
done
wait "$flutter_pid"
wait "$android_pid"
