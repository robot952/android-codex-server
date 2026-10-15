#!/usr/bin/env bash

# Source this file from both Gitee entry points. Keep exported SDK paths in the
# caller, and all progress on stderr (the SDK helpers return paths on stdout).
prepare_ci_environment() {
    local root="${1:?repository root required}"
    local ci_prepare_deadline=$(( $(ci_prepare_now) + 3600 ))
    local node_bin prepared_paths
    local gradle_cache_home="${GRADLE_USER_HOME:-$HOME/.gradle}"
    export FLUTTER_VERSION=3.44.8
    export FLUTTER_REVISION=058e0af2c2b57e369d905a03ac9748b0ebf543c6
    export FLUTTER_STORAGE_BASE_URL="${FLUTTER_STORAGE_BASE_URL:-https://storage.flutter-io.cn}"
    export PUB_HOSTED_URL="${PUB_HOSTED_URL:-https://pub.flutter-io.cn}"
    export PUB_CACHE="${PUB_CACHE:-$HOME/.pub-cache}"
    export CODEX_BUILD_ONLINE=1
    export CODEX_CI_PUB=1
    export CODEX_CI_MAVEN_MIRRORS=1
    export CODEX_CI_HOSTED_DEPENDENCIES=1
    export CODEX_CI_APK_BUILD_TIMEOUT=1200
    export GRADLE_OPTS="${GRADLE_OPTS:--Dorg.gradle.jvmargs=-Xmx4g -Dfile.encoding=UTF-8 -Dorg.gradle.workers.max=4}"
    export GRADLE_OPTS="$GRADLE_OPTS -Dorg.gradle.daemon=false -Dorg.gradle.internal.http.connectionTimeout=30000 -Dorg.gradle.internal.http.socketTimeout=30000"
    mkdir -p "$PUB_CACHE" || return $?

    # Gitee's global init scripts can add project repositories to Flutter's
    # included build, which explicitly forbids them. Reuse only cache data,
    # never inherited Gradle configuration or credentials.
    GRADLE_USER_HOME="$(ci_prepare_stage 'Gradle user home' 60 bash "$root/scripts/prepare-ci-gradle-home.sh" \
        "$gradle_cache_home" "$root/.workflow-cache/gradle-user-homes")" || return $?
    export GRADLE_USER_HOME

    node_bin="$(ci_prepare_stage 'Node SDK' 900 bash "$root/scripts/prepare-ci-node.sh" \
        "$HOME/.cache/codex/node")" || return $?
    export PATH="$node_bin:$PATH"

    CODEX_CI_MAVEN_REPOSITORY="$(ci_prepare_stage 'Hosted Maven dependencies' 420 bash "$root/scripts/prepare-ci-maven.sh" \
        "$HOME/.cache/codex/maven" "$root/.workflow-cache/maven-repositories")" || return $?
    export CODEX_CI_MAVEN_REPOSITORY

    # Only our reviewed settings-level policy enters the private home. It is
    # scoped to this exact Flutter SDK, leaving project-repository bans intact.
    mkdir -p "$GRADLE_USER_HOME/init.d" || return $?
    cp "$root/scripts/ci-flutter-repositories.init.gradle" \
        "$GRADLE_USER_HOME/init.d/codex-flutter-repositories.gradle" || return $?

    prepared_paths="$(mktemp -d "$GRADLE_USER_HOME/prepared-paths.XXXXXX")" || return $?
    # Foreground supervisor: never capture its stdout in a substitution, where
    # a surviving peer could keep the pipe open after the other worker fails.
    ci_prepare_stage 'Parallel SDK preparation' 3600 bash "$root/scripts/prepare-ci-sdk-pair.sh" \
        "$root" "$prepared_paths" "$ci_prepare_deadline" >&2 || return $?
    FLUTTER_ROOT="$(<"$prepared_paths/flutter")"
    ANDROID_HOME="$(<"$prepared_paths/android")"
    [[ -n "$FLUTTER_ROOT" && -n "$ANDROID_HOME" ]] || return 1
    export FLUTTER_ROOT ANDROID_HOME
    export CODEX_FLUTTER_BIN="$FLUTTER_ROOT/bin/flutter"
    export ANDROID_SDK_ROOT="$ANDROID_HOME"
    export PATH="$ANDROID_HOME/cmake/3.22.1/bin:$ANDROID_HOME/platform-tools:$FLUTTER_ROOT/bin:$PATH"
    ci_prepare_stage 'Gradle repository preflight' 240 bash "$root/scripts/test-ci-gradle-repositories.sh" >&2 || return $?
    ci_prepare_stage 'Flutter Android precache' 600 "$CODEX_FLUTTER_BIN" precache --android >&2 || return $?
}

ci_prepare_stage() {
    local label="$1" limit="$2"
    shift 2
    local remaining=$((ci_prepare_deadline - $(ci_prepare_now)))
    if (( remaining <= 0 )); then
        echo "[CI] Environment preparation exceeded its 3600s budget before $label" >&2
        return 124
    fi
    if (( remaining < limit )); then limit=$remaining; fi
    bash "$root/scripts/run-ci-stage.sh" "$label" "$limit" "$@"
}

# Linux monotonic time is shared across the parent and both worker shells;
# shell-local SECONDS resets in a child and wall time can jump during NTP sync.
ci_prepare_now() {
    awk '{print int($1)}' /proc/uptime
}
