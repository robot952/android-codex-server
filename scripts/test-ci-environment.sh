#!/usr/bin/env bash
set -euo pipefail

# Isolated entry-point and timeout regressions. No SDK/network/APK work.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
# Timeout-failure fixtures must own their groups rather than kill this test.
unset CODEX_CI_PROCESS_GROUP CODEX_CI_GRADLE_BOUNDED CODEX_RELEASE_BUILD_MODE CODEX_RELEASE_BRANCH FAIL_PHASE
unset CODEX_CI_HOSTED_DEPENDENCIES CODEX_CI_MAVEN_REPOSITORY
unset PAIR_STALL PAIR_CANCEL
# The isolated tag entry stops at its fake build, before release publication.
export CODEX_RELEASE_TOKEN=fixture-token-not-a-secret
entry="$fixture/repo"
mkdir -p "$entry/scripts" "$entry/node/bin" "$entry/flutter/bin" "$entry/android/platform-tools" "$entry/dist" "$fixture/home"
cp "$ROOT_DIR/scripts/prepare-ci-environment.sh" "$ROOT_DIR/scripts/run-ci-stage.sh" \
    "$ROOT_DIR/scripts/prepare-ci-sdk-pair.sh" \
    "$ROOT_DIR/scripts/prepare-ci-gradle-home.sh" \
    "$ROOT_DIR/scripts/ci-flutter-repositories.init.gradle" \
    "$ROOT_DIR/scripts/build-gitee-release.sh" "$ROOT_DIR/scripts/publish-tag-release.sh" "$entry/scripts/"
export WORKSPACE="$entry" HOME="$fixture/home" FIXTURE_STAGES="$fixture/stages"
export PUB_CACHE="$fixture/custom-pub" GRADLE_USER_HOME="$fixture/custom-gradle"
export FIXTURE_GRADLE_CACHE="$GRADLE_USER_HOME"
mkdir -p "$GRADLE_USER_HOME/init.d"
printf 'throw new GradleException("inherited init must not run")\n' > "$GRADLE_USER_HOME/init.d/injected.gradle"
printf '.workflow-cache/\n' > "$entry/.gitignore"
export GRADLE_OPTS=-Dfixture=keep
export FLUTTER_STORAGE_BASE_URL=https://fixture.invalid/flutter PUB_HOSTED_URL=https://fixture.invalid/pub
export FIXTURE_BARRIER="$fixture/barrier"
mkdir -p "$FIXTURE_BARRIER"
cat > "$entry/scripts/pair-barrier.sh" <<'SH'
touch "$FIXTURE_BARRIER/$1"
for attempt in {1..100}; do
    [[ ! -e "$FIXTURE_BARRIER/flutter" || ! -e "$FIXTURE_BARRIER/android" ]] || break
    sleep 0.02
done
[[ -e "$FIXTURE_BARRIER/flutter" && -e "$FIXTURE_BARRIER/android" ]]
if [[ "${PAIR_STALL:-}" == "$1" ]]; then
    bash -c 'trap "" TERM; exec sleep 120' &
    printf '%s\n' "$!" > "$FIXTURE_BARRIER/child.pid"
    wait "$!"
elif [[ -n "${PAIR_STALL:-}" ]]; then
    for attempt in {1..100}; do
        [[ ! -s "$FIXTURE_BARRIER/child.pid" ]] || break
        sleep 0.02
    done
    [[ -s "$FIXTURE_BARRIER/child.pid" ]]
    if [[ "${PAIR_CANCEL:-0}" == 1 ]]; then sleep 120; fi
    exit 42
