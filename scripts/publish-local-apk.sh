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
readonly DEFAULT_VERIFY_URLS="http://192.168.8.107/codex.apk,http://frp.asdb.top:18080/codex.apk"
readonly APK_PATH="$ROOT_DIR/flutter_app/build/app/outputs/flutter-apk/app-release.apk"
readonly EXPECTED_APPLICATION_ID="top.asdb.agent"
readonly PUBLISH_LOCK_FILE=".agent-apk-publish.lock"

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
version_code="$(apk_version_code "$ROOT_DIR")"

if [[ "$reuse" == 1 ]]; then
    "$ROOT_DIR/scripts/build-android.sh" release --reuse
else
    "$ROOT_DIR/scripts/build-android.sh" release --force
fi

certificate_sha256="$(apk_verify_stable_signature "$ANDROID_HOME" "$APK_PATH")"

apkanalyzer="$(apk_find_apkanalyzer "$ANDROID_HOME")"
apksigner="$(apk_find_build_tool "$ANDROID_HOME" apksigner)"

apk_manifest_value() {
    local field="$1"
    local apk_path="$2"
    "$apkanalyzer" manifest "$field" "$apk_path" 2>/dev/null | tr -d '\r'
}

validate_apk_identity() {
    local apk_path="$1"
    local label="$2"
    local application_id
    local actual_version_name
    local actual_version_code
    local actual_certificate
    application_id="$(apk_manifest_value application-id "$apk_path")" || {
        echo "Unable to read package name from $label: $apk_path" >&2
        return 1
    }
    actual_version_name="$(apk_manifest_value version-name "$apk_path")" || {
        echo "Unable to read versionName from $label: $apk_path" >&2
        return 1
    }
    actual_version_code="$(apk_version_code_from_apk "$ANDROID_HOME" "$apk_path")" || return 1
    actual_certificate="$(apk_certificate_sha256 "$apksigner" "$apk_path")"
    if [[ "$application_id" != "$EXPECTED_APPLICATION_ID" ]]; then
        echo "Unexpected package name in $label: $application_id" >&2
        return 1
    fi
    if [[ -z "$actual_version_name" || ! "$actual_version_name" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]]; then
        echo "Invalid versionName in $label: $actual_version_name" >&2
        return 1
    fi
    if [[ "$actual_certificate" != "$certificate_sha256" ]]; then
        echo "Unexpected signing certificate in $label: ${actual_certificate:-missing}" >&2
        return 1
    fi
    printf '%s\n' "$actual_version_code"
}

validate_apk_metadata() {
    local apk_path="$1"
    local label="$2"
    local actual_version_code
    actual_version_code="$(validate_apk_identity "$apk_path" "$label")" || return 1
    local actual_version_name
    actual_version_name="$(apk_manifest_value version-name "$apk_path")"
    if [[ "$actual_version_name" != "$version_name" ]]; then
        echo "versionName mismatch in $label: expected $version_name, got $actual_version_name" >&2
        return 1
    fi
    if [[ "$actual_version_code" != "$version_code" ]]; then
        echo "versionCode mismatch in $label: expected $version_code, got $actual_version_code" >&2
        return 1
    fi
}

validate_apk_metadata "$APK_PATH" "build artifact"

output_dir="${CODEX_LOCAL_OUTPUT_DIR:-$ROOT_DIR/dist}"
publish_dir="${CODEX_LOCAL_PUBLISH_DIR:-$DEFAULT_PUBLISH_DIR}"
verify_urls="${CODEX_LOCAL_VERIFY_URLS:-${CODEX_LOCAL_VERIFY_URL:-$DEFAULT_VERIFY_URLS}}"
if [[ ! -d "$publish_dir" || ! -w "$publish_dir" ]]; then
    echo "CODEX_LOCAL_PUBLISH_DIR is not a writable directory: $publish_dir" >&2
    exit 1
fi

if ! command -v flock >/dev/null 2>&1; then
    echo "flock is required for consistent APK publication" >&2
    exit 1
fi
exec {publish_lock_fd}>"$publish_dir/$PUBLISH_LOCK_FILE"
if ! flock -n "$publish_lock_fd"; then
    echo "Another APK publication is already running for $publish_dir" >&2
    exit 1
fi

artifact_path="$output_dir/Agent-$version_name.apk"
mkdir -p "$output_dir"
install -m 0644 "$APK_PATH" "$artifact_path"
artifact_sha256="$(sha256sum "$artifact_path" | awk '{print $1}')"
artifact_version_code="$(apk_version_code_from_apk "$ANDROID_HOME" "$artifact_path")"
if [[ "$artifact_version_code" != "$version_code" ]]; then
    echo "Published artifact versionCode does not match pubspec: expected $version_code, got $artifact_version_code" >&2
    exit 1
fi
validate_apk_metadata "$artifact_path" "release artifact"

