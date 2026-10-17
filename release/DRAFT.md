Loom / لوم 0.1.0-alpha.1

The first alpha brings conversations, MLS groups, attachments and media,
English/Persian layouts and multiple delivery paths. A guided Home Node installer
sets up HTTPS, storage and selected voice/video/group-call services. Node Manager
provides account, federation, calling, backup and update controls.

Android signing status appears in each filename and manifest. Signed APKs use the
configured production key; unsigned-engineering APKs are not installable as-is.
Windows and Linux packages are unsigned builds. macOS ZIPs and DMGs
contain the complete ad-hoc signed application; they are not Developer ID signed
or notarized. Node bundles include server source and the compiled manager, not
offline Docker images.

Each platform includes a build manifest with its revision/toolchains and
SHA256SUMS. Keep complete desktop bundles together. Retain identity and recovery
backups before upgrading.

Calls require live connectivity. Fully offline read receipts are not implemented.
Device permissions, background delivery and calls across real networks need
validation on your devices and deployment. See README for installation,
compatibility and recovery limitations.