fi
SH
cat > "$entry/scripts/prepare-ci-node.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo node >> "$FIXTURE_STAGES"
[[ "${FAIL_PHASE:-}" != node ]] || exit 42
[[ "$1" == "$HOME/.cache/codex/node" ]]
printf '%s\n' "$WORKSPACE/node/bin"
SH
cat > "$entry/node/bin/node" <<'SH'
#!/bin/sh
printf 'v22.17.0\n'
SH
cat > "$entry/scripts/prepare-ci-flutter.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo flutter >> "$FIXTURE_STAGES"
source "$WORKSPACE/scripts/pair-barrier.sh" flutter
[[ "${FAIL_PHASE:-}" != flutter ]] || exit 42
[[ "$(command -v node)" == "$WORKSPACE/node/bin/node" && "$(node --version)" == v22.17.0 ]]
[[ "$2" == 3.44.8 && "$3" == 058e0af2c2b57e369d905a03ac9748b0ebf543c6 ]]
[[ "$4" == https://fixture.invalid/flutter/* && "$5" == 672089e001571a9fbb209a495c583580c0c6c73ef98999264ba07fa93ace332d ]]
printf '%s\n' "$WORKSPACE/flutter"
SH
cat > "$entry/scripts/prepare-ci-maven.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo maven >> "$FIXTURE_STAGES"
[[ "${FAIL_PHASE:-}" != maven ]] || exit 42
[[ "$CODEX_CI_HOSTED_DEPENDENCIES" == 1 ]]
[[ "$1" == "$HOME/.cache/codex/maven" && "$2" == "$WORKSPACE/.workflow-cache/maven-repositories" ]]
printf '%s\n' "$WORKSPACE/hosted-maven"
SH
cat > "$entry/scripts/prepare-ci-android.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo android >> "$FIXTURE_STAGES"
source "$WORKSPACE/scripts/pair-barrier.sh" android
[[ "${FAIL_PHASE:-}" != android ]] || exit 42
printf '%s\n' "$WORKSPACE/android"
SH
cat > "$entry/scripts/prepare-ci-gradle.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo gradle >> "$FIXTURE_STAGES"
[[ "${FAIL_PHASE:-}" != gradle ]] || exit 42
[[ "$1" == "$HOME/.cache/codex/gradle" ]]
[[ "$2" == "$WORKSPACE/flutter_app/android/gradle/wrapper/gradle-wrapper.properties" ]]
[[ "$ANDROID_HOME" == "$WORKSPACE/android" && "$ANDROID_SDK_ROOT" == "$ANDROID_HOME" ]]
[[ "$CODEX_CI_GRADLE_BOUNDED" == 1 && "$CODEX_CI_PROCESS_GROUP" =~ ^[1-9][0-9]*$ ]]
[[ "$GRADLE_USER_HOME" == "$WORKSPACE/.workflow-cache/gradle-user-homes/"* ]]
[[ "$(readlink "$GRADLE_USER_HOME/caches")" == "$FIXTURE_GRADLE_CACHE/caches" ]]
[[ "$(readlink "$GRADLE_USER_HOME/wrapper")" == "$FIXTURE_GRADLE_CACHE/wrapper" ]]
[[ ! -e "$GRADLE_USER_HOME/gradle.properties" && ! -e "$GRADLE_USER_HOME/init.d/injected.gradle" ]]
cmp "$WORKSPACE/scripts/ci-flutter-repositories.init.gradle" "$GRADLE_USER_HOME/init.d/codex-flutter-repositories.gradle"
echo fixture.zip
SH
cat > "$entry/flutter/bin/flutter" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo precache >> "$FIXTURE_STAGES"
[[ "${FAIL_PHASE:-}" != precache ]] || exit 42
[[ "$*" == 'precache --android' ]]
[[ "$(command -v node)" == "$WORKSPACE/node/bin/node" ]]
SH
cat > "$entry/scripts/test-ci-gradle-repositories.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo repository-preflight >> "$FIXTURE_STAGES"
[[ "${FAIL_PHASE:-}" != repository-preflight ]] || exit 42
[[ "$GRADLE_USER_HOME" == "$WORKSPACE/.workflow-cache/gradle-user-homes/"* ]]
SH
cat > "$entry/scripts/publish-gitee-release.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$CODEX_RELEASE_BRANCH" == flutter-refactor ]]
[[ "$CODEX_CI_PUB" == 1 && "$CODEX_BUILD_ONLINE" == 1 ]]
[[ "$CODEX_CI_MAVEN_MIRRORS" == 1 && "$CODEX_CI_APK_BUILD_TIMEOUT" == 1200 ]]
[[ "$CODEX_CI_MAVEN_REPOSITORY" == "$WORKSPACE/hosted-maven" && "$CODEX_CI_HOSTED_DEPENDENCIES" == 1 ]]
[[ "$GRADLE_OPTS" == '-Dfixture=keep -Dorg.gradle.daemon=false -Dorg.gradle.internal.http.connectionTimeout=30000 -Dorg.gradle.internal.http.socketTimeout=30000' ]]
[[ "$PATH" == "$ANDROID_HOME/cmake/3.22.1/bin:$ANDROID_HOME/platform-tools:"* ]]
[[ "$PUB_CACHE" == */custom-pub ]]
[[ "$GRADLE_USER_HOME" == "$WORKSPACE/.workflow-cache/gradle-user-homes/"* ]]
[[ "$(command -v node)" == "$WORKSPACE/node/bin/node" ]]
echo publish >> "$FIXTURE_STAGES"
SH
chmod +x "$entry/node/bin/node" "$entry/flutter/bin/flutter" "$entry/scripts/publish-gitee-release.sh"
bash "$entry/scripts/build-gitee-release.sh" flutter-refactor >"$fixture/entry.log" 2>&1
assert_prepared_order() {
    [[ "$(grep -v '^flutter$' "$FIXTURE_STAGES" | tr '\n' ' ')" == "node maven android gradle repository-preflight precache $1 " ]]
    [[ "$(grep -cx flutter "$FIXTURE_STAGES")" == 1 ]]
    [[ "$(sed -n '/repository-preflight/,$p' "$FIXTURE_STAGES" | tr '\n' ' ')" == "repository-preflight precache $1 " ]]
}
assert_prepared_order publish

