#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# Registered workflows publish existing immutable version tags only. Reject the
# old main argument before any stages, including a stale platform registration.
if (( $# > 0 )) || [[ -n "${CODEX_RELEASE_BRANCH:-}" ]]; then
    echo 'Usage: run-gitee-release.sh (existing version tag required; branch publication is disabled)' >&2
    exit 2
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
