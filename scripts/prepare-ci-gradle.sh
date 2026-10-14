#!/usr/bin/env bash
set -euo pipefail

# Cover every phase, including lock waits, checksum I/O and Java startup. GNU
# timeout owns a process group (do not use --foreground), so stalled curl/Java
# descendants receive TERM after 40 minutes and KILL 30 seconds later.
# The shared CI stage already owns that boundary. Its private opt-in preserves
# the caller's process group so cancellation cannot strand a nested timeout.
# Never set CODEX_CI_GRADLE_BOUNDED=1 outside an active group-aware supervisor.
if [[ "${1:-}" == --within-timeout ]]; then
    shift
elif [[ "${CODEX_CI_GRADLE_BOUNDED:-0}" != 1 ]]; then
    command -v timeout >/dev/null || { echo "Gradle preparation requires GNU timeout" >&2; exit 1; }
    status=0
    timeout --signal=TERM --kill-after=30s 2400s \
        bash "${BASH_SOURCE[0]}" --within-timeout "$@" || status=$?
    if [[ "$status" == 124 || "$status" == 137 ]]; then
        echo "Gradle preparation exceeded its 40-minute deadline; its process group was terminated (30-second kill grace)" >&2
    fi
    exit "$status"
fi

# Keep the monitored worker alive for the kill-after grace period even if a
# direct child exits on TERM while one of its descendants ignores that signal.
# Otherwise GNU timeout could return early before killing that remaining group.
# The active timeout supervisor then sends KILL to this entire group.
trap 'trap "" TERM; while :; do sleep 1; done' TERM

# stdout is the verified ZIP path; all progress goes to stderr. Never replace the
# cache root itself: Gitee can mount it. Keep the source ZIP because the wrapper
# removes its own copy after extracting a distribution.
cache_root="${1:?cache directory required}"
properties="${2:?Gradle wrapper properties required}"
version=9.1.0
archive_name="gradle-$version-all.zip"
official_url="https://services.gradle.org/distributions/$archive_name"
# https://services.gradle.org/distributions/gradle-9.1.0-all.zip.sha256
archive_sha256=b84e04fa845fecba48551f425957641074fcc00a88a84d2aae5808743b35fc85

property() {
    awk -F= -v key="$1" '$1 == key {sub(/^[^=]*=/, ""); sub(/\r$/, ""); print}' "$properties"
}
distribution_url="$(property distributionUrl)"
distribution_url="${distribution_url//\\:/:}"
if [[ "$distribution_url" != "$official_url" ||
      "$(property distributionBase)" != GRADLE_USER_HOME ||
      "$(property distributionPath)" != wrapper/dists ||
      "$(property zipStoreBase)" != GRADLE_USER_HOME ||
      "$(property zipStorePath)" != wrapper/dists ]]; then
    echo "Unsupported Gradle wrapper distribution or cache layout; review the pinned bootstrap before upgrading" >&2
    exit 2
fi
configured_sha="$(property distributionSha256Sum)"
if [[ -n "$configured_sha" && "$configured_sha" != "$archive_sha256" ]]; then
    echo "Gradle wrapper SHA-256 disagrees with the reviewed distribution pin" >&2
    exit 2
fi
for tool in curl sha256sum flock java; do
    command -v "$tool" >/dev/null || { echo "Gradle preparation requires $tool" >&2; exit 1; }
done

mkdir -p -- "$cache_root"
cache_root="$(cd "$cache_root" && pwd -P)"
exec 9>"$cache_root/.prepare.lock"
flock -w 300 9 || { echo "Timed out waiting for the Gradle cache preparation lock" >&2; exit 1; }
archive="$cache_root/gradle-$version-all-$archive_sha256.zip"
partial="$archive.part"
valid_archive() {
    [[ -f "$1" ]] && [[ "$(sha256sum "$1" | awk '{print $1}')" == "$archive_sha256" ]]
}

if valid_archive "$archive"; then
    echo "Reusing verified Gradle $version distribution" >&2
