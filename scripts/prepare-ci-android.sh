#!/usr/bin/env bash
set -euo pipefail

# stdout is the ready SDK root; diagnostics and sdkmanager output go to stderr.
cache_root="${1:-$HOME/.cache/codex/android-sdk}"
tools_version=12.0
tools_archive=commandlinetools-linux-11076708_latest.zip
# Verified against Google's repository2-1.xml (SHA-1 d313adb7aedccf6cf0cfca51ec180f0059f5f8f8).
tools_sha256=2d2d50857e4eb553af5a6dc3ad507a17adf43d115264b1afc116f95c92e5e258
repository_url="${CODEX_ANDROID_REPOSITORY_URL:-https://googledownloads.cn/android/repository}"
tools_url="${repository_url%/}/$tools_archive"
# A private mirror/fixture must provide its own integrity pin explicitly.
if [[ -n "${CODEX_ANDROID_TOOLS_URL:-}" ]]; then
    tools_url="$CODEX_ANDROID_TOOLS_URL"
    tools_sha256="${CODEX_ANDROID_TOOLS_SHA256:?A custom tools archive needs its SHA-256}"
fi
[[ "$tools_sha256" =~ ^[a-f0-9]{64}$ ]] || exit 2

find_sdkmanager() {
    local root="$1" candidate
    for candidate in "$root/cmdline-tools/latest/bin/sdkmanager" \
        "$root/cmdline-tools/$tools_version/bin/sdkmanager" \
        "$root"/cmdline-tools/*/bin/sdkmanager "$root/tools/bin/sdkmanager"; do
        if [[ -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

# The app uses API 36, but locked Android plugins also compile against 34/35.
# Prepare every required platform here, including copies from a read-only SDK;
# otherwise AGP downloads them during assembleRelease and consumes its deadline.
packages=("platform-tools" "platforms;android-34" "platforms;android-35" "platforms;android-36" "build-tools;36.0.0" "ndk;28.2.13676358" "cmake;3.22.1")
property_matches() {
    local file="$1" key="$2" value="$3"
    [[ -f "$file" ]] || return 1
    grep -Eq "^[[:space:]]*${key}[[:space:]]*=[[:space:]]*${value}[[:space:]]*$" "$file"
}
cmake_tools_ready() {
    local cmake="$1" ninja="$2" version
    [[ -x "$cmake" && -x "$ninja" ]] || {
        echo 'Android SDK CMake or bundled Ninja executable is missing' >&2; return 1;
    }
    version="$(timeout --kill-after=5s 10 "$cmake" --version 2>/dev/null)" || {
        echo 'Android SDK CMake --version failed or timed out' >&2; return 1;
    }
    # Google's Android package reports 3.22.1-g37088a8; upstream reports 3.22.1.
    [[ "${version%%$'\n'*}" =~ ^cmake\ version\ 3\.22\.1(-g[0-9a-f]+)?$ ]] || {
        printf 'Android SDK CMake version mismatch: %s\n' "${version%%$'\n'*}" >&2; return 1;
    }
    timeout --kill-after=5s 10 "$ninja" --version >/dev/null 2>&1 || {
        echo 'Android SDK Ninja --version failed or timed out' >&2; return 1;
    }
}
package_ready() {
    local api sdk_root="${2:-$sdk_root}"
    case "$1" in
        platform-tools) [[ -x "$sdk_root/platform-tools/adb" ]] &&
            property_matches "$sdk_root/platform-tools/source.properties" 'Pkg\.Revision' '[0-9]+(\.[0-9]+)+' ;;
        'platforms;android-'*)
            api="${1#platforms;android-}"
            [[ "$api" =~ ^[0-9]+$ && -s "$sdk_root/platforms/android-$api/android.jar" ]] &&
                property_matches "$sdk_root/platforms/android-$api/source.properties" 'AndroidVersion\.ApiLevel' "$api" ;;
        'build-tools;36.0.0') [[ -x "$sdk_root/build-tools/36.0.0/aapt" &&
            -x "$sdk_root/build-tools/36.0.0/apksigner" && -x "$sdk_root/build-tools/36.0.0/zipalign" ]] &&
            property_matches "$sdk_root/build-tools/36.0.0/source.properties" 'Pkg\.Revision' '36\.0\.0' ;;
        'ndk;28.2.13676358') [[ -x "$sdk_root/ndk/28.2.13676358/toolchains/llvm/prebuilt/linux-x86_64/bin/clang" ]] &&
            property_matches "$sdk_root/ndk/28.2.13676358/source.properties" 'Pkg\.Revision' '28\.2\.13676358' ;;
        'cmake;3.22.1')
            property_matches "$sdk_root/cmake/3.22.1/source.properties" 'Pkg\.Revision' '3\.22\.1' || {
                echo 'Android SDK CMake package revision mismatch' >&2; return 1;
            }
            cmake_tools_ready "$sdk_root/cmake/3.22.1/bin/cmake" "$sdk_root/cmake/3.22.1/bin/ninja" ;;
        *) return 1 ;;
    esac
}

sdk_root="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
path_manager="$(command -v sdkmanager || true)"
if [[ -z "$sdk_root" && -n "$path_manager" ]]; then
    path_manager="$(readlink -f "$path_manager")"
    case "$path_manager" in
        */cmdline-tools/*/bin/sdkmanager) sdk_root="${path_manager%/cmdline-tools/*}" ;;
        */tools/bin/sdkmanager) sdk_root="${path_manager%/tools/bin/sdkmanager}" ;;
    esac
