#!/usr/bin/env bash

# APK metadata and signing helpers shared by local and automated publishers.

apk_expected_certificate_sha256() {
    printf '%s' '72722218709a6d7fd0e80b944903ae2961b4cfa8abe03586f602acdc1ea0f52a'
}

apk_version_name() {
    local root_dir="$1"
    local version_name
    version_name="$(sed -nE 's/^[[:space:]]*version:[[:space:]]*([^+[:space:]]+)(\+[0-9]+)?[[:space:]]*$/\1/p' "$root_dir/flutter_app/pubspec.yaml")"
    if [[ ! "$version_name" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]]; then
        echo "Unable to read a semantic version from flutter_app/pubspec.yaml" >&2
        return 1
    fi
    printf '%s' "$version_name"
}

apk_version_code() {
    local root_dir="$1"
    local version_code
    version_code="$(sed -nE 's/^[[:space:]]*version:[[:space:]]*[0-9A-Za-z.-]+\+([0-9]+)[[:space:]]*$/\1/p' "$root_dir/flutter_app/pubspec.yaml")"
    if [[ ! "$version_code" =~ ^[1-9][0-9]*$ ]]; then
        echo "Unable to read a positive version code from flutter_app/pubspec.yaml" >&2
        return 1
    fi
    printf '%s' "$version_code"
}

apk_find_apkanalyzer() {
    local android_home="$1"
    local candidate
    candidate="$(find "$android_home/cmdline-tools" -type f -name apkanalyzer -perm -u+x \
        -printf '%p\n' 2>/dev/null | sort -V | tail -n 1)"
    if [[ -z "$candidate" ]]; then
        echo "apkanalyzer was not found under $android_home/cmdline-tools" >&2
        return 1
    fi
    printf '%s' "$candidate"
}

apk_version_code_from_apk() {
    local android_home="$1"
    local apk_path="$2"
    local analyzer
    local version_code
    [[ -f "$apk_path" ]] || {
        echo "APK was not produced: $apk_path" >&2
        return 1
    }
    analyzer="$(apk_find_apkanalyzer "$android_home")"
    version_code="$("$analyzer" manifest version-code "$apk_path" 2>/dev/null || true)"
    if [[ ! "$version_code" =~ ^[1-9][0-9]*$ ]]; then
        echo "Unable to read APK version code: $apk_path" >&2
        return 1
    fi
    printf '%s' "$version_code"
}

apk_find_build_tool() {
    local android_home="$1"
    local tool_name="$2"
    local candidate
    candidate="$(find "$android_home/build-tools" -mindepth 2 -maxdepth 2 \
        -type f -name "$tool_name" -perm -u+x -printf '%h/%f\n' 2>/dev/null |
        sort -V | tail -n 1)"
    if [[ -z "$candidate" ]]; then
        echo "$tool_name was not found under $android_home/build-tools" >&2
        return 1
    fi
    printf '%s' "$candidate"
}

apk_certificate_sha256() {
    local apksigner="$1"
    local apk_path="$2"
    "$apksigner" verify --print-certs "$apk_path" |
        sed -nE 's/^Signer #1 certificate SHA-256 digest: ([0-9A-Fa-f]+)$/\1/p' |
        tr '[:upper:]' '[:lower:]'
}

apk_verify_stable_signature() {
    local android_home="$1"
    local apk_path="$2"
    local apksigner
    local certificate_sha256
    local expected_certificate_sha256
    [[ -f "$apk_path" ]] || {
        echo "APK was not produced: $apk_path" >&2
        return 1
    }
    apksigner="$(apk_find_build_tool "$android_home" apksigner)"
    certificate_sha256="$(apk_certificate_sha256 "$apksigner" "$apk_path")"
    expected_certificate_sha256="$(apk_expected_certificate_sha256)"
    if [[ "$certificate_sha256" != "$expected_certificate_sha256" ]]; then
        echo "Unexpected APK signing certificate: ${certificate_sha256:-missing}" >&2
        return 1
    fi
    printf '%s' "$certificate_sha256"
}
