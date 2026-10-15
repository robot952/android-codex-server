#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$ROOT_DIR/.workflow-cache"
fixture="$(mktemp -d "$ROOT_DIR/.workflow-cache/test-ci-dependency.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT
trap 'status=$?; echo "CI dependency regression failed at line $LINENO (exit $status)" >&2; tail -n 30 "$fixture/last.log" >&2; exit "$status"' ERR
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
export TEST_DEP_REAL_GIT="$(command -v git)"
export TEST_DEP_REAL_TIMEOUT="$(command -v timeout)"
git init --quiet --bare "$fixture/source.git"
printf 'immutable dependency fixture\n' > "$fixture/payload"
sha="$(sha256sum "$fixture/payload" | awk '{print $1}')"
blob="$(git --git-dir="$fixture/source.git" hash-object -w "$fixture/payload")"
tree="$(printf '100644 blob %s\tpackage.zip\n' "$blob" | git --git-dir="$fixture/source.git" mktree)"
commit="$(git --git-dir="$fixture/source.git" -c user.name='CI Fixture' -c user.email=ci@example.invalid commit-tree "$tree" -m fixture)"
git --git-dir="$fixture/source.git" update-ref refs/tags/package-v1 "$commit"
fetch_dependency() {
    # Fixtures exercise the same standalone deadline without killing the outer
    # regression process group when deliberately simulating cancellation.
    env -u CODEX_CI_PROCESS_GROUP bash "$ROOT_DIR/scripts/fetch-ci-dependency.sh" \
        "file://$fixture/source.git" refs/tags/package-v1 "${1:-$commit}" \
        "${3:-package.zip}" "${2:-$sha}" "$fixture/output.zip" >"$fixture/last.log" 2>&1
}
fetch_dependency
cmp "$fixture/payload" "$fixture/output.zip"
grep -q 'CI dependency verified' "$fixture/last.log"
# A valid cache needs no repository, ref lookup or network connection.
mv "$fixture/source.git" "$fixture/offline.git"
fetch_dependency
grep -q 'Reusing SHA-256 verified' "$fixture/last.log"
mv "$fixture/offline.git" "$fixture/source.git"
# Failed checks preserve the old file; neither a moved tag nor wrong hash can
# install another binary. Temporary bare repositories must also be removed.
printf 'previous archive\n' > "$fixture/output.zip"
cp "$fixture/output.zip" "$fixture/previous.zip"
if fetch_dependency "$(printf '0%.0s' {1..40})"; then exit 1; fi
grep -q 'commit mismatch' "$fixture/last.log"
cmp "$fixture/output.zip" "$fixture/previous.zip"
if fetch_dependency "$commit" "$(printf '0%.0s' {1..64})"; then exit 1; fi
grep -q 'SHA-256 mismatch' "$fixture/last.log"
cmp "$fixture/output.zip" "$fixture/previous.zip"
if fetch_dependency "$commit" "$sha" missing.zip; then exit 1; fi
cmp "$fixture/output.zip" "$fixture/previous.zip"
if fetch_dependency "$commit" "$sha" ../package.zip; then exit 1; fi

