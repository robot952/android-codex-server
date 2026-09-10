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
mkdir -p "$sdk_root"
sdk_root="$(cd "$sdk_root" && pwd -P)"
export ANDROID_HOME="$sdk_root" ANDROID_SDK_ROOT="$sdk_root"
# The pinned Android command-line tools support this repository override.
# Use Google's China download endpoint for metadata AND package archives.
export SDK_TEST_BASE_URL="${repository_url%/}/"
exec 9>"$sdk_root/.prepare.lock"
flock 9

manager="$(find_sdkmanager "$sdk_root" || true)"
if [[ -z "$manager" ]] || ! timeout 30 "$manager" --sdk_root="$sdk_root" --version >/dev/null 2>&1; then
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
    trap 'rm -rf -- "$staging"' EXIT
    unzip -q "$archive" -d "$staging"
    staged_manager="$staging/cmdline-tools/bin/sdkmanager"
    [[ -x "$staged_manager" && -d "$staging/cmdline-tools/lib" ]] || {
        echo "Incomplete Android command-line tools archive" >&2; exit 1;
    }
    timeout 30 "$staged_manager" --sdk_root="$sdk_root" --version >&2
    target="$sdk_root/cmdline-tools/$tools_version"
    if [[ -e "$target" || -L "$target" ]]; then mv -- "$target" "$staging/previous-tools"; fi
    mv -- "$staging/cmdline-tools" "$target"
    manager="$target/bin/sdkmanager"
fi
echo "Using sdkmanager: $manager" >&2

packages=("platform-tools" "platforms;android-36" "build-tools;36.0.0" "ndk;28.2.13676358")
package_ready() {
    case "$1" in
        platform-tools) [[ -x "$sdk_root/platform-tools/adb" ]] ;;
        'platforms;android-36') [[ -s "$sdk_root/platforms/android-36/android.jar" ]] ;;
        'build-tools;36.0.0') [[ -x "$sdk_root/build-tools/36.0.0/aapt" &&
            -x "$sdk_root/build-tools/36.0.0/apksigner" && -x "$sdk_root/build-tools/36.0.0/zipalign" ]] ;;
        'ndk;28.2.13676358') [[ -x "$sdk_root/ndk/28.2.13676358/toolchains/llvm/prebuilt/linux-x86_64/bin/clang" ]] ;;
    esac
}
missing=()
for package in "${packages[@]}"; do
    package_ready "$package" || missing+=("$package")
done

run_manager() {
    # yes normally exits with SIGPIPE. Propagate sdkmanager's status, not yes's.
    local statuses
    set +e
    yes | timeout 1800 "$manager" --sdk_root="$sdk_root" "$@" >&2
    statuses=("${PIPESTATUS[@]}")
    set -e
    return "${statuses[1]}"
}
if [[ ${#missing[@]} -gt 0 || ! -s "$sdk_root/licenses/android-sdk-license" ]]; then
    echo "Accepting Android SDK licenses" >&2
    run_manager --licenses || { echo "Android SDK license preparation failed" >&2; exit 1; }
fi
if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Installing Android SDK packages: ${missing[*]}" >&2
    installed=0
    for attempt in 1 2 3; do
        if run_manager "${missing[@]}"; then installed=1; break; fi
        echo "Android SDK package installation failed (attempt $attempt/3)" >&2
    done
    [[ "$installed" == 1 ]] || exit 1
fi
for package in "${packages[@]}"; do
    package_ready "$package" || { echo "Android SDK package is incomplete: $package" >&2; exit 1; }
done
[[ -s "$sdk_root/licenses/android-sdk-license" ]] || { echo "Android SDK license is missing" >&2; exit 1; }
echo "Android SDK ready: $sdk_root" >&2
printf '%s\n' "$sdk_root"
