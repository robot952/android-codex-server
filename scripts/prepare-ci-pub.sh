#!/usr/bin/env bash
set -euo pipefail

flutter_bin="${1:?Flutter executable required}"
project="${2:?Flutter project directory required}"
cd "$project"
[[ -f pubspec.lock ]] || { echo 'CI requires pubspec.lock' >&2; exit 1; }
primary="${PUB_HOSTED_URL:-https://pub.flutter-io.cn}"
primary="${primary%/}"
sources=("$primary")
# Do not send private package requests to public servers when a custom host is set.
if [[ "$primary" == https://pub.flutter-io.cn ]]; then
    sources+=(https://pub.dev)
fi

temporary="$(mktemp -d .ci-pub.XXXXXX)"
cp -p pubspec.lock "$temporary/pubspec.lock"
cleanup() {
    cp -p "$temporary/pubspec.lock" pubspec.lock
    rm -rf -- "$temporary"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for source in "${sources[@]}"; do
    cp -p "$temporary/pubspec.lock" pubspec.lock
    # A mirror is a different hosted source to Pub. Map only the public source URL;
    # every package version and SHA-256 stays locked. Restore the original on exit.
    if [[ "$source" == https://pub.flutter-io.cn ]]; then
        sed -i 's#url: "https://pub.dev"#url: "https://pub.flutter-io.cn"#g' pubspec.lock
    fi
    for attempt in 1 2; do
        echo "Fetching locked Flutter dependencies (source $source, attempt $attempt/2)"
        set +e
        PUB_HOSTED_URL="$source" timeout --kill-after=15 300 \
            "$flutter_bin" pub get --enforce-lockfile 2>&1 | tee "$temporary/output"
        statuses=("${PIPESTATUS[@]}")
        set -e
        status="${statuses[0]}"
        [[ "${statuses[1]}" == 0 ]] || exit "${statuses[1]}"
        if [[ "$status" == 0 ]]; then
            echo 'Locked Flutter dependencies ready'
            exit 0
        fi
        # Retry only transport failures. Version conflicts, bad hashes and invalid
        # lockfiles are code/integrity errors and must stop without switching hosts.
        if [[ "$status" != 124 ]] && ! grep -Eiq \
            '(\b(408|424|429|5[0-9]{2})\b.*(trying to find package|trying to download)|SocketException|HandshakeException|Connection (reset|closed|refused)|[Tt]imed? out|[Tt]imeout|[Hh]ost lookup|[Nn]etwork is unreachable)' "$temporary/output"; then
            exit "$status"
        fi
        echo "Pub source request failed (exit $status)" >&2
    done
done
echo 'Flutter dependency download failed after bounded source retries' >&2
exit "$status"
