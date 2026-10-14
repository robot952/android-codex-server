#!/usr/bin/env bash
set -euo pipefail

# Offline filesystem fixture only: never launches Gradle, downloads dependencies,
# or touches the caller's HOME/GRADLE_USER_HOME. A separate CI stage runs Gradle.
ROOT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
prepare="$ROOT_DIR/scripts/prepare-ci-gradle-home.sh"
mkdir -p "$ROOT_DIR/.workflow-cache"
test_root="$(mktemp -d "$ROOT_DIR/.workflow-cache/ci-gradle-home-test.XXXXXX")"
trap 'chmod -R u+w -- "$test_root"; rm -rf -- "$test_root"' EXIT
fail() { echo "Gradle home isolation fixture: $*" >&2; exit 1; }

cache_home="$test_root/cache mount/original home"
isolated_parent="$test_root/nested parent/isolated homes"
mkdir -p "$cache_home/init.d" "$cache_home/caches" "$cache_home/wrapper" "$cache_home/daemon"
printf 'throw new GradleException("FIXTURE_SECRET_must_not_be_read")\n' > "$cache_home/init.gradle"
printf 'error("FIXTURE_SECRET_must_not_be_read")\n' > "$cache_home/init.gradle.kts"
printf 'throw new GradleException("FIXTURE_SECRET_must_not_be_read")\n' > "$cache_home/init.d/injected.gradle"
printf 'systemProp.fixture.secret=FIXTURE_SECRET_must_not_be_read\n' > "$cache_home/gradle.properties"
printf 'cache sentinel\n' > "$cache_home/caches/sentinel"
printf 'wrapper sentinel\n' > "$cache_home/wrapper/sentinel"
printf 'old home marker\n' > "$cache_home/user-marker"
printf 'old daemon marker\n' > "$cache_home/daemon/registry.bin"

source_snapshot() {
    # Device/inode identity detects replacing a mount root even with equal bytes.
    stat -c '%d:%i:%a' -- "$cache_home" "$cache_home/caches" "$cache_home/wrapper" "$cache_home/init.d"
    local name
    for name in init.gradle init.gradle.kts init.d/injected.gradle gradle.properties \
            caches/sentinel wrapper/sentinel user-marker daemon/registry.bin; do
        stat -c '%d:%i:%a:%s:%Y:%Z' -- "$cache_home/$name"
        sha256sum -- "$cache_home/$name"
    done
}
original_snapshot="$(source_snapshot)"

