#!/usr/bin/env bash
set -euo pipefail

# Keep shell expansion here: Gitee also expands ${...} in inline YAML commands.
if [[ -n "${WORKSPACE:-}" ]]; then cd "$WORKSPACE"; fi
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
export CODEX_RELEASE_BRANCH="${1:-release}"
export FLUTTER_VERSION="3.44.8"
export FLUTTER_REVISION="058e0af2c2b57e369d905a03ac9748b0ebf543c6"
export FLUTTER_STORAGE_BASE_URL="${FLUTTER_STORAGE_BASE_URL:-https://storage.flutter-io.cn}"
export PUB_HOSTED_URL="${PUB_HOSTED_URL:-https://pub.flutter-io.cn}"
FLUTTER_ARCHIVE_URL="$FLUTTER_STORAGE_BASE_URL/flutter_infra_release/releases/stable/linux/flutter_linux_$FLUTTER_VERSION-stable.tar.xz"
FLUTTER_ARCHIVE_SHA256="672089e001571a9fbb209a495c583580c0c6c73ef98999264ba07fa93ace332d"
FLUTTER_ROOT="$(bash "$ROOT_DIR/scripts/prepare-ci-flutter.sh" \
    "$HOME/.cache/codex/flutter-$FLUTTER_VERSION" "$FLUTTER_VERSION" "$FLUTTER_REVISION" \
    "$FLUTTER_ARCHIVE_URL" "$FLUTTER_ARCHIVE_SHA256")"
export FLUTTER_ROOT
export CODEX_FLUTTER_BIN="$FLUTTER_ROOT/bin/flutter"
export PUB_CACHE="$HOME/.pub-cache"
export GRADLE_USER_HOME="$HOME/.gradle"
export CODEX_BUILD_ONLINE=1
export GRADLE_OPTS="-Dorg.gradle.jvmargs=-Xmx4g -Dfile.encoding=UTF-8 -Dorg.gradle.workers.max=4"
export PATH="$FLUTTER_ROOT/bin:$PATH"
mkdir -p "$PUB_CACHE" "$GRADLE_USER_HOME"

ANDROID_HOME="$(bash "$ROOT_DIR/scripts/prepare-ci-android.sh" "$HOME/.cache/codex/android-sdk")"
export ANDROID_HOME
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export PATH="$ANDROID_HOME/platform-tools:$PATH"
"$CODEX_FLUTTER_BIN" precache --android
"$ROOT_DIR/scripts/publish-gitee-release.sh"
ls -lh dist
