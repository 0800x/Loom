allprojects {
    repositories {
        // AndroidX artifacts belong to Google Maven. Dynamic test versions must
        // not probe Flutter's engine repository, which can return HTTP 403.
        exclusiveContent {
            forRepository { google() }
            filter { includeGroupByRegex("androidx\\..*") }
        }
        mavenCentral()
    }
}

// Flutter's settings plugin already loads this project's AGP (9.1.0).
// Native selector, recorder and player plugins declare their own buildscript
// classpaths. Resolve them against the same AGP instead of mixing toolchains.
val loomAgpVersion = providers.gradleProperty("loomAgpVersion").get()
subprojects {
    if (name == "integration_test") {
        // Flutter declares runner/rules 1.2+ and espresso 3.3+. Keep test
        // resolution reproducible and aligned with app androidTest versions.
        val testVersions = mapOf(
            "androidx.test:runner" to "1.3.0",
            "androidx.test:rules" to "1.3.0",
            "androidx.test.espresso:espresso-core" to "3.3.0"
        )
        configurations.configureEach {
            resolutionStrategy.eachDependency {
                testVersions["${requested.group}:${requested.name}"]?.let { version ->
                    useVersion(version)
                    because("Integration test dependencies must use fixed compatible versions")
                }
            }
        }
    }
    if (name in setOf("audio_service", "audio_session", "file_selector_android", "record_android", "audioplayers_android", "video_compress", "camera_android", "media_kit_libs_android_video", "media_kit_video", "flutter_plugin_android_lifecycle", "image_picker_android")) {
        buildscript.configurations.configureEach {
            resolutionStrategy.eachDependency {
                if (requested.group == "com.android.tools.build" && requested.name == "gradle") {
                    useVersion(loomAgpVersion)
                    because("Native media plugins must share the app's Android Gradle plugin")
                }
            }
        }
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}


