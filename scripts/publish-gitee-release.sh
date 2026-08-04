#!/usr/bin/env bash
set -euo pipefail

# Publishes a signed release APK from the protected release branch.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
source "$ROOT_DIR/scripts/android-sdk.sh"
source "$ROOT_DIR/scripts/apk-lib.sh"

readonly GITEE_API_BASE="${CODEX_GITEE_API_BASE:-https://gitee.com/api/v5}"
readonly GITEE_RELEASE_OWNER="${CODEX_RELEASE_OWNER:-YanGanYuan}"
readonly GITEE_RELEASE_REPOSITORY="${CODEX_RELEASE_REPOSITORY:-android-codex-server}"
readonly GITEE_RELEASE_BRANCH="${CODEX_RELEASE_BRANCH:-release}"
readonly APK_PATH="$ROOT_DIR/app/build/outputs/apk/release/app-release.apk"

release_token="${CODEX_RELEASE_TOKEN:-}"
if [[ -z "$release_token" ]]; then
    echo "CODEX_RELEASE_TOKEN must be configured as a protected Gitee Go variable" >&2
    exit 2
fi

version_name="$(apk_version_name "$ROOT_DIR")"

expected_tag="v$version_name"
head_commit="$(git rev-parse HEAD)"
release_branch_commit="$(git ls-remote origin "refs/heads/$GITEE_RELEASE_BRANCH" | awk 'NR == 1 { print $1 }')"
if [[ "$release_branch_commit" != "$head_commit" ]]; then
    echo "Release must run from $GITEE_RELEASE_BRANCH pointing at HEAD ($head_commit)" >&2
    exit 1
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "Refusing to publish from a checkout with modified tracked files" >&2
    exit 1
fi

resolve_android_sdk "$ROOT_DIR"

"$ROOT_DIR/scripts/build-android.sh" release --force
certificate_sha256="$(apk_verify_stable_signature "$ANDROID_HOME" "$APK_PATH")"

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

# Gitee Go checks out a shallow branch commit. Deepen only the release branch
# so the user-visible changelog remains useful without a full repository clone.
git fetch --quiet --depth=32 origin "refs/heads/$GITEE_RELEASE_BRANCH" || true
release_notes="$(git log -12 --pretty=format:'- `%h` %s' HEAD)"
if [[ -z "$release_notes" ]]; then
    release_notes="- `$head_commit` 发布 $expected_tag"
fi
release_body=$'## 更新日志\n\n'
release_body+="$release_notes"
release_body+=$'\n\n## APK 校验\n\n'
release_body+="SHA-256: \`$artifact_sha256\`"

release_api="$GITEE_API_BASE/repos/$GITEE_RELEASE_OWNER/$GITEE_RELEASE_REPOSITORY/releases"
tags_api="$GITEE_API_BASE/repos/$GITEE_RELEASE_OWNER/$GITEE_RELEASE_REPOSITORY/tags"

remote_tag_commit() {
    local tag_commit
    tag_commit="$(git ls-remote origin "refs/tags/$expected_tag^{}" | awk 'NR == 1 { print $1 }')"
    if [[ -z "$tag_commit" ]]; then
        tag_commit="$(git ls-remote origin "refs/tags/$expected_tag" | awk 'NR == 1 { print $1 }')"
    fi
    printf '%s' "$tag_commit"
}

tag_commit="$(remote_tag_commit)"
if [[ -n "$tag_commit" && "$tag_commit" != "$head_commit" ]]; then
    echo "Refusing to move existing tag $expected_tag from $tag_commit" >&2
    exit 1
fi
if [[ -z "$tag_commit" ]]; then
    curl --fail --silent --show-error --request POST \
        --data-urlencode "access_token=$release_token" \
        --data-urlencode "tag_name=$expected_tag" \
        --data-urlencode "refs=$head_commit" \
        "$tags_api" >/dev/null

    # The API write and the Git reference advertisement may race briefly.
    for _ in {1..5}; do
        tag_commit="$(remote_tag_commit)"
        [[ "$tag_commit" == "$head_commit" ]] && break
        sleep 1
    done
    if [[ "$tag_commit" != "$head_commit" ]]; then
        echo "Gitee created $expected_tag, but it does not point at HEAD" >&2
        exit 1
    fi
    echo "Created Gitee tag $expected_tag"
else
    echo "Using existing Gitee tag $expected_tag"
fi

# A missing Release is a normal first-publish condition, so distinguish its
# 404 response from actual API failures before attempting to create it.
release_lookup="$(curl --silent --show-error --get --write-out $'\n%{http_code}' \
    --data-urlencode "access_token=$release_token" \
    "$release_api/tags/$expected_tag")"
release_status="${release_lookup##*$'\n'}"
release_response="${release_lookup%$'\n'*}"
case "$release_status" in
    200) ;;
    404) release_response="" ;;
    *)
        echo "Unable to look up Gitee Release $expected_tag (HTTP $release_status)" >&2
        exit 1
        ;;
esac
release_id="$(printf '%s' "$release_response" | sed -nE 's/^[[:space:]]*\{[[:space:]]*"id"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p')"

if [[ -z "$release_id" ]]; then
    release_response="$(curl --fail --silent --show-error --request POST \
        --data-urlencode "access_token=$release_token" \
        --data-urlencode "tag_name=$expected_tag" \
        --data-urlencode "name=$expected_tag" \
        --data-urlencode "body=$release_body" \
        --data-urlencode "target_commitish=$head_commit" \
        "$release_api")"
    release_id="$(printf '%s' "$release_response" | sed -nE 's/^[[:space:]]*\{[[:space:]]*"id"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p')"
    if [[ -z "$release_id" ]]; then
        echo "Gitee did not return a Release ID" >&2
        exit 1
    fi
    echo "Created Gitee Release $expected_tag"
else
    echo "Using existing Gitee Release $expected_tag"
fi

if printf '%s' "$release_response" | tr -d '[:space:]' | grep -Fq "\"name\":\"$artifact_name\""; then
    echo "Release attachment already exists: $artifact_name"
    exit 0
fi

curl --fail --silent --show-error --request POST \
    --form "access_token=$release_token" \
    --form "file=@$artifact_path;filename=$artifact_name" \
    "$release_api/$release_id/attach_files" >/dev/null

echo "Uploaded $artifact_name to Gitee Release $expected_tag"
