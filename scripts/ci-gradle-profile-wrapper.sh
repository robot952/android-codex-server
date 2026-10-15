#!/usr/bin/env bash
set -euo pipefail
# Temporary CI-only launcher. The original launcher remains beside this file,
# so its Wrapper JAR and properties resolve exactly as they do without profiling.
exec bash "${CODEX_CI_ORIGINAL_GRADLEW:?profile launcher was not prepared}" --profile "$@"