fi
if [[ -z "$sdk_root" ]]; then
    for root in "$cache_root" /opt/android-sdk /opt/android-sdk-linux \
        /usr/local/android-sdk /usr/local/android-sdk-linux /usr/lib/android-sdk \
        /android-sdk "$HOME/android-sdk" "$HOME/Android/Sdk"; do
        if find_sdkmanager "$root" >/dev/null; then
            sdk_root="$root"
            break
        fi
    done
fi
sdk_root="${sdk_root:-$cache_root}"
# Hosted runners can export a preinstalled SDK on a read-only bind mount.
# Check actual writes (not just mode bits, which are misleading for root/ACLs)
# before opening the lock, accepting licenses or installing any packages.
readonly_sdk_root=
writable_directory() {
    local directory="$1" probe
    mkdir -p -- "$directory" 2>/dev/null || return 1
    probe="$(mktemp "$directory/.codex-write-test.XXXXXX" 2>/dev/null)" || return 1
    rm -f -- "$probe"
}
if ! writable_directory "$sdk_root"; then
    # Invalid inherited paths may not even be directories. Retain only a real
    # preinstalled root; otherwise the normal writable-cache bootstrap applies.
    if [[ -d "$sdk_root" ]]; then readonly_sdk_root="$(cd "$sdk_root" && pwd -P)"; fi
    echo "Android SDK directory is not writable: $sdk_root; using cache: $cache_root" >&2
    sdk_root="$cache_root"
    if ! writable_directory "$sdk_root"; then
        echo "Android SDK cache is not writable: $sdk_root; provide a writable cache directory" >&2
        exit 1
    fi
fi
sdk_root="$(cd "$sdk_root" && pwd -P)"
export ANDROID_HOME="$sdk_root" ANDROID_SDK_ROOT="$sdk_root"
# The pinned Android command-line tools support this repository override.
# Use Google's China download endpoint for metadata AND package archives.
export SDK_TEST_BASE_URL="${repository_url%/}/"
manager_deadline() {
    local seconds="$1"
    shift
    if [[ -n "${CODEX_CI_PROCESS_GROUP:-}" ]]; then
        bash "$(dirname "${BASH_SOURCE[0]}")/run-ci-stage.sh" 'Android sdkmanager' "$seconds" "$@"
    else
        timeout --kill-after=30s "$seconds" "$@"
    fi
}

