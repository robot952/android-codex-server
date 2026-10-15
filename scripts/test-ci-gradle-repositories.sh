#!/usr/bin/env bash
set -euo pipefail

# Run only in CI, after prepare-ci-gradle.sh, inside a 240-second run-ci-stage.
# This fixture compiles one local Settings plugin, never an APK or external
# dependency. Launch a private copy of the pinned distribution directly: the
# legacy root Wrapper cannot bootstrap Gradle 9.1's relocated CLI entry point.
# Keep both Gradle invocations inside the caller's process group.
ROOT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
fail() { echo "CI Gradle repository isolation: $*" >&2; exit 1; }
[[ "$#" == 0 ]] || fail 'no arguments are supported'
[[ -n "${GRADLE_USER_HOME:-}" ]] || fail 'prepare the CI Gradle user home first'
for tool in java jar git sha256sum grep unzip; do
    command -v "$tool" >/dev/null || fail "required tool is missing: $tool"
done

# A system property wins over GRADLE_USER_HOME. Reject that ambiguity without
# displaying inherited JVM arguments, which may contain proxy credentials.
for name in GRADLE_OPTS JAVA_OPTS JAVA_TOOL_OPTIONS JDK_JAVA_OPTIONS _JAVA_OPTIONS; do
    [[ "${!name:-}" != *gradle.user.home* ]] || fail 'an inherited JVM option overrides the isolated Gradle user home'
done
cache_home="$(CDPATH= cd -- "$GRADLE_USER_HOME" && pwd -P)"
[[ -d "$cache_home/wrapper" && -d "$cache_home/caches" ]] || fail 'prepared wrapper/cache directories are missing'
wrapper_cache="$(CDPATH= cd -- "$cache_home/wrapper" && pwd -P)"
dependency_cache="$(CDPATH= cd -- "$cache_home/caches" && pwd -P)"
git -C "$ROOT_DIR" ls-files --error-unmatch \
    flutter_app/android/gradle/wrapper/gradle-wrapper.properties >/dev/null 2>&1 || fail 'tracked distribution properties are missing'