check_existing_version_code() {
    local target="$1"
    if [[ -e "$target" && ! -f "$target" ]]; then
        echo "Refusing to replace a non-file APK target: $target" >&2
        return 1
    fi
    [[ -f "$target" ]] || return 0
    local existing_version_code
    local existing_sha256
    existing_version_code="$(validate_apk_identity "$target" "existing APK")" || {
        echo "Refusing to replace an invalid existing APK: $target" >&2
        return 1
    }
    existing_sha256="$(sha256sum "$target" | awk '{print $1}')"
    if (( 10#$artifact_version_code < 10#$existing_version_code )); then
        echo "Refusing to publish versionCode $artifact_version_code over $existing_version_code: $target" >&2
        return 1
    fi
    if (( 10#$artifact_version_code == 10#$existing_version_code )) &&
        [[ "$existing_sha256" != "$artifact_sha256" ]]; then
        echo "Refusing to publish versionCode $artifact_version_code over $existing_version_code: $target" >&2
        return 1
    fi
}

check_existing_version_code "$publish_dir/codex.apk"
check_existing_version_code "$publish_dir/agent.apk"
{
    printf 'applicationId=%s\n' "$EXPECTED_APPLICATION_ID"
    printf 'versionName=%s\n' "$version_name"
    printf 'versionCode=%s\n' "$version_code"
    printf 'gitCommit=%s\n' "$(git rev-parse HEAD)"
    printf 'apkSha256=%s\n' "$artifact_sha256"
    printf 'certificateSha256=%s\n' "$certificate_sha256"
} > "$output_dir/local-release-metadata.txt"

temporary_apk="$(mktemp "$publish_dir/.codex.apk.XXXXXX")"
temporary_compat_apk="$(mktemp "$publish_dir/.agent.apk.XXXXXX")"
backup_codex=""
backup_agent=""
had_codex=0
had_agent=0
publish_committed=0
verify_file="$(mktemp)"
cleanup_publish() {
    local status=$?
    set +e
    if (( publish_committed == 0 )); then
        if (( had_codex == 1 )); then
            mv -f "$backup_codex" "$publish_dir/codex.apk"
        else
            rm -f "$publish_dir/codex.apk"
        fi
        if (( had_agent == 1 )); then
            mv -f "$backup_agent" "$publish_dir/agent.apk"
        else
            rm -f "$publish_dir/agent.apk"
        fi
    fi
    rm -f "$temporary_apk" "$temporary_compat_apk" "$backup_codex" "$backup_agent" "$verify_file"
    trap - EXIT
    exit "$status"
}
trap cleanup_publish EXIT

backup_target() {
    local target="$1"
    [[ -e "$target" ]] || return 0
    local backup
    backup="$(mktemp "$publish_dir/.agent-apk-backup.XXXXXX")"
    rm -f "$backup"
    if ! ln -- "$target" "$backup"; then
        rm -f "$backup"
        echo "Unable to snapshot existing APK: $target" >&2
        return 1
    fi
    printf '%s\n' "$backup"
}

backup_codex="$(backup_target "$publish_dir/codex.apk")"
[[ -n "$backup_codex" ]] && had_codex=1
backup_agent="$(backup_target "$publish_dir/agent.apk")"
[[ -n "$backup_agent" ]] && had_agent=1

publish_name() {
    local name="$1"
    local target="$publish_dir/$name"
    local temporary="$temporary_apk"
    [[ "$name" == agent.apk ]] && temporary="$temporary_compat_apk"
    if [[ -e "$target" && ! -f "$target" ]]; then
        echo "Refusing to replace a non-file APK target: $target" >&2
        return 1
    fi
    local published_sha256=""
    if [[ -f "$target" ]]; then
        published_sha256="$(sha256sum "$target" | awk '{print $1}')"
    fi
    if [[ "$published_sha256" == "$artifact_sha256" ]]; then
        echo "Reusing unchanged $target"
        return
    fi
    install -m 0644 "$artifact_path" "$temporary"
    mv -f "$temporary" "$target"
    echo "Published $target"
}

# codex.apk is the canonical download name. Keep agent.apk for users of the
# previous alias.
publish_name codex.apk
publish_name agent.apk

for published_name in codex.apk agent.apk; do
    published_path="$publish_dir/$published_name"
    [[ -f "$published_path" ]] || {
        echo "APK alias was not published: $published_path" >&2
        exit 1
    }
    published_sha256="$(sha256sum "$published_path" | awk '{print $1}')"
    [[ "$published_sha256" == "$artifact_sha256" ]] || {
        echo "APK alias is inconsistent: $published_path" >&2
        exit 1
    }
    validate_apk_metadata "$published_path" "$published_name"
done
if ! cmp -s "$publish_dir/codex.apk" "$publish_dir/agent.apk"; then
    echo "APK aliases differ after publication" >&2
    exit 1
fi
publish_committed=1

IFS=',' read -r -a urls <<< "$verify_urls"
for verify_url in "${urls[@]}"; do
    [[ -n "$verify_url" ]] || continue
    curl --noproxy '*' --fail --location --silent --show-error --max-time 180 \
        --output "$verify_file" "$verify_url"
    verified_sha256="$(sha256sum "$verify_file" | awk '{print $1}')"
    if [[ "$verified_sha256" != "$artifact_sha256" ]]; then
        echo "Published APK verification failed for $verify_url" >&2
        exit 1
    fi
    validate_apk_metadata "$verify_file" "downloaded APK from $verify_url"
    echo "Published and verified $verify_url"
done

echo "Release artifact: $artifact_path"
echo "SHA-256: $artifact_sha256"