staging_directories=()
cleanup() {
    local directory
    for directory in "${staging_directories[@]}"; do rm -rf -- "$directory"; done
}
trap cleanup EXIT
reuse_directory() {
    local source="$1" target="$2" staging
    staging="$(mktemp -d "$sdk_root/.reuse.XXXXXX")"
    staging_directories+=("$staging")
    mkdir -p -- "$staging/payload" "$(dirname "$target")"
    # Copy only required, validated packages. Reflinks save local I/O where
    # available; independent writable copies also survive later runner mounts.
    # Never link sdkmanager's installation targets back into a read-only SDK.
    manager_deadline 300 cp -a --reflink=auto -- "$source/." "$staging/payload/"
    manager_deadline 60 chmod -R u+w -- "$staging/payload"
    if [[ -e "$target" || -L "$target" ]]; then mv -- "$target" "$staging/previous"; fi
    mv -- "$staging/payload" "$target"
    rm -rf -- "$staging"
}

reuse_system_cmake() {
    local cmake ninja prefix staging payload tool
    cmake="$(command -v cmake || true)"
    ninja="$(command -v ninja || true)"
    [[ -n "$cmake" && -n "$ninja" ]] || return 0
    echo "Inspecting system CMake/Ninja: $cmake, $ninja" >&2
    cmake_tools_ready "$cmake" "$ninja" || return 0
    cmake="$(readlink -f "$cmake")"
    prefix="${cmake%/bin/cmake}"
    # Copy only CMake's runtime files, never an entire system prefix such as /usr.
    [[ -f "$prefix/share/cmake-3.22/Modules/CMake.cmake" ]] || return 0
    staging="$(mktemp -d "$sdk_root/.cmake-reuse.XXXXXX")"
    staging_directories+=("$staging")
    payload="$staging/cmake/3.22.1"
    mkdir -p "$payload/bin" "$payload/share"
    cp -L -- "$cmake" "$payload/bin/cmake"
    cp -L -- "$ninja" "$payload/bin/ninja"
    for tool in ctest cpack; do
        if [[ -x "$prefix/bin/$tool" ]]; then cp -L -- "$prefix/bin/$tool" "$payload/bin/"; fi
    done
    manager_deadline 60 cp -a --reflink=auto -- "$prefix/share/cmake-3.22" "$payload/share/"
    printf 'Pkg.Revision = 3.22.1\nPkg.Path = cmake;3.22.1\nPkg.Desc = CMake 3.22.1\n' > "$payload/source.properties"
    package_ready 'cmake;3.22.1' "$staging"
    reuse_directory "$payload" "$sdk_root/cmake/3.22.1"
    echo 'Reusing system CMake 3.22.1 and Ninja; no CMake download needed' >&2
}