for phase in node maven flutter android gradle repository-preflight precache; do
    : > "$FIXTURE_STAGES"
    status=0
    FAIL_PHASE="$phase" bash "$entry/scripts/build-gitee-release.sh" flutter-refactor >"$fixture/failure.log" 2>&1 || status=$?
    [[ "$status" == 42 ]]
    ! grep -qx publish "$FIXTURE_STAGES"
    case "$phase" in
        node|maven) [[ "$(tail -n 1 "$FIXTURE_STAGES")" == "$phase" ]] ;;
        flutter|android|gradle) ! grep -qx repository-preflight "$FIXTURE_STAGES" ;;
        repository-preflight) ! grep -qx precache "$FIXTURE_STAGES" ;;
    esac
done

# Either failed lane must return its status immediately and reap an ignoring
# peer. Exercise a standalone entry and the nested release process group.
for stalled_lane in flutter android; do
    for supervision in direct nested cancel; do
        rm -f "$FIXTURE_BARRIER/child.pid"
        : > "$FIXTURE_STAGES"
        status=0
        case "$supervision" in
            direct)
                PAIR_STALL="$stalled_lane" bash "$entry/scripts/build-gitee-release.sh" flutter-refactor >"$fixture/pair.log" 2>&1 || status=$?
                [[ "$status" == 42 ]] ;;
            nested)
                PAIR_STALL="$stalled_lane" bash "$ROOT_DIR/scripts/run-ci-stage.sh" pair-fixture 10 \
                    bash "$entry/scripts/build-gitee-release.sh" flutter-refactor >"$fixture/pair.log" 2>&1 || status=$?
                [[ "$status" == 42 ]] ;;
            cancel)
                PAIR_STALL="$stalled_lane" PAIR_CANCEL=1 bash "$ROOT_DIR/scripts/run-ci-stage.sh" pair-cancel 2 \
                    bash "$entry/scripts/build-gitee-release.sh" flutter-refactor >"$fixture/pair.log" 2>&1 || status=$?
                [[ "$status" == 124 || "$status" == 137 ]] ;;
        esac
        [[ -s "$FIXTURE_BARRIER/child.pid" ]]
        child="$(<"$FIXTURE_BARRIER/child.pid")"
        for attempt in {1..20}; do
            state="$(ps -o stat= -p "$child" 2>/dev/null || true)"
            [[ -n "$state" && "$state" != Z* ]] || break
            sleep 0.1
        done
        [[ -z "$state" || "$state" == Z* ]]
        ! grep -qx repository-preflight "$FIXTURE_STAGES"
    done
