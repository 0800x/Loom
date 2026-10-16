group = "com.llfbandit.record"
version = "1.0"
buildscript {
    repositories { google(); mavenCentral() }
    dependencies {
        val agp = project.findProperty("loomAgpVersion")?.toString() ?: "9.1.0"
        classpath("com.android.tools.build:gradle:$agp")
    }
}
plugins { id("com.android.library") }
android {
    namespace = "com.llfbandit.record"
    compileSdk = 36
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    defaultConfig { minSdk = 24 }
}
// AGP 9 supplies Kotlin and derives its JVM target from compileOptions.