prepare_cmake_archive() {
    local url archive partial expected_sha status http_status attempt staging payload
    # The China mirror returns 404 and Gitee workers cannot reliably reach Google.
    # Default to our immutable dependency branch, containing the untouched official
    # archive. Other SDK packages stay on their selected repository.
    url="${CODEX_ANDROID_CMAKE_URL:-}"
    # Official repository SHA-1: fd0a48b4a758310df8c7aa51f59840ed48fe7ed8.
    expected_sha=9196644852a978012caf7a4067ba1898debf6cc204c3341562771e31080d6869
    if [[ -n "${CODEX_ANDROID_CMAKE_URL:-}" ]]; then
        expected_sha="${CODEX_ANDROID_CMAKE_SHA256:?A custom CMake archive needs its SHA-256}"
    fi
    [[ "$expected_sha" =~ ^[a-f0-9]{64}$ ]] || return 2
    mkdir -p "$sdk_root/.downloads"
    archive="$sdk_root/.downloads/cmake-3.22.1-linux.zip"
    partial="$archive.part"
    cmake_archive_valid() {
        [[ -f "$1" && "$(sha256sum "$1" | awk '{print $1}')" == "$expected_sha" ]]
    }
    if [[ -z "$url" ]] && ! cmake_archive_valid "$archive"; then
        echo 'Preparing official CMake 3.22.1 archive from Gitee ci-deps (22,308,647 bytes)' >&2
        bash "$(dirname "${BASH_SOURCE[0]}")/fetch-ci-dependency.sh" \
            https://gitee.com/YanGanYuan/android-codex-server.git \
            refs/tags/ci-deps-cmake-3.22.1-linux-x86_64 \
            598abbd92d9711f953613ee51987bd5c71b23b4f \
            cmake/cmake-3.22.1-linux.zip "$expected_sha" "$archive" || return $?
    fi
    if ! cmake_archive_valid "$archive"; then
        for attempt in 1 2; do
            cmake_archive_valid "$partial" && break
            echo "Downloading CMake 3.22.1 only (attempt $attempt/2, timeout 180s, SHA-256 verified)" >&2
            status=0
            http_status="$(curl --http1.1 --fail --location --silent --show-error \
                --connect-timeout 20 --max-time 180 --speed-time 30 --speed-limit 1024 \
                --continue-at - --output "$partial" --write-out '%{http_code}' "$url")" || status=$?
            cmake_archive_valid "$partial" && break
            case "$status" in 124|137|129|130|143) return "$status" ;; esac
            if [[ "$status" == 0 || "$status" == 33 || "$http_status" == 416 ]]; then rm -f -- "$partial"; fi
            # A missing archive or invalid credentials cannot be fixed by retrying.
            case "$http_status" in 400|401|403|404) break ;; esac
        done
        cmake_archive_valid "$partial" || { echo 'CMake download failed or SHA-256 mismatch; SDK repository was not switched' >&2; return 1; }
        mv -f -- "$partial" "$archive"
    fi
    staging="$(mktemp -d "$sdk_root/.cmake-install.XXXXXX")"
    staging_directories+=("$staging")
    payload="$staging/cmake/3.22.1"
    mkdir -p "$payload"
    manager_deadline 60 unzip -q "$archive" -d "$payload"
    # Reject corrupt/incomplete tools before replacing any previous installation.
    package_ready 'cmake;3.22.1' "$staging"
    reuse_directory "$payload" "$sdk_root/cmake/3.22.1"
    echo 'Installed and verified CMake 3.22.1 with bundled Ninja' >&2
}

prepare_hosted_android_package() {
    local package="$1" key relative archive_root archive staging
    case "$package" in
        platform-tools) key=android-platform-tools; relative=platform-tools; archive_root=platform-tools ;;
        'platforms;android-'*)
            key="android-platform-${package#platforms;android-}"
            relative="platforms/android-${package#platforms;android-}"
            archive_root="android-${package#platforms;android-}" ;;
        'build-tools;36.0.0') key=android-build-tools-36; relative=build-tools/36.0.0; archive_root=android-16 ;;
        *) return 0 ;;
    esac
    mkdir -p "$sdk_root/.downloads"
    archive="$sdk_root/.downloads/$key.zip"
    bash "$(dirname "${BASH_SOURCE[0]}")/fetch-ci-package.sh" "$key" "$archive" || return $?
    staging="$(mktemp -d "$sdk_root/.hosted-install.XXXXXX")"
    staging_directories+=("$staging")
    mkdir -p "$staging/extracted" "$(dirname "$staging/sdk/$relative")"
    manager_deadline 60 unzip -q "$archive" -d "$staging/extracted" || return $?
    mv -- "$staging/extracted/$archive_root" "$staging/sdk/$relative" || return $?
    package_ready "$package" "$staging/sdk" || {
        echo "Hosted Android SDK package is incomplete: $package" >&2; return 1;
    }
    reuse_directory "$staging/sdk/$relative" "$sdk_root/$relative"
    echo "Installed verified hosted Android SDK package: $package" >&2
}

