#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# Gitee's command list does not stop on an intermediate nonzero exit. Keep all
# stages in one strict shell so a failed regression can never reach publication.
# Each stage retains its own bounded process-group supervisor.
bash scripts/run-ci-stage.sh bootstrap-regression 300 bash scripts/test-ci-environment.sh
bash scripts/run-ci-stage.sh android-sdk-regression 300 bash scripts/test-ci-android.sh
bash scripts/run-ci-stage.sh gradle-regression 600 bash scripts/test-ci-gradle.sh
bash scripts/run-ci-stage.sh gitee-release 5400 bash scripts/publish-tag-release.sh
