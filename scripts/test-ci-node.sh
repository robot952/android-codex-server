#!/usr/bin/env bash
set -euo pipefail

# Offline prerequisite regression: no host Node, network, SDK or APK is used.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
unset CODEX_CI_HOSTED_DEPENDENCIES
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
prepare="$ROOT_DIR/scripts/prepare-ci-node.sh"
bash_bin="$(command -v bash)"
export FIXTURE_REAL_SHA="$(command -v sha256sum)" FIXTURE_REAL_CP="$(command -v cp)"
export FIXTURE_ARCHIVE="$fixture/node.tar.gz" FIXTURE_CALLS="$fixture/calls"
export FIXTURE_ARCH=x86_64 FIXTURE_MODE=success
mkdir -p "$fixture/tools" "$fixture/source/node-v22.17.0-linux-x64/bin" "$fixture/existing"
for tool in awk bash dirname flock gzip head mkdir mktemp mv rm tar timeout; do
    ln -s "$(command -v "$tool")" "$fixture/tools/$tool"
done
cat > "$fixture/source/node-v22.17.0-linux-x64/bin/node" <<'SH'
#!/bin/sh
printf 'v22.17.0\n'
SH
chmod +x "$fixture/source/node-v22.17.0-linux-x64/bin/node"
tar -czf "$FIXTURE_ARCHIVE" -C "$fixture/source" node-v22.17.0-linux-x64
export FIXTURE_ARCHIVE_SHA="$(sha256sum "$FIXTURE_ARCHIVE" | awk '{print $1}')"
cat > "$fixture/tools/uname" <<'SH'
#!/bin/sh
case "$1" in -s) printf 'Linux\n';; -m) printf '%s\n' "$FIXTURE_ARCH";; *) exit 2;; esac
SH
cat > "$fixture/tools/sha256sum" <<'SH'
#!/bin/bash
set -euo pipefail
actual="$("$FIXTURE_REAL_SHA" "$1")"
# Translate only the exact fixture bytes to the reviewed official digest.
# Corrupt/partial archives and executable hashes use real SHA-256 unchanged.
if [[ "$1" == *.tar.gz* && "${actual%% *}" == "$FIXTURE_ARCHIVE_SHA" ]]; then
    case "$1" in
        *linux-x64-*) digest=0fa01328a0f3d10800623f7107fbcd654a60ec178fab1ef5b9779e94e0419e1a ;;
        *linux-arm64-*) digest=3e99df8b01b27dc8b334a2a30d1cd500442b3b0877d217b308fd61a9ccfc33d4 ;;
        *) exit 2 ;;
    esac
    printf '%s  %s\n' "$digest" "$1"
else
    printf '%s\n' "$actual"
fi
SH
cat > "$fixture/tools/curl" <<'SH'
#!/bin/bash
set -euo pipefail
args=" $* "
[[ "$args" == *' --proto =https '* && "$args" == *' --proto-redir =https '* &&
   "$args" == *' --http1.1 '* && "$args" == *' --connect-timeout 20 '* &&
   "$args" == *' --max-time 180 '* && "$args" == *' --speed-time 60 '* &&
   "$args" == *' --speed-limit 1024 '* && "$args" == *' --continue-at - '* ]]
output=''
while (( $# )); do
    case "$1" in --output) output="$2"; shift 2;; *) url="$1"; shift;; esac
done
[[ -n "$output" && "$url" == https://*/v22.17.0/node-v22.17.0-linux-*.tar.gz ]]
printf '%s|resume=%s\n' "$url" "$([[ -s "$output" ]] && printf yes || printf no)" >> "$FIXTURE_CALLS"
case "$FIXTURE_MODE" in
    fail) printf partial > "$output"; exit 28 ;;
    corrupt) printf corrupt > "$output"; printf 200; exit 0 ;;
    partial)
        if [[ ! -s "$output" ]]; then head -c 10 "$FIXTURE_ARCHIVE" > "$output"; exit 18; fi ;;
