#!/usr/bin/env bash
set -euo pipefail

# Exercise the real orchestration with isolated stage/command stubs. There are
# no SDK downloads, application builds, real releases or recursive regressions.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Keep exactly one registered source configuration. A second YAML can register
# another webhook and consume two builds for the same release tag. Platform-side
# legacy registrations must also be disabled before pushing a new tag.
shopt -s nullglob
pipeline_configs=("$ROOT_DIR"/.workflow/*.yml "$ROOT_DIR"/.workflow/*.yaml)
[[ "${#pipeline_configs[@]}" == 1 &&
   "${pipeline_configs[0]}" == "$ROOT_DIR/.workflow/流水线-flutter-refactor-编译.yml" ]] || {
    echo 'Expected exactly one Gitee Go pipeline: Flutter Refactor 发布' >&2
    exit 1
}
shopt -u nullglob
# Cache upload runs before artifact publication on Gitee. Keep it explicitly
# disabled until a size-bounded cross-job cache policy has been verified.
# Do not remove the actual release artifact while fixing oversized caches.
pipeline_config="${pipeline_configs[0]}"
[[ "$(grep -Ec '^[[:space:]]*caches:' "$pipeline_config")" == 1 ]] &&
    grep -Eq '^    caches: \[\][[:space:]]*$' "$pipeline_config" || {
    echo 'Gitee cross-job cache upload must stay disabled to avoid HTTP 413' >&2
    exit 1
}
grep -Fxq '    artifacts:' "$pipeline_config" &&
    grep -Fxq '    - name: FLUTTER_REFACTOR_BUILD_ARTIFACT' "$pipeline_config" &&
    grep -Fxq '      - dist' "$pipeline_config" &&
    grep -Fxq '      type: .tar.gz' "$pipeline_config" || {
    echo 'Gitee must retain the dist release artifact archive' >&2
    exit 1
}
mkdir -p "$ROOT_DIR/.workflow-cache"
test_root="$(mktemp -d "$ROOT_DIR/.workflow-cache/gitee-pipeline-test.XXXXXX")"
trap 'rm -rf -- "$test_root"' EXIT
mkdir -p "$test_root/repo/scripts"
cp "$ROOT_DIR/scripts/run-gitee-release.sh" "$test_root/repo/scripts/"

cat > "$test_root/repo/scripts/run-ci-stage.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s %s\n' "$1" "$2" >> "$FIXTURE_STAGES"
shift 2
exec "$@"
SH
for stage_script in test-ci-environment.sh test-ci-android.sh test-ci-gradle.sh publish-tag-release.sh; do
    cat > "$test_root/repo/scripts/$stage_script" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
script="${0##*/}"
printf '%s\n' "$script" >> "$FIXTURE_COMMANDS"
if [[ "$script" == "$FIXTURE_FAIL_SCRIPT" ]]; then
    exit "$FIXTURE_FAIL_STATUS"
fi
SH
done

export FIXTURE_STAGES="$test_root/stages" FIXTURE_COMMANDS="$test_root/commands"
assert_pipeline() {
    local fail_script="$1" expected_status="$2" expected_count="$3" status=0
    : > "$FIXTURE_STAGES"
    : > "$FIXTURE_COMMANDS"
    # Call from outside the fixture repo: the entry must anchor its own cwd.
    (cd "$test_root" && FIXTURE_FAIL_SCRIPT="$fail_script" \
        FIXTURE_FAIL_STATUS="$expected_status" bash repo/scripts/run-gitee-release.sh) || status=$?
    [[ "$status" == "$expected_status" ]]
    [[ "$(wc -l < "$FIXTURE_STAGES" | tr -d '[:space:]')" == "$expected_count" ]]
    [[ "$(wc -l < "$FIXTURE_COMMANDS" | tr -d '[:space:]')" == "$expected_count" ]]
    [[ "$(sed -n '1p' "$FIXTURE_STAGES")" == 'bootstrap-regression 300' ]]
    [[ "$(sed -n '1p' "$FIXTURE_COMMANDS")" == test-ci-environment.sh ]]
    if (( expected_count >= 2 )); then
        [[ "$(sed -n '2p' "$FIXTURE_STAGES")" == 'android-sdk-regression 300' ]]
        [[ "$(sed -n '2p' "$FIXTURE_COMMANDS")" == test-ci-android.sh ]]
    fi
    if (( expected_count >= 3 )); then
        [[ "$(sed -n '3p' "$FIXTURE_STAGES")" == 'gradle-regression 600' ]]
        [[ "$(sed -n '3p' "$FIXTURE_COMMANDS")" == test-ci-gradle.sh ]]
    fi
    if (( expected_count == 4 )); then
        [[ "$(sed -n '4p' "$FIXTURE_STAGES")" == 'gitee-release 5400' ]]
        [[ "$(sed -n '4p' "$FIXTURE_COMMANDS")" == publish-tag-release.sh ]]
    fi
}

assert_pipeline none 0 4
assert_pipeline test-ci-environment.sh 42 1
assert_pipeline test-ci-android.sh 42 2
assert_pipeline test-ci-android.sh 124 2
assert_pipeline test-ci-android.sh 137 2
assert_pipeline test-ci-gradle.sh 44 3
assert_pipeline test-ci-gradle.sh 124 3
assert_pipeline test-ci-gradle.sh 137 3
assert_pipeline publish-tag-release.sh 45 4
echo 'Gitee pipeline artifact-only upload, fail-fast and stage deadline regressions passed'
