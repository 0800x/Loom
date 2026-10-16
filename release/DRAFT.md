Loom / لوم 0.1.0-alpha.1 is an engineering alpha for testing.

Android signing status is recorded in each filename and manifest. APKs labeled
unsigned-engineering are not installable as-is; signed builds require the existing
production keystore. Windows and Linux
artifacts are unsigned engineering builds. macOS apps are ad-hoc signed
engineering builds, without Developer ID signing or notarization.
macOS packages include complete .app ZIPs and DMGs.
Node bundles contain server source and the compiled manager, not offline
Docker images. Installations still need runtime dependencies and images.

The release assets include per-platform build manifests, toolchain versions,
source revisions and SHA256SUMS. Verify the complete application bundle and
architecture before installation. Do not replace or discard recovery material.

See README for transport, receipt, recovery and platform limitations. Calls need
live connectivity. Offline read receipts are not implemented. Physical-device
results must be reviewed in the acceptance checklist before public publication.

This release remains a draft until the owner explicitly approves publication.
