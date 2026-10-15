#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ $# == 2 ]] || { echo 'Usage: prepare-ci-maven.sh CACHE DESTINATION_ROOT' >&2; exit 2; }
archive="$1/android-test-maven-v1.zip"
bash "$root/scripts/fetch-ci-package.sh" android-test-maven-v1 "$archive"
mkdir -p -- "$2"
destination="$(mktemp -d "$2/android-test.XXXXXX")"
destination="$(cd "$destination" && pwd -P)"
cleanup() { if [[ -n "$destination" ]]; then rm -rf -- "$destination"; fi; }
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
# Always extract the verified archive into a fresh directory. A stale Gradle
# cache or edited manifest cannot silently change the hosted Maven repository.
unzip -q "$archive" -d "$destination"
(cd "$destination" && sha256sum --strict --check --status SHA256SUMS)
[[ -s "$destination/modules.tsv" && -d "$destination/repository" ]]
echo 'Hosted Android test Maven repository verified' >&2
printf '%s\n' "$destination"
destination=
