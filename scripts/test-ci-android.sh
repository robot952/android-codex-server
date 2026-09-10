#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$ROOT_DIR/.workflow-cache"
fixture="$(mktemp -d "$ROOT_DIR/.workflow-cache/test-ci-android.XXXXXX")"
mounts=()
cleanup() {
    local index
    for ((index=${#mounts[@]}-1; index>=0; index--)); do umount "${mounts[index]}"; done
    rm -rf -- "$fixture"
}
trap cleanup EXIT
case "${1:-}" in
    ''|--read-only-mounts) ;;
    *) echo "usage: $0 [--read-only-mounts]" >&2; exit 2 ;;
esac
mkdir -p "$fixture/tools/cmdline-tools/bin" "$fixture/tools/cmdline-tools/lib"
cat > "$fixture/tools/cmdline-tools/bin/sdkmanager" <<'MANAGER'
#!/usr/bin/env bash
set -euo pipefail
root="${1#--sdk_root=}"
shift
[[ "$ANDROID_HOME" == "$root" && "$ANDROID_SDK_ROOT" == "$root" ]]
[[ "$SDK_TEST_BASE_URL" == https://googledownloads.cn/android/repository/ ]]
case "$1" in
    --version) echo '12.0'; exit 0 ;;
    --licenses)
        [[ ! -f "$root/fail-license" ]] || exit 7
        mkdir -p "$root/licenses"
        printf 'fixture accepted license\n' > "$root/licenses/android-sdk-license"
        echo 'licenses accepted' >> "$root/calls"
        exit 0 ;;
esac
printf '%s\n' "$*" >> "$root/calls"
[[ ! -f "$root/fail-install" ]] || exit 8
[[ ! -f "$root/omit-packages" ]] || exit 0
for package in "$@"; do
    case "$package" in
        platform-tools) paths=(platform-tools/adb) ;;
        'platforms;android-36') paths=(platforms/android-36/android.jar) ;;
        'build-tools;36.0.0') paths=(build-tools/36.0.0/{aapt,apksigner,zipalign}) ;;
        'ndk;28.2.13676358') paths=(ndk/28.2.13676358/toolchains/llvm/prebuilt/linux-x86_64/bin/clang) ;;
        *) exit 9 ;;
    esac
    for path in "${paths[@]}"; do
        mkdir -p "$root/$(dirname "$path")"
        printf '#!/bin/sh\nexit 0\n' > "$root/$path"
        chmod +x "$root/$path"
    done
done
echo 'packages installed'
MANAGER
chmod +x "$fixture/tools/cmdline-tools/bin/sdkmanager"
python3 - "$fixture" <<'ZIP'
import pathlib
import sys
import zipfile
fixture = pathlib.Path(sys.argv[1])
with zipfile.ZipFile(fixture / 'tools.zip', 'w') as archive:
    for path in sorted((fixture / 'tools').rglob('*')):
        archive.write(path, path.relative_to(fixture / 'tools'))
ZIP
export CODEX_ANDROID_TOOLS_URL="file://$fixture/tools.zip"
export CODEX_ANDROID_TOOLS_SHA256="$(sha256sum "$fixture/tools.zip" | awk '{print $1}')"
unset CODEX_ANDROID_REPOSITORY_URL
prepare() {
    ANDROID_HOME="$1" ANDROID_SDK_ROOT="$fixture/stale-sdk-root" \
        bash "$ROOT_DIR/scripts/prepare-ci-android.sh" "${2:-$fixture/cache}" 2>"$fixture/last.log"
}

# First install from nothing: root stdout is not polluted, all packages and licenses exist.
sdk="$fixture/sdk with spaces"
mkdir -p "$sdk"
printf 'keep\n' > "$sdk/sentinel"
inode="$(stat -c %i "$sdk")"
[[ "$(prepare "$sdk")" == "$sdk" ]]
[[ "$(stat -c %i "$sdk")" == "$inode" && -f "$sdk/sentinel" ]]
[[ "$(wc -l < "$sdk/calls")" == 2 ]]
rg -Fxq 'platform-tools platforms;android-36 build-tools;36.0.0 ndk;28.2.13676358' "$sdk/calls"

# A complete cached SDK needs neither archive access nor network/package installation.
[[ "$(CODEX_ANDROID_TOOLS_URL=file:///missing.zip prepare "$sdk")" == "$sdk" ]]
[[ "$(wc -l < "$sdk/calls")" == 2 ]]

# Existing installations often use cmdline-tools/tools or a numbered subdirectory, not latest.
mv "$sdk/cmdline-tools/12.0" "$sdk/cmdline-tools/tools"
[[ "$(CODEX_ANDROID_TOOLS_URL=file:///missing.zip prepare "$sdk")" == "$sdk" ]]
mv "$sdk/cmdline-tools/tools" "$sdk/cmdline-tools/17.0"
[[ "$(CODEX_ANDROID_TOOLS_URL=file:///missing.zip prepare "$sdk")" == "$sdk" ]]