done

# An exhausted shared budget must reject work before launching either SDK.
: > "$FIXTURE_STAGES"
status=0
mkdir -p "$fixture/expired-paths"
FLUTTER_VERSION=3.44.8 FLUTTER_REVISION=fixture \
    bash "$ROOT_DIR/scripts/run-ci-stage.sh" expired-pair 10 \
    bash "$entry/scripts/prepare-ci-sdk-pair.sh" "$entry" "$fixture/expired-paths" 1 \
    >"$fixture/expired.log" 2>&1 || status=$?
[[ "$status" == 124 || "$status" == 137 ]]
[[ ! -s "$FIXTURE_STAGES" ]]

# A failed home isolation must stop before downloading or publishing anything.
: > "$FIXTURE_STAGES"
printf 'not a directory\n' > "$fixture/invalid-gradle-home"
status=0
GRADLE_USER_HOME="$fixture/invalid-gradle-home" bash "$entry/scripts/build-gitee-release.sh" flutter-refactor >"$fixture/home-failure.log" 2>&1 || status=$?
[[ "$status" != 0 && ! -s "$FIXTURE_STAGES" ]]

# Prove a tag cannot bypass preparation, and invalid/dirty tags never download.
cat > "$entry/scripts/apk-lib.sh" <<'SH'
apk_version_name() { printf '1.2.3\n'; }
SH
cat > "$entry/scripts/android-sdk.sh" <<'SH'
resolve_android_sdk() { [[ "$ANDROID_HOME" == "$WORKSPACE/android" ]]; }
SH
cat > "$entry/scripts/build-android.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == 'all --force' && "$CODEX_CI_PUB" == 1 ]]
[[ "$(command -v node)" == "$WORKSPACE/node/bin/node" && "$(node --version)" == v22.17.0 ]]
[[ "$GRADLE_USER_HOME" == "$WORKSPACE/.workflow-cache/gradle-user-homes/"* ]]
[[ "$(readlink "$GRADLE_USER_HOME/wrapper")" == "$FIXTURE_GRADLE_CACHE/wrapper" ]]
echo build >> "$FIXTURE_STAGES"
# Stop before packaging: this regression never creates/publishes an APK.
exit 43
SH
chmod +x "$entry/scripts/build-android.sh"
git -C "$entry" init --quiet
git -C "$entry" add .
git -C "$entry" -c user.name=Fixture -c user.email=fixture@example.invalid commit --quiet -m fixture
older_commit="$(git -C "$entry" rev-parse HEAD)"
git -C "$entry" -c user.name=Fixture -c user.email=fixture@example.invalid commit --quiet --allow-empty -m release
: > "$FIXTURE_STAGES"
status=0
bash "$entry/scripts/publish-tag-release.sh" >"$fixture/tag.log" 2>&1 || status=$?
[[ "$status" == 1 && ! -s "$FIXTURE_STAGES" ]]
git -C "$entry" tag v1.2.3
for missing_token in '' '   '; do
    status=0
    CODEX_RELEASE_TOKEN="$missing_token" bash "$entry/scripts/publish-tag-release.sh" >"$fixture/tag.log" 2>&1 || status=$?
    [[ "$status" == 2 && ! -s "$FIXTURE_STAGES" ]]
    grep -Fq 'CODEX_RELEASE_TOKEN is required' "$fixture/tag.log"
