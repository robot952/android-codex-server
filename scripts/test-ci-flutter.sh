#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$ROOT_DIR/.workflow-cache"
test_root="$(mktemp -d "$ROOT_DIR/.workflow-cache/ci-flutter-test.XXXXXX")"
mounted_cache=""
cleanup() {
    if [[ -n "$mounted_cache" ]]; then umount "$mounted_cache"; fi
    rm -rf -- "$test_root"
}
trap cleanup EXIT
prepare="$ROOT_DIR/scripts/prepare-ci-flutter.sh"
repo="$test_root/flutter"
mkdir -p "$repo/bin"
printf '#!/bin/sh\nexit 0\n' > "$repo/bin/flutter"
chmod +x "$repo/bin/flutter"
git -C "$repo" init --quiet
git -C "$repo" add bin/flutter
git -C "$repo" -c user.name=Fixture -c user.email=fixture@example.invalid commit --quiet -m first
git -C "$repo" tag 1.2.3
revision="$(git -C "$repo" rev-parse HEAD)"
tar -cJf "$test_root/sdk.tar.xz" -C "$test_root" flutter
archive_sha256="$(sha256sum "$test_root/sdk.tar.xz" | awk '{print $1}')"
upstream="file://$test_root/sdk.tar.xz"

prepare_sdk() {
    bash "$prepare" "$1" 1.2.3 "$2" "$3" "$archive_sha256"
}

# CI creates/mounts the cache before the first build. Never replace that directory.
cache="$test_root/mounted cache"
mkdir -p "$cache"
if [[ "${1:-}" == --mount-cache ]]; then
    mount --bind "$cache" "$cache"
    mounted_cache="$cache"
fi
printf 'keep\n' > "$cache/cache-marker"
inode="$(stat -c %i "$cache")"
sdk="$(prepare_sdk "$cache" "$revision" "$upstream")"
[[ "$(stat -c %i "$cache")" == "$inode" && -f "$cache/cache-marker" ]]
[[ -x "$sdk/bin/flutter" && "$(git -C "$sdk" rev-parse HEAD)" == "$revision" ]]

# Reuse is offline, including Flutter's downloaded engine/Dart cache.
mkdir -p "$sdk/bin/cache"
printf 'keep\n' > "$sdk/bin/cache/engine-marker"
[[ "$(prepare_sdk "$cache" "$revision" "$test_root/offline")" == "$sdk" ]]
[[ -f "$sdk/bin/cache/engine-marker" ]]

# A mismatch must fail before replacing the previous usable SDK.
printf 'changed\n' > "$repo/new-file"
git -C "$repo" add new-file
git -C "$repo" -c user.name=Fixture -c user.email=fixture@example.invalid commit --quiet -m second
other_revision="$(git -C "$repo" rev-parse HEAD)"
if prepare_sdk "$cache" "$other_revision" "$upstream" >"$test_root/mismatch.log" 2>&1; then
    echo "A wrong Flutter revision was accepted" >&2
    exit 1
fi
[[ -f "$sdk/bin/cache/engine-marker" && -f "$cache/cache-marker" ]]

# A partial install can be retried without removing the mounted cache root.
chmod -x "$sdk/bin/flutter"
[[ "$(prepare_sdk "$cache" "$revision" "$upstream")" == "$sdk" ]]
[[ -x "$sdk/bin/flutter" && "$(stat -c %i "$cache")" == "$inode" ]]
failed_cache="$test_root/failed"
if prepare_sdk "$failed_cache" "$revision" "file://$test_root/offline" >"$test_root/failure.log" 2>&1; then
    echo "A failed Flutter download was accepted" >&2
    exit 1
fi
[[ -d "$failed_cache" ]]
prepare_sdk "$failed_cache" "$revision" "$upstream" >/dev/null

# A complete cache from the original YAML layout remains reusable.
legacy="$test_root/legacy"
mkdir -p "$legacy"
tar -xJf "$test_root/sdk.tar.xz" -C "$legacy" --strip-components=1
[[ "$(prepare_sdk "$legacy" "$revision" "$test_root/offline")" == "$legacy" ]]

# Simultaneous jobs prepare one verified SDK under the same cache lock.
for job in 1 2; do
    prepare_sdk "$test_root/concurrent" "$revision" "$upstream" >"$test_root/job-$job" 2>"$test_root/job-$job.log" &
    if [[ "$job" == 1 ]]; then first_pid=$!; else second_pid=$!; fi
done
wait "$first_pid"
wait "$second_pid"
cmp "$test_root/job-1" "$test_root/job-2"
node "$ROOT_DIR/scripts/test-ci-flutter-download.cjs" "$prepare" "$test_root/sdk.tar.xz" "$revision" "$archive_sha256" "$test_root"
echo "CI Flutter bootstrap tests passed (cache root, offline reuse, revision, retry, legacy, concurrency)"
