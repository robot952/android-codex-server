#!/usr/bin/env bash
set -euo pipefail

# Fetch one immutable dependency from a small, independent Git branch/tag.
# Never check out its files, run hooks or change the application's HEAD/index.
[[ $# == 6 ]] || { echo 'Usage: fetch-ci-dependency.sh REPOSITORY REF COMMIT PATH SHA256 OUTPUT' >&2; exit 2; }
repository="$1" ref="$2" commit="$3" entry="$4" expected_sha="$5" output="$6"
[[ "$commit" =~ ^[a-f0-9]{40}$ && "$expected_sha" =~ ^[a-f0-9]{64}$ ]] || exit 2
[[ "$ref" == refs/tags/* || "$ref" == refs/heads/* ]] || exit 2
git check-ref-format "$ref" || exit 2
[[ "$entry" =~ ^[a-zA-Z0-9._/-]+$ && "$entry" != /* && "$entry" != -* && "/$entry/" != *'/../'* ]] || exit 2
# The production caller uses a public HTTPS Gitee repository. Local repositories
# are supported for offline regression fixtures; credentials are never required.
case "$repository" in
    https://*) [[ "$repository" != *'@'* && "$repository" != *'?'* && "$repository" != *'#'* ]] || exit 2 ;;
    file:///*) ;;
    *) echo 'CI dependency repository must be public HTTPS or a local fixture' >&2; exit 2 ;;
esac
for prerequisite in git timeout sha256sum; do
    command -v "$prerequisite" >/dev/null || { echo "Required tool missing: $prerequisite" >&2; exit 127; }
done
valid_archive() {
    [[ -f "$1" && "$(sha256sum "$1" | awk '{print $1}')" == "$expected_sha" ]]
}
if valid_archive "$output"; then
    echo 'Reusing SHA-256 verified CI dependency archive' >&2
    exit 0
fi
mkdir -p -- "$(dirname "$output")"
staging="$(mktemp -d "$(dirname "$output")/.ci-dependency.XXXXXX")"
trap 'rm -rf -- "$staging"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
# Do not inherit credential helpers, authorization headers, URL rewrites or Git
# hooks. Fetch uses a public dependency branch, not the checkout/release token.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/false
unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
git init --bare --quiet --template= "$staging/repo.git"
bounded_fetch() {
    local runner="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-ci-stage.sh"
    if [[ -n "${CODEX_CI_PROCESS_GROUP:-}" ]]; then
        bash "$runner" 'CI dependency fetch' 180 "$@"
    else
        timeout --kill-after=30s 180 "$@"
    fi
}
downloaded=0
for attempt in 1 2; do
    echo "Fetching pinned CI dependency (attempt $attempt/2, timeout 180s)" >&2
    status=0
    bounded_fetch git --git-dir="$staging/repo.git" \
        -c core.hooksPath=/dev/null -c credential.helper= \
        -c http.version=HTTP/1.1 -c http.lowSpeedLimit=1024 -c http.lowSpeedTime=30 \
        fetch --quiet --depth=1 --no-tags --no-recurse-submodules \
        "$repository" "$ref" >"$staging/fetch.log" 2>&1 || status=$?
    if [[ "$status" == 0 ]]; then downloaded=1; break; fi
    echo "CI dependency fetch failed (exit $status)" >&2
    # A stage deadline/cancellation is terminal, not a fresh retry budget.
    case "$status" in 124|137|129|130|143) exit "$status" ;; esac
done
[[ "$downloaded" == 1 ]] || { echo 'Unable to fetch pinned CI dependency from repository' >&2; exit 1; }
actual_commit="$(git --git-dir="$staging/repo.git" rev-parse 'FETCH_HEAD^{commit}')"
[[ "$actual_commit" == "$commit" ]] || {
    echo 'CI dependency commit mismatch; refusing moved tag/branch' >&2; exit 1;
}
git --git-dir="$staging/repo.git" cat-file blob "$commit:$entry" > "$staging/archive"
valid_archive "$staging/archive" || { echo 'CI dependency SHA-256 mismatch' >&2; exit 1; }
mv -f -- "$staging/archive" "$output"
echo "CI dependency verified: commit $commit, SHA-256 $expected_sha" >&2
