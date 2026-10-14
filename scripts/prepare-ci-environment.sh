#!/usr/bin/env bash

# Source this file from both Gitee entry points. Keep exported SDK paths in the
# caller, and all progress on stderr (the SDK helpers return paths on stdout).
prepare_ci_environment() {
    local root="${1:?repository root required}"
    local ci_prepare_deadline=$((SECONDS + 3600))
    local flutter_archive_url flutter_archive_sha256
    export FLUTTER_VERSION=3.44.8
    export FLUTTER_REVISION=058e0af2c2b57e369d905a03ac9748b0ebf543c6
    export FLUTTER_STORAGE_BASE_URL="${FLUTTER_STORAGE_BASE_URL:-https://storage.flutter-io.cn}"
    export PUB_HOSTED_URL="${PUB_HOSTED_URL:-https://pub.flutter-io.cn}"
    export PUB_CACHE="${PUB_CACHE:-$HOME/.pub-cache}"
    export GRADLE_USER_HOME="${GRADLE_USER_HOME:-$HOME/.gradle}"
    export CODEX_BUILD_ONLINE=1
    export CODEX_CI_PUB=1
    export GRADLE_OPTS="${GRADLE_OPTS:--Dorg.gradle.jvmargs=-Xmx4g -Dfile.encoding=UTF-8 -Dorg.gradle.workers.max=4}"
    export GRADLE_OPTS="$GRADLE_OPTS -Dorg.gradle.daemon=false"
    mkdir -p "$PUB_CACHE" "$GRADLE_USER_HOME" || return $?

    flutter_archive_url="$FLUTTER_STORAGE_BASE_URL/flutter_infra_release/releases/stable/linux/flutter_linux_$FLUTTER_VERSION-stable.tar.xz"
    flutter_archive_sha256=672089e001571a9fbb209a495c583580c0c6c73ef98999264ba07fa93ace332d
    FLUTTER_ROOT="$(ci_prepare_stage 'Flutter SDK' 1200 bash "$root/scripts/prepare-ci-flutter.sh" \
        "$HOME/.cache/codex/flutter-$FLUTTER_VERSION" "$FLUTTER_VERSION" "$FLUTTER_REVISION" \
        "$flutter_archive_url" "$flutter_archive_sha256")" || return $?
    export FLUTTER_ROOT
    export CODEX_FLUTTER_BIN="$FLUTTER_ROOT/bin/flutter"
    export PATH="$FLUTTER_ROOT/bin:$PATH"

    ANDROID_HOME="$(ci_prepare_stage 'Android SDK' 1800 bash "$root/scripts/prepare-ci-android.sh" \
        "$HOME/.cache/codex/android-sdk")" || return $?
    export ANDROID_HOME
    export ANDROID_SDK_ROOT="$ANDROID_HOME"
    export PATH="$ANDROID_HOME/platform-tools:$PATH"
    ci_prepare_stage 'Gradle distribution' 2400 env CODEX_CI_GRADLE_BOUNDED=1 bash "$root/scripts/prepare-ci-gradle.sh" \
        "$HOME/.cache/codex/gradle" "$root/flutter_app/android/gradle/wrapper/gradle-wrapper.properties" >&2 || return $?
    ci_prepare_stage 'Flutter Android precache' 600 "$CODEX_FLUTTER_BIN" precache --android >&2 || return $?
}

ci_prepare_stage() {
    local label="$1" limit="$2"
    shift 2
    local remaining=$((ci_prepare_deadline - SECONDS))
    if (( remaining <= 0 )); then
        echo "[CI] Environment preparation exceeded its 3600s budget before $label" >&2
        return 124
    fi
    if (( remaining < limit )); then limit=$remaining; fi
    bash "$root/scripts/run-ci-stage.sh" "$label" "$limit" "$@"
}