seed_preinstalled_packages() {
    local package relative target license
    [[ -n "$readonly_sdk_root" ]] || return 0
    echo "Inspecting preinstalled Android SDK: $readonly_sdk_root" >&2
    for package in "${packages[@]}"; do
        if package_ready "$package"; then
            echo "Reusing cached Android SDK package: $package" >&2
            continue
        fi
        if ! package_ready "$package" "$readonly_sdk_root"; then
            echo "Preinstalled Android SDK package missing or incompatible: $package" >&2
            continue
        fi
        case "$package" in
            platform-tools) relative=platform-tools ;;
            'platforms;android-'*) relative="platforms/android-${package#platforms;android-}" ;;
            'build-tools;36.0.0') relative=build-tools/36.0.0 ;;
            'ndk;28.2.13676358') relative=ndk/28.2.13676358 ;;
            'cmake;3.22.1') relative=cmake/3.22.1 ;;
        esac
        target="$sdk_root/$relative"
        echo "Reusing preinstalled Android SDK package: $package" >&2
        reuse_directory "$readonly_sdk_root/$relative" "$target"
    done
    mkdir -p -- "$sdk_root/licenses"
    for license in "$readonly_sdk_root"/licenses/*; do
        [[ -f "$license" ]] || continue
        target="$sdk_root/licenses/${license##*/}"
        if [[ ! -s "$target" ]]; then
            cp --remove-destination -- "$license" "$target"
            chmod u+w -- "$target"
        fi
    done
}

exec 9>"$sdk_root/.prepare.lock"
flock -w 300 9 || { echo 'Timed out waiting for Android SDK cache lock' >&2; exit 1; }
seed_preinstalled_packages
manager="$(find_sdkmanager "$sdk_root" || true)"
if [[ -z "$manager" ]] || ! manager_deadline 30 "$manager" --sdk_root="$sdk_root" --version >/dev/null; then
    manager=
    preinstalled_manager=
    if [[ -n "$readonly_sdk_root" ]]; then
        preinstalled_manager="$(find_sdkmanager "$readonly_sdk_root" || true)"
    fi
    if [[ -n "$preinstalled_manager" ]] &&
        manager_deadline 30 "$preinstalled_manager" --sdk_root="$sdk_root" --version >/dev/null; then
        echo "Reusing preinstalled Android command-line tools: $preinstalled_manager" >&2
        case "$preinstalled_manager" in
            */cmdline-tools/*/bin/sdkmanager) target="$sdk_root/cmdline-tools/preinstalled" ;;
            */tools/bin/sdkmanager) target="$sdk_root/tools" ;;
        esac
        reuse_directory "${preinstalled_manager%/bin/sdkmanager}" "$target"
        manager="$target/bin/sdkmanager"
        manager_deadline 30 "$manager" --sdk_root="$sdk_root" --version >/dev/null
    fi
fi
if [[ -z "$manager" ]]; then
    echo "Preparing Android command-line tools $tools_version in $sdk_root" >&2
    for command in curl unzip sha256sum java; do
        command -v "$command" >/dev/null || { echo "Required tool missing: $command" >&2; exit 1; }
    done
    mkdir -p "$sdk_root/.downloads" "$sdk_root/cmdline-tools"
    archive="$sdk_root/.downloads/$tools_archive"
    partial="$archive.part"
    valid_archive() {
        [[ -f "$1" ]] && [[ "$(sha256sum "$1" | awk '{print $1}')" == "$tools_sha256" ]]
    }
    if ! valid_archive "$archive"; then
        for attempt in 1 2 3; do
            valid_archive "$partial" && break
            echo "Downloading Android command-line tools (attempt $attempt/3, resumable)" >&2
            status=0
            http_status="$(curl --http1.1 --fail --location --silent --show-error \
                --connect-timeout 20 --max-time 300 --speed-time 60 --speed-limit 1024 \
                --continue-at - --output "$partial" --write-out '%{http_code}' "$tools_url")" || status=$?
            valid_archive "$partial" && break
            if [[ "$status" == 0 || "$status" == 33 || "$http_status" == 416 ]]; then
                rm -f -- "$partial"
            fi
        done
        valid_archive "$partial" || { echo "Android tools download failed or SHA-256 mismatch" >&2; exit 1; }
        mv -f -- "$partial" "$archive"
    fi
    staging="$(mktemp -d "$sdk_root/.prepare.XXXXXX")"
    staging_directories+=("$staging")
    unzip -q "$archive" -d "$staging"
    staged_manager="$staging/cmdline-tools/bin/sdkmanager"
    [[ -x "$staged_manager" && -d "$staging/cmdline-tools/lib" ]] || {
        echo "Incomplete Android command-line tools archive" >&2; exit 1;
    }
    manager_deadline 30 "$staged_manager" --sdk_root="$sdk_root" --version >&2
    target="$sdk_root/cmdline-tools/$tools_version"
    if [[ -e "$target" || -L "$target" ]]; then mv -- "$target" "$staging/previous-tools"; fi
    mv -- "$staging/cmdline-tools" "$target"
    manager="$target/bin/sdkmanager"
