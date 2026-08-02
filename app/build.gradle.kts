plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.serialization")
}

val pinnedCodexVersion = rootProject.file("protocol/codex-version.txt").readText().trim()
require(Regex("\\d+\\.\\d+\\.\\d+(?:[-+][0-9A-Za-z.-]+)?").matches(pinnedCodexVersion)) {
    "protocol/codex-version.txt must contain a semantic version"
}
val pinnedNodeVersion = rootProject.file("protocol/node-version.txt").readText().trim()
require(Regex("\\d+\\.\\d+\\.\\d+").matches(pinnedNodeVersion)) {
    "protocol/node-version.txt must contain a semantic version"
}
val configuredSigningPath = providers.gradleProperty("codexSigningKeystore")
    .orElse(providers.environmentVariable("CODEX_SIGNING_KEYSTORE"))
    .orNull
    ?.takeIf { it.isNotBlank() }
val stableSigningFile = configuredSigningPath?.let { rootProject.file(it) }
    ?: rootProject.file("keystore/codex-remote-stable.keystore")
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
    namespace = "top.asdb.codexremote"
    compileSdk = 34

    defaultConfig {
        applicationId = "top.asdb.codexremote"
        minSdk = 26
        targetSdk = 34
        versionCode = 74
        versionName = "1.7.52"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        vectorDrawables.useSupportLibrary = true
        buildConfigField("String", "PINNED_CODEX_VERSION", "\"$pinnedCodexVersion\"")
        buildConfigField("String", "PINNED_NODE_VERSION", "\"$pinnedNodeVersion\"")
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
            isMinifyEnabled = true
            isShrinkResources = true
            signingConfig = signingConfigs.getByName("stable")
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    buildFeatures {
        buildConfig = true
        compose = true
    }

    composeOptions {
        kotlinCompilerExtensionVersion = "1.5.10"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    packaging {
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1,DEPENDENCIES,NOTICE,LICENSE}"
        resources.excludes += "/META-INF/versions/**/OSGI-INF/MANIFEST.MF"
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.02.02")

    implementation(composeBom)
    androidTestImplementation(composeBom)

    implementation("androidx.activity:activity-compose:1.8.2")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.core:core-ktx:1.12.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.7.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.7.0")
    implementation("androidx.security:security-crypto:1.1.0-alpha06")

    implementation("com.github.mwiede:jsch:0.2.17")
    implementation("org.bouncycastle:bcprov-jdk18on:1.85")
    implementation("io.noties.markwon:core:4.6.2")
    implementation("io.noties.markwon:ext-tables:4.6.2")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.6.3")

    debugImplementation("androidx.compose.ui:ui-tooling")
    debugImplementation("androidx.compose.ui:ui-test-manifest")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.8.0")
    androidTestImplementation("androidx.test.ext:junit:1.1.5")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.5.1")
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
}
