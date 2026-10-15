pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        if (System.getenv("CODEX_CI_MAVEN_MIRRORS") == "1") {
            maven("https://maven.aliyun.com/repository/google") {
                content { excludeGroupByRegex("org\\.jetbrains(\\..*)?") }
            }
            maven("https://maven.aliyun.com/repository/central")
            maven("https://maven.aliyun.com/repository/gradle-plugin")
        }
        google {
            if (System.getenv("CODEX_CI_MAVEN_MIRRORS") == "1") {
                content { excludeGroupByRegex("org\\.jetbrains(\\..*)?") }
            }
        }
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.0.1" apply false
    id("org.jetbrains.kotlin.android") version "2.3.20" apply false
}

include(":app")
