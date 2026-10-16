import java.security.KeyStore
import java.security.PrivateKey
import java.security.cert.X509Certificate
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Environment credentials take precedence as a complete set. Never mix a CI
// keystore with passwords/aliases from a developer's local configuration.
val signingEnvironment = mapOf(
    "storeFile" to System.getenv("LOOM_ANDROID_KEYSTORE"),
    "storePassword" to System.getenv("LOOM_ANDROID_STORE_PASSWORD"),
    "keyAlias" to System.getenv("LOOM_ANDROID_KEY_ALIAS"),
    "keyPassword" to System.getenv("LOOM_ANDROID_KEY_PASSWORD")
)
val signingProperties = Properties()
val signingPropertiesFile = rootProject.file("key.properties")
if (signingEnvironment.values.none { !it.isNullOrBlank() } && signingPropertiesFile.isFile) {
    signingPropertiesFile.inputStream().use { signingProperties.load(it) }
}
val releaseSigning = if (signingEnvironment.values.any { !it.isNullOrBlank() }) {
    signingEnvironment
} else {
    signingEnvironment.keys.associateWith { signingProperties.getProperty(it) }
}
// Standard key.properties paths are relative to the Android directory.
val unsignedEngineering = System.getenv("LOOM_ANDROID_ENGINEERING_UNSIGNED") == "true"
val releaseStoreFile = releaseSigning["storeFile"]?.takeIf { it.isNotBlank() }
    ?.let { rootProject.file(it) }

android {
    namespace = "app.loom.messenger"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "app.loom.messenger"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // The Android photo selector requires API 24 or newer.
        minSdk = maxOf(flutter.minSdkVersion, 24)
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("production") {
            storeFile = releaseStoreFile
            storePassword = releaseSigning["storePassword"]
            keyAlias = releaseSigning["keyAlias"]
            keyPassword = releaseSigning["keyPassword"]
        }
    }
    buildTypes {
        release {
            signingConfig = if (unsignedEngineering) null else signingConfigs.getByName("production")
        }
        // Validation artifacts can compile without manufacturing any signing key.
        // Unsigned APKs are engineering output and cannot be installed as-is.
        if (unsignedEngineering) {
            getByName("debug") { signingConfig = null }
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
    // Flutter's integration_test exports runner/rules 1.3.0 into debug runtime.
    // AGP 9 resolves androidTest consistently with that runtime: match its
    // versions rather than introduce conflicting test-only upgrades.
    androidTestImplementation("androidx.test:core:1.3.0")
    androidTestImplementation("androidx.test:runner:1.3.0")
    androidTestImplementation("androidx.test.ext:junit:1.1.2")
}


gradle.taskGraph.whenReady {
    if (!unsignedEngineering && allTasks.any { it.project == project && it.name.contains("Release") &&
            (it.name.startsWith("package") || it.name.startsWith("validateSigning") ||
             it.name.startsWith("assemble") || it.name.startsWith("bundle")) }) {
        check(releaseSigning.values.all { !it.isNullOrBlank() }) {
            "Release signing is required. Run scripts/build-android.ps1 from the repository root, " +
                "or configure android/key.properties (storeFile, storePassword, keyAlias, keyPassword), " +
                "or all four LOOM_ANDROID_KEYSTORE, LOOM_ANDROID_STORE_PASSWORD, " +
                "LOOM_ANDROID_KEY_ALIAS and LOOM_ANDROID_KEY_PASSWORD environment variables."
        }
        check(releaseSigning["keyAlias"] != "androiddebugkey") { "Debug key cannot sign a production release" }
        val signingStore = releaseStoreFile!!
        check(signingStore.isFile && signingStore.name != "debug.keystore") { "A production keystore is required" }
        val keyStore = KeyStore.getInstance(signingStore, releaseSigning["storePassword"]!!.toCharArray())
        check(keyStore.isKeyEntry(releaseSigning["keyAlias"])) { "Release signing alias must identify a private key" }
        val signingKey = keyStore.getKey(releaseSigning["keyAlias"], releaseSigning["keyPassword"]!!.toCharArray())
        check(signingKey is PrivateKey) { "Release signing alias must identify a private key" }
        val certificate = keyStore.getCertificate(releaseSigning["keyAlias"]) as? X509Certificate
        check(certificate != null && !certificate.subjectX500Principal.name.contains("CN=Android Debug", ignoreCase = true)) {
            "Android debug certificates cannot sign a production release"
        }
    }
}

// Bundle the native engine on ordinary `flutter build apk` too. A fresh
// checkout cannot rely on a developer remembering a separate prebuild command.
val mlsRepository = rootProject.projectDir.resolve("../../..").canonicalFile
val mlsSources = mlsRepository.resolve("native/loom_mls")
val mlsOutput = projectDir.resolve("src/main/jniLibs")
val mlsLocalProperties = Properties().apply {
    val local = rootProject.file("local.properties")
    if (local.isFile) local.inputStream().use { load(it) }
}
val mlsSdk = System.getenv("ANDROID_HOME") ?: System.getenv("ANDROID_SDK_ROOT") ?: mlsLocalProperties.getProperty("sdk.dir")
val mlsNdk = System.getenv("ANDROID_NDK_HOME") ?: mlsSdk?.let { "$it/ndk/${flutter.ndkVersion}" }
val buildNativeMls = tasks.register<Exec>("buildNativeMls") {
    inputs.files(mlsSources.resolve("Cargo.toml"), mlsSources.resolve("Cargo.lock"))
    inputs.dir(mlsSources.resolve("src"))
    inputs.files(mlsRepository.resolve("scripts/build-mls.sh"), mlsRepository.resolve("scripts/build-mls.ps1"))
    inputs.property("ndk", mlsNdk.orEmpty())
    outputs.files(listOf("arm64-v8a", "armeabi-v7a", "x86_64").map { mlsOutput.resolve("$it/libloom_mls.so") })
    workingDir(mlsRepository)
    doFirst {
        require(!mlsNdk.isNullOrBlank() && file(mlsNdk.orEmpty()).isDirectory) {
            "MLS requires NDK ${flutter.ndkVersion}. Install it with SDK Manager or set ANDROID_NDK_HOME."
        }
    }
    if (System.getProperty("os.name").startsWith("Windows")) {
        commandLine("powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", mlsRepository.resolve("scripts/build-mls.ps1"), "-Target", "Android", "-NdkPath", mlsNdk.orEmpty())
    } else {
        environment("ANDROID_NDK_HOME", mlsNdk.orEmpty())
        commandLine("bash", mlsRepository.resolve("scripts/build-mls.sh"), "android")
    }
}
tasks.named("preBuild").configure { dependsOn(buildNativeMls) }
