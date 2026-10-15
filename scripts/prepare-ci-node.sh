#!/usr/bin/env bash
set -euo pipefail

# stdout is the Node bin directory; callers must export it in their own PATH.
# Run under ci_prepare_stage so downloads, locking and extraction share its limit.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cache_root="${1:?Node cache directory required}"
version="$(<"$ROOT_DIR/protocol/node-version.txt")"
[[ "$version" == 22.17.0 ]] || { echo 'Node pin changed; review the official archive hashes first' >&2; exit 2; }
command -v timeout >/dev/null || { echo 'Node preparation requires timeout' >&2; exit 1; }

node_version() {
    [[ -x "$1" ]] && timeout --foreground --signal=TERM --kill-after=5s 10s "$1" --version 2>/dev/null
}
existing_node="$(command -v node || true)"
existing_version="$(node_version "$existing_node" || true)"
if [[ "$existing_version" =~ ^v([0-9]{1,3})\.[0-9]+\.[0-9]+$ ]] && (( 10#${BASH_REMATCH[1]} >= 18 )); then
    echo "Reusing existing Node $existing_version" >&2
    (cd "$(dirname "$existing_node")" && pwd -P)
    exit 0
fi

[[ "$(uname -s)" == Linux ]] || { echo 'Managed CI Node supports Linux only' >&2; exit 1; }
# https://nodejs.org/dist/v22.17.0/SHASUMS256.txt (official Linux tar.gz archives).
case "$(uname -m)" in
    x86_64|amd64) arch=x64; archive_sha256=0fa01328a0f3d10800623f7107fbcd654a60ec178fab1ef5b9779e94e0419e1a ;;
    aarch64|arm64) arch=arm64; archive_sha256=3e99df8b01b27dc8b334a2a30d1cd500442b3b0877d217b308fd61a9ccfc33d4 ;;
    *) echo 'Unsupported CI Node architecture' >&2; exit 1 ;;
esac
for tool in curl tar sha256sum flock; do
    command -v "$tool" >/dev/null || { echo "Node preparation requires $tool" >&2; exit 1; }
done
mkdir -p "$cache_root"
cache_root="$(cd "$cache_root" && pwd -P)"
exec 9>"$cache_root/.prepare.lock"
flock -w 300 9 || { echo 'Timed out waiting for Node cache lock' >&2; exit 1; }
name="node-v$version-linux-$arch"
sdk_root="$cache_root/$name-$archive_sha256"
archive="$cache_root/$name-$archive_sha256.tar.gz"
partial="$archive.part"

valid_sdk() {
    [[ -f "$1/.archive-sha256" && "$(<"$1/.archive-sha256")" == "$archive_sha256" &&
       -f "$1/.node-sha256" && -x "$1/bin/node" ]] &&
        [[ "$(sha256sum "$1/bin/node" | awk '{print $1}')" == "$(<"$1/.node-sha256")" ]] &&
        [[ "$(node_version "$1/bin/node")" == "v$version" ]]
}
valid_archive() {
    [[ -f "$1" ]] && [[ "$(sha256sum "$1" | awk '{print $1}')" == "$archive_sha256" ]]
}
if valid_sdk "$sdk_root"; then
    echo "Reusing cached Node $version ($arch)" >&2
    printf '%s\n' "$sdk_root/bin"
    exit 0
fi

if ! valid_archive "$archive"; then
    if [[ "${CODEX_CI_HOSTED_DEPENDENCIES:-0}" == 1 && "$arch" == x64 ]]; then
        bash "$ROOT_DIR/scripts/fetch-ci-package.sh" "node-$version-linux-$arch" "$archive"
    fi
fi
if ! valid_archive "$archive"; then
    downloaded=0
    # A domestic mirror first, then the official distribution; never unbounded.
    for base_url in https://npmmirror.com/mirrors/node https://nodejs.org/dist https://nodejs.org/dist; do
        if valid_archive "$partial"; then downloaded=1; break; fi
        echo "Downloading pinned Node $version ($arch)" >&2
        transfer_status=0
        http_status="$(curl --proto '=https' --proto-redir '=https' --http1.1 --fail --location --silent --show-error \
            --connect-timeout 20 --max-time 180 --speed-time 60 --speed-limit 1024 \
            --continue-at - --output "$partial" --write-out '%{http_code}' \
            "$base_url/v$version/$name.tar.gz")" || transfer_status=$?
        if valid_archive "$partial"; then downloaded=1; break; fi
        if [[ "$transfer_status" == 0 ]]; then
            echo 'Node archive SHA-256 mismatch; discarding corrupt download' >&2
            rm -f -- "$partial"
        elif [[ "$transfer_status" == 33 || "$http_status" == 416 ]]; then
            echo 'Node server cannot resume this partial file; restarting download' >&2
            rm -f -- "$partial"
        else
            echo "Node download interrupted (curl $transfer_status); keeping partial file" >&2
        fi
    done
    [[ "$downloaded" == 1 ]] || { echo 'Node download failed after 3 bounded attempts' >&2; exit 1; }
    mv -f -- "$partial" "$archive"
fi

# Never remove the cache mount point or activate an incomplete/unverified SDK.
staging="$(mktemp -d "$cache_root/.prepare.XXXXXX")"
trap 'rm -rf -- "$staging"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
tar --extract --gzip --file "$archive" --directory "$staging" --no-same-owner
[[ "$(node_version "$staging/$name/bin/node")" == "v$version" ]] || {
    echo "Incomplete Node archive or incorrect executable version; expected $version" >&2
    exit 1
}
printf '%s\n' "$archive_sha256" > "$staging/$name/.archive-sha256"
sha256sum "$staging/$name/bin/node" | awk '{print $1}' > "$staging/$name/.node-sha256"
if [[ -e "$sdk_root" || -L "$sdk_root" ]]; then mv -- "$sdk_root" "$staging/previous-sdk"; fi
mv -- "$staging/$name" "$sdk_root"
printf '%s\n' "$sdk_root/bin"