esac
"$FIXTURE_REAL_CP" "$FIXTURE_ARCHIVE" "$output"
printf 200
SH
chmod +x "$fixture/tools/"{uname,sha256sum,curl}
run_prepare() {
    PATH="$fixture/tools" "$bash_bin" "$prepare" "$1" 2>"$fixture/prepare.log"
}
assert_failure() {
    local cache="$1" status=0
    run_prepare "$cache" >"$fixture/result" || status=$?
    [[ "$status" != 0 && ! -s "$fixture/result" ]] || { echo 'Expected Node preparation failure' >&2; exit 1; }
}

# A compatible existing Node is reused without downloading or creating a cache.
cat > "$fixture/existing/node" <<'SH'
#!/bin/sh
printf 'v18.20.8\n'
SH
chmod +x "$fixture/existing/node"
: > "$FIXTURE_CALLS"
result="$(PATH="$fixture/existing:$fixture/tools" "$bash_bin" "$prepare" "$fixture/unused" 2>"$fixture/prepare.log")"
[[ "$result" == "$fixture/existing" && ! -e "$fixture/unused" && ! -s "$FIXTURE_CALLS" ]]

# Cold install and warm/offline reuse preserve the cache root and foreign files.
cache="$fixture/cache"
mkdir -p "$cache"
printf keep > "$cache/sentinel"
inode="$(stat -c %i "$cache")"
result="$(run_prepare "$cache")"
[[ -x "$result/node" && "$("$result/node" --version)" == v22.17.0 ]]
[[ "$(wc -l < "$FIXTURE_CALLS")" == 1 && "$(cat "$cache/sentinel")" == keep && "$(stat -c %i "$cache")" == "$inode" ]]
: > "$FIXTURE_CALLS"
export FIXTURE_MODE=fail
[[ "$(run_prepare "$cache")" == "$result" && ! -s "$FIXTURE_CALLS" ]]
# Same-version tampering must be repaired from the verified cached archive.
printf '\n# modified executable\n' >> "$result/node"
[[ "$(run_prepare "$cache")" == "$result" && ! -s "$FIXTURE_CALLS" ]]
! grep -q modified "$result/node"

# An old executable does not satisfy the prerequisite; install the pinned Node.
sed -i 's/v18.20.8/v16.20.2/' "$fixture/existing/node"
export FIXTURE_MODE=success
result="$(PATH="$fixture/existing:$fixture/tools" "$bash_bin" "$prepare" "$fixture/old-node" 2>"$fixture/prepare.log")"
[[ "$result" == "$fixture/old-node/"*/bin && "$("$result/node" --version)" == v22.17.0 ]]

# Network failures stop after three attempts and retain a resumable partial.
: > "$FIXTURE_CALLS"
export FIXTURE_MODE=fail
assert_failure "$fixture/failed"
[[ "$(wc -l < "$FIXTURE_CALLS")" == 3 ]]
compgen -G "$fixture/failed/*.part" >/dev/null
grep -q 'after 3 bounded attempts' "$fixture/prepare.log"
export FIXTURE_MODE=success
result="$(run_prepare "$fixture/failed")"
[[ -x "$result/node" ]]
tail -n 1 "$FIXTURE_CALLS" | grep -q 'resume=yes'

# Corrupt bytes cannot be activated even when curl returns HTTP 200.
: > "$FIXTURE_CALLS"
export FIXTURE_MODE=corrupt
assert_failure "$fixture/corrupt"
[[ "$(wc -l < "$FIXTURE_CALLS")" == 3 ]]
! compgen -G "$fixture/corrupt/*.part" >/dev/null
! compgen -G "$fixture/corrupt/*/bin/node" >/dev/null
grep -q 'SHA-256 mismatch' "$fixture/prepare.log"