# Infer SDK root from a PATH symlink and support ANDROID_SDK_ROOT alone.
mkdir "$fixture/bin"
ln -s "$sdk/cmdline-tools/17.0/bin/sdkmanager" "$fixture/bin/sdkmanager"
[[ "$(ANDROID_HOME= ANDROID_SDK_ROOT= PATH="$fixture/bin:$PATH" \
    bash "$ROOT_DIR/scripts/prepare-ci-android.sh" "$fixture/unused" 2>"$fixture/last.log")" == "$sdk" ]]
[[ "$(ANDROID_HOME= ANDROID_SDK_ROOT="$sdk" \
    bash "$ROOT_DIR/scripts/prepare-ci-android.sh" "$fixture/unused" 2>"$fixture/last.log")" == "$sdk" ]]

# An incomplete package triggers only the missing package install, not a full re-download.
rm "$sdk/build-tools/36.0.0/apksigner"
[[ "$(prepare "$sdk")" == "$sdk" ]]
[[ "$(tail -n 1 "$sdk/calls")" == 'build-tools;36.0.0' ]]

# Broken preinstalled launchers are replaced only after validating a fresh tools archive.
broken="$fixture/broken"
mkdir -p "$broken/cmdline-tools/12.0/bin"
printf '#!/bin/sh\nexit 1\n' > "$broken/cmdline-tools/12.0/bin/sdkmanager"
chmod +x "$broken/cmdline-tools/12.0/bin/sdkmanager"
[[ "$(prepare "$broken")" == "$broken" ]]

# Invalid archives never install tools, remove the cache root or swallow failure.
bad="$fixture/bad"
mkdir -p "$bad"
printf 'keep\n' > "$bad/sentinel"
if CODEX_ANDROID_TOOLS_SHA256="$(printf '0%.0s' {1..64})" prepare "$bad" >"$fixture/out"; then
    echo 'Invalid tools SHA accepted' >&2; exit 1
fi
[[ ! -s "$fixture/out" && -f "$bad/sentinel" && ! -e "$bad/cmdline-tools/12.0" ]]

# License errors are not hidden by `|| true` or the yes pipe's SIGPIPE.
license="$fixture/license"
mkdir -p "$license"
touch "$license/fail-license"
if prepare "$license" >"$fixture/out"; then echo 'License failure swallowed' >&2; exit 1; fi
[[ ! -s "$fixture/out" ]]
rg -q 'license preparation failed' "$fixture/last.log"

# Nonzero install exits retry a bounded three times, then fail; silent omissions fail too.
failed="$fixture/failed"
mkdir -p "$failed"
touch "$failed/fail-install"
if prepare "$failed" >"$fixture/out"; then echo 'Install failure swallowed' >&2; exit 1; fi
[[ "$(wc -l < "$failed/calls")" == 4 && ! -s "$fixture/out" ]]
silent="$fixture/silent"
mkdir -p "$silent"
touch "$silent/omit-packages"
if prepare "$silent" >"$fixture/out"; then echo 'Incomplete SDK accepted' >&2; exit 1; fi
rg -q 'package is incomplete' "$fixture/last.log"

# Concurrent jobs share a lock and do not install into the same cache simultaneously.
concurrent="$fixture/concurrent"
prepare "$concurrent" >"$fixture/one" & one=$!
prepare "$concurrent" >"$fixture/two" & two=$!
wait "$one"; wait "$two"
cmp "$fixture/one" "$fixture/two"
[[ "$(wc -l < "$concurrent/calls")" == 2 ]]

# Exercise the actual Gitee entry without publishing anything externally.
entry="$fixture/entry"
mkdir -p "$entry/scripts" "$entry/flutter/bin" "$entry/dist" "$entry/home"
cp "$ROOT_DIR/scripts/build-gitee-release.sh" "$ROOT_DIR/scripts/prepare-ci-android.sh" "$entry/scripts/"
printf '#!/bin/sh\nprintf "%%s\\n" "$WORKSPACE/flutter"\n' > "$entry/scripts/prepare-ci-flutter.sh"
printf '#!/bin/sh\ntest "$1 $2" = "precache --android"\n' > "$entry/flutter/bin/flutter"
cat > "$entry/scripts/publish-gitee-release.sh" <<'PUBLISH'
#!/bin/sh
set -eu
test "$CODEX_RELEASE_BRANCH" = flutter-refactor
test "$ANDROID_HOME" = "$EXPECTED_SDK"
test "$ANDROID_SDK_ROOT" = "$EXPECTED_SDK"
test -x "$ANDROID_HOME/build-tools/36.0.0/apksigner"
test "$CODEX_FLUTTER_BIN" = "$WORKSPACE/flutter/bin/flutter"
echo 'entry environment verified'
PUBLISH
chmod +x "$entry/scripts/publish-gitee-release.sh" "$entry/flutter/bin/flutter"
WORKSPACE="$entry" HOME="$entry/home" EXPECTED_SDK="$sdk" ANDROID_HOME="$sdk" ANDROID_SDK_ROOT= \
    bash "$entry/scripts/build-gitee-release.sh" flutter-refactor >"$fixture/entry.log" 2>&1
