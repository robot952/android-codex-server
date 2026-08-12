#!/usr/bin/env bash
set -euo pipefail

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly NATIVE_DIR="$ROOT_DIR/flutter_app/android/app/src/main/jniLibs/arm64-v8a"
readonly APK="${1:-}"

for tool in file readelf sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || {
        printf 'Missing required tool: %s\n' "$tool" >&2
        exit 1
    }
done

check_hash() {
    local name="$1"
    local expected="$2"
    printf '%s  %s\n' "$expected" "$NATIVE_DIR/$name" | sha256sum -c -
}

check_hash libproot.so 990189030543c1d256a2c47eebfa807cafd02a2ea77cc80b819b9dc88b72be2b
check_hash libproot-loader.so 44ef39c1e1a18c09f6e4c4b5d6f8bba82d30596598bd155ec162d05c5122ff04
check_hash libandroid-shmem.so 84475798e07c8174dbbfaec70a827fdb02f19ffa69a589380c13e7507fd0e731
check_hash libtalloc.so 3c9b207c0a6ea2896b7523e03f55d9ab0d9e88baa115d4c32b84058ff4246fbb

for library in "$NATIVE_DIR"/*.so; do
    file "$library" | grep -q 'ARM aarch64'
done
readelf -d "$NATIVE_DIR/libproot.so" | grep -q '\[libtalloc.so\]'
readelf -d "$NATIVE_DIR/libproot.so" | grep -q '\[libandroid-shmem.so\]'
readelf -d "$NATIVE_DIR/libproot.so" | grep -q '\[\$ORIGIN\]'

if [[ -n "$APK" ]]; then
    command -v unzip >/dev/null 2>&1 || {
        echo 'Missing required tool: unzip' >&2
        exit 1
    }
    [[ -f "$APK" ]] || {
        printf 'APK does not exist: %s\n' "$APK" >&2
        exit 1
    }
    apk_runtime_dir="$(mktemp -d "${TMPDIR:-/tmp}/agent-local-linux-apk.XXXXXX")"
    trap 'rm -rf "$apk_runtime_dir"' EXIT
    for name in libproot.so libproot-loader.so libandroid-shmem.so libtalloc.so; do
        unzip -p "$APK" "lib/arm64-v8a/$name" > "$apk_runtime_dir/$name"
        cmp -s "$apk_runtime_dir/$name" "$NATIVE_DIR/$name"
    done
fi

echo 'Local Linux runtime verification passed'