mkdir -p -- "$ROOT_DIR/.workflow-cache"
fixture="$(mktemp -d "$ROOT_DIR/.workflow-cache/ci-gradle-repositories.XXXXXX")"
cleanup() {
    local status=$? attempt
    # A --no-daemon single-use Gradle process can still be closing its private
    # registry just after the client returns. Bound this cleanup race instead
    # of turning a passing routing check into an intermittent CI failure.
    for attempt in 1 2 3 4 5; do
        if rm -rf -- "$fixture" 2>/dev/null; then return "$status"; fi
        sleep 1
    done
    echo 'CI Gradle fixture cleanup did not finish within 5 attempts' >&2
    (( status != 0 )) && return "$status"
    return 1
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
project="$fixture/project"
old_home="$fixture/old-home"
export FLUTTER_ROOT="$fixture/flutter sdk"
flutter_build="$FLUTTER_ROOT/packages/flutter_tools/gradle"
mkdir -p "$project/gradle/wrapper" "$flutter_build/src/main/java/fixture" "$project/fixture-plugin" "$old_home"
cp "$ROOT_DIR/flutter_app/android/gradle/wrapper/gradle-wrapper.properties" \
    "$project/gradle/wrapper/gradle-wrapper.properties"
ln -s -- "$wrapper_cache" "$old_home/wrapper"
ln -s -- "$dependency_cache" "$old_home/caches"

# Require the ZIP prefilled by prepare-ci-gradle.sh under the exact pinned URL's
# MD5/base36 cache identity. Never invoke or download through the legacy Wrapper.
# Still check shared distribution init.d for the subsequent real Flutter build;
# only inspect filenames, never read platform initialization code.
cat > "$fixture/CheckPreparedWrapper.java" <<'JAVA'
import java.io.InputStream;
import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.HexFormat;
import java.util.Properties;

class CheckPreparedWrapper {
    private static final String VERSION = "9.1.0";
    private static final String URL = "https://services.gradle.org/distributions/gradle-9.1.0-all.zip";
    private static final String SHA = "b84e04fa845fecba48551f425957641074fcc00a88a84d2aae5808743b35fc85";

    static void require(boolean condition, String message) {
        if (!condition) throw new IllegalStateException(message);
    }

    static boolean validZip(Path zip) throws Exception {
        if (!Files.isRegularFile(zip)) return false;
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        try (InputStream input = Files.newInputStream(zip)) {
            byte[] bytes = new byte[65536];
            for (int count; (count = input.read(bytes)) != -1;) digest.update(bytes, 0, count);
        }
        return SHA.equals(HexFormat.of().formatHex(digest.digest()));
    }

    static Path check(String[] args) throws Exception {
        Properties properties = new Properties();
        try (InputStream input = Files.newInputStream(Path.of(args[0]))) { properties.load(input); }
        require(URL.equals(properties.getProperty("distributionUrl")) &&
            SHA.equals(properties.getProperty("distributionSha256Sum")), "unexpected distribution pin");
        for (String key : new String[]{"distributionBase", "zipStoreBase"})
            require("GRADLE_USER_HOME".equals(properties.getProperty(key)), "unexpected cache base");
        for (String key : new String[]{"distributionPath", "zipStorePath"})
            require("wrapper/dists".equals(properties.getProperty(key)), "unexpected cache layout");
        String hash = new BigInteger(1, MessageDigest.getInstance("MD5")
            .digest(URL.getBytes(StandardCharsets.UTF_8))).toString(36);
        Path directory = Path.of(args[1]).resolve("dists/gradle-" + VERSION + "-all").resolve(hash);
        require(Files.isDirectory(directory), "pinned wrapper cache is absent; refusing a network download");
        Path distribution = directory.resolve("gradle-" + VERSION);
        try (var entries = Files.list(directory)) {
            for (Path entry : entries.filter(Files::isDirectory).toList()) {
                require(entry.equals(distribution) && !Files.isSymbolicLink(entry), "unexpected extracted distribution layout");
            }
        }
        Path init = distribution.resolve("init.d");
        require(!Files.isSymbolicLink(init), "distribution init directory is redirected");
        if (Files.isDirectory(init)) {
            try (var entries = Files.list(init)) {
                require(entries.noneMatch(path -> {
                    String name = path.getFileName().toString();
                    return name.endsWith(".gradle") || name.endsWith(".gradle.kts");
                }), "distribution contains initialization scripts; refusing shared wrapper reuse");
            }
        }
        Path zip = directory.resolve("gradle-" + VERSION + "-all.zip");
        require(validZip(zip), "verified prefilled distribution ZIP is missing or invalid; refusing a network download");
        return zip;
    }

    public static void main(String[] args) {
        try { System.out.println(check(args)); }
        catch (Exception error) {
            // Do not emit paths, configuration contents, or a JVM stack trace.
            System.err.println("CI Gradle wrapper preflight failed: " +
                (error instanceof IllegalStateException ? error.getMessage() : "cannot validate the prepared distribution"));
            System.exit(1);
        }
    }
}
JAVA
check_wrapper() {
    env -u JAVA_TOOL_OPTIONS -u JDK_JAVA_OPTIONS -u _JAVA_OPTIONS \
        java "$fixture/CheckPreparedWrapper.java" "$project/gradle/wrapper/gradle-wrapper.properties" "$wrapper_cache"
}
distribution_archive="$(check_wrapper)"
mkdir -p "$fixture/runtime"
if ! unzip -q "$distribution_archive" -d "$fixture/runtime" > "$fixture/unzip.log" 2>&1; then
    fail 'could not extract the verified distribution into the private fixture directory'
fi
private_gradle="$fixture/runtime/gradle-9.1.0/bin/gradle"
[[ -f "$private_gradle" ]] || fail 'the verified distribution has no Gradle launcher'

negative_marker=CODEX_FIXTURE_OLD_GRADLE_INIT_EXECUTED
printf 'throw new GradleException("%s")\n' "$negative_marker" > "$old_home/init.gradle"
init_sha="$(sha256sum "$old_home/init.gradle" | cut -d ' ' -f 1)"
export CODEX_FIXTURE_INCLUDED_MARKER="$fixture/included-build.marker"
export CODEX_FIXTURE_PLUGIN_MARKER="$fixture/settings-plugin.marker"
export CODEX_FIXTURE_REPOSITORY_MARKER="$fixture/project-repositories.marker"
export CODEX_FIXTURE_REPOSITORY_POLICY="$ROOT_DIR/flutter_app/android/ci-repositories.gradle"
export CODEX_FIXTURE_MAVEN_ROOT="$fixture/maven"
export CODEX_FIXTURE_KOTLIN_MARKER="$fixture/kotlin-routing.marker"

# Real offline dependency resolution, not repository-order assertions alone.
# Duplicate poison artifacts make consulting the wrong repository observable.
write_module() {
    local repository="$1" group="$2" artifact="$3" content="$4"
    local directory="$CODEX_FIXTURE_MAVEN_ROOT/$repository/${group//.//}/$artifact/0.0-fixture"
    mkdir -p "$directory"
    printf '<project><modelVersion>4.0.0</modelVersion><groupId>%s</groupId><artifactId>%s</artifactId><version>0.0-fixture</version></project>\n' \
        "$group" "$artifact" > "$directory/$artifact-0.0-fixture.pom"
    printf '%s' "$content" > "$fixture/module.txt"
    jar --create --file "$directory/$artifact-0.0-fixture.jar" -C "$fixture" module.txt
}
for artifact in armeabi_v7a_release arm64_v8a_release x86_64_release flutter_embedding_release; do
    write_module flutter io.flutter "$artifact" flutter-engine
    write_module google io.flutter "$artifact" WRONG-GOOGLE
    write_module central io.flutter "$artifact" WRONG-CENTRAL
done
write_module central org.jetbrains.kotlin kotlin-assignment-compiler-plugin-embeddable kotlin-central
write_module google org.jetbrains.kotlin kotlin-assignment-compiler-plugin-embeddable WRONG-GOOGLE
write_module google com.android.fixture android-library android-google
write_module central com.android.fixture android-library WRONG-CENTRAL
write_module central org.example.fixture ordinary-library ordinary-central

cat > "$project/settings.gradle" <<'GROOVY'
pluginManagement { includeBuild(System.getenv('FLUTTER_ROOT') + '/packages/flutter_tools/gradle') }
plugins { id 'codex.fixture.settings-loader' }
rootProject.name = 'gradle-repository-isolation-fixture'
include ':fixture-plugin'
GROOVY
cat > "$project/build.gradle" <<'GROOVY'
apply from: System.getenv('CODEX_FIXTURE_REPOSITORY_POLICY')
tasks.named('help') {
    dependsOn ':fixture-plugin:verifyRouting'
    doLast { println 'CODEX_FIXTURE_ISOLATED_GRADLE_HELP_OK' }
}
GROOVY
cat > "$project/fixture-plugin/build.gradle" <<'GROOVY'
// Model a Flutter plugin's legacy classpath repositories. Mirrors must already
// be present at buildscript evaluation time, before dependency resolution.
buildscript {
    repositories { google(); mavenCentral() }
    def expected = ['google', 'central', 'gradle-plugin'].collect {
        'https://maven.aliyun.com/repository/' + it
    }
    assert repositories.take(3).collect { it.url.toString() } == expected
    repositories.each { repository ->
        def kind = repository.url.toString().contains('google') ? 'google' : 'central'
        repository.url = new File(System.getenv('CODEX_FIXTURE_MAVEN_ROOT'), kind).toURI()
    }
    dependencies { classpath 'org.jetbrains.kotlin:kotlin-assignment-compiler-plugin-embeddable:0.0-fixture' }
    assert configurations.classpath.files.every { artifact ->
        new java.util.zip.ZipFile(artifact).withCloseable { it.getInputStream(it.getEntry('module.txt')).text } == 'kotlin-central'
    }
}
repositories {
    google(); mavenCentral()
    // Flutter adds its own engine repository during plugin application too.
    maven { url = uri((System.getenv('FLUTTER_STORAGE_BASE_URL') ?: 'https://storage.flutter-io.cn') + '/download.flutter.io') }
}
assert repositories.take(2).collect { it.url.toString() } == [
    'https://maven.aliyun.com/repository/google',
    'https://maven.aliyun.com/repository/central'
]
repositories.each { repository ->
    def url = repository.url.toString()
    def kind = url.endsWith('/download.flutter.io') ? 'flutter' : url.contains('google') ? 'google' : 'central'
    repository.url = new File(System.getenv('CODEX_FIXTURE_MAVEN_ROOT'), kind).toURI()
}
configurations { routing }
dependencies {
    ['armeabi_v7a_release', 'arm64_v8a_release', 'x86_64_release', 'flutter_embedding_release'].each {
        routing "io.flutter:$it:0.0-fixture"
    }
    routing 'org.jetbrains.kotlin:kotlin-assignment-compiler-plugin-embeddable:0.0-fixture'
    routing 'com.android.fixture:android-library:0.0-fixture'
    routing 'org.example.fixture:ordinary-library:0.0-fixture'
}
tasks.register('verifyRouting') {
    doLast {
        def actual = configurations.routing.files.collect { artifact ->
            new java.util.zip.ZipFile(artifact).withCloseable { it.getInputStream(it.getEntry('module.txt')).text }
        }.sort()
        assert actual == ['flutter-engine', 'flutter-engine', 'flutter-engine', 'flutter-engine',
            'kotlin-central', 'android-google', 'ordinary-central'].sort()
    }
}
new File(System.getenv('CODEX_FIXTURE_REPOSITORY_MARKER')).text = 'mirrors-before-official\n'
GROOVY
cat > "$flutter_build/settings.gradle" <<'GROOVY'
import org.gradle.api.initialization.resolve.RepositoriesMode
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories { google(); mavenCentral() }
}
gradle.settingsEvaluated { settings ->
    assert settings.pluginManagement.repositories.take(3).collect { it.url.toString() } == [
        'https://maven.aliyun.com/repository/google',
        'https://maven.aliyun.com/repository/central',
        'https://maven.aliyun.com/repository/gradle-plugin'
    ]
    settings.dependencyResolutionManagement.repositories.each { repository ->
        def kind = repository.url.toString().contains('google') ? 'google' : 'central'
        repository.url = new File(System.getenv('CODEX_FIXTURE_MAVEN_ROOT'), kind).toURI()
    }
}
rootProject.name = 'fixture-settings-loader'
new File(System.getenv('CODEX_FIXTURE_INCLUDED_MARKER')).text =
    dependencyResolutionManagement.repositoriesMode.get().name() + '\n'
