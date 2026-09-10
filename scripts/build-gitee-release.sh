#!/usr/bin/env bash
set -euo pipefail

# Keep shell expansion here: Gitee also expands ${...} in inline YAML commands.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
export CODEX_RELEASE_BRANCH="${1:-release}"
export FLUTTER_VERSION="3.44.8"
export FLUTTER_REVISION="058e0af2c2b57e369d905a03ac9748b0ebf543c6"
FLUTTER_ROOT="$(bash "$ROOT_DIR/scripts/prepare-ci-flutter.sh" \
    "$HOME/.cache/codex/flutter-$FLUTTER_VERSION" "$FLUTTER_VERSION" "$FLUTTER_REVISION")"
export FLUTTER_ROOT
export CODEX_FLUTTER_BIN="$FLUTTER_ROOT/bin/flutter"
export PUB_CACHE="$HOME/.pub-cache"
export GRADLE_USER_HOME="$HOME/.gradle"
export CODEX_BUILD_ONLINE=1
export GRADLE_OPTS="-Dorg.gradle.jvmargs=-Xmx4g -Dfile.encoding=UTF-8 -Dorg.gradle.workers.max=4"
export PATH="$FLUTTER_ROOT/bin:$PATH"
mkdir -p "$PUB_CACHE" "$GRADLE_USER_HOME"

SDKMANAGER="$(command -v sdkmanager || true)"
if [[ -z "$SDKMANAGER" ]]; then
    for sdk_root in "${ANDROID_SDK_ROOT:-}" "${ANDROID_HOME:-}"; do
        [[ -n "$sdk_root" ]] || continue
        for candidate in "$sdk_root/cmdline-tools/latest/bin/sdkmanager" "$sdk_root/tools/bin/sdkmanager"; do
            if [[ -x "$candidate" ]]; then
                SDKMANAGER="$candidate"
                break 2
            fi
        done
    done
fi
if [[ -z "$SDKMANAGER" ]]; then
    echo "sdkmanager was not found; check ANDROID_HOME/ANDROID_SDK_ROOT in the Gitee runner" >&2
    exit 1
fi

# Some runners expose sdkmanager on PATH without exporting the SDK root.
if [[ -z "${ANDROID_HOME:-}" && -z "${ANDROID_SDK_ROOT:-}" ]]; then
    sdkmanager_path="$(readlink -f "$SDKMANAGER")"
    case "$sdkmanager_path" in
        */cmdline-tools/*/bin/sdkmanager) export ANDROID_HOME="${sdkmanager_path%/cmdline-tools/*}" ;;
        */tools/bin/sdkmanager) export ANDROID_HOME="${sdkmanager_path%/tools/bin/sdkmanager}" ;;
    esac
fi
source "$ROOT_DIR/scripts/android-sdk.sh"
resolve_android_sdk "$ROOT_DIR"
yes | "$SDKMANAGER" --licenses >/dev/null 2>&1 || true
"$SDKMANAGER" --sdk_root="$ANDROID_HOME" \
    "platforms;android-36" "build-tools;36.0.0" "ndk;28.2.13676358"
"$CODEX_FLUTTER_BIN" precache --android
"$ROOT_DIR/scripts/publish-gitee-release.sh"
ls -lh dist
