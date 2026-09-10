#!/usr/bin/env bash
set -euo pipefail

# stdout is the verified SDK directory. The cache root may be a CI mount point.
cache_root="${1:?cache directory required}"
version="${2:?Flutter version required}"
revision="${3:?Flutter revision required}"
archive_url="${4:?Flutter SDK archive URL required}"
archive_sha256="${5:?Flutter SDK archive SHA-256 required}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$revision" =~ ^[a-f0-9]{40}$ &&
   "$archive_sha256" =~ ^[a-f0-9]{64}$ ]] || {
    echo "Invalid pinned Flutter version, revision or archive SHA-256" >&2
    exit 2
}

mkdir -p "$cache_root"
cache_root="$(cd "$cache_root" && pwd -P)"
exec 9>"$cache_root/.prepare.lock"
flock 9

valid_sdk() {
    [[ -d "$1/.git" && -x "$1/bin/flutter" ]] &&
        [[ "$(git -C "$1" rev-parse HEAD 2>/dev/null)" == "$revision" ]]
}

# Reuse a complete cache created by the old pipeline layout.
if valid_sdk "$cache_root"; then
    echo "Reusing Flutter $version from legacy cache" >&2
    printf '%s\n' "$cache_root"
    exit 0
fi

sdk_root="$cache_root/sdk-$revision"
if valid_sdk "$sdk_root"; then
    echo "Reusing Flutter $version ($revision)" >&2
    printf '%s\n' "$sdk_root"
    exit 0
fi

# Keep partial downloads across attempts/jobs so an interrupted transfer resumes.
archive="$cache_root/flutter-$version-$archive_sha256.tar.xz"
partial="$archive.part"
valid_archive() {
    [[ -f "$1" ]] && [[ "$(sha256sum "$1" | awk '{print $1}')" == "$archive_sha256" ]]
}
if ! valid_archive "$archive"; then
    downloaded=0
    for attempt in 1 2 3; do
        if valid_archive "$partial"; then
            downloaded=1
            break
        fi
        echo "Downloading Flutter $version SDK archive (attempt $attempt/3, resumable)" >&2
        transfer_status=0
        http_status="$(curl --http1.1 --fail --location --silent --show-error \
            --connect-timeout 20 --max-time 300 --speed-time 60 --speed-limit 1024 \
            --continue-at - --output "$partial" --write-out '%{http_code}' "$archive_url")" || transfer_status=$?
        if valid_archive "$partial"; then
            downloaded=1
            break
        fi
        if [[ "$transfer_status" == 0 ]]; then
            echo "Flutter archive SHA-256 mismatch; discarding the corrupt download" >&2
            rm -f -- "$partial"
        elif [[ "$transfer_status" == 33 || "$http_status" == 416 ]]; then
            echo "Archive server cannot resume this partial file; restarting download" >&2
            rm -f -- "$partial"
        else
            echo "Flutter download interrupted (curl $transfer_status); keeping partial file" >&2
        fi
    done
    if [[ "$downloaded" != 1 ]]; then
        echo "Flutter SDK download failed after 3 attempts; rerun to resume" >&2
        exit 1
    fi
    mv -f -- "$partial" "$archive"
fi

# Extract below the mount, verify before activation, and clean only staging.
staging="$(mktemp -d "$cache_root/.prepare.XXXXXX")"
trap 'rm -rf -- "$staging"' EXIT
tar --extract --xz --file "$archive" --directory "$staging" --no-same-owner
if ! valid_sdk "$staging/flutter"; then
    echo "Flutter revision mismatch or incomplete SDK: expected $revision" >&2
    exit 1
fi
if [[ -e "$sdk_root" || -L "$sdk_root" ]]; then
    mv -- "$sdk_root" "$staging/previous-sdk"
fi
mv -- "$staging/flutter" "$sdk_root"
printf '%s\n' "$sdk_root"
