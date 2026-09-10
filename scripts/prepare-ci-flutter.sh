#!/usr/bin/env bash
set -euo pipefail

# stdout is the verified SDK directory. The cache root may be a CI mount point.
cache_root="${1:?cache directory required}"
version="${2:?Flutter version required}"
revision="${3:?Flutter revision required}"
repository="${4:-https://github.com/flutter/flutter.git}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$revision" =~ ^[a-f0-9]{40}$ ]] || {
    echo "Invalid pinned Flutter version or revision" >&2
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

# Clone below the mount, verify before activation, and clean only our staging dir.
staging="$(mktemp -d "$cache_root/.prepare.XXXXXX")"
trap 'rm -rf -- "$staging"' EXIT
git clone --branch "$version" --depth 1 "$repository" "$staging/sdk" >&2
if ! valid_sdk "$staging/sdk"; then
    echo "Flutter revision mismatch or incomplete SDK: expected $revision" >&2
    exit 1
fi
if [[ -e "$sdk_root" || -L "$sdk_root" ]]; then
    mv -- "$sdk_root" "$staging/previous-sdk"
fi
mv -- "$staging/sdk" "$sdk_root"
printf '%s\n' "$sdk_root"