assert_clean_home() (
    local home="$1" name
    [[ "$home" == "$isolated_parent/gradle-home."* && -d "$home" && ! -L "$home" ]] || fail 'invalid isolated path'
    [[ "$home" != *$'\n'* && "$(stat -c %a -- "$home")" == 700 ]] || fail 'home is not private'
    shopt -s nullglob dotglob
    local entries=("$home"/*)
    [[ "${#entries[@]}" == 2 ]] || fail 'isolated home inherited extra entries'
    for name in caches wrapper; do
        [[ -L "$home/$name" && "$(readlink -- "$home/$name")" == "$cache_home/$name" ]] || fail "incorrect $name link"
        cmp "$home/$name/sentinel" "$cache_home/$name/sentinel"
    done
    for name in init.gradle init.gradle.kts init.d gradle.properties daemon; do
        [[ ! -e "$home/$name" && ! -L "$home/$name" ]] || fail "inherited $name"
    done
)

# Relative/nested paths, spaces and inherited CDPATH must not pollute stdout.
first_home="$(
    cd "$test_root"
    CDPATH="$test_root" bash "$prepare" './cache mount/original home' \
        './nested parent/isolated homes' 2> "$test_root/first.log"
)"
assert_clean_home "$first_home"
diagnostic="$(<"$test_root/first.log")"
[[ "$diagnostic" == *'init.gradle=1 init.gradle.kts=1 init.d=1 gradle.properties=1'* ]] || fail 'missing configuration diagnosis'
[[ "$diagnostic" != *FIXTURE_SECRET* ]] || fail 'configuration content leaked'

# A previous invocation's own configuration must not enter the next home.
printf 'first invocation only\n' > "$first_home/gradle.properties"
second_home="$(bash "$prepare" "$cache_home" "$isolated_parent" 2> "$test_root/second.log")"
[[ "$first_home" != "$second_home" && -f "$first_home/gradle.properties" ]] || fail 'home was reused or replaced'
assert_clean_home "$second_home"
printf 'shared cache write\n' > "$first_home/caches/shared-write"
[[ "$(<"$second_home/caches/shared-write")" == 'shared cache write' ]] || fail 'cache was copied instead of shared'
[[ "$(source_snapshot)" == "$original_snapshot" ]] || fail 'original home, configuration or cache changed'

expect_failure() {
    local label="$1"
    shift
    if "$@" > "$test_root/$label.out" 2> "$test_root/$label.err"; then
        fail "$label unexpectedly succeeded"
    fi
    [[ ! -s "$test_root/$label.out" ]] || fail "$label emitted a usable path"
}
expect_failure missing-arguments bash "$prepare"
expect_failure extra-argument bash "$prepare" "$cache_home" "$isolated_parent" unexpected
expect_failure empty-cache bash "$prepare" '' "$isolated_parent"
expect_failure empty-parent bash "$prepare" "$cache_home" ''
expect_failure multiline-path bash "$prepare" "$cache_home" "$test_root/invalid"$'\npath'
expect_failure cache-is-file bash "$prepare" "$cache_home/user-marker" "$isolated_parent"
expect_failure parent-is-file bash "$prepare" "$cache_home" "$cache_home/user-marker"

# Root CI ignores chmod write restrictions; inject the same failed mktemp result
# there. Non-root runners exercise the actual unwritable parent directory.
blocked_parent="$test_root/blocked parent"
mkdir -p "$blocked_parent" "$test_root/bin"
chmod 500 "$blocked_parent"
if [[ ! -w "$blocked_parent" ]]; then
    expect_failure unwritable-parent bash "$prepare" "$cache_home" "$blocked_parent"
else
    printf '#!/usr/bin/env bash\necho "fixture: parent is not writable" >&2\nexit 73\n' > "$test_root/bin/mktemp"
    chmod +x "$test_root/bin/mktemp"
    expect_failure unwritable-parent env PATH="$test_root/bin:$PATH" bash "$prepare" "$cache_home" "$blocked_parent"
    rm -f -- "$test_root/bin/mktemp"
fi
chmod 700 "$blocked_parent"
[[ -z "$(ls -A -- "$blocked_parent")" ]] || fail 'failed setup left a home'

# Fail the second symlink after the first was created, then verify cleanup only
# removed this invocation's staging directory, not existing homes or cache data.
export FIXTURE_LN_BIN="$(command -v ln)"
printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' \
    '[[ "${@: -1}" != */wrapper ]] || exit 73' \
    'exec "$FIXTURE_LN_BIN" "$@"' > "$test_root/bin/ln"
chmod +x "$test_root/bin/ln"
before_homes="$(printf '%s\n' "$isolated_parent"/*)"
expect_failure partial-setup env PATH="$test_root/bin:$PATH" bash "$prepare" "$cache_home" "$isolated_parent"
[[ "$(printf '%s\n' "$isolated_parent"/*)" == "$before_homes" ]] || fail 'partial home was not cleaned'
[[ -f "$first_home/gradle.properties" ]] || fail 'an existing isolated home was removed'
assert_clean_home "$second_home"
[[ "$(source_snapshot)" == "$original_snapshot" ]] || fail 'failure cleanup changed original data'

# Cold caches are created in place, without adding global init/properties files.
cold_cache="$test_root/cold cache"
cold_home="$(bash "$prepare" "$cold_cache" "$test_root/cold homes" 2> "$test_root/cold.log")"
[[ -d "$cold_cache/caches" && -d "$cold_cache/wrapper" ]] || fail 'cold cache directories missing'
[[ "$(readlink -- "$cold_home/caches")" == "$cold_cache/caches" ]] || fail 'cold cache link missing'
[[ "$(readlink -- "$cold_home/wrapper")" == "$cold_cache/wrapper" ]] || fail 'cold wrapper link missing'
[[ "$(<"$test_root/cold.log")" == *'init.gradle=0 init.gradle.kts=0 init.d=0 gradle.properties=0'* ]] || fail 'cold configuration diagnosis incorrect'
echo 'Gradle user-home isolation filesystem regressions passed'