done
status=0
bash "$entry/scripts/publish-tag-release.sh" >"$fixture/tag.log" 2>&1 || status=$?
[[ "$status" == 43 ]]
assert_prepared_order build
: > "$FIXTURE_STAGES"
status=0
CODEX_RELEASE_BUILD_MODE=invalid bash "$entry/scripts/publish-tag-release.sh" >"$fixture/tag.log" 2>&1 || status=$?
[[ "$status" == 2 && ! -s "$FIXTURE_STAGES" ]]

# Real file:// shallow clones reproduce Gitee's commit-only checkout without
# contacting a hosting service. All transport commands have the same deadline.
stage="$ROOT_DIR/scripts/run-ci-stage.sh"
origin="$fixture/origin.git"
bash "$stage" fixture-origin 60 git clone --quiet --bare "$entry" "$origin" >"$fixture/clone.log" 2>&1
clone_release_fixture() {
    local destination="$1" remote="$2"
    bash "$stage" fixture-clone 60 env GIT_TERMINAL_PROMPT=0 git clone \
        --quiet --no-tags --depth=1 "file://$remote" "$destination" >"$fixture/clone.log" 2>&1
    [[ "$(git -C "$destination" rev-parse --is-shallow-repository)" == true ]]
    [[ -z "$(git -C "$destination" tag --list)" ]]
}
assert_release_status() {
    local checkout="$1" expected="$2"
    : > "$FIXTURE_STAGES"
    status=0
    WORKSPACE="$checkout" bash "$checkout/scripts/publish-tag-release.sh" >"$fixture/tag.log" 2>&1 || status=$?
    if [[ "$status" != "$expected" ]]; then
        cat "$fixture/tag.log" >&2
        echo "Expected release status $expected, got $status" >&2
        exit 1
    fi
}

shallow="$fixture/shallow"
clone_release_fixture "$shallow" "$origin"
assert_release_status "$shallow" 43
assert_prepared_order build
[[ "$(git -C "$shallow" rev-parse 'FETCH_HEAD^{commit}')" == "$(git -C "$shallow" rev-parse HEAD)" ]]
[[ -z "$(git -C "$shallow" tag --list)" ]]

# These wrong/missing refs exist only in isolated bare fixture repositories.
wrong_origin="$fixture/wrong-origin.git"
bash "$stage" fixture-origin 60 git clone --quiet --bare "$entry" "$wrong_origin" >"$fixture/clone.log" 2>&1
git --git-dir="$wrong_origin" update-ref refs/tags/v1.2.3 "$older_commit"
wrong_checkout="$fixture/wrong-tag"
clone_release_fixture "$wrong_checkout" "$wrong_origin"
assert_release_status "$wrong_checkout" 1
[[ ! -s "$FIXTURE_STAGES" && -z "$(git -C "$wrong_checkout" tag --list)" ]]

missing_origin="$fixture/missing-origin.git"
bash "$stage" fixture-origin 60 git clone --quiet --bare "$entry" "$missing_origin" >"$fixture/clone.log" 2>&1
git --git-dir="$missing_origin" update-ref -d refs/tags/v1.2.3
missing_checkout="$fixture/missing-tag"
clone_release_fixture "$missing_checkout" "$missing_origin"
# A previous successful fetch at HEAD must not authorize a later missing tag;
# a same-named branch must not be accepted instead of the exact tag either.
bash "$stage" fixture-fetch 60 git -C "$missing_checkout" fetch --quiet --no-tags origin HEAD >"$fixture/clone.log" 2>&1
[[ "$(git -C "$missing_checkout" rev-parse 'FETCH_HEAD^{commit}')" == "$(git -C "$missing_checkout" rev-parse HEAD)" ]]
git -C "$missing_checkout" branch v1.2.3
assert_release_status "$missing_checkout" 128
[[ ! -s "$FIXTURE_STAGES" && -z "$(git -C "$missing_checkout" tag --list)" ]]