: > "$FIXTURE_CALLS"
export FIXTURE_MODE=partial
result="$(run_prepare "$fixture/partial")"
[[ -x "$result/node" && "$(wc -l < "$FIXTURE_CALLS")" == 2 ]]
tail -n 1 "$FIXTURE_CALLS" | grep -q '^https://nodejs.org/dist/.*resume=yes'

# Hosted x64 packages replace only the cold-download path. Existing Node and
# verified caches still win, and a failed hosted fetch must not fall through.
mkdir -p "$fixture/hosted/scripts" "$fixture/hosted/protocol"
cp "$prepare" "$fixture/hosted/scripts/prepare-ci-node.sh"
cp "$ROOT_DIR/protocol/node-version.txt" "$fixture/hosted/protocol/"
cat > "$fixture/hosted/scripts/fetch-ci-package.sh" <<'SH'
#!/bin/bash
set -euo pipefail
[[ "$1" == node-22.17.0-linux-x64 && "$2" == *linux-x64-*.tar.gz ]]
echo hosted >> "$FIXTURE_CALLS"
[[ "${FIXTURE_HOSTED_FAIL:-0}" == 0 ]] || exit 74
"$FIXTURE_REAL_CP" "$FIXTURE_ARCHIVE" "$2"
SH
: > "$FIXTURE_CALLS"
result="$(CODEX_CI_HOSTED_DEPENDENCIES=1 PATH="$fixture/tools" "$bash_bin" \
    "$fixture/hosted/scripts/prepare-ci-node.sh" "$fixture/hosted-cache" 2>"$fixture/prepare.log")"
[[ -x "$result/node" && "$(cat "$FIXTURE_CALLS")" == hosted ]]
: > "$FIXTURE_CALLS"
status=0
CODEX_CI_HOSTED_DEPENDENCIES=1 FIXTURE_HOSTED_FAIL=1 PATH="$fixture/tools" "$bash_bin" \
    "$fixture/hosted/scripts/prepare-ci-node.sh" "$fixture/hosted-failure" >"$fixture/result" 2>"$fixture/prepare.log" || status=$?
[[ "$status" == 74 && ! -s "$fixture/result" && "$(cat "$FIXTURE_CALLS")" == hosted ]]

# A correctly hashed archive must still contain the expected executable version.
sed -i 's/v22.17.0/v16.20.2/' "$fixture/source/node-v22.17.0-linux-x64/bin/node"
tar -czf "$FIXTURE_ARCHIVE" -C "$fixture/source" node-v22.17.0-linux-x64
export FIXTURE_ARCHIVE_SHA="$(sha256sum "$FIXTURE_ARCHIVE" | awk '{print $1}')" FIXTURE_MODE=success
assert_failure "$fixture/wrong-version"
! compgen -G "$fixture/wrong-version/*/bin/node" >/dev/null
grep -q 'incorrect executable version' "$fixture/prepare.log"

# ARM64 uses its own official digest and archive name; unknown hosts fail closed.
mv "$fixture/source/node-v22.17.0-linux-x64" "$fixture/source/node-v22.17.0-linux-arm64"
sed -i 's/v16.20.2/v22.17.0/' "$fixture/source/node-v22.17.0-linux-arm64/bin/node"
tar -czf "$FIXTURE_ARCHIVE" -C "$fixture/source" node-v22.17.0-linux-arm64
export FIXTURE_ARCHIVE_SHA="$(sha256sum "$FIXTURE_ARCHIVE" | awk '{print $1}')" FIXTURE_ARCH=aarch64
result="$(run_prepare "$fixture/arm64")"
[[ "$result" == *node-v22.17.0-linux-arm64-3e99df8b01b27dc8b334a2a30d1cd500442b3b0877d217b308fd61a9ccfc33d4/bin ]]
: > "$FIXTURE_CALLS"
export FIXTURE_ARCH=unsupported
assert_failure "$fixture/unsupported"
[[ ! -s "$FIXTURE_CALLS" && ! -e "$fixture/unsupported" ]]
echo 'CI Node prerequisite, cache, hash and bounded download regressions passed'
