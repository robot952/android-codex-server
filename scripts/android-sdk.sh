#!/usr/bin/env bash

# Resolves the SDK location shared by local builds and CI release entry points.
# Callers may still override the result through ANDROID_HOME or ANDROID_SDK_ROOT.
resolve_android_sdk() {
    local root_dir="$1"

    if [[ -z "${ANDROID_HOME:-}" && -n "${ANDROID_SDK_ROOT:-}" ]]; then
        export ANDROID_HOME="$ANDROID_SDK_ROOT"
    elif [[ -z "${ANDROID_HOME:-}" && -d "$root_dir/../android-sdk" ]]; then
        export ANDROID_HOME="$root_dir/../android-sdk"
    elif [[ -z "${ANDROID_HOME:-}" && -d /tmp/android-sdk ]]; then
        export ANDROID_HOME=/tmp/android-sdk
    elif [[ -z "${ANDROID_HOME:-}" && -d /var/lib/docker/volumes/android-sdk/_data ]]; then
        export ANDROID_HOME=/var/lib/docker/volumes/android-sdk/_data
    fi

    if [[ -n "${ANDROID_HOME:-}" && -z "${ANDROID_SDK_ROOT:-}" ]]; then
        export ANDROID_SDK_ROOT="$ANDROID_HOME"
    fi
    if [[ -z "${ANDROID_HOME:-}" || ! -d "$ANDROID_HOME" ]]; then
        echo "Android SDK not found. Set ANDROID_HOME or place it at $root_dir/../android-sdk" >&2
        return 1
    fi
}
