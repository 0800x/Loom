Local source fork of video_compress 3.1.4, published by jonataslaw/VideoCompress.
Upstream native and Dart sources and MIT license are retained.

Changes: Android build uses the application's loomAgpVersion (9.1.0), built-in
Kotlin, the Kotlin source set, Java 17 and minimum SDK 24. It does not apply a
second Kotlin Gradle plugin. This fork targets the Loom AGP 9 build with built-in Kotlin enabled.

The package API and Android/iOS/macOS codecs are retained. Android MediumQuality uses a 720-pixel maximum and the requested frame rate, and converts raw filesystem paths to file URIs. Windows/Linux do not
have a compressor in this plugin; these platforms retain the selected video
and enforce the 32 MB encrypted attachment limit. Do not delete original media.

Errors are returned to Dart without printing filesystem/media error details.

Dart compression status is reset in finally even when a native call throws.
