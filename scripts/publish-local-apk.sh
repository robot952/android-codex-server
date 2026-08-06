#!/usr/bin/env bash
set -euo pipefail

# Builds the current checkout locally, verifies the stable signing identity, and
# atomically replaces the APK served by the local HTTP server. This workflow is
# intentionally independent of Gitee tags and release-branch automation.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
source "$ROOT_DIR/scripts/android-sdk.sh"
source "$ROOT_DIR/scripts/apk-lib.sh"

readonly DEFAULT_PUBLISH_DIR="/var/www/html"
readonly DEFAULT_VERIFY_URLS="http://192.168.8.109:18080/codex.apk,http://frp.asdb.top:18080/codex.apk"
readonly APK_PATH="$ROOT_DIR/flutter_app/build/app/outputs/flutter-apk/app-release.apk"

resolve_android_sdk "$ROOT_DIR"

reuse=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --reuse) reuse=1 ;;
        --force) reuse=0 ;;
        *)
            echo "usage: $0 [--reuse|--force]" >&2
            exit 2
            ;;
    esac
    shift
done

version_name="$(apk_version_name "$ROOT_DIR")"

if [[ "$reuse" == 1 ]]; then
    "$ROOT_DIR/scripts/build-android.sh" release --reuse
else
    "$ROOT_DIR/scripts/build-android.sh" release --force
fi

certificate_sha256="$(apk_verify_stable_signature "$ANDROID_HOME" "$APK_PATH")"

output_dir="${CODEX_LOCAL_OUTPUT_DIR:-$ROOT_DIR/dist}"
publish_dir="${CODEX_LOCAL_PUBLISH_DIR:-$DEFAULT_PUBLISH_DIR}"
verify_urls="${CODEX_LOCAL_VERIFY_URLS:-${CODEX_LOCAL_VERIFY_URL:-$DEFAULT_VERIFY_URLS}}"
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
    printf 'gitCommit=%s\n' "$(git rev-parse HEAD)"
    printf 'apkSha256=%s\n' "$artifact_sha256"
    printf 'certificateSha256=%s\n' "$certificate_sha256"
} > "$output_dir/local-release-metadata.txt"

temporary_apk="$(mktemp "$publish_dir/.codex.apk.XXXXXX")"
verify_file="$(mktemp)"
trap 'rm -f "$temporary_apk" "$verify_file"' EXIT
published_sha256=""
if [[ -f "$publish_dir/codex.apk" ]]; then
    published_sha256="$(sha256sum "$publish_dir/codex.apk" | awk '{print $1}')"
fi
if [[ "$published_sha256" == "$artifact_sha256" ]]; then
    echo "Reusing unchanged $publish_dir/codex.apk"
else
    install -m 0644 "$artifact_path" "$temporary_apk"
    mv -f "$temporary_apk" "$publish_dir/codex.apk"
fi

IFS=',' read -r -a urls <<< "$verify_urls"
for verify_url in "${urls[@]}"; do
    [[ -n "$verify_url" ]] || continue
    curl --noproxy '*' --fail --location --silent --show-error --max-time 60 \
        --output "$verify_file" "$verify_url"
    verified_sha256="$(sha256sum "$verify_file" | awk '{print $1}')"
    if [[ "$verified_sha256" != "$artifact_sha256" ]]; then
        echo "Published APK verification failed for $verify_url" >&2
        exit 1
    fi
    echo "Published and verified $verify_url"
done

echo "Release artifact: $artifact_path"
echo "SHA-256: $artifact_sha256"