rg -q 'entry environment verified' "$fixture/entry.log"

# A path that cannot be a directory must also fall back, without leaking stdout.
not_directory="$fixture/not-a-directory"
printf 'keep\n' > "$not_directory"
[[ "$(prepare "$not_directory/sdk" "$sdk")" == "$sdk" ]]
[[ "$(cat "$not_directory")" == keep ]]

# Run in an isolated mount namespace, including when the test runs as root:
# unshare --mount --propagation private bash scripts/test-ci-android.sh --read-only-mounts
if [[ "${1:-}" == --read-only-mounts ]]; then
    readonly_sdk="$fixture/pipeline-tools/standard/android/sdk"
    mkdir -p "$readonly_sdk"
    cp -a "$sdk/." "$readonly_sdk/"
    # Model a partial platform SDK; never install missing packages into this mount.
    rm "$readonly_sdk/build-tools/36.0.0/apksigner" "$readonly_sdk/.prepare.lock"
    before="$(find "$readonly_sdk" -type f -exec sha256sum {} + | sort)"
    mount --bind "$readonly_sdk" "$readonly_sdk"
    mounts+=("$readonly_sdk")
    mount -o remount,bind,ro "$readonly_sdk"
    if (touch "$readonly_sdk/must-not-write") 2>/dev/null; then
        echo 'Test SDK is not actually read-only' >&2; exit 1
    fi
    fallback="$fixture/writable-cache"
    [[ "$(prepare "$readonly_sdk" "$fallback")" == "$fallback" ]]
    rg -Fq "using cache: $fallback" "$fixture/last.log"
    [[ -x "$fallback/build-tools/36.0.0/apksigner" ]]
    # Subsequent jobs must reuse the writable cache even if env/PATH still point at the mount.
    [[ "$(CODEX_ANDROID_TOOLS_URL=file:///missing.zip prepare "$readonly_sdk" "$fallback")" == "$fallback" ]]
    [[ "$(wc -l < "$fallback/calls")" == 2 ]]
    [[ "$(ANDROID_HOME= ANDROID_SDK_ROOT="$readonly_sdk" \
        bash "$ROOT_DIR/scripts/prepare-ci-android.sh" "$fallback" 2>"$fixture/last.log")" == "$fallback" ]]
    [[ "$(ANDROID_HOME= ANDROID_SDK_ROOT= PATH="$readonly_sdk/cmdline-tools/17.0/bin:$PATH" \
        bash "$ROOT_DIR/scripts/prepare-ci-android.sh" "$fallback" 2>"$fixture/last.log")" == "$fallback" ]]
    # If the fallback aliases the same read-only filesystem, fail once with a clear message.
    ln -s "$readonly_sdk" "$fixture/readonly-alias"
    if prepare "$readonly_sdk" "$fixture/readonly-alias" >"$fixture/out"; then
        echo 'Read-only fallback accepted' >&2; exit 1
    fi
    [[ ! -s "$fixture/out" ]]
    rg -q 'Android SDK cache is not writable' "$fixture/last.log"
    # Gitee entry must pass the FALLBACK SDK to the publisher/Gradle, not inherited env.
    mkdir -p "$entry/home/.cache/codex"
    cp -a "$fallback" "$entry/home/.cache/codex/android-sdk"
    WORKSPACE="$entry" HOME="$entry/home" EXPECTED_SDK="$entry/home/.cache/codex/android-sdk" \
        ANDROID_HOME="$readonly_sdk" ANDROID_SDK_ROOT="$readonly_sdk" \
        bash "$entry/scripts/build-gitee-release.sh" flutter-refactor >"$fixture/entry.log" 2>&1
    rg -q 'entry environment verified' "$fixture/entry.log"
    [[ "$(find "$readonly_sdk" -type f -exec sha256sum {} + | sort)" == "$before" ]]
    [[ ! -e "$readonly_sdk/.prepare.lock" ]]
    echo 'CI Android read-only mount tests passed (cold/warm cache, env/PATH, fallback failure, entry, unchanged SDK)'
fi
echo 'CI Android SDK tests passed (bootstrap, discovery, cache, failure, concurrency, entry)'
