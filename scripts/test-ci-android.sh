#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for prerequisite in java bash curl unzip sha256sum flock timeout grep; do
    if ! command -v "$prerequisite" >/dev/null 2>&1; then
        echo "CI Android SDK tests require $prerequisite" >&2
        exit 127
    fi
done
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
case "$SDK_TEST_BASE_URL" in
    https://googledownloads.cn/android/repository/|https://dl.google.com/android/repository/|https://sdk.fixture.invalid/repository/) ;;
    *) echo 'Unexpected SDK repository' >&2; exit 9 ;;
esac
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
printf '%s\n' "$SDK_TEST_BASE_URL" >> "$root/package-sources"
if [[ -f "$root/install-status" ]]; then exit "$(cat "$root/install-status")"; fi
[[ ! -f "$root/fail-install" ]] || exit 8
if [[ -f "$root/fail-mirror" && "$SDK_TEST_BASE_URL" == https://googledownloads.cn/android/repository/ ]]; then
    echo 'Package archive returned HTTP 404' >&2
    exit 8
fi
[[ ! -f "$root/omit-packages" ]] || exit 0
for package in "$@"; do
    case "$package" in
        platform-tools) paths=(platform-tools/adb) ;;
        'platforms;android-36') paths=(platforms/android-36/android.jar) ;;
        'build-tools;36.0.0') paths=(build-tools/36.0.0/{aapt,apksigner,zipalign}) ;;
        'ndk;28.2.13676358') paths=(ndk/28.2.13676358/toolchains/llvm/prebuilt/linux-x86_64/bin/clang) ;;
        'cmake;3.22.1') paths=(cmake/3.22.1/bin/{cmake,ninja}) ;;
        *) exit 9 ;;
    esac
    for path in "${paths[@]}"; do
        mkdir -p "$root/$(dirname "$path")"
        case "$path" in
            # Match the official Android archive, including its build suffix and footer.
            */bin/cmake) printf '#!/bin/sh\necho "cmake version 3.22.1-g37088a8"\necho\necho "CMake suite maintained and supported by Kitware (kitware.com/cmake)."\n' > "$root/$path" ;;
            */bin/ninja) printf '#!/bin/sh\necho "1.10.2"\n' > "$root/$path" ;;
            *) printf '#!/bin/sh\nexit 0\n' > "$root/$path" ;;
        esac
        chmod +x "$root/$path"
    done
done
echo 'packages installed'
MANAGER
chmod +x "$fixture/tools/cmdline-tools/bin/sdkmanager"
# Use the build's JDK, retaining executable permissions for sdkmanager after unzip.
cat > "$fixture/AndroidToolsArchive.java" <<'JAVA'
import java.nio.file.FileSystems;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Map;

