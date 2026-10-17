# Artifacts and signing

Artifacts use the public label `0.1.0-alpha.1`. Check the exact revision and
signing status in each generated build manifest and the corresponding
[Actions run](https://github.com/0800x/Loom/actions/workflows/loom-alpha.yml).

| Platform | Architecture and format | Signing |
| --- | --- | --- |
| Android | armeabi-v7a, arm64-v8a, x86_64 APKs | Existing protected production key when selected/required; explicitly labelled engineering artifacts otherwise |
| Windows | x64 complete portable ZIP and installer | Unsigned |
| Linux | x64 full application bundle | Unsigned; [runtime dependencies](linux-runtime.md) |
| macOS | Intel x64 and Apple Silicon arm64; full .app ZIP and DMG | Ad-hoc signed; not Developer ID signed or notarized |
| Node / TUI | Linux amd64/arm64; Windows amd64 | Manager binary and server source bundle; unsigned |

The candidate at `64de59fab2368dc6c0dfd223fe0deebc50542f54` passed all required
native build jobs, including Android APKs signed with the configured release key.
Later changes require their own checks. Artifact availability depends on the
selected Actions run or published release; a draft is not a public download.

Universal APK/AAB are optional local build-script outputs. Android 32-bit x86,
Windows ARM64, Linux ARM64 messenger and universal macOS packages are not
advertised. x86_64 is 64-bit x86. Node source bundles do not include offline
Docker images.

Native MLS libraries are packaged and checked for every advertised messenger
architecture. Missing libraries, failed checks and missing required signing
credentials fail the relevant build. Packaging complete desktop bundles includes
their framework/library and data directories.

Every platform produces deterministic artifact names, SHA256SUMS and a manifest
with revision, architecture, actual toolchain versions and signing status.
Draft assembly requires matching successful manifests and verifies their hashes.
