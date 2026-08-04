#!/usr/bin/env bash

# Shared helpers for the local development workflow. Keep this file free of
# repository-specific side effects so every entry point can source it.

workflow_cache_dir() {
    local root_dir="$1"
    printf '%s' "${CODEX_WORKFLOW_CACHE_DIR:-$root_dir/.workflow-cache}"
}

workflow_sha256() {
    sha256sum | awk '{print $1}'
}

# Hashes tracked and non-ignored untracked files under the supplied paths. The
# path is part of the digest, so renames invalidate the result even when the
# file contents are unchanged. Ignored build outputs never enter the digest.
workflow_repo_hash() {
    local root_dir="$1"
    shift
    (
        cd "$root_dir"
        git ls-files -co --exclude-standard -z -- "$@" |
            sort -zu |
            while IFS= read -r -d '' file_path; do
                if [[ -f "$file_path" ]]; then
                    printf 'path=%s\n' "$file_path"
                    stat -c 'mode=%a' -- "$file_path"
                    sha256sum -- "$file_path"
                elif [[ -L "$file_path" ]]; then
                    printf 'link=%s->%s\n' "$file_path" "$(readlink "$file_path")"
                fi
            done
    ) | workflow_sha256
}

workflow_stamp_value() {
    local stamp_path="$1"
    local key="$2"
    [[ -f "$stamp_path" ]] || return 1
    sed -nE "0,/^${key}=/{s/^${key}=//p}" "$stamp_path"
}

workflow_stamp_matches() {
    local stamp_path="$1"
    local fingerprint="$2"
    [[ "$(workflow_stamp_value "$stamp_path" fingerprint 2>/dev/null || true)" == "$fingerprint" ]]
}

workflow_write_stamp() {
    local stamp_path="$1"
    local fingerprint="$2"
    local temporary_stamp
    mkdir -p "$(dirname "$stamp_path")"
    temporary_stamp="$(mktemp "${stamp_path}.XXXXXX")"
    {
        printf 'fingerprint=%s\n' "$fingerprint"
        printf 'completedAt=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$temporary_stamp"
    mv -f "$temporary_stamp" "$stamp_path"
}

workflow_elapsed() {
    local started_seconds="$1"
    local elapsed_seconds=$(( $(date +%s) - started_seconds ))
    printf '%dm%02ds' "$((elapsed_seconds / 60))" "$((elapsed_seconds % 60))"
}

workflow_file_sha256_cached() {
    local root_dir="$1"
    local file_path="$2"
    local resolved_path
    local file_key
    local file_metadata
    local identity_dir
    local identity_path
    local cached_metadata
    local cached_sha256
    local actual_sha256
    local temporary_identity
    local lock_fd

    resolved_path="$(readlink -f "$file_path")"
    [[ -f "$resolved_path" ]] || {
        echo "Cannot fingerprint missing file: $file_path" >&2
        return 1
    }
    file_key="$(printf '%s' "$resolved_path" | workflow_sha256)"
    file_metadata="$(stat -Lc '%d:%i:%s:%y:%z:%a' "$resolved_path")"
    identity_dir="$(workflow_cache_dir "$root_dir")/file-identities"
    identity_path="$identity_dir/$file_key.sha256"
    mkdir -p "$identity_dir"

    exec {lock_fd}>"$identity_path.lock"
    flock "$lock_fd"
    cached_metadata="$(workflow_stamp_value "$identity_path" metadata 2>/dev/null || true)"
    cached_sha256="$(workflow_stamp_value "$identity_path" sha256 2>/dev/null || true)"
    if [[ "$cached_metadata" == "$file_metadata" && "$cached_sha256" =~ ^[0-9a-f]{64}$ ]]; then
        printf '%s' "$cached_sha256"
        exec {lock_fd}>&-
        return 0
    fi

    actual_sha256="$(sha256sum -- "$resolved_path" | awk '{print $1}')"
    temporary_identity="$(mktemp "${identity_path}.XXXXXX")"
    {
        printf 'metadata=%s\n' "$file_metadata"
        printf 'sha256=%s\n' "$actual_sha256"
    } > "$temporary_identity"
    mv -f "$temporary_identity" "$identity_path"
    printf '%s' "$actual_sha256"
    exec {lock_fd}>&-
}

workflow_opencode_version() {
    local executable_path="$1"
    local resolved_path
    local package_json
    local package_version
    resolved_path="$(readlink -f "$executable_path")"
    package_json="$(dirname "$(dirname "$resolved_path")")/package.json"
    if [[ -f "$package_json" ]] && command -v node >/dev/null 2>&1; then
        package_version="$(node -e '
            const fs = require("node:fs");
            const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8")).version;
            if (typeof value !== "string" || value.length === 0) process.exit(1);
            process.stdout.write(value);
        ' "$package_json" 2>/dev/null || true)"
        if [[ -n "$package_version" ]]; then
            printf '%s' "$package_version"
            return 0
        fi
    fi
    "$resolved_path" --version 2>&1 | head -n 1 | tr -d '\r[:space:]'
}

workflow_find_opencode() {
    local root_dir="$1"
    local version="$2"
    local candidate=""
    local command_candidate=""
    local -a candidates=()

    if [[ -n "${OPENCODE_BIN:-}" ]]; then
        if [[ -x "$OPENCODE_BIN" ]]; then
            if [[ "$(workflow_opencode_version "$OPENCODE_BIN" || true)" == "$version" ]]; then
                readlink -f "$OPENCODE_BIN"
                return 0
            fi
            echo "OPENCODE_BIN version does not match $version: $OPENCODE_BIN" >&2
            return 1
        fi
        echo "OPENCODE_BIN is not executable: $OPENCODE_BIN" >&2
        return 1
    fi

    command_candidate="$(command -v opencode 2>/dev/null || true)"
    [[ -n "$command_candidate" ]] && candidates+=("$command_candidate")
    candidates+=(
        "$HOME/.local/share/codex-remote/opencode/releases/$version/node_modules/.bin/opencode"
        "/root/.local/share/codex-remote/opencode/releases/$version/node_modules/.bin/opencode"
        "$(workflow_cache_dir "$root_dir")/opencode/$version/node_modules/.bin/opencode"
    )

    for candidate in "${candidates[@]}"; do
        if [[ -x "$candidate" ]]; then
            local candidate_version
            candidate_version="$(workflow_opencode_version "$candidate" || true)"
            if [[ "$candidate_version" == "$version" ]]; then
                readlink -f "$candidate"
                return 0
            fi
        fi
    done
    return 1
}