GROOVY
cat > "$flutter_build/build.gradle" <<'GROOVY'
plugins { id 'java-gradle-plugin' }
configurations { routing }
dependencies { routing 'org.jetbrains.kotlin:kotlin-assignment-compiler-plugin-embeddable:0.0-fixture' }
tasks.register('verifyKotlinRouting') {
    doLast {
        assert new java.util.zip.ZipFile(configurations.routing.singleFile).withCloseable {
            it.getInputStream(it.getEntry('module.txt')).text
        } == 'kotlin-central'
        new File(System.getenv('CODEX_FIXTURE_KOTLIN_MARKER')).text = 'kotlin-central\n'
    }
}
tasks.named('jar') { dependsOn 'verifyKotlinRouting' }
gradlePlugin {
    plugins {
        fixtureLoader {
            id = 'codex.fixture.settings-loader'
            implementationClass = 'fixture.SettingsLoader'
        }
    }
}
GROOVY
cat > "$flutter_build/src/main/java/fixture/SettingsLoader.java" <<'JAVA'
package fixture;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import org.gradle.api.GradleException;
import org.gradle.api.Plugin;
import org.gradle.api.initialization.Settings;

public class SettingsLoader implements Plugin<Settings> {
    @Override public void apply(Settings settings) {
        try {
            File expected = new File(System.getenv("CODEX_FIXTURE_EXPECTED_HOME")).getCanonicalFile();
            if (!expected.equals(settings.getGradle().getGradleUserHomeDir().getCanonicalFile()))
                throw new GradleException("Fixture did not use the isolated Gradle user home");
            String policy = Files.readString(Path.of(System.getenv("CODEX_FIXTURE_INCLUDED_MARKER")));
            if (!policy.equals("FAIL_ON_PROJECT_REPOS\n"))
                throw new GradleException("Fixture included build did not enforce its repository policy");
            if (!settings.getDependencyResolutionManagement().getRepositories().isEmpty())
                throw new GradleException("Flutter-only repository policy leaked into root Settings");
            Files.writeString(Path.of(System.getenv("CODEX_FIXTURE_PLUGIN_MARKER")),
                "settings-plugin-applied\n", StandardCharsets.UTF_8);
        } catch (Exception error) {
            throw new GradleException("Fixture Settings plugin validation failed", error);
        }
    }
}
JAVA

