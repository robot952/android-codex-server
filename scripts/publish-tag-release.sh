#!/usr/bin/env bash
set -euo pipefail

# CI entry point for a protected v<versionName> tag. It is intentionally usable
# by any self-hosted Gitee runner without storing the signing key in Git.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
source "$ROOT_DIR/scripts/android-sdk.sh"
source "$ROOT_DIR/scripts/apk-lib.sh"

readonly DEFAULT_RELEASE_VERIFY_URLS="http://192.168.8.109:18080/codex.apk,http://frp.asdb.top:18080/codex.apk"
readonly APK_PATH="$ROOT_DIR/flutter_app/build/app/outputs/flutter-apk/app-release.apk"

version_name="$(apk_version_name "$ROOT_DIR")"

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

resolve_android_sdk "$ROOT_DIR"

build_mode="${CODEX_RELEASE_BUILD_MODE:-all}"
case "$build_mode" in
    release|all) ;;
    *)
        echo "CODEX_RELEASE_BUILD_MODE must be release or all" >&2
        exit 2
        ;;
esac

"$ROOT_DIR/scripts/build-android.sh" "$build_mode" --force
certificate_sha256="$(apk_verify_stable_signature "$ANDROID_HOME" "$APK_PATH")"

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
    verify_urls="$DEFAULT_RELEASE_VERIFY_URLS"
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
