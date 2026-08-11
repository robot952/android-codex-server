#!/usr/bin/env bash

# Shared helpers for the local development workflow. Keep this file free of
# repository-specific side effects so every entry point can source it.

workflow_cache_dir() {
    local root_dir="$1"
    printf '%s' "${CODEX_WORKFLOW_CACHE_DIR:-$root_dir/.workflow-cache}"
}

workflow_resolve_flutter() {
    local root_dir="$1"
    local candidate
    if [[ -n "${CODEX_FLUTTER_BIN:-}" ]]; then
        candidate="$CODEX_FLUTTER_BIN"
    elif command -v flutter >/dev/null 2>&1; then
        candidate="$(command -v flutter)"
    elif [[ -x "$root_dir/../.toolchains/flutter-root/bin/flutter" ]]; then
        candidate="$root_dir/../.toolchains/flutter-root/bin/flutter"
    elif [[ -x "$root_dir/.toolchains/flutter-root/bin/flutter" ]]; then
        candidate="$root_dir/.toolchains/flutter-root/bin/flutter"
    elif [[ -x "$root_dir/../.toolchains/flutter/bin/flutter" ]]; then
        candidate="$root_dir/../.toolchains/flutter/bin/flutter"
    elif [[ -x "$HOME/flutter/bin/flutter" ]]; then
        candidate="$HOME/flutter/bin/flutter"
    else
        echo "Flutter CLI was not found; set CODEX_FLUTTER_BIN" >&2
        return 1
    fi
    [[ -x "$candidate" ]] || {
        echo "Flutter CLI is not executable: $candidate" >&2
        return 1
    }
    printf '%s' "$candidate"
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

workflow_format_duration_ms() {
    local elapsed_ms="$1"
    local elapsed_seconds=$((elapsed_ms / 1000))
    printf '%dm%02d.%03ds' \
        "$((elapsed_seconds / 60))" \
        "$((elapsed_seconds % 60))" \
        "$((elapsed_ms % 1000))"
}

# Produces a side-effect-free Android gate plan. A valid Debug or Release gate
# proves that analyze and the full Flutter test suite passed for the same input
# fingerprint, so the sibling APK can be built without repeating validation.
workflow_android_gate_plan() {
    local mode="$1"
    local reuse="$2"
    local fast_valid="$3"
    local debug_valid="$4"
    local release_valid="$5"

    WORKFLOW_ANDROID_PLAN_VALIDATE=0
    WORKFLOW_ANDROID_PLAN_BUILD_DEBUG=0
    WORKFLOW_ANDROID_PLAN_BUILD_RELEASE=0
    WORKFLOW_ANDROID_PLAN_CACHE_HIT=0
    WORKFLOW_ANDROID_PLAN_VALIDATION_SOURCE="none"

    if [[ "$reuse" != 1 ]]; then
        fast_valid=0
        debug_valid=0
        release_valid=0
    fi

    case "$mode" in
        fast)
            if [[ "$fast_valid" == 1 || "$debug_valid" == 1 || "$release_valid" == 1 ]]; then
                WORKFLOW_ANDROID_PLAN_CACHE_HIT=1
            else
                WORKFLOW_ANDROID_PLAN_VALIDATE=1
            fi
            ;;
        debug)
            if [[ "$debug_valid" == 1 ]]; then
                WORKFLOW_ANDROID_PLAN_CACHE_HIT=1
            else
                WORKFLOW_ANDROID_PLAN_BUILD_DEBUG=1
                if [[ "$release_valid" == 1 ]]; then
                    WORKFLOW_ANDROID_PLAN_VALIDATION_SOURCE="release"
                else
                    WORKFLOW_ANDROID_PLAN_VALIDATE=1
                fi
            fi
            ;;
        release)
            if [[ "$release_valid" == 1 ]]; then
                WORKFLOW_ANDROID_PLAN_CACHE_HIT=1
            else
                WORKFLOW_ANDROID_PLAN_BUILD_RELEASE=1
                if [[ "$debug_valid" == 1 ]]; then
                    WORKFLOW_ANDROID_PLAN_VALIDATION_SOURCE="debug"
                else
                    WORKFLOW_ANDROID_PLAN_VALIDATE=1
                fi
            fi
            ;;
        all)
            [[ "$debug_valid" == 1 ]] || WORKFLOW_ANDROID_PLAN_BUILD_DEBUG=1
            [[ "$release_valid" == 1 ]] || WORKFLOW_ANDROID_PLAN_BUILD_RELEASE=1
            if [[ "$debug_valid" == 1 && "$release_valid" == 1 ]]; then
                WORKFLOW_ANDROID_PLAN_CACHE_HIT=1
            elif [[ "$debug_valid" == 1 ]]; then
                WORKFLOW_ANDROID_PLAN_VALIDATION_SOURCE="debug"
            elif [[ "$release_valid" == 1 ]]; then
                WORKFLOW_ANDROID_PLAN_VALIDATION_SOURCE="release"
            else
                WORKFLOW_ANDROID_PLAN_VALIDATE=1
            fi
            ;;
        *)
            echo "Unknown Android gate mode: $mode" >&2
            return 2
            ;;
    esac
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
