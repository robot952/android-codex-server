#!/usr/bin/env bash
set -euo pipefail

# Publishes a signed release APK to the Gitee Release associated with versionName.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

readonly GITEE_API_BASE="${CODEX_GITEE_API_BASE:-https://gitee.com/api/v5}"
readonly GITEE_RELEASE_OWNER="${CODEX_RELEASE_OWNER:-YanGanYuan}"
readonly GITEE_RELEASE_REPOSITORY="${CODEX_RELEASE_REPOSITORY:-android-codex-server}"
readonly EXPECTED_CERTIFICATE_SHA256="72722218709a6d7fd0e80b944903ae2961b4cfa8abe03586f602acdc1ea0f52a"
readonly APK_PATH="$ROOT_DIR/app/build/outputs/apk/release/app-release.apk"

release_token="${CODEX_RELEASE_TOKEN:-}"
if [[ -z "$release_token" ]]; then
    echo "CODEX_RELEASE_TOKEN must be configured as a protected Gitee Go variable" >&2
    exit 2
fi

version_name="$(sed -nE 's/^[[:space:]]*versionName = "([^"]+)".*/\1/p' app/build.gradle.kts)"
if [[ ! "$version_name" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]]; then
    echo "Unable to read a semantic versionName from app/build.gradle.kts" >&2
    exit 1
fi

expected_tag="v$version_name"
head_commit="$(git rev-parse HEAD)"
tag_commit="$(git ls-remote origin "refs/tags/$expected_tag^{}" | awk 'NR == 1 { print $1 }')"
if [[ -z "$tag_commit" ]]; then
    tag_commit="$(git ls-remote origin "refs/tags/$expected_tag" | awk 'NR == 1 { print $1 }')"
fi
if [[ "$tag_commit" != "$head_commit" ]]; then
    echo "Release must run from $expected_tag pointing at HEAD ($head_commit)" >&2
    exit 1
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "Refusing to publish from a checkout with modified tracked files" >&2
    exit 1
fi

if [[ -z "${ANDROID_HOME:-}" && -n "${ANDROID_SDK_ROOT:-}" ]]; then
    export ANDROID_HOME="$ANDROID_SDK_ROOT"
elif [[ -z "${ANDROID_HOME:-}" && -d /var/lib/docker/volumes/android-sdk/_data ]]; then
    export ANDROID_HOME=/var/lib/docker/volumes/android-sdk/_data
fi
if [[ -n "${ANDROID_HOME:-}" && -z "${ANDROID_SDK_ROOT:-}" ]]; then
    export ANDROID_SDK_ROOT="$ANDROID_HOME"
fi
if [[ -z "${ANDROID_HOME:-}" || ! -d "$ANDROID_HOME" ]]; then
    echo "ANDROID_HOME must point to an installed Android SDK" >&2
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

output_dir="${CODEX_RELEASE_OUTPUT_DIR:-$ROOT_DIR/dist}"
artifact_name="CodexRemote-$version_name.apk"
artifact_path="$output_dir/$artifact_name"
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

# Gitee Go checks out a shallow tag commit. Fetching the tag with depth two lets
# the release body include the most recent two commits when the runner permits it.
git fetch --quiet --depth=2 origin "refs/tags/$expected_tag:refs/tags/$expected_tag" || true
release_notes="$(git log -2 --pretty=format:'- `%h` %s' HEAD)"
if [[ -z "$release_notes" ]]; then
    release_notes="- `$head_commit` 发布 $expected_tag"
fi
release_body=$'## 更新提交\n\n'
release_body+="$release_notes"
release_body+=$'\n\n## APK 校验\n\n'
release_body+="SHA-256: \`$artifact_sha256\`"

release_api="$GITEE_API_BASE/repos/$GITEE_RELEASE_OWNER/$GITEE_RELEASE_REPOSITORY/releases"
release_response="$(curl --fail --silent --show-error --get \
    --data-urlencode "access_token=$release_token" \
    "$release_api/tags/$expected_tag")"
release_id="$(printf '%s' "$release_response" | sed -nE 's/^[[:space:]]*\{"id"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p')"

if [[ -z "$release_id" ]]; then
    release_response="$(curl --fail --silent --show-error --request POST \
        --data-urlencode "access_token=$release_token" \
        --data-urlencode "tag_name=$expected_tag" \
        --data-urlencode "name=$expected_tag" \
        --data-urlencode "body=$release_body" \
        --data-urlencode "target_commitish=$head_commit" \
        "$release_api")"
    release_id="$(printf '%s' "$release_response" | sed -nE 's/^[[:space:]]*\{"id"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p')"
    if [[ -z "$release_id" ]]; then
        echo "Gitee did not return a Release ID" >&2
        exit 1
    fi
    echo "Created Gitee Release $expected_tag"
else
    echo "Using existing Gitee Release $expected_tag"
fi

if printf '%s' "$release_response" | grep -Fq "\"name\":\"$artifact_name\""; then
    echo "Release attachment already exists: $artifact_name"
    exit 0
fi

curl --fail --silent --show-error --request POST \
    --form "access_token=$release_token" \
    --form "file=@$artifact_path;filename=$artifact_name" \
    "$release_api/$release_id/attach_files" >/dev/null

echo "Uploaded $artifact_name to Gitee Release $expected_tag"
