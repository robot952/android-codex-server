#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ $# == 2 ]] || { echo 'Usage: fetch-ci-package.sh PACKAGE OUTPUT' >&2; exit 2; }
key="$1" output="$2"
[[ "$key" =~ ^[a-zA-Z0-9._-]+$ ]] || exit 2
record="$(awk -F '\t' -v key="$key" '$1 == key {print}' "$root/scripts/ci-dependencies.tsv")"
[[ -n "$record" && "$record" != *$'\n'* ]] || { echo "Unknown hosted CI package: $key" >&2; exit 2; }
IFS=$'\t' read -r package tag commit entry sha size <<< "$record"
[[ "$size" =~ ^[1-9][0-9]*$ ]] && (( size <= 200000000 )) || exit 2
echo "Preparing hosted CI package: $package ($size bytes)" >&2
bash "$root/scripts/fetch-ci-dependency.sh" \
    https://gitee.com/YanGanYuan/android-codex-server.git "refs/tags/$tag" \
    "$commit" "$entry" "$sha" "$output"
[[ "$(wc -c < "$output")" == "$size" ]] || { echo 'CI package size mismatch' >&2; exit 1; }