else
    downloaded=0
    urls=(
        "https://repo.huaweicloud.com/gradle/$archive_name"
        "https://downloads.gradle.org/distributions/$archive_name"
        "$official_url"
    )
    for source_index in "${!urls[@]}"; do
        for attempt in 1 2; do
            if valid_archive "$partial"; then downloaded=1; break; fi
            echo "Downloading Gradle $version (source $((source_index + 1))/3, attempt $attempt/2, resumable)" >&2
            transfer_status=0
            http_status="$(curl --http1.1 --fail --location --silent --show-error \
                --proto '=https' --proto-redir '=https' \
                --connect-timeout 20 --max-time 300 --speed-time 60 --speed-limit 1024 \
                --continue-at - --output "$partial" --write-out '%{http_code}' \
                "${urls[$source_index]}")" || transfer_status=$?
            if valid_archive "$partial"; then downloaded=1; break; fi
            if [[ "$transfer_status" == 0 ]]; then
                echo "Gradle archive SHA-256 mismatch; discarding only the corrupt partial download" >&2
                rm -f -- "$partial"
            elif [[ "$transfer_status" == 33 || "$http_status" == 416 ]]; then
                echo "Gradle server cannot resume this file; restarting the partial download" >&2
                rm -f -- "$partial"
            else
                echo "Gradle transfer interrupted (curl $transfer_status); retaining partial download" >&2
            fi
        done
        [[ "$downloaded" != 1 ]] || break
    done
    if [[ "$downloaded" != 1 ]]; then
        echo "Gradle download failed after at most 6 attempts; rerun to resume the retained partial file" >&2
        exit 1
    fi
    mv -f -- "$partial" "$archive"
fi

# Match Gradle PathAssembler: MD5 of the original distribution URI, as unsigned
# base36. Java 17 is already a build prerequisite; no Node/Python dependency is
# introduced. Use the same Java file lock as the wrapper, not an incompatible
# flock, when publishing its ZIP. Do not create .ok or alter extracted releases.
staging="$(mktemp -d "$cache_root/.prepare.XXXXXX")"
trap 'rm -rf -- "$staging"' EXIT
cat >"$staging/PrepareGradleCache.java" <<'JAVA'
import java.io.InputStream;
import java.math.BigInteger;
import java.nio.channels.FileChannel;
import java.nio.channels.FileLock;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.security.MessageDigest;
import java.time.Duration;
import java.util.HexFormat;

class PrepareGradleCache {
    static boolean valid(Path path, String expected) throws Exception {
        if (!Files.isRegularFile(path)) return false;
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        try (InputStream input = Files.newInputStream(path)) {
            byte[] buffer = new byte[65536];
            for (int count; (count = input.read(buffer)) != -1;) digest.update(buffer, 0, count);
        }
        return HexFormat.of().formatHex(digest.digest()).equals(expected);
    }

    public static void main(String[] args) throws Exception {
        String hash = new BigInteger(1, MessageDigest.getInstance("MD5")
            .digest(args[0].getBytes(StandardCharsets.UTF_8))).toString(36);
        Path directory = Path.of(args[2]).toAbsolutePath().normalize()
            .resolve("wrapper/dists/gradle-9.1.0-all").resolve(hash);
        Files.createDirectories(directory);
        Path target = directory.resolve("gradle-9.1.0-all.zip");
        try (FileChannel channel = FileChannel.open(directory.resolve("gradle-9.1.0-all.zip.lck"),
                StandardOpenOption.CREATE, StandardOpenOption.WRITE)) {
            FileLock lock = null;
            long deadline = System.nanoTime() + Duration.ofSeconds(120).toNanos();
            while (lock == null && System.nanoTime() < deadline) {
                lock = channel.tryLock();
                if (lock == null) Thread.sleep(200);
            }
            if (lock == null) throw new IllegalStateException("Timed out waiting for Gradle wrapper cache lock");
            try {
                if (valid(target, args[3])) return;
                Path temporary = Files.createTempFile(directory, ".gradle-download.", ".tmp");
                try {
                    Files.copy(Path.of(args[1]), temporary, StandardCopyOption.REPLACE_EXISTING);
                    if (!valid(temporary, args[3])) throw new IllegalStateException("Gradle cache copy SHA-256 mismatch");
                    Files.move(temporary, target, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
                } finally {
                    Files.deleteIfExists(temporary);
                }
            } finally {
                lock.release();
            }
        }
    }
}
JAVA
java "$staging/PrepareGradleCache.java" "$distribution_url" "$archive" \
    "${GRADLE_USER_HOME:-$HOME/.gradle}" "$archive_sha256"
echo "Gradle $version distribution prepared in the original wrapper cache" >&2
printf '%s\n' "$archive"