run_gradle() {
    local home="$1" log="$2"
    GRADLE_USER_HOME="$home" CODEX_FIXTURE_EXPECTED_HOME="$home" CODEX_CI_MAVEN_MIRRORS=1 \
        bash "$private_gradle" --project-dir "$project" --offline --no-daemon --console=plain \
        --max-workers=2 '-Dorg.gradle.jvmargs=-Xmx768m -Dfile.encoding=UTF-8' help > "$log" 2>&1
}
status=0
run_gradle "$old_home" "$fixture/old-home.log" || status=$?
[[ "$status" == 1 ]] || fail 'the inherited-init negative control did not fail as expected'
grep -Fq "$negative_marker" "$fixture/old-home.log" || fail 'the negative control missed its synthetic init marker'
[[ ! -e "$CODEX_FIXTURE_INCLUDED_MARKER" && ! -e "$CODEX_FIXTURE_PLUGIN_MARKER" &&
   ! -e "$CODEX_FIXTURE_REPOSITORY_MARKER" ]] || fail 'negative control evaluated the build before its init failure'

isolated_home="$(bash "$ROOT_DIR/scripts/prepare-ci-gradle-home.sh" "$old_home" "$fixture/isolated-homes")"
for name in init.gradle init.gradle.kts init.d gradle.properties; do
    [[ ! -e "$isolated_home/$name" && ! -L "$isolated_home/$name" ]] || fail 'isolated home inherited configuration'
