plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val configuredSigningPath = providers.gradleProperty("codexSigningKeystore")
    .orElse(providers.environmentVariable("CODEX_SIGNING_KEYSTORE"))
    .orNull
    ?.takeIf { it.isNotBlank() }
val stableSigningFile = configuredSigningPath?.let { rootProject.file(it) }
    ?: rootProject.file("../../keystore/codex-remote-stable.keystore")
require(stableSigningFile.isFile) {
    "Stable APK signing key is missing: ${stableSigningFile.absolutePath}. " +
        "Set CODEX_SIGNING_KEYSTORE for a CI runner."
}
val stableStorePassword = providers.gradleProperty("codexSigningStorePassword")
    .orElse(providers.environmentVariable("CODEX_SIGNING_STORE_PASSWORD"))
    .getOrElse("android")
val stableKeyAlias = providers.gradleProperty("codexSigningKeyAlias")
    .orElse(providers.environmentVariable("CODEX_SIGNING_KEY_ALIAS"))
    .getOrElse("androiddebugkey")
val stableKeyPassword = providers.gradleProperty("codexSigningKeyPassword")
    .orElse(providers.environmentVariable("CODEX_SIGNING_KEY_PASSWORD"))
    .getOrElse("android")

android {
    namespace = "top.asdb.agent"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "top.asdb.agent"
        minSdk = 26
        targetSdk = 34
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("stable") {
            storeFile = stableSigningFile
            storePassword = stableStorePassword
            keyAlias = stableKeyAlias
            keyPassword = stableKeyPassword
        }
    }

    buildTypes {
        getByName("debug") {
            signingConfig = signingConfigs.getByName("stable")
        }
        release {
            signingConfig = signingConfigs.getByName("stable")
        }
    }

    packaging {
        jniLibs {
            // PRoot is launched as an executable from nativeLibraryDir. Modern
            // Android versions prohibit executing files from writable app data.
            useLegacyPackaging = true
            keepDebugSymbols += setOf("**/libproot.so", "**/libproot-loader.so")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    implementation("androidx.security:security-crypto:1.1.0-alpha06")
    implementation("org.apache.commons:commons-compress:1.27.1")
    implementation("org.tukaani:xz:1.10")
}
