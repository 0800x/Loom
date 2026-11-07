Loom / لوم 0.3.0-alpha.1

## Fixes in this build

- **Android release build:** fixed the foreground-service notification intent flags assignment in Kotlin by using `Intent.setFlags(...)`, resolving the `'val' cannot be reassigned` compilation error.
- **MLS group messaging:** serialized ephemeral typing frames with all other MLS operations and atomically persisted the advanced sealed MLS state together with the exact encrypted outbox request. Retries now reuse the same operation ID and ciphertext after an uncertain delivery result.
- **MLS self-echo handling:** record successful ephemeral message receipts so the sender's own inbox echo is skipped instead of being processed as a second inbound MLS message. Typing controls remain excluded from local conversation history.
- **Native MLS diagnostics:** preserve a bounded, sanitized native rejection reason across the FFI boundary and expose it to Dart instead of returning only a generic rejection.
- **Regression coverage:** added a three-device integration scenario for a lost typing receipt, outbox recovery, self-echo handling, and a subsequent normal group message.

The first alpha brings conversations, MLS groups, attachments and media,
English/Persian layouts and multiple delivery paths. A guided Home Node installer
sets up HTTPS, storage and selected voice/video/group-call services. Node Manager
provides account, federation, calling, backup and update controls.

Android signing status appears in each filename and manifest. Signed APKs use the
configured production key; unsigned-engineering APKs are not installable as-is.
Windows and Linux packages are unsigned builds. macOS ZIPs and DMGs
contain the complete ad-hoc signed application; they are not Developer ID signed
or notarized. Node releases include a precompiled Manager and server source
bundle; matching multi-architecture Node and MinIO images are published to GHCR.
The Home Node installer pulls them instead of compiling locally.

Each platform includes a build manifest with its revision/toolchains and
SHA256SUMS. Keep complete desktop bundles together. Retain identity and recovery
backups before upgrading.

Calls require live connectivity. Fully offline read receipts are not implemented.
Device permissions, background delivery and calls across real networks need
validation on your devices and deployment. See README for installation,
compatibility and recovery limitations.
