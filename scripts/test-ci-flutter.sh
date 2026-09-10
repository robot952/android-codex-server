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
repo="$test_root/upstream"
mkdir -p "$repo/bin"
printf '#!/bin/sh\nexit 0\n' > "$repo/bin/flutter"
chmod +x "$repo/bin/flutter"
git -C "$repo" init --quiet
git -C "$repo" add bin/flutter
git -C "$repo" -c user.name=Fixture -c user.email=fixture@example.invalid commit --quiet -m first
git -C "$repo" tag 1.2.3
revision="$(git -C "$repo" rev-parse HEAD)"
upstream="file://$repo"

# CI creates/mounts the cache before the first build. Never replace that directory.
cache="$test_root/mounted cache"
mkdir -p "$cache"
if [[ "${1:-}" == --mount-cache ]]; then
    mount --bind "$cache" "$cache"
    mounted_cache="$cache"
fi
printf 'keep\n' > "$cache/cache-marker"
inode="$(stat -c %i "$cache")"
sdk="$(bash "$prepare" "$cache" 1.2.3 "$revision" "$upstream")"
[[ "$(stat -c %i "$cache")" == "$inode" && -f "$cache/cache-marker" ]]
[[ -x "$sdk/bin/flutter" && "$(git -C "$sdk" rev-parse HEAD)" == "$revision" ]]

# Reuse is offline, including Flutter's downloaded engine/Dart cache.
mkdir -p "$sdk/bin/cache"
printf 'keep\n' > "$sdk/bin/cache/engine-marker"
[[ "$(bash "$prepare" "$cache" 1.2.3 "$revision" "$test_root/offline")" == "$sdk" ]]
[[ -f "$sdk/bin/cache/engine-marker" ]]

# A mismatch must fail before replacing the previous usable SDK.
printf 'changed\n' > "$repo/new-file"
git -C "$repo" add new-file
git -C "$repo" -c user.name=Fixture -c user.email=fixture@example.invalid commit --quiet -m second
other_revision="$(git -C "$repo" rev-parse HEAD)"
if bash "$prepare" "$cache" 1.2.3 "$other_revision" "$upstream" >"$test_root/mismatch.log" 2>&1; then
    echo "A wrong Flutter revision was accepted" >&2
    exit 1
fi
[[ -f "$sdk/bin/cache/engine-marker" && -f "$cache/cache-marker" ]]

# A partial install can be retried without removing the mounted cache root.
chmod -x "$sdk/bin/flutter"
[[ "$(bash "$prepare" "$cache" 1.2.3 "$revision" "$upstream")" == "$sdk" ]]
[[ -x "$sdk/bin/flutter" && "$(stat -c %i "$cache")" == "$inode" ]]
failed_cache="$test_root/failed"
if bash "$prepare" "$failed_cache" 1.2.3 "$revision" "$test_root/offline" >"$test_root/failure.log" 2>&1; then
    echo "A failed Flutter download was accepted" >&2
    exit 1
fi
[[ -d "$failed_cache" ]]
bash "$prepare" "$failed_cache" 1.2.3 "$revision" "$upstream" >/dev/null

# A complete cache from the original YAML layout remains reusable.
legacy="$test_root/legacy"
git clone --quiet "$upstream" "$legacy"
git -C "$legacy" checkout --quiet 1.2.3
[[ "$(bash "$prepare" "$legacy" 1.2.3 "$revision" "$test_root/offline")" == "$legacy" ]]

# Simultaneous jobs prepare one verified SDK under the same cache lock.
for job in 1 2; do
    bash "$prepare" "$test_root/concurrent" 1.2.3 "$revision" "$upstream" >"$test_root/job-$job" 2>"$test_root/job-$job.log" &
    if [[ "$job" == 1 ]]; then first_pid=$!; else second_pid=$!; fi
done
wait "$first_pid"
wait "$second_pid"
cmp "$test_root/job-1" "$test_root/job-2"
echo "CI Flutter bootstrap tests passed (cache root, offline reuse, revision, retry, legacy, concurrency)"
