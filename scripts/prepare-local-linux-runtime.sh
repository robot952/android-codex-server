#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly OUTPUT_DIR="$REPO_ROOT/flutter_app/android/app/src/main/jniLibs/arm64-v8a"
readonly TERMUX_BASE="https://packages.termux.dev/apt/termux-main"
readonly PROOT_PATH="pool/main/p/proot/proot_5.1.107.89_aarch64.deb"
readonly SHMEM_PATH="pool/main/liba/libandroid-shmem/libandroid-shmem_0.7_aarch64.deb"
readonly TALLOC_PATH="pool/main/libt/libtalloc/libtalloc_2.4.3_aarch64.deb"
readonly PROOT_SHA256="ec9fe38c50cfd49dd31fe360ffbcc3124a945dc1ea16293a8a769303dd724f46"
readonly SHMEM_SHA256="0da3a24d558b93c92bcf8d611e0826a99ff96e396b148e6cdf33b47c47c57ff6"
readonly TALLOC_SHA256="ac81ad623d74c209718b9f3acb2dd702cc8a88c431e820d212229910b4db29da"

for tool in curl dpkg-deb patchelf sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || {
        printf 'Missing required tool: %s\n' "$tool" >&2
        exit 1
    }
done

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/agent-local-linux.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

download() {
    local path="$1"
    local sha256="$2"
    local target="$3"
    curl --fail --location --retry 5 --retry-all-errors --silent --show-error \
        --output "$target" "$TERMUX_BASE/$path"
    printf '%s  %s\n' "$sha256" "$target" | sha256sum -c -
}

download "$PROOT_PATH" "$PROOT_SHA256" "$work_dir/proot.deb"
download "$SHMEM_PATH" "$SHMEM_SHA256" "$work_dir/shmem.deb"
download "$TALLOC_PATH" "$TALLOC_SHA256" "$work_dir/talloc.deb"

mkdir -p "$work_dir/root" "$OUTPUT_DIR"
dpkg-deb -x "$work_dir/proot.deb" "$work_dir/root"
dpkg-deb -x "$work_dir/shmem.deb" "$work_dir/root"
dpkg-deb -x "$work_dir/talloc.deb" "$work_dir/root"

readonly TERMUX_ROOT="$work_dir/root/data/data/com.termux/files/usr"
cp "$TERMUX_ROOT/bin/proot" "$OUTPUT_DIR/libproot.so"
cp "$TERMUX_ROOT/libexec/proot/loader" "$OUTPUT_DIR/libproot-loader.so"
cp "$TERMUX_ROOT/lib/libandroid-shmem.so" "$OUTPUT_DIR/libandroid-shmem.so"
cp "$TERMUX_ROOT/lib/libtalloc.so.2.4.3" "$OUTPUT_DIR/libtalloc.so"

# Termux packages use an absolute Termux RUNPATH and a versioned talloc name.
# APK native libraries live together in applicationInfo.nativeLibraryDir.
patchelf --replace-needed libtalloc.so.2 libtalloc.so "$OUTPUT_DIR/libproot.so"
patchelf --set-rpath '$ORIGIN' "$OUTPUT_DIR/libproot.so"

file "$OUTPUT_DIR/libproot.so" | grep -q 'ARM aarch64'
file "$OUTPUT_DIR/libproot-loader.so" | grep -q 'ARM aarch64'
readelf -d "$OUTPUT_DIR/libproot.so" | grep -q '\[libtalloc.so\]'
readelf -d "$OUTPUT_DIR/libproot.so" | grep -q '\[\$ORIGIN\]'

sha256sum "$OUTPUT_DIR"/libproot*.so "$OUTPUT_DIR/libandroid-shmem.so" \
    "$OUTPUT_DIR/libtalloc.so"