# Split archives are fetched once and joined by strict, contiguous part names.
printf first > "$fixture/first"
printf second > "$fixture/second"
first_blob="$(git --git-dir="$fixture/source.git" hash-object -w "$fixture/first")"
second_blob="$(git --git-dir="$fixture/source.git" hash-object -w "$fixture/second")"
cat "$fixture/first" "$fixture/second" > "$fixture/joined"
joined_sha="$(sha256sum "$fixture/joined" | awk '{print $1}')"
parts_commit() {
    local parts_tree="$1" tree
    tree="$(printf '040000 tree %s\tparts\n' "$parts_tree" | git --git-dir="$fixture/source.git" mktree)"
    git --git-dir="$fixture/source.git" -c user.name='CI Fixture' -c user.email=ci@example.invalid commit-tree "$tree" -m parts
}
parts_tree="$(printf '100644 blob %s\tpart-000\n100644 blob %s\tpart-001\n' "$first_blob" "$second_blob" | git --git-dir="$fixture/source.git" mktree)"
parts_revision="$(parts_commit "$parts_tree")"
git --git-dir="$fixture/source.git" update-ref refs/tags/package-v1 "$parts_revision"
fetch_dependency "$parts_revision" "$joined_sha" parts
cmp "$fixture/output.zip" "$fixture/joined"
cp "$fixture/output.zip" "$fixture/previous.zip"
# A missing first part or reversed bytes cannot overwrite the verified output.
for mode in missing reversed; do
    if [[ "$mode" == missing ]]; then
        parts_tree="$(printf '100644 blob %s\tpart-001\n' "$second_blob" | git --git-dir="$fixture/source.git" mktree)"
    else
        parts_tree="$(printf '100644 blob %s\tpart-000\n100644 blob %s\tpart-001\n' "$second_blob" "$first_blob" | git --git-dir="$fixture/source.git" mktree)"
    fi
    parts_revision="$(parts_commit "$parts_tree")"
    git --git-dir="$fixture/source.git" update-ref refs/tags/package-v1 "$parts_revision"
    # Deliberately change the requested hash: otherwise a valid cached archive
    # correctly skips fetching, hiding the malformed-parts negative control.
    if fetch_dependency "$parts_revision" "$sha" parts; then exit 1; fi
    cmp "$fixture/output.zip" "$fixture/previous.zip"
done
git --git-dir="$fixture/source.git" update-ref refs/tags/package-v1 "$commit"
shopt -s nullglob
leftovers=("$fixture"/.ci-dependency.*)
[[ ${#leftovers[@]} == 0 ]]

mkdir -p "$fixture/bin"
export TEST_DEP_FETCH_LOG="$fixture/fetch-count" TEST_DEP_DEADLINE_LOG="$fixture/deadlines"
cat > "$fixture/bin/git" <<'SH'
#!/usr/bin/env bash
for argument in "$@"; do
    if [[ "$argument" == fetch ]]; then
        printf 'fetch\n' >> "$TEST_DEP_FETCH_LOG"
        exit "${TEST_DEP_FETCH_STATUS:-128}"
    fi
done
exec "$TEST_DEP_REAL_GIT" "$@"
SH
cat > "$fixture/bin/timeout" <<'SH'
#!/usr/bin/env bash
[[ "$1" == --kill-after=30s && "$2" == 180 ]] || exit 99
printf '180s\n' >> "$TEST_DEP_DEADLINE_LOG"
if [[ -n "${TEST_DEP_TIMEOUT_STATUS:-}" ]]; then exit "$TEST_DEP_TIMEOUT_STATUS"; fi
exec "$TEST_DEP_REAL_TIMEOUT" "$@"
SH
chmod +x "$fixture/bin/git" "$fixture/bin/timeout"
export PATH="$fixture/bin:$PATH"
if fetch_dependency; then exit 1; fi
[[ "$(wc -l < "$TEST_DEP_FETCH_LOG")" == 2 ]]
[[ "$(wc -l < "$TEST_DEP_DEADLINE_LOG")" == 2 ]]
cmp "$fixture/output.zip" "$fixture/previous.zip"
for terminal_status in 124 137 129 130 143; do
    : > "$TEST_DEP_DEADLINE_LOG"
    status=0
    TEST_DEP_TIMEOUT_STATUS="$terminal_status" fetch_dependency || status=$?
    [[ "$status" == "$terminal_status" ]]
    [[ "$(wc -l < "$TEST_DEP_DEADLINE_LOG")" == 1 ]]
    cmp "$fixture/output.zip" "$fixture/previous.zip"
done
echo 'CI dependency immutable commit, hash, cache and bounded fetch regressions passed'