fi
if [[ -n "$manager" ]]; then echo "Using sdkmanager: $manager" >&2; fi
if [[ -z "${CODEX_ANDROID_REPOSITORY_URL:-}" ]] && ! package_ready 'cmake;3.22.1'; then
    reuse_system_cmake
fi
missing=()
for package in "${packages[@]}"; do
    package_ready "$package" || missing+=("$package")
done

run_manager() {
    # yes normally exits with SIGPIPE. Propagate sdkmanager's status, not yes's.
    local statuses
    set +e
    yes | manager_deadline 1800 "$manager" --sdk_root="$sdk_root" "$@" >&2
    statuses=("${PIPESTATUS[@]}")
    set -e
    return "${statuses[1]}"
}
if [[ ${#missing[@]} -gt 0 || ! -s "$sdk_root/licenses/android-sdk-license" ]]; then
    echo "Accepting Android SDK licenses" >&2
    run_manager --licenses || { echo "Android SDK license preparation failed" >&2; exit 1; }
fi
# An explicit repository remains authoritative, including for CMake. Otherwise
# prepare CMake separately so its known mirror 404 cannot redirect other packages.
if [[ -z "${CODEX_ANDROID_REPOSITORY_URL:-}" ]] && ! package_ready 'cmake;3.22.1'; then
    prepare_cmake_archive
    missing=()
    for package in "${packages[@]}"; do
        package_ready "$package" || missing+=("$package")
    done
fi
if [[ "${CODEX_CI_HOSTED_DEPENDENCIES:-0}" == 1 && -z "${CODEX_ANDROID_REPOSITORY_URL:-}" ]]; then
    # Reuse preinstalled/cached packages first. Only small missing components are
    # hosted; the NDK remains on sdkmanager and custom repositories stay in control.
    for package in "${missing[@]}"; do
        prepare_hosted_android_package "$package"
    done
    missing=()
    for package in "${packages[@]}"; do
        package_ready "$package" || missing+=("$package")
    done
fi
if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Installing Android SDK packages: ${missing[*]}" >&2
    installed=0
    for attempt in 1 2 3; do
        if run_manager "${missing[@]}"; then
            installed=1
            break
        else
            install_status=$?
        fi
        echo "Android SDK package installation failed (attempt $attempt/3, exit $install_status)" >&2
        # A deadline or cancellation ends this stage; it must not start another download.
        case "$install_status" in
            124|137|129|130|143) exit "$install_status" ;;
        esac
        if [[ "$attempt" == 1 && -z "${CODEX_ANDROID_REPOSITORY_URL:-}" ]]; then
            # The default mirror may list packages whose archives return 404.
            # Keep sdkmanager's checksum checks and the same three-attempt budget.
            export SDK_TEST_BASE_URL=https://dl.google.com/android/repository/
            echo 'Default Android SDK repository failed; retrying with Google official repository' >&2
        fi
    done
    [[ "$installed" == 1 ]] || exit 1
fi
for package in "${packages[@]}"; do
    package_ready "$package" || { echo "Android SDK package is incomplete: $package" >&2; exit 1; }
done
[[ -s "$sdk_root/licenses/android-sdk-license" ]] || { echo "Android SDK license is missing" >&2; exit 1; }
echo "Android SDK ready: $sdk_root" >&2
echo "Native build tools ready: CMake 3.22.1, bundled Ninja" >&2
printf '%s\n' "$sdk_root"
