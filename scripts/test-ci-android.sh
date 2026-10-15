#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
unset CODEX_CI_HOSTED_DEPENDENCIES CODEX_CI_MAVEN_REPOSITORY
for prerequisite in java bash curl unzip sha256sum flock timeout grep git; do
    if ! command -v "$prerequisite" >/dev/null 2>&1; then
        echo "CI Android SDK tests require $prerequisite" >&2
        exit 127
    fi
done
bash "$ROOT_DIR/scripts/test-ci-dependency.sh"
mkdir -p "$ROOT_DIR/.workflow-cache"
fixture="$(mktemp -d "$ROOT_DIR/.workflow-cache/test-ci-android.XXXXXX")"
mounts=()
cleanup() {
    local index
    for ((index=${#mounts[@]}-1; index>=0; index--)); do umount "${mounts[index]}"; done
    rm -rf -- "$fixture"
}
trap cleanup EXIT
report_failure() {
    local status="$1" line="$2" log
    printf 'CI Android SDK regression failed at %s:%s (exit %s)\n' "${BASH_SOURCE[0]}" "$line" "$status" >&2
    # Only print bounded logs from this isolated SDK fixture; never enable shell tracing.
    for log in "$fixture/last.log" "$fixture/entry.log"; do
        if [[ -s "$log" ]]; then
            printf '%s (last 60 lines):\n' "${log##*/}" >&2
            tail -n 60 -- "$log" >&2 || :
        fi
    done
    exit "$status"
}
trap 'report_failure "$?" "$LINENO"' ERR
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
    if [[ "$package" == 'platforms;android-35' && -f "$root/omit-platform-35" ]]; then continue; fi
    case "$package" in
        platform-tools) package_dir=platform-tools; paths=(platform-tools/adb) ;;
        'platforms;android-34'|'platforms;android-35'|'platforms;android-36')
            package_dir="platforms/android-${package#platforms;android-}"
            paths=("$package_dir/android.jar") ;;
        'build-tools;36.0.0') package_dir=build-tools/36.0.0; paths=(build-tools/36.0.0/{aapt,apksigner,zipalign}) ;;
        'ndk;28.2.13676358') package_dir=ndk/28.2.13676358; paths=(ndk/28.2.13676358/toolchains/llvm/prebuilt/linux-x86_64/bin/clang) ;;
        'cmake;3.22.1') package_dir=cmake/3.22.1; paths=(cmake/3.22.1/bin/{cmake,ninja}) ;;
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
    case "$package" in
        platform-tools) property='Pkg.Revision=37.0.0' ;;
        'platforms;android-'*) property="AndroidVersion.ApiLevel=${package#platforms;android-}" ;;
        'build-tools;36.0.0') property='Pkg.Revision=36.0.0' ;;
        'ndk;28.2.13676358') property='Pkg.Revision = 28.2.13676358' ;;
        'cmake;3.22.1') property='Pkg.Revision = 3.22.1' ;;
    esac
    printf '%s\n' "$property" > "$root/$package_dir/source.properties"
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
mkdir -p "$fixture/cmake/bin" "$fixture/cmake/share/cmake-3.22/Modules" "$fixture/no-system-cmake"
printf '#!/bin/sh\necho "cmake version 3.22.1-g37088a8"\n' > "$fixture/cmake/bin/cmake"
printf '#!/bin/sh\necho "1.10.2"\n' > "$fixture/cmake/bin/ninja"
printf 'Pkg.Revision = 3.22.1\n' > "$fixture/cmake/source.properties"
printf '# fixture module\n' > "$fixture/cmake/share/cmake-3.22/Modules/CMake.cmake"
# Tests must not accidentally reuse the host's CMake instead of exercising downloads.
printf '#!/bin/sh\nexit 1\n' > "$fixture/no-system-cmake/cmake"
chmod +x "$fixture/cmake/bin/"* "$fixture/no-system-cmake/cmake"
export PATH="$fixture/no-system-cmake:$PATH"
java --source 17 "$fixture/AndroidToolsArchive.java" "$fixture/cmake" "$fixture/cmake.zip"
export CODEX_ANDROID_CMAKE_URL="file://$fixture/cmake.zip"
export CODEX_ANDROID_CMAKE_SHA256="$(sha256sum "$fixture/cmake.zip" | awk '{print $1}')"
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
grep -Fxq 'platform-tools platforms;android-34 platforms;android-35 platforms;android-36 build-tools;36.0.0 ndk;28.2.13676358' "$sdk/calls"
[[ "$(cat "$sdk/package-sources")" == https://googledownloads.cn/android/repository/ ]]
grep -Fq 'Installed and verified CMake 3.22.1 with bundled Ninja' "$fixture/last.log"

# CMake is acquired independently: a mirror missing only that ZIP never changes
# metadata or build-tools to the slow official repository (the real Gitee failure).
! grep -Fq 'cmake;3.22.1' "$sdk/calls"
[[ -x "$sdk/cmake/3.22.1/bin/cmake" && -x "$sdk/cmake/3.22.1/bin/ninja" ]]

# The production default must select the pinned Gitee object, not a floating
# branch, Google URL or inherited custom hash. Simulate a fetch failure to prove
# it stops preparation instead of falling through to another downloader.
default_sdk="$fixture/default-cmake-sdk"
mkdir -p "$fixture/default-scripts"
cp -a "$sdk" "$default_sdk"
rm -rf "$default_sdk/cmake/3.22.1"
cp "$ROOT_DIR/scripts/prepare-ci-android.sh" "$ROOT_DIR/scripts/run-ci-stage.sh" "$fixture/default-scripts/"
cat > "$fixture/default-scripts/fetch-ci-dependency.sh" <<'FETCH'
#!/usr/bin/env bash
set -euo pipefail
[[ $# == 6 ]]
[[ "$1" == https://gitee.com/YanGanYuan/android-codex-server.git ]]
[[ "$2" == refs/tags/ci-deps-cmake-3.22.1-linux-x86_64 ]]
[[ "$3" == 598abbd92d9711f953613ee51987bd5c71b23b4f ]]
[[ "$4" == cmake/cmake-3.22.1-linux.zip ]]
[[ "$5" == 9196644852a978012caf7a4067ba1898debf6cc204c3341562771e31080d6869 ]]
[[ "$6" == "$ANDROID_HOME/.downloads/cmake-3.22.1-linux.zip" ]]
echo 'pinned Gitee dependency selected' >&2
exit 73
FETCH
default_status=0
ANDROID_HOME="$default_sdk" env -u CODEX_ANDROID_CMAKE_URL \
    bash "$fixture/default-scripts/prepare-ci-android.sh" "$default_sdk" >"$fixture/out" 2>"$fixture/last.log" || default_status=$?
[[ "$default_status" == 73 ]]
grep -Fq 'pinned Gitee dependency selected' "$fixture/last.log"
! grep -Fq 'Downloading CMake' "$fixture/last.log"
[[ ! -e "$default_sdk/cmake/3.22.1" ]]

# A matching CMake/Ninja already on PATH is copied with its modules, without a download.
system_sdk="$fixture/system-cmake-sdk"
[[ "$(PATH="$fixture/cmake/bin:$PATH" CODEX_ANDROID_CMAKE_URL=file:///missing-cmake.zip \
    prepare "$system_sdk")" == "$system_sdk" ]]
grep -Fq 'Reusing system CMake 3.22.1 and Ninja' "$fixture/last.log"
cmp "$fixture/cmake/share/cmake-3.22/Modules/CMake.cmake" "$system_sdk/cmake/3.22.1/share/cmake-3.22/Modules/CMake.cmake"
[[ ! -e "$system_sdk/.downloads/cmake-3.22.1-linux.zip" ]]

# An incompatible system version must not bypass the pinned, verified package.
mkdir -p "$fixture/wrong-system/bin"
printf '#!/bin/sh\necho "cmake version 3.10.2"\n' > "$fixture/wrong-system/bin/cmake"
cp "$fixture/cmake/bin/ninja" "$fixture/wrong-system/bin/ninja"
chmod +x "$fixture/wrong-system/bin/cmake"
[[ "$(PATH="$fixture/wrong-system/bin:$PATH" prepare "$fixture/wrong-system/sdk")" == "$fixture/wrong-system/sdk" ]]
grep -Fq 'CMake version mismatch: cmake version 3.10.2' "$fixture/last.log"
[[ -e "$fixture/wrong-system/sdk/.downloads/cmake-3.22.1-linux.zip" ]]

# Invalid hashes cannot replace a previous installation or proceed to other SDK downloads.
bad_cmake="$fixture/bad-cmake-sdk"
mkdir -p "$bad_cmake/cmake/3.22.1"
printf 'preserve\n' > "$bad_cmake/cmake/3.22.1/sentinel"
if CODEX_ANDROID_CMAKE_SHA256="$(printf '0%.0s' {1..64})" prepare "$bad_cmake" >"$fixture/out"; then
    echo 'Invalid CMake hash accepted' >&2; exit 1
fi
[[ ! -s "$fixture/out" && "$(cat "$bad_cmake/cmake/3.22.1/sentinel")" == preserve ]]
[[ "$(cat "$bad_cmake/calls")" == 'licenses accepted' && ! -e "$bad_cmake/package-sources" ]]
grep -Fq 'CMake download failed or SHA-256 mismatch' "$fixture/last.log"

# Even a correctly hashed ZIP must contain runnable CMake AND Ninja before activation.
mkdir -p "$fixture/incomplete-cmake"
cp -a "$fixture/cmake/." "$fixture/incomplete-cmake/"
rm "$fixture/incomplete-cmake/bin/ninja"
java --source 17 "$fixture/AndroidToolsArchive.java" "$fixture/incomplete-cmake" "$fixture/incomplete-cmake.zip"
if CODEX_ANDROID_CMAKE_URL="file://$fixture/incomplete-cmake.zip" \
    CODEX_ANDROID_CMAKE_SHA256="$(sha256sum "$fixture/incomplete-cmake.zip" | awk '{print $1}')" \
    prepare "$bad_cmake" >"$fixture/out"; then
    echo 'Incomplete CMake ZIP accepted' >&2; exit 1
fi
[[ ! -s "$fixture/out" && "$(cat "$bad_cmake/cmake/3.22.1/sentinel")" == preserve ]]
[[ ! -e "$bad_cmake/package-sources" ]]
grep -Fq 'CMake or bundled Ninja executable is missing' "$fixture/last.log"

# Every CMake request is bounded, and a persistent network failure has two tries.
mkdir -p "$fixture/bounded-cmake/bin" "$fixture/bounded-cmake/sdk/cmdline-tools/12.0"
cp -a "$fixture/tools/cmdline-tools/." "$fixture/bounded-cmake/sdk/cmdline-tools/12.0/"
cat > "$fixture/bounded-cmake/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$CMAKE_CURL_CALLS"
[[ " $* " == *' --connect-timeout 20 '* && " $* " == *' --max-time 180 '* ]]
[[ " $* " == *' --speed-time 30 '* && " $* " == *' --continue-at - '* ]]
printf '000'
exit 28
CURL
chmod +x "$fixture/bounded-cmake/bin/curl"
if PATH="$fixture/bounded-cmake/bin:$PATH" CMAKE_CURL_CALLS="$fixture/bounded-cmake/calls" \
    prepare "$fixture/bounded-cmake/sdk" >"$fixture/out"; then
    echo 'CMake download timeout swallowed' >&2; exit 1
fi
[[ ! -s "$fixture/out" && "$(wc -l < "$fixture/bounded-cmake/calls")" == 2 ]]
[[ ! -e "$fixture/bounded-cmake/sdk/package-sources" ]]

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
grep -Fq 'cmake;3.22.1' "$custom/calls"
[[ ! -e "$custom/.downloads/cmake-3.22.1-linux.zip" ]]
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
[[ "$(CODEX_ANDROID_TOOLS_URL=file:///missing.zip CODEX_ANDROID_CMAKE_URL=file:///missing.zip prepare "$sdk")" == "$sdk" ]]
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

# A cache from the old API-36-only bootstrap must acquire the plugin platforms
# before Gradle starts. Directory names without the right API metadata are invalid.
rm "$sdk/platforms/android-34/android.jar"
printf 'AndroidVersion.ApiLevel=36\n' > "$sdk/platforms/android-35/source.properties"
[[ "$(prepare "$sdk")" == "$sdk" ]]
[[ "$(tail -n 2 "$sdk/calls")" == $'licenses accepted\nplatforms;android-34 platforms;android-35' ]]
for api in 34 35 36; do
    [[ -s "$sdk/platforms/android-$api/android.jar" ]]
    grep -Fxq "AndroidVersion.ApiLevel=$api" "$sdk/platforms/android-$api/source.properties"
done

# A cached CMake without its bundled Ninja must be repaired before compilation.
rm "$sdk/cmake/3.22.1/bin/ninja"
[[ "$(prepare "$sdk")" == "$sdk" ]]
[[ "$(tail -n 1 "$sdk/calls")" == 'licenses accepted' ]]
[[ "$("$sdk/cmake/3.22.1/bin/ninja" --version)" == 1.10.2 ]]
# Wrong releases and non-build suffixes must still trigger a targeted repair.
for wrong_version in 3.10.2 3.22.10 3.22.1-rc1 3.22.1-gINVALID; do
    calls_before="$(wc -l < "$sdk/calls")"
    printf '#!/bin/sh\necho "cmake version %s"\n' "$wrong_version" > "$sdk/cmake/3.22.1/bin/cmake"
    [[ "$(prepare "$sdk")" == "$sdk" ]]
    # Only license confirmation reaches sdkmanager; CMake uses the verified ZIP.
    [[ "$(wc -l < "$sdk/calls")" == "$((calls_before + 1))" ]]
    [[ "$(tail -n 1 "$sdk/calls")" == 'licenses accepted' ]]
    grep -Fq "CMake version mismatch: cmake version $wrong_version" "$fixture/last.log"
    "$sdk/cmake/3.22.1/bin/cmake" --version | grep -Fxq 'cmake version 3.22.1-g37088a8'
done
# Version text alone cannot hide a broken executable's nonzero exit.
for native_tool in cmake ninja; do
    calls_before="$(wc -l < "$sdk/calls")"
    printf '\nexit 1\n' >> "$sdk/cmake/3.22.1/bin/$native_tool"
    [[ "$(prepare "$sdk")" == "$sdk" ]]
    [[ "$(wc -l < "$sdk/calls")" == "$((calls_before + 1))" ]]
    [[ "$(tail -n 1 "$sdk/calls")" == 'licenses accepted' ]]
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

# A successful sdkmanager exit must not hide a missing plugin-only platform.
silent_platform="$fixture/silent-platform"
mkdir -p "$silent_platform"
touch "$silent_platform/omit-platform-35"
if prepare "$silent_platform" >"$fixture/out"; then
    echo 'Missing plugin platform accepted after SDK installation' >&2; exit 1
fi
[[ ! -s "$fixture/out" && -s "$silent_platform/platforms/android-36/android.jar" ]]
grep -Fq 'Android SDK package is incomplete: platforms;android-35' "$fixture/last.log"

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
    "$ROOT_DIR/scripts/prepare-ci-sdk-pair.sh" \
    "$ROOT_DIR/scripts/fetch-ci-dependency.sh" \
    "$ROOT_DIR/scripts/prepare-ci-gradle-home.sh" \
    "$ROOT_DIR/scripts/ci-flutter-repositories.init.gradle" \
    "$ROOT_DIR/scripts/prepare-ci-environment.sh" "$ROOT_DIR/scripts/run-ci-stage.sh" "$entry/scripts/"
printf '#!/bin/sh\nprintf "%%s\\n" "$WORKSPACE/flutter"\n' > "$entry/scripts/prepare-ci-flutter.sh"
printf '#!/bin/sh\nprintf "%%s\\n" "$WORKSPACE/node/bin"\n' > "$entry/scripts/prepare-ci-node.sh"
printf '#!/bin/sh\nprintf "%%s\\n" "$WORKSPACE/hosted-maven"\n' > "$entry/scripts/prepare-ci-maven.sh"
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
for api in 34 35 36; do
    test -s "$ANDROID_HOME/platforms/android-$api/android.jar"
    grep -Fxq "AndroidVersion.ApiLevel=$api" "$ANDROID_HOME/platforms/android-$api/source.properties"
done
test "$(command -v cmake)" = "$ANDROID_HOME/cmake/3.22.1/bin/cmake"
test "$(command -v ninja)" = "$ANDROID_HOME/cmake/3.22.1/bin/ninja"
cmake --version | grep -Fxq 'cmake version 3.22.1-g37088a8'
test "$(ninja --version)" = 1.10.2
test "$CODEX_FLUTTER_BIN" = "$WORKSPACE/flutter/bin/flutter"
test "$(command -v node)" = "$WORKSPACE/node/bin/node"
test -L "$GRADLE_USER_HOME/caches"
test -L "$GRADLE_USER_HOME/wrapper"
cmp "$WORKSPACE/scripts/ci-flutter-repositories.init.gradle" "$GRADLE_USER_HOME/init.d/codex-flutter-repositories.gradle"
echo 'entry environment verified'
PUBLISH
chmod +x "$entry/scripts/publish-gitee-release.sh" "$entry/flutter/bin/flutter" "$entry/node/bin/node"
WORKSPACE="$entry" HOME="$entry/home" GRADLE_USER_HOME="$entry/gradle-cache" \
    EXPECTED_SDK="$sdk" ANDROID_HOME="$sdk" ANDROID_SDK_ROOT= \
    bash "$entry/scripts/build-gitee-release.sh" flutter-refactor >"$fixture/entry.log" 2>&1
grep -q 'entry environment verified' "$fixture/entry.log"

# Exercise missing hosted packages with real ZIP extraction/version checks,
# without network or a second install. Complete SDKs must not call the fetcher.
mkdir -p "$fixture/hosted-scripts" "$fixture/hosted-build-tools"
cp "$ROOT_DIR/scripts/prepare-ci-android.sh" "$ROOT_DIR/scripts/run-ci-stage.sh" "$fixture/hosted-scripts/"
cp -a "$sdk/build-tools/36.0.0" "$fixture/hosted-build-tools/android-16"
java --source 17 "$fixture/AndroidToolsArchive.java" "$sdk/platforms" "$fixture/hosted-platforms.zip"
java --source 17 "$fixture/AndroidToolsArchive.java" "$fixture/hosted-build-tools" "$fixture/hosted-build-tools.zip"
export FIXTURE_HOSTED_ROOT="$fixture" FIXTURE_HOSTED_CALLS="$fixture/hosted-calls"
cat > "$fixture/hosted-scripts/fetch-ci-package.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo "$1" >> "$FIXTURE_HOSTED_CALLS"
[[ "${FIXTURE_HOSTED_FAIL:-0}" == 0 ]] || exit 74
case "$1" in
    android-platform-34|android-platform-35|android-platform-36)
        cp "$FIXTURE_HOSTED_ROOT/hosted-platforms.zip" "$2" ;;
    android-build-tools-36) cp "$FIXTURE_HOSTED_ROOT/hosted-build-tools.zip" "$2" ;;
    *) exit 99 ;;
esac
SH
hosted_sdk="$fixture/hosted-sdk"
cp -a "$sdk" "$hosted_sdk"
rm -f "$hosted_sdk/calls" "$hosted_sdk/package-sources"
rm -rf "$hosted_sdk/platforms" "$hosted_sdk/build-tools/36.0.0"
: > "$FIXTURE_HOSTED_CALLS"
ANDROID_HOME="$hosted_sdk" CODEX_CI_HOSTED_DEPENDENCIES=1 \
    bash "$fixture/hosted-scripts/prepare-ci-android.sh" "$hosted_sdk" >"$fixture/out" 2>"$fixture/last.log"
[[ "$(cat "$fixture/out")" == "$hosted_sdk" && "$(wc -l < "$FIXTURE_HOSTED_CALLS")" == 4 ]]
[[ "$(cat "$hosted_sdk/calls")" == 'licenses accepted' ]]
[[ -x "$hosted_sdk/build-tools/36.0.0/apksigner" && -s "$hosted_sdk/platforms/android-35/android.jar" ]]
: > "$FIXTURE_HOSTED_CALLS"
ANDROID_HOME="$hosted_sdk" CODEX_CI_HOSTED_DEPENDENCIES=1 FIXTURE_HOSTED_FAIL=1 \
    bash "$fixture/hosted-scripts/prepare-ci-android.sh" "$hosted_sdk" >"$fixture/out" 2>"$fixture/last.log"
[[ ! -s "$FIXTURE_HOSTED_CALLS" ]]
rm -rf "$hosted_sdk/platforms/android-35"
status=0
ANDROID_HOME="$hosted_sdk" CODEX_CI_HOSTED_DEPENDENCIES=1 FIXTURE_HOSTED_FAIL=1 \
    bash "$fixture/hosted-scripts/prepare-ci-android.sh" "$hosted_sdk" >"$fixture/out" 2>"$fixture/last.log" || status=$?
[[ "$status" == 74 && ! -s "$fixture/out" && ! -e "$hosted_sdk/platforms/android-35" ]]
# Explicit repositories remain authoritative even with hosting enabled.
: > "$FIXTURE_HOSTED_CALLS"
ANDROID_HOME="$hosted_sdk" CODEX_CI_HOSTED_DEPENDENCIES=1 FIXTURE_HOSTED_FAIL=1 \
    CODEX_ANDROID_REPOSITORY_URL=https://sdk.fixture.invalid/repository \
    bash "$fixture/hosted-scripts/prepare-ci-android.sh" "$hosted_sdk" >"$fixture/out" 2>"$fixture/last.log"
[[ ! -s "$FIXTURE_HOSTED_CALLS" && -s "$hosted_sdk/platforms/android-35/android.jar" ]]

# Maven preparation extracts only a verified package and never reuses a mutable
# installed repository. Keep this Java ZIP fixture independent of Python/Node.
mkdir -p "$fixture/maven-fixture/repository/fixture/library/1" "$fixture/maven-entry/scripts"
printf 'fixture bytes\n' > "$fixture/maven-fixture/repository/fixture/library/1/library-1.jar"
printf 'fixture\tlibrary\t1\n' > "$fixture/maven-fixture/modules.tsv"
(cd "$fixture/maven-fixture" && sha256sum modules.tsv repository/fixture/library/1/library-1.jar > SHA256SUMS)
java --source 17 "$fixture/AndroidToolsArchive.java" "$fixture/maven-fixture" "$fixture/maven.zip"
cp "$ROOT_DIR/scripts/prepare-ci-maven.sh" "$fixture/maven-entry/scripts/"
export FIXTURE_MAVEN_ARCHIVE="$fixture/maven.zip"
cat > "$fixture/maven-entry/scripts/fetch-ci-package.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == android-test-maven-v1 ]]
[[ "${FIXTURE_HOSTED_FAIL:-0}" == 0 ]] || exit 74
mkdir -p "$(dirname "$2")"
cp "$FIXTURE_MAVEN_ARCHIVE" "$2"
SH
maven_root="$(bash "$fixture/maven-entry/scripts/prepare-ci-maven.sh" "$fixture/maven-cache" "$fixture/maven-destinations")"
printf corrupt > "$maven_root/repository/fixture/library/1/library-1.jar"
next_maven="$(bash "$fixture/maven-entry/scripts/prepare-ci-maven.sh" "$fixture/maven-cache" "$fixture/maven-destinations")"
[[ "$maven_root" != "$next_maven" && "$(cat "$next_maven/repository/fixture/library/1/library-1.jar")" == 'fixture bytes' ]]
status=0
FIXTURE_HOSTED_FAIL=1 bash "$fixture/maven-entry/scripts/prepare-ci-maven.sh" "$fixture/maven-cache" "$fixture/maven-failure" >"$fixture/out" || status=$?
[[ "$status" == 74 && ! -s "$fixture/out" && ! -e "$fixture/maven-failure" ]]

# A path that cannot be a directory must also fall back, without leaking stdout.
not_directory="$fixture/not-a-directory"
printf 'keep\n' > "$not_directory"
[[ "$(prepare "$not_directory/sdk" "$sdk")" == "$sdk" ]]
[[ "$(cat "$not_directory")" == keep ]]

# The ordinary Gitee regression does not require mount privileges. Emulate only the
# write probe's EROFS result; package copying, version checks and sdkmanager
# still execute against real fixture files. Optional mount mode repeats these
# same checks on actual read-only mounts, including when running as root:
# unshare --mount --propagation private bash scripts/test-ci-android.sh --read-only-mounts
original_path="$PATH"
if [[ "${1:-}" != --read-only-mounts ]]; then
    export FIXTURE_MKTEMP="$(command -v mktemp)"
    export FIXTURE_READONLY_ROOT="$fixture/pipeline-tools"
    mkdir -p "$fixture/readonly-bin"
    cat > "$fixture/readonly-bin/mktemp" <<'MKTEMP'
#!/usr/bin/env bash
set -euo pipefail
for argument in "$@"; do
    case "$argument" in
        */.codex-write-test.*)
            directory="$(cd "${argument%/*}" && pwd -P)"
            case "$directory" in "$FIXTURE_READONLY_ROOT"/*) exit 1 ;; esac ;;
    esac
done
exec "$FIXTURE_MKTEMP" "$@"
MKTEMP
    chmod +x "$fixture/readonly-bin/mktemp"
    export PATH="$fixture/readonly-bin:$PATH"
fi
make_readonly() {
    if [[ "${read_only_mounts:-0}" == 1 ]]; then
        mount --bind "$1" "$1"
        mounts+=("$1")
        mount -o remount,bind,ro "$1"
        if (touch "$1/must-not-write") 2>/dev/null; then
            echo 'Test SDK is not actually read-only' >&2; exit 1
        fi
    fi
}
read_only_mounts=0
[[ "${1:-}" != --read-only-mounts ]] || read_only_mounts=1
{
    readonly_complete="$fixture/pipeline-tools/complete-sdk"
    mkdir -p "$readonly_complete"
    cp -a "$sdk/." "$readonly_complete/"
    rm -f -- "$readonly_complete/.prepare.lock"
    chmod a-w "$readonly_complete/licenses/android-sdk-license"
    complete_before="$(find "$readonly_complete" -type f -exec sha256sum {} + | sort)"
    make_readonly "$readonly_complete"
    complete_cache="$fixture/complete-cache"
    [[ "$(CODEX_ANDROID_TOOLS_URL=file:///missing.zip prepare "$readonly_complete" "$complete_cache")" == "$complete_cache" ]]
    grep -Fq 'Reusing preinstalled Android command-line tools:' "$fixture/last.log"
    [[ "$(grep -Fc 'Reusing preinstalled Android SDK package:' "$fixture/last.log")" == 7 ]]
    for api in 34 35 36; do
        grep -Fq "Reusing preinstalled Android SDK package: platforms;android-$api" "$fixture/last.log"
        [[ -s "$complete_cache/platforms/android-$api/android.jar" && ! -L "$complete_cache/platforms/android-$api" ]]
    done
    [[ ! -e "$complete_cache/calls" && ! -e "$complete_cache/.downloads" ]]
    [[ ! -L "$complete_cache/ndk/28.2.13676358" && -x "$complete_cache/cmdline-tools/preinstalled/bin/sdkmanager" ]]
    # Reuse needs no original mount, tools archive or package download on a later job.
    [[ "$(CODEX_ANDROID_TOOLS_URL=file:///missing.zip prepare "$complete_cache")" == "$complete_cache" ]]
    [[ ! -e "$complete_cache/calls" ]]
    [[ "$(find "$readonly_complete" -type f -exec sha256sum {} + | sort)" == "$complete_before" ]]

    readonly_sdk="$fixture/pipeline-tools/standard/android/sdk"
    mkdir -p "$readonly_sdk"
    cp -a "$sdk/." "$readonly_sdk/"
    # Model a partial platform SDK; never install missing packages into this mount.
    rm "$readonly_sdk/build-tools/36.0.0/apksigner" "$readonly_sdk/.prepare.lock"
    before="$(find "$readonly_sdk" -type f -exec sha256sum {} + | sort)"
    make_readonly "$readonly_sdk"
    fallback="$fixture/writable-cache"
    # Replace an incomplete cached NDK from the validated preinstalled package.
    mkdir -p "$fallback/ndk/28.2.13676358"
    printf 'partial\n' > "$fallback/ndk/28.2.13676358/partial-download"
    [[ "$(prepare "$readonly_sdk" "$fallback")" == "$fallback" ]]
    grep -Fq "using cache: $fallback" "$fixture/last.log"
    [[ -x "$fallback/build-tools/36.0.0/apksigner" ]]
    [[ ! -L "$fallback/platform-tools" && ! -L "$fallback/platforms/android-36" &&
        ! -L "$fallback/ndk/28.2.13676358" && ! -L "$fallback/cmake/3.22.1" ]]
    [[ ! -e "$fallback/ndk/28.2.13676358/partial-download" ]]
    [[ ! -L "$fallback/build-tools/36.0.0" ]]
    [[ "$(cat "$fallback/calls")" == $'licenses accepted\nbuild-tools;36.0.0' ]]
    [[ "$(cat "$fallback/package-sources")" == https://googledownloads.cn/android/repository/ ]]
    # Subsequent jobs must reuse the writable cache even if env/PATH still point at the mount.
    [[ "$(CODEX_ANDROID_TOOLS_URL=file:///missing.zip prepare "$readonly_sdk" "$fallback")" == "$fallback" ]]
    [[ "$(cat "$fallback/calls")" == $'licenses accepted\nbuild-tools;36.0.0' ]]
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
    # Directory names alone cannot prove package versions. A wrong preinstalled
    # revision must not be copied, while an already valid cache remains intact.
    wrong_sdk="$fixture/pipeline-tools/wrong-version-sdk"
    mkdir -p "$wrong_sdk"
    cp -a "$sdk/." "$wrong_sdk/"
    printf 'Pkg.Revision=35.0.0\n' > "$wrong_sdk/build-tools/36.0.0/source.properties"
    make_readonly "$wrong_sdk"
    wrong_cache="$fixture/wrong-version-cache"
    [[ "$(prepare "$wrong_sdk" "$wrong_cache")" == "$wrong_cache" ]]
    [[ "$(cat "$wrong_cache/calls")" == $'licenses accepted\nbuild-tools;36.0.0' ]]
    printf 'keep\n' > "$wrong_cache/build-tools/36.0.0/cache-sentinel"
    [[ "$(CODEX_ANDROID_TOOLS_URL=file:///missing.zip prepare "$wrong_sdk" "$wrong_cache")" == "$wrong_cache" ]]
    [[ "$(cat "$wrong_cache/build-tools/36.0.0/cache-sentinel")" == keep ]]
    [[ "$(cat "$wrong_cache/calls")" == $'licenses accepted\nbuild-tools;36.0.0' ]]
    # A runner can have API 36 and only part of the older plugin platforms.
    # Reuse all valid packages, downloading only missing/corrupt platform SDKs.
    platform_sdk="$fixture/pipeline-tools/partial-platform-sdk"
    mkdir -p "$platform_sdk"
    cp -a "$sdk/." "$platform_sdk/"
    rm "$platform_sdk/platforms/android-35/android.jar"
    printf 'AndroidVersion.ApiLevel=33\n' > "$platform_sdk/platforms/android-34/source.properties"
    platform_before="$(find "$platform_sdk" -type f -exec sha256sum {} + | sort)"
    make_readonly "$platform_sdk"
    platform_cache="$fixture/platform-cache"
    [[ "$(CODEX_ANDROID_TOOLS_URL=file:///missing.zip prepare "$platform_sdk" "$platform_cache")" == "$platform_cache" ]]
    [[ "$(cat "$platform_cache/calls")" == $'licenses accepted\nplatforms;android-34 platforms;android-35' ]]
    grep -Fq 'Reusing preinstalled Android SDK package: platforms;android-36' "$fixture/last.log"
    [[ "$(find "$platform_sdk" -type f -exec sha256sum {} + | sort)" == "$platform_before" ]]
    [[ "$(CODEX_ANDROID_TOOLS_URL=file:///missing.zip prepare "$platform_sdk" "$platform_cache")" == "$platform_cache" ]]
    [[ "$(wc -l < "$platform_cache/calls")" == 2 ]]
    echo 'CI Android preinstalled SDK tests passed (complete/partial copies, version rejection, cache reuse, fallback, entry, unchanged SDK)'
}
export PATH="$original_path"
echo 'CI Android SDK tests passed (bootstrap, discovery, cache, failure, concurrency, entry)'