done
mkdir -p "$isolated_home/init.d"
cp "$ROOT_DIR/scripts/ci-flutter-repositories.init.gradle" "$isolated_home/init.d/codex-flutter-repositories.gradle"
check_wrapper >/dev/null
if ! run_gradle "$isolated_home" "$fixture/isolated-home.log"; then
    # Inherited JVM options can be printed by Java itself; never dump raw logs.
    fail 'isolated offline Gradle failed to load the strict included build or project repository policy'
fi
grep -Fq 'CODEX_FIXTURE_ISOLATED_GRADLE_HELP_OK' "$fixture/isolated-home.log" || fail 'the isolated help task did not execute'
if grep -Fq "$negative_marker" "$fixture/isolated-home.log"; then
    fail 'isolated Gradle executed the old-home init script'
fi
[[ "$(<"$CODEX_FIXTURE_INCLUDED_MARKER")" == FAIL_ON_PROJECT_REPOS ]] || fail 'strict included build was not evaluated'
[[ "$(<"$CODEX_FIXTURE_PLUGIN_MARKER")" == settings-plugin-applied ]] || fail 'local Settings plugin was not applied'
[[ "$(<"$CODEX_FIXTURE_REPOSITORY_MARKER")" == mirrors-before-official ]] || fail 'plugin classpath and dependency mirrors were not applied before official repositories'
[[ "$(<"$CODEX_FIXTURE_KOTLIN_MARKER")" == kotlin-central ]] || fail 'Flutter included build resolved Kotlin from the wrong repository'
[[ "$(sha256sum "$old_home/init.gradle" | cut -d ' ' -f 1)" == "$init_sha" ]] || fail 'the synthetic source init script changed'
echo 'Real offline Gradle repository routing passed (verified distribution, inherited-init rejection, strict scoped Settings, Kotlin classpaths, three Flutter engine ABIs, Android and Central dependencies)'
