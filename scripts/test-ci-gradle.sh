#!/usr/bin/env bash
set -euo pipefail

# Isolated transport fixture: no SDK download and no Flutter/Gradle build. The
# production checksum stays immutable; only this private script copy accepts the
# tiny fixture's checksum. Java still independently hashes every published ZIP.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
wrapper_jar="$ROOT_DIR/gradle/wrapper/gradle-wrapper.jar"
[[ -f "$wrapper_jar" ]] || {
    echo 'The tracked Gradle wrapper JAR is required for independent cache-path verification' >&2
    exit 1
}
mkdir -p "$ROOT_DIR/.workflow-cache"
test_root="$(mktemp -d "$ROOT_DIR/.workflow-cache/ci-gradle-test.XXXXXX")"
trap 'rm -rf -- "$test_root"' EXIT
mkdir -p "$test_root/bin"
export FIXTURE_TIMEOUT_BIN="$(command -v timeout)"
fixture="$test_root/distribution.zip"
printf 'fixture Gradle distribution: verified bytes only\n' > "$fixture"
fixture_sha="$(sha256sum "$fixture" | awk '{print $1}')"
pin=b84e04fa845fecba48551f425957641074fcc00a88a84d2aae5808743b35fc85
prepare="$test_root/prepare-ci-gradle.sh"
sed "s/$pin/$fixture_sha/g" "$ROOT_DIR/scripts/prepare-ci-gradle.sh" > "$prepare"
properties="$test_root/gradle-wrapper.properties"
sed "s/$pin/$fixture_sha/g" \
    "$ROOT_DIR/flutter_app/android/gradle/wrapper/gradle-wrapper.properties" > "$properties"

cat > "$test_root/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FIXTURE_REQUESTS"
output=""
http1=0
resume=0
bounded=0
while (($#)); do
    case "$1" in
        --http1.1) http1=1; shift ;;
        --continue-at) [[ "$2" == - ]]; resume=1; shift 2 ;;
        --max-time) [[ "$2" == 300 ]]; bounded=1; shift 2 ;;
        --output) output="$2"; shift 2 ;;
        *) shift ;;
    esac
done
[[ "$http1$resume$bounded" == 111 && -n "$output" ]]
attempt="$(wc -l < "$FIXTURE_REQUESTS" | tr -d ' ')"
case "$FIXTURE_MODE" in
    offline) echo 'unexpected network request' >&2; exit 98 ;;
    corrupt) printf 'corrupt\n' > "$output"; printf 200; exit 0 ;;
    fallback)
        if [[ "$attempt" -le 2 ]]; then printf 503; exit 22; fi ;;
    official)
        if [[ "$attempt" -le 4 ]]; then printf 503; exit 22; fi ;;
    interrupted)
        if [[ "$attempt" == 1 ]]; then head -c 12 "$FIXTURE_ARCHIVE" > "$output"; printf 200; exit 18; fi
        [[ -f "$output" && "$(wc -c < "$output" | tr -d ' ')" == 12 ]] ;;
    deferred)
        if [[ "$attempt" == 1 ]]; then head -c 12 "$FIXTURE_ARCHIVE" > "$output"; printf 200; exit 18; fi
        printf 503; exit 22 ;;
    no_range)
        if [[ -s "$output" ]]; then printf 416; exit 33; fi ;;
    stalled)
        # Both the transfer and its child ignore TERM. The outer group deadline
        # must still kill them, release the inherited cache lock and fail closed.
        trap '' TERM
        sleep 600 &
        child=$!
        printf '%s\n' "$$" "$child" > "$FIXTURE_PROCESS_IDS"
        wait "$child"
        exit 97 ;;
esac
cp "$FIXTURE_ARCHIVE" "$output"
printf 200
SH
cat > "$test_root/bin/timeout" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
# Assert the production bound on every run; only the explicit stalled fixture
# shortens elapsed time. No --foreground: descendants must share the kill group.
[[ "${CODEX_CI_GRADLE_BOUNDED:-0}" != 1 ]] || {
    echo 'A bounded CI stage must not create a nested Gradle timeout group' >&2; exit 96;
}
[[ "${1:-}" == --signal=TERM && "${2:-}" == --kill-after=30s && "${3:-}" == 2400s ]]
if [[ "${FIXTURE_SHORT_TIMEOUT:-0}" == 1 ]]; then
    shift 3
    exec "$FIXTURE_TIMEOUT_BIN" --signal=TERM --kill-after=1s 5s "$@"
fi
exec "$FIXTURE_TIMEOUT_BIN" "$@"
SH
chmod +x "$test_root/bin/curl" "$test_root/bin/timeout"
export PATH="$test_root/bin:$PATH"
export FIXTURE_ARCHIVE="$fixture"
export FIXTURE_REQUESTS="$test_root/requests"
export FIXTURE_PROCESS_IDS="$test_root/stalled-processes"
export GRADLE_USER_HOME="$test_root/gradle user home"
unset CODEX_CI_GRADLE_BOUNDED

