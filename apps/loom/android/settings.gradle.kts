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

    val loomAgpVersion = providers.gradleProperty("loomAgpVersion").get()
    plugins {
        id("com.android.application") version loomAgpVersion
    }

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") apply false
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
}

include(":app")

// Flutter requests an unqualified release task. Gradle otherwise selects that
// task in every subproject, including dev-only plugins such as integration_test.
// Build the app and let its release dependency graph select the required native
// plugins. Explicit project tasks and debug/instrumentation builds stay intact.
gradle.startParameter.setTaskNames(gradle.startParameter.taskNames.map { task ->
    if (!task.contains(':') && task.endsWith("Release") &&
        (task.startsWith("assemble") || task.startsWith("bundle"))) {
        ":app:$task"
    } else {
        task
    }
})
