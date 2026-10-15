#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# Only the registered main workflow opts into creating its version tag.
# Explicit tag invocations retain the existing immutable-tag verification.
if (( $# > 0 )); then
    [[ $# == 1 && "$1" == main ]] || { echo 'Usage: run-gitee-release.sh [main]' >&2; exit 2; }
    export CODEX_RELEASE_BRANCH=main
fi

# Gitee's command list does not stop on an intermediate nonzero exit. Keep all
# stages in one strict shell so a failed regression can never reach publication.
# Each stage retains its own bounded process-group supervisor.
bash scripts/run-ci-stage.sh bootstrap-regression 300 bash scripts/test-ci-environment.sh
bash scripts/run-ci-stage.sh android-sdk-regression 300 bash scripts/test-ci-android.sh
bash scripts/run-ci-stage.sh gradle-regression 600 bash scripts/test-ci-gradle.sh
# Only the signed Release APK is published. Do not spend a cold CI job building
# a Debug APK first; release mode still runs analyze, the full tests and signing
# checks. Keep an explicit `all` override for diagnosing both build variants.
CODEX_RELEASE_BUILD_MODE="${CODEX_RELEASE_BUILD_MODE:-release}" \
    bash scripts/run-ci-stage.sh gitee-release 5400 bash scripts/publish-tag-release.sh