run_prepare() {
    FIXTURE_MODE="$1" bash "$prepare" "$2" "$properties"
}
reset_requests() { : > "$FIXTURE_REQUESTS"; }
request_count() { wc -l < "$FIXTURE_REQUESTS" | tr -d ' '; }
archive_path() { printf '%s/gradle-9.1.0-all-%s.zip\n' "$1" "$fixture_sha"; }

cache="$test_root/cache mount"
mkdir -p "$cache"
printf 'keep\n' > "$cache/user-marker"
inode="$(stat -c %i "$cache")"
reset_requests
archive="$(run_prepare success "$cache")"
[[ "$archive" == "$(archive_path "$cache")" && "$(request_count)" == 1 ]]
cmp "$fixture" "$archive"
[[ "$(stat -c %i "$cache")" == "$inode" && -f "$cache/user-marker" ]]
wrapper_zips=("$GRADLE_USER_HOME"/wrapper/dists/gradle-9.1.0-all/*/gradle-9.1.0-all.zip)
[[ "${#wrapper_zips[@]}" == 1 && -f "${wrapper_zips[0]}" ]]
wrapper_zip="${wrapper_zips[0]}"
cmp "$fixture" "$wrapper_zip"
[[ ! -e "$wrapper_zip.ok" ]]

# Verify base36 identity independently with the tracked root wrapper PathAssembler,
# so a self-consistent but incorrect MD5 directory implementation cannot pass.
# The Flutter Android wrapper JAR is generated and ignored, and is not present in
# a clean CI checkout before Flutter prepares that project.
cat > "$test_root/WrapperPath.java" <<'JAVA'
import java.net.URI;
import java.io.File;
import org.gradle.wrapper.PathAssembler;
import org.gradle.wrapper.WrapperConfiguration;
class WrapperPath {
    public static void main(String[] args) throws Exception {
        WrapperConfiguration configuration = new WrapperConfiguration();
        configuration.setDistribution(new URI("https://services.gradle.org/distributions/gradle-9.1.0-all.zip"));
        configuration.setDistributionBase("GRADLE_USER_HOME");
        configuration.setDistributionPath("wrapper/dists");
        configuration.setZipBase("GRADLE_USER_HOME");
        configuration.setZipPath("wrapper/dists");
        System.out.println(new PathAssembler(new File(args[0]), new File(args[1]))
            .getDistribution(configuration).getZipFile().getAbsolutePath());
    }
}
JAVA
expected_zip="$(java --class-path "$wrapper_jar" \
    "$test_root/WrapperPath.java" "$GRADLE_USER_HOME" "$ROOT_DIR")"
[[ "$wrapper_zip" == "$expected_zip" ]]

# A wrapper may consume/delete its ZIP. Repopulate without network or clearing
# already extracted releases, markers, other distributions or cache mount points.
mkdir -p "$(dirname "$wrapper_zip")/gradle-9.1.0/lib" "$GRADLE_USER_HOME/wrapper/dists/other"
printf 'keep\n' > "$(dirname "$wrapper_zip")/gradle-9.1.0/lib/user-marker"
printf 'keep\n' > "$GRADLE_USER_HOME/wrapper/dists/other/user-marker"
touch "$wrapper_zip.ok"
rm -f "$wrapper_zip"
reset_requests
[[ "$(run_prepare offline "$cache")" == "$archive" && "$(request_count)" == 0 ]]
cmp "$fixture" "$wrapper_zip"
[[ -f "$wrapper_zip.ok" && -f "$(dirname "$wrapper_zip")/gradle-9.1.0/lib/user-marker" ]]
[[ -f "$GRADLE_USER_HOME/wrapper/dists/other/user-marker" ]]

# An already bounded shared stage may reuse the same cache without invoking
# another timeout or moving curl/Java into a separate, uncancellable group.
[[ "$(CODEX_CI_GRADLE_BOUNDED=1 run_prepare offline "$cache")" == "$archive" ]]
[[ "$(request_count)" == 0 ]]

reset_requests
run_prepare interrupted "$test_root/interrupted" >/dev/null
[[ "$(request_count)" == 2 ]]

reset_requests
run_prepare fallback "$test_root/fallback" >/dev/null
[[ "$(request_count)" == 3 ]]
sed -n '1p' "$FIXTURE_REQUESTS" | grep -q 'https://repo.huaweicloud.com/gradle/'
sed -n '3p' "$FIXTURE_REQUESTS" | grep -q 'https://downloads.gradle.org/distributions/'
reset_requests
run_prepare official "$test_root/official" >/dev/null
[[ "$(request_count)" == 5 ]]
sed -n '5p' "$FIXTURE_REQUESTS" | grep -q 'https://services.gradle.org/distributions/'

cache="$test_root/no-range"
mkdir -p "$cache"
head -c 12 "$fixture" > "$(archive_path "$cache").part"
reset_requests
run_prepare no_range "$cache" >/dev/null
[[ "$(request_count)" == 2 ]]

cache="$test_root/deferred"
reset_requests
if run_prepare deferred "$cache" > "$test_root/deferred.log" 2>&1; then
    echo 'An incomplete Gradle transfer was accepted' >&2; exit 1
fi
[[ "$(request_count)" == 6 && -s "$(archive_path "$cache").part" ]]
reset_requests
run_prepare success "$cache" >/dev/null
[[ "$(request_count)" == 1 ]]

cache="$test_root/corrupt"
mkdir -p "$cache"
printf 'keep\n' > "$cache/user-marker"
reset_requests
if run_prepare corrupt "$cache" > "$test_root/corrupt.log" 2>&1; then
    echo 'An unverified Gradle archive was accepted' >&2; exit 1
fi
[[ "$(request_count)" == 6 && ! -e "$(archive_path "$cache")" ]]
[[ ! -e "$(archive_path "$cache").part" && -f "$cache/user-marker" ]]
cmp "$fixture" "$wrapper_zip"

# Two jobs sharing a mounted archive cache publish one independently verified
# distribution while retaining the original cache mount and extracted files.
reset_requests
run_prepare success "$test_root/concurrent" > "$test_root/first.path" 2> "$test_root/first.log" &
first_pid=$!
run_prepare success "$test_root/concurrent" > "$test_root/second.path" 2> "$test_root/second.log" &
second_pid=$!
wait "$first_pid"
wait "$second_pid"
cmp "$test_root/first.path" "$test_root/second.path"
[[ "$(request_count)" == 1 ]]

# Production pins cannot be replaced through wrapper properties; a future upgrade
# must explicitly update both reviewed pins instead of using an arbitrary URL.
sed 's/gradle-9.1.0-all/gradle-9.2.0-all/' "$properties" > "$test_root/unsupported.properties"
reset_requests
if FIXTURE_MODE=offline bash "$prepare" "$test_root/rejected" "$test_root/unsupported.properties" \
        > "$test_root/rejected.log" 2>&1; then
    echo 'An unsupported Gradle version was accepted' >&2; exit 1
fi
[[ "$(request_count)" == 0 && ! -d "$test_root/rejected" ]]

# Exercise the real GNU timeout supervisor with only its wall-clock duration
# shortened. A stalled transfer cannot leave a TERM-ignoring descendant or hold
# the mounted cache lock after the helper reports its hard timeout.
cache="$test_root/stalled"
reset_requests
timeout_status=0
FIXTURE_SHORT_TIMEOUT=1 FIXTURE_MODE=stalled bash "$prepare" "$cache" "$properties" \
    > "$test_root/stalled.log" 2>&1 || timeout_status=$?
[[ "$timeout_status" == 137 && -s "$FIXTURE_PROCESS_IDS" ]]
grep -q '40-minute deadline' "$test_root/stalled.log"
assert_stalled_children_stopped() {
    local pid state
    while IFS= read -r pid; do
        state="$(ps -o stat= -p "$pid" || true)"
        state="${state//[[:space:]]/}"
        [[ -z "$state" || "$state" == Z* ]] || {
            echo "Gradle timeout left a live descendant: $pid ($state)" >&2; exit 1;
        }
    done < "$FIXTURE_PROCESS_IDS"
}
assert_stalled_children_stopped
flock -n "$cache/.prepare.lock" true
[[ ! -f "$(archive_path "$cache")" && "$(request_count)" == 1 ]]
cmp "$fixture" "$wrapper_zip"

# The external stage supervisor must also kill the worker and all its children
# when the helper is deliberately reusing that existing process-group boundary.
cache="$test_root/externally-bounded"
reset_requests
rm -f "$FIXTURE_PROCESS_IDS"
timeout_status=0
CODEX_CI_GRADLE_BOUNDED=1 FIXTURE_MODE=stalled \
    "$FIXTURE_TIMEOUT_BIN" --signal=TERM --kill-after=1s 5s \
    bash "$prepare" "$cache" "$properties" \
    > "$test_root/externally-bounded.log" 2>&1 || timeout_status=$?
[[ "$timeout_status" == 137 && -s "$FIXTURE_PROCESS_IDS" ]]
assert_stalled_children_stopped
flock -n "$cache/.prepare.lock" true
[[ ! -f "$(archive_path "$cache")" && "$(request_count)" == 1 ]]
cmp "$fixture" "$wrapper_zip"
echo 'CI Gradle bootstrap tests passed (wrapper identity, verified cache, bounded fallback, resume, checksum rejection, process-group timeout)'
