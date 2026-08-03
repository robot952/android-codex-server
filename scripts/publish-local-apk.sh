#!/usr/bin/env bash
set -euo pipefail

# Builds the current checkout locally, verifies the stable signing identity, and
# atomically replaces the APK served by the local HTTP server. This workflow is
# intentionally independent of Gitee tags and release-branch automation.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
source "$ROOT_DIR/scripts/android-sdk.sh"

readonly EXPECTED_CERTIFICATE_SHA256="72722218709a6d7fd0e80b944903ae2961b4cfa8abe03586f602acdc1ea0f52a"
readonly DEFAULT_PUBLISH_DIR="/var/www/html"
readonly DEFAULT_VERIFY_URL="http://210.16.163.118:18080/codex.apk"
readonly APK_PATH="$ROOT_DIR/app/build/outputs/apk/release/app-release.apk"

resolve_android_sdk "$ROOT_DIR"

version_name="$(sed -nE 's/^[[:space:]]*versionName = "([^"]+)".*/\1/p' app/build.gradle.kts)"
if [[ ! "$version_name" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]]; then
    echo "Unable to read a semantic versionName from app/build.gradle.kts" >&2
    exit 1
fi

"$ROOT_DIR/scripts/build-android.sh" release

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

certificate_sha256="$("$apksigner" verify --print-certs "$APK_PATH" |
    sed -nE 's/^Signer #1 certificate SHA-256 digest: ([0-9A-Fa-f]+)$/\1/p' |
    tr '[:upper:]' '[:lower:]')"
if [[ "$certificate_sha256" != "$EXPECTED_CERTIFICATE_SHA256" ]]; then
    echo "Unexpected APK signing certificate: ${certificate_sha256:-missing}" >&2
    exit 1
fi

output_dir="${CODEX_LOCAL_OUTPUT_DIR:-$ROOT_DIR/dist}"
publish_dir="${CODEX_LOCAL_PUBLISH_DIR:-$DEFAULT_PUBLISH_DIR}"
verify_url="${CODEX_LOCAL_VERIFY_URL:-$DEFAULT_VERIFY_URL}"
if [[ ! -d "$publish_dir" || ! -w "$publish_dir" ]]; then
    echo "CODEX_LOCAL_PUBLISH_DIR is not a writable directory: $publish_dir" >&2
    exit 1
fi

artifact_path="$output_dir/CodexRemote-$version_name.apk"
mkdir -p "$output_dir"
install -m 0644 "$APK_PATH" "$artifact_path"
artifact_sha256="$(sha256sum "$artifact_path" | awk '{print $1}')"
{
    printf 'versionName=%s\n' "$version_name"
    printf 'apkSha256=%s\n' "$artifact_sha256"
    printf 'certificateSha256=%s\n' "$certificate_sha256"
} > "$output_dir/local-release-metadata.txt"

temporary_apk="$(mktemp "$publish_dir/.codex.apk.XXXXXX")"
verify_file="$(mktemp)"
trap 'rm -f "$temporary_apk" "$verify_file"' EXIT
install -m 0644 "$artifact_path" "$temporary_apk"
mv -f "$temporary_apk" "$publish_dir/codex.apk"

curl --noproxy '*' --fail --location --silent --show-error --max-time 60 \
    --output "$verify_file" "$verify_url"
verified_sha256="$(sha256sum "$verify_file" | awk '{print $1}')"
if [[ "$verified_sha256" != "$artifact_sha256" ]]; then
    echo "Published APK verification failed for $verify_url" >&2
    exit 1
fi

echo "Published and verified $verify_url"
echo "Release artifact: $artifact_path"
