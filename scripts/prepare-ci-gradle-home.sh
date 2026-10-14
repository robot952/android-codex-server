#!/usr/bin/env bash
set -euo pipefail

# The caller supplies the bounded CI stage. stdout is only the new absolute
# GRADLE_USER_HOME; inherited configuration is diagnosed without reading it.
if [[ "$#" != 2 || -z "${1:-}" || -z "${2:-}" ]]; then
    echo 'Usage: prepare-ci-gradle-home.sh CACHE_HOME ISOLATED_PARENT' >&2
    exit 2
fi
for path in "$@"; do
    if [[ "$path" == *$'\n'* || "$path" == *$'\r'* ]]; then
        echo 'Gradle home paths must not contain line breaks' >&2
        exit 2
    fi
done

cache_home="$1"
isolated_parent="$2"
mkdir -p -- "$cache_home" "$isolated_parent"
cache_home="$(CDPATH= cd -- "$cache_home" && pwd -P)"
isolated_parent="$(CDPATH= cd -- "$isolated_parent" && pwd -P)"

configuration=()
for name in init.gradle init.gradle.kts init.d gradle.properties; do
    present=0
    if [[ -e "$cache_home/$name" || -L "$cache_home/$name" ]]; then
        present=1
    fi
    configuration+=("$name=$present")
done
printf 'Gradle home isolation: ignored source configuration (%s)\n' "${configuration[*]}" >&2

isolated_home=''
cleanup() {
    local status=$?
    if [[ "$status" != 0 && -n "$isolated_home" ]]; then
        # Only this invocation's private directory is disposable. rm does not
        # follow its cache symlinks; the mounted cache root remains untouched.
        rm -rf -- "$isolated_home"
    fi
    return "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

isolated_home="$(mktemp -d "$isolated_parent/gradle-home.XXXXXX")"
for name in caches wrapper; do
    mkdir -p -- "$cache_home/$name"
    ln -s -- "$cache_home/$name" "$isolated_home/$name"
done
printf '%s\n' "$isolated_home"
