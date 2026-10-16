Local Android source fork of record_android 2.1.2 (llfbandit/record).
BSD license and upstream plugin API are retained. Only build configuration is
changed: use Loom's AGP 9.1.0, built-in Kotlin and Java 17 instead of resolving
an additional AGP 9.2.1/Kotlin Gradle Plugin classpath. Minimum SDK is 24.