local_wrong="$fixture/local-wrong-tag"
bash "$stage" fixture-clone 60 git clone --quiet --no-tags "file://$origin" "$local_wrong" >"$fixture/clone.log" 2>&1
git -C "$local_wrong" tag v1.2.3 "$older_commit"
assert_release_status "$local_wrong" 1
[[ ! -s "$FIXTURE_STAGES" ]]
[[ "$(git -C "$local_wrong" rev-parse 'refs/tags/v1.2.3^{commit}')" == "$older_commit" ]]

# Annotated tags fetched without local refs still peel to the release commit.
annotated_origin="$fixture/annotated-origin.git"
bash "$stage" fixture-origin 60 git clone --quiet --bare --no-tags "$entry" "$annotated_origin" >"$fixture/clone.log" 2>&1
git --git-dir="$annotated_origin" update-ref -d refs/tags/v1.2.3
git --git-dir="$annotated_origin" -c user.name=Fixture -c user.email=fixture@example.invalid tag -a v1.2.3 -m release
annotated_checkout="$fixture/annotated-tag"
clone_release_fixture "$annotated_checkout" "$annotated_origin"
assert_release_status "$annotated_checkout" 43
assert_prepared_order build
[[ -z "$(git -C "$annotated_checkout" tag --list)" ]]

: > "$FIXTURE_STAGES"
printf '\n# dirty fixture\n' >> "$entry/scripts/build-android.sh"
status=0
bash "$entry/scripts/publish-tag-release.sh" >"$fixture/tag.log" 2>&1 || status=$?
[[ "$status" == 1 && ! -s "$FIXTURE_STAGES" ]]

stage="$ROOT_DIR/scripts/run-ci-stage.sh"
[[ "$(bash "$stage" output 10 printf path)" == path ]]
status=0
bash "$stage" failure 10 bash -c 'exit 42' 2>"$fixture/stage.log" || status=$?
[[ "$status" == 42 ]]
status=0
bash "$stage" invalid 0 true 2>"$fixture/stage.log" || status=$?
[[ "$status" == 2 ]]
status=0
CODEX_CI_PROCESS_GROUP=1 bash "$stage" unsafe-group 10 true 2>"$fixture/stage.log" || status=$?
[[ "$status" == 2 ]]

# A TERM-responsive parent with a TERM-ignoring child must not leak that child
# when timeout returns early, either at a nested deadline or outer cancellation.
cat > "$fixture/stalled.sh" <<'SH'
#!/usr/bin/env bash
trap 'exit 143' TERM
bash -c 'trap "" TERM; exec sleep 120' &
printf '%s\n' "$!" > "$FIXTURE_CHILD"
while :; do sleep 0.1; done
SH
export FIXTURE_CHILD="$fixture/child.pid"
for mode in direct nested outer; do
    rm -f "$FIXTURE_CHILD"
    status=0
    case "$mode" in
        direct) bash "$stage" direct 1 bash "$fixture/stalled.sh" >"$fixture/stage.log" 2>&1 || status=$? ;;
        nested) bash "$stage" outer 20 bash "$stage" inner 1 bash "$fixture/stalled.sh" >"$fixture/stage.log" 2>&1 || status=$? ;;
        outer) bash "$stage" outer 1 bash "$stage" inner 20 bash "$fixture/stalled.sh" >"$fixture/stage.log" 2>&1 || status=$? ;;
    esac
    [[ "$status" == 124 || "$status" == 137 ]]
    [[ -s "$FIXTURE_CHILD" ]]
    child="$(cat "$FIXTURE_CHILD")"
    for attempt in {1..20}; do
        state="$(ps -o stat= -p "$child" 2>/dev/null || true)"
        [[ -n "$state" && "$state" != Z* ]] || break
        sleep 0.1
    done
    [[ -z "$state" || "$state" == Z* ]] || { echo "Leaked child after $mode timeout" >&2; exit 1; }
done
bash "$ROOT_DIR/scripts/test-ci-node.sh"
bash "$ROOT_DIR/scripts/test-ci-gradle-home.sh"
bash "$ROOT_DIR/scripts/test-gitee-pipeline.sh"
echo 'CI environment, tag validation and bounded cancellation regressions passed'
