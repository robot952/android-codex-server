#!/usr/bin/env bash
set -euo pipefail

# Run the workflow's actual preflight against local Git stubs. No workflow is
# dispatched, no tag is written, and no SDK or application build is started.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="$ROOT_DIR/.github/workflows/flutter-refactor-ios.yml"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

sed -n '/^on:/,/^permissions:/p' "$workflow" > "$test_root/triggers"
grep -Fxq '  push:' "$test_root/triggers"
grep -Fxq '    tags:' "$test_root/triggers"
grep -Fxq "      - 'v*'" "$test_root/triggers"
grep -Fxq '  workflow_dispatch:' "$test_root/triggers"
[[ "$(grep -Ec '^[[:space:]]*-' "$test_root/triggers")" == 1 ]]
if grep -Eq 'branches:|pull_request|schedule:|workflow_run:' "$test_root/triggers"; then
    echo 'GitHub packaging must only start from a version tag or explicit manual run' >&2
    exit 1
fi
grep -Fq -- '--verify-tag' "$workflow"
if grep -Fq -- '--target "$GITHUB_SHA"' "$workflow"; then
    echo 'GitHub Release publication must not create a missing tag' >&2
    exit 1
fi

# Test the embedded code instead of maintaining a second copy of its checks.
awk '
    /^  release-preflight:/ { in_job = 1; next }
    in_job && /^  [A-Za-z0-9_-]+:/ { exit }
    in_job && /^        run: \|$/ { in_script = 1; next }
    in_script { sub(/^          /, ""); print }
' "$workflow" > "$test_root/preflight.sh"
[[ -s "$test_root/preflight.sh" ]]
bash -n "$test_root/preflight.sh"
mkdir -p "$test_root/bin" "$test_root/flutter_app"
printf 'version: 9.8.7+123\n' > "$test_root/flutter_app/pubspec.yaml"

cat > "$test_root/bin/git" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == 'ls-remote origin refs/tags/v9.8.7 refs/tags/v9.8.7^{}' ]]
printf 'read\n' >> "$FIXTURE_GIT_CALLS"
case "$FIXTURE_TAG_MODE" in
    lightweight) printf '%s\trefs/tags/v9.8.7\n' "$GITHUB_SHA" ;;
    annotated)
        printf '%040d\trefs/tags/v9.8.7\n' 2
        printf '%s\trefs/tags/v9.8.7^{}\n' "$GITHUB_SHA"
        ;;
    missing) ;;
    moved) printf '%040d\trefs/tags/v9.8.7\n' 3 ;;
    unreachable) exit 42 ;;
    *) exit 43 ;;
esac
SH
chmod +x "$test_root/bin/git"

assert_preflight() {
    local ref="$1" mode="$2" expected_status="$3" expected_calls="$4" event="${5:-push}" status=0
    : > "$test_root/git-calls"
    (cd "$test_root" && PATH="$test_root/bin:$PATH" \
        GITHUB_REF="$ref" GITHUB_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
        GITHUB_EVENT_NAME="$event" FIXTURE_TAG_MODE="$mode" \
        FIXTURE_GIT_CALLS="$test_root/git-calls" bash preflight.sh \
        > "$test_root/result.log" 2>&1) || status=$?
    if [[ "$status" != "$expected_status" ||
          "$(wc -l < "$test_root/git-calls" | tr -d '[:space:]')" != "$expected_calls" ]]; then
        echo "Unexpected GitHub preflight result: ref=$ref mode=$mode status=$status" >&2
        tail -n 10 "$test_root/result.log" >&2
        exit 1
    fi
}

assert_preflight refs/tags/v9.8.7 lightweight 0 1
assert_preflight refs/tags/v9.8.7 annotated 0 1
assert_preflight refs/tags/v9.8.7 annotated 0 1 workflow_dispatch
assert_preflight refs/heads/main lightweight 1 0
assert_preflight refs/heads/main lightweight 1 0 workflow_dispatch
assert_preflight refs/heads/feature lightweight 1 0
assert_preflight refs/tags/ci-deps-node lightweight 1 0
assert_preflight refs/tags/v9.8.8 lightweight 1 0
assert_preflight refs/tags/v9.8.7-rc.1 lightweight 1 0
assert_preflight refs/tags/v9.8.7 missing 1 1
assert_preflight refs/tags/v9.8.7 moved 1 1
assert_preflight refs/tags/v9.8.7 unreachable 42 1

echo 'GitHub tag triggers and immutable release preflight regressions passed'
