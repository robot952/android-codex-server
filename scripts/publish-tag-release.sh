#!/usr/bin/env bash
set -euo pipefail

# CI entry point for a protected v<versionName> tag. It is intentionally usable
# by any self-hosted Gitee runner without storing the signing key in Git.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

readonly EXPECTED_CERTIFICATE_SHA256="72722218709a6d7fd0e80b944903ae2961b4cfa8abe03586f602acdc1ea0f52a"
readonly DEFAULT_RELEASE_VERIFY_URL="http://210.16.163.118:18080/codex.apk"
readonly APK_PATH="$ROOT_DIR/app/build/outputs/apk/release/app-release.apk"

version_name="$(sed -nE 's/^[[:space:]]*versionName = "([^"]+)".*/\1/p' app/build.gradle.kts)"
if [[ ! "$version_name" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]]; then
    echo "Unable to read a semantic versionName from app/build.gradle.kts" >&2
    exit 1
fi

expected_tag="v$version_name"
head_commit="$(git rev-parse HEAD)"
tag_commit="$(git rev-list -n 1 "$expected_tag" 2>/dev/null || true)"
if [[ "$tag_commit" != "$head_commit" ]]; then
    echo "Release must run from tag $expected_tag pointing at HEAD ($head_commit)" >&2
    exit 1
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "Refusing to publish from a checkout with modified tracked files" >&2
    exit 1
fi

if [[ -z "${ANDROID_HOME:-}" && -d /tmp/android-sdk ]]; then
    export ANDROID_HOME=/tmp/android-sdk
fi
if [[ -n "${ANDROID_HOME:-}" && -z "${ANDROID_SDK_ROOT:-}" ]]; then
    export ANDROID_SDK_ROOT="$ANDROID_HOME"
fi
if [[ -z "${ANDROID_HOME:-}" || ! -d "$ANDROID_HOME" ]]; then
    echo "ANDROID_HOME must point to an installed Android SDK" >&2
    exit 1
fi

build_mode="${CODEX_RELEASE_BUILD_MODE:-all}"
case "$build_mode" in
    release|all) ;;
    *)
        echo "CODEX_RELEASE_BUILD_MODE must be release or all" >&2
        exit 2
        ;;
esac

"$ROOT_DIR/scripts/build-android.sh" "$build_mode"

if [[ ! -f "$APK_PATH" ]]; then
    echo "Release APK was not produced: $APK_PATH" >&2
    exit 1
fi

apksigner=""
for build_tools_dir in "$ANDROID_HOME"/build-tools/*; do
    candidate="$build_tools_dir/apksigner"
    if [[ -x "$candidate" ]]; then
        apksigner="$candidate"
    fi
done
if [[ -z "$apksigner" ]]; then
    echo "apksigner was not found under $ANDROID_HOME/build-tools" >&2
    exit 1
fi

certificate_sha256="$("$apksigner" verify --print-certs "$APK_PATH" | \
    sed -nE 's/^Signer #1 certificate SHA-256 digest: ([0-9A-Fa-f]+)$/\1/p' | tr '[:upper:]' '[:lower:]')"
if [[ "$certificate_sha256" != "$EXPECTED_CERTIFICATE_SHA256" ]]; then
    echo "Unexpected APK signing certificate: ${certificate_sha256:-missing}" >&2
    exit 1
fi

output_dir="${CODEX_RELEASE_OUTPUT_DIR:-$ROOT_DIR/dist}"
artifact_path="$output_dir/CodexRemote-$version_name.apk"
mkdir -p "$output_dir"
install -m 0644 "$APK_PATH" "$artifact_path"
artifact_sha256="$(sha256sum "$artifact_path" | awk '{print $1}')"
{
    printf 'tag=%s\n' "$expected_tag"
    printf 'versionName=%s\n' "$version_name"
    printf 'gitCommit=%s\n' "$head_commit"
    printf 'apkSha256=%s\n' "$artifact_sha256"
    printf 'certificateSha256=%s\n' "$certificate_sha256"
} > "$output_dir/release-metadata.txt"

publish_dir="${CODEX_RELEASE_PUBLISH_DIR:-}"
if [[ -n "$publish_dir" ]]; then
    if [[ ! -d "$publish_dir" || ! -w "$publish_dir" ]]; then
        echo "CODEX_RELEASE_PUBLISH_DIR is not a writable directory: $publish_dir" >&2
        exit 1
    fi
    temporary_apk="$(mktemp "$publish_dir/.codex.apk.XXXXXX")"
    trap 'rm -f "$temporary_apk"' EXIT
    install -m 0644 "$artifact_path" "$temporary_apk"
    mv -f "$temporary_apk" "$publish_dir/codex.apk"
    trap - EXIT
    echo "Published $publish_dir/codex.apk"
fi

verify_urls="${CODEX_RELEASE_VERIFY_URLS:-}"
if [[ -z "$verify_urls" && -n "$publish_dir" ]]; then
    verify_urls="$DEFAULT_RELEASE_VERIFY_URL"
fi
if [[ -n "$verify_urls" ]]; then
    IFS=',' read -r -a urls <<< "$verify_urls"
    for url in "${urls[@]}"; do
        if [[ -z "$url" ]]; then
            continue
        fi
        curl --noproxy '*' --fail --location --silent --show-error --head --max-time 20 "$url" >/dev/null
        echo "Verified $url"
    done
fi

echo "Release artifact: $artifact_path"