class AndroidToolsArchive {
    public static void main(String[] args) throws Exception {
        Path source = Path.of(args[0]);
        try (var archive = FileSystems.newFileSystem(Path.of(args[1]),
                Map.of("create", "true", "enablePosixFileAttributes", "true"));
             var paths = Files.walk(source)) {
            for (Path path : paths.sorted().toList()) {
                if (path.equals(source)) continue;
                Path target = archive.getPath("/" + source.relativize(path));
                if (Files.isDirectory(path)) Files.createDirectories(target);
                else Files.copy(path, target);
                Files.setPosixFilePermissions(target, Files.getPosixFilePermissions(path));
            }
        }
    }
}
JAVA
java --source 17 "$fixture/AndroidToolsArchive.java" "$fixture/tools" "$fixture/tools.zip"
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
grep -Fxq 'platform-tools platforms;android-36 build-tools;36.0.0 ndk;28.2.13676358 cmake;3.22.1' "$sdk/calls"
[[ "$(cat "$sdk/package-sources")" == https://googledownloads.cn/android/repository/ ]]

# A missing default-mirror archive falls back to official downloads, preserving the SDK root.
fallback="$fixture/fallback"
mkdir -p "$fallback"
touch "$fallback/fail-mirror" "$fallback/sentinel"
[[ "$(prepare "$fallback")" == "$fallback" ]]
[[ -f "$fallback/sentinel" && "$(wc -l < "$fallback/package-sources")" == 2 ]]
[[ "$(head -n 1 "$fallback/package-sources")" == https://googledownloads.cn/android/repository/ ]]
[[ "$(tail -n 1 "$fallback/package-sources")" == https://dl.google.com/android/repository/ ]]
"$fallback/cmake/3.22.1/bin/cmake" --version | grep -Fxq 'cmake version 3.22.1-g37088a8'
[[ "$("$fallback/cmake/3.22.1/bin/ninja" --version)" == 1.10.2 ]]

# Explicit repository choices remain authoritative, whether installation succeeds or fails.
custom="$fixture/custom"
[[ "$(CODEX_ANDROID_REPOSITORY_URL=https://sdk.fixture.invalid/repository prepare "$custom")" == "$custom" ]]
[[ "$(cat "$custom/package-sources")" == https://sdk.fixture.invalid/repository/ ]]
custom_failed="$fixture/custom-failed"
mkdir -p "$custom_failed"
touch "$custom_failed/fail-install"
if CODEX_ANDROID_REPOSITORY_URL=https://sdk.fixture.invalid/repository/ prepare "$custom_failed" >"$fixture/out"; then
    echo 'Custom repository failure swallowed' >&2; exit 1
fi
[[ ! -s "$fixture/out" && "$(wc -l < "$custom_failed/package-sources")" == 3 ]]
[[ "$(sort -u "$custom_failed/package-sources")" == https://sdk.fixture.invalid/repository/ ]]

# Timeout and cancellation statuses stop after one attempt, without retrying another source.
for status in 124 137 129 130 143; do
    stopped="$fixture/stopped-$status"
    mkdir -p "$stopped"
    printf '%s\n' "$status" > "$stopped/install-status"
    # These are simulated exit codes; do not let the nested CI supervisor cancel
    # the real regression job. The outer regression deadline remains in force.
    if CODEX_CI_PROCESS_GROUP= prepare "$stopped" >"$fixture/out"; then
        echo 'SDK timeout or cancellation swallowed' >&2; exit 1
    else
        actual_status=$?
    fi
    [[ "$actual_status" == "$status" && ! -s "$fixture/out" ]]
    [[ "$(cat "$stopped/package-sources")" == https://googledownloads.cn/android/repository/ ]]
done

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

# Both Google's suffixed build and an exact upstream version reuse the cache.
calls_before="$(wc -l < "$sdk/calls")"
printf '#!/bin/sh\necho "cmake version 3.22.1"\n' > "$sdk/cmake/3.22.1/bin/cmake"
[[ "$(prepare "$sdk")" == "$sdk" ]]
[[ "$(wc -l < "$sdk/calls")" == "$calls_before" ]]

# An incomplete package triggers only the missing package install, not a full re-download.
rm "$sdk/build-tools/36.0.0/apksigner"
[[ "$(prepare "$sdk")" == "$sdk" ]]
[[ "$(tail -n 1 "$sdk/calls")" == 'build-tools;36.0.0' ]]

# A cached CMake without its bundled Ninja must be repaired before compilation.
rm "$sdk/cmake/3.22.1/bin/ninja"
[[ "$(prepare "$sdk")" == "$sdk" ]]
[[ "$(tail -n 1 "$sdk/calls")" == 'cmake;3.22.1' ]]
[[ "$("$sdk/cmake/3.22.1/bin/ninja" --version)" == 1.10.2 ]]
# Wrong releases and non-build suffixes must still trigger a targeted repair.
for wrong_version in 3.10.2 3.22.10 3.22.1-rc1 3.22.1-gINVALID; do
    calls_before="$(wc -l < "$sdk/calls")"
    printf '#!/bin/sh\necho "cmake version %s"\n' "$wrong_version" > "$sdk/cmake/3.22.1/bin/cmake"
    [[ "$(prepare "$sdk")" == "$sdk" ]]
    [[ "$(wc -l < "$sdk/calls")" == "$((calls_before + 1))" ]]
    [[ "$(tail -n 1 "$sdk/calls")" == 'cmake;3.22.1' ]]
    grep -Fq "CMake version mismatch: cmake version $wrong_version" "$fixture/last.log"
    "$sdk/cmake/3.22.1/bin/cmake" --version | grep -Fxq 'cmake version 3.22.1-g37088a8'
done
# Version text alone cannot hide a broken executable's nonzero exit.
for native_tool in cmake ninja; do
    calls_before="$(wc -l < "$sdk/calls")"
    printf '\nexit 1\n' >> "$sdk/cmake/3.22.1/bin/$native_tool"
    [[ "$(prepare "$sdk")" == "$sdk" ]]
    [[ "$(wc -l < "$sdk/calls")" == "$((calls_before + 1))" ]]
    [[ "$(tail -n 1 "$sdk/calls")" == 'cmake;3.22.1' ]]
    grep -Fq -- '--version failed or timed out' "$fixture/last.log"
done

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
grep -q 'license preparation failed' "$fixture/last.log"

# Nonzero install exits retry a bounded three times, then fail; silent omissions fail too.
failed="$fixture/failed"
mkdir -p "$failed"
touch "$failed/fail-install"
if prepare "$failed" >"$fixture/out"; then echo 'Install failure swallowed' >&2; exit 1; fi
[[ "$(wc -l < "$failed/calls")" == 4 && ! -s "$fixture/out" ]]
[[ "$(head -n 1 "$failed/package-sources")" == https://googledownloads.cn/android/repository/ ]]
[[ "$(grep -Fxc 'https://dl.google.com/android/repository/' "$failed/package-sources")" == 2 ]]
silent="$fixture/silent"
mkdir -p "$silent"
touch "$silent/omit-packages"
if prepare "$silent" >"$fixture/out"; then echo 'Incomplete SDK accepted' >&2; exit 1; fi
grep -q 'package is incomplete' "$fixture/last.log"

# Concurrent jobs share a lock and do not install into the same cache simultaneously.
concurrent="$fixture/concurrent"
prepare "$concurrent" >"$fixture/one" & one=$!
prepare "$concurrent" >"$fixture/two" & two=$!
wait "$one"; wait "$two"
cmp "$fixture/one" "$fixture/two"
[[ "$(wc -l < "$concurrent/calls")" == 2 ]]

# Exercise the actual Gitee entry without publishing anything externally.
entry="$fixture/entry"
mkdir -p "$entry/scripts" "$entry/flutter/bin" "$entry/node/bin" "$entry/dist" "$entry/home"
cp "$ROOT_DIR/scripts/build-gitee-release.sh" "$ROOT_DIR/scripts/prepare-ci-android.sh" \
    "$ROOT_DIR/scripts/prepare-ci-gradle-home.sh" \
    "$ROOT_DIR/scripts/prepare-ci-environment.sh" "$ROOT_DIR/scripts/run-ci-stage.sh" "$entry/scripts/"
printf '#!/bin/sh\nprintf "%%s\\n" "$WORKSPACE/flutter"\n' > "$entry/scripts/prepare-ci-flutter.sh"
printf '#!/bin/sh\nprintf "%%s\\n" "$WORKSPACE/node/bin"\n' > "$entry/scripts/prepare-ci-node.sh"
printf '#!/bin/sh\nprintf "v22.17.0\\n"\n' > "$entry/node/bin/node"
printf '#!/bin/sh\nexit 0\n' > "$entry/scripts/prepare-ci-gradle.sh"
printf '#!/bin/sh\nexit 0\n' > "$entry/scripts/test-ci-gradle-repositories.sh"
printf '#!/bin/sh\ntest "$1 $2" = "precache --android"\n' > "$entry/flutter/bin/flutter"
cat > "$entry/scripts/publish-gitee-release.sh" <<'PUBLISH'
#!/bin/sh
set -eu
test "$CODEX_RELEASE_BRANCH" = flutter-refactor
test "$ANDROID_HOME" = "$EXPECTED_SDK"
test "$ANDROID_SDK_ROOT" = "$EXPECTED_SDK"
test -x "$ANDROID_HOME/build-tools/36.0.0/apksigner"
test "$(command -v cmake)" = "$ANDROID_HOME/cmake/3.22.1/bin/cmake"
test "$(command -v ninja)" = "$ANDROID_HOME/cmake/3.22.1/bin/ninja"
cmake --version | grep -Fxq 'cmake version 3.22.1-g37088a8'
test "$(ninja --version)" = 1.10.2
test "$CODEX_FLUTTER_BIN" = "$WORKSPACE/flutter/bin/flutter"
test "$(command -v node)" = "$WORKSPACE/node/bin/node"
test -L "$GRADLE_USER_HOME/caches"
test -L "$GRADLE_USER_HOME/wrapper"
test ! -e "$GRADLE_USER_HOME/init.d"
echo 'entry environment verified'
PUBLISH
chmod +x "$entry/scripts/publish-gitee-release.sh" "$entry/flutter/bin/flutter" "$entry/node/bin/node"
WORKSPACE="$entry" HOME="$entry/home" GRADLE_USER_HOME="$entry/gradle-cache" \
    EXPECTED_SDK="$sdk" ANDROID_HOME="$sdk" ANDROID_SDK_ROOT= \
    bash "$entry/scripts/build-gitee-release.sh" flutter-refactor >"$fixture/entry.log" 2>&1
grep -q 'entry environment verified' "$fixture/entry.log"

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
    grep -Fq "using cache: $fallback" "$fixture/last.log"
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
    grep -q 'Android SDK cache is not writable' "$fixture/last.log"
    # Gitee entry must pass the FALLBACK SDK to the publisher/Gradle, not inherited env.
    mkdir -p "$entry/home/.cache/codex"
    cp -a "$fallback" "$entry/home/.cache/codex/android-sdk"
    WORKSPACE="$entry" HOME="$entry/home" EXPECTED_SDK="$entry/home/.cache/codex/android-sdk" \
        GRADLE_USER_HOME="$entry/gradle-cache" \
        ANDROID_HOME="$readonly_sdk" ANDROID_SDK_ROOT="$readonly_sdk" \
        bash "$entry/scripts/build-gitee-release.sh" flutter-refactor >"$fixture/entry.log" 2>&1
    grep -q 'entry environment verified' "$fixture/entry.log"
    [[ "$(find "$readonly_sdk" -type f -exec sha256sum {} + | sort)" == "$before" ]]
    [[ ! -e "$readonly_sdk/.prepare.lock" ]]
    echo 'CI Android read-only mount tests passed (cold/warm cache, env/PATH, fallback failure, entry, unchanged SDK)'
fi
echo 'CI Android SDK tests passed (bootstrap, discovery, cache, failure, concurrency, entry)'
