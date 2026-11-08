# Loom 0.6.0 — Alpha

Loom 0.6.0 is the current repository alpha snapshot. Public preview artifacts
are published only after the required GitHub Actions validation and build jobs
succeed. Check [GitHub Releases](https://github.com/0800x/Loom/releases) for
the exact commit and available downloads, and [Actions](https://github.com/0800x/Loom/actions/workflows/loom-alpha.yml)
for build status.

| Component | Version |
| --- | --- |
| Messenger | 0.6.0+34 |
| Node runtime | 0.10.10 |
| Terminal Manager | 0.8.6 |
| Desktop Node UI | 0.7.1+2 |

The app version is `0.6.0` (build 34). Node runtime, Terminal Manager and
Desktop Node UI retain independent component versions. Artifact filenames and
manifests include the product version, platform, architecture and signing mode.

## What's included

This release updates Android notification handling, onboarding and recovery,
group calls, chat and media UX, MLS synchronization, encrypted call verification,
reverse DTN delivery, Node server resilience, PostgreSQL timeouts and map tile
configuration/cache services. The full change list and known limitations are in
[the 0.6.0 release notes](DRAFT.md).

## Home Node images

The release workflow builds Loom Node and MinIO images for linux/amd64 and
linux/arm64. MinIO is compiled from a pinned upstream source revision. The
Home Node installer pulls the matching published images; it does not compile
the Node runtime or MinIO on the target VPS.

## Compatibility and release status

Application ID: `app.loom.messenger`; Node home: `/opt/loom-node`.
The alpha uses the Loom protocol, discovery and recovery namespaces. It does not
silently import, delete or replace another application's identity or data.
Keep recovery exports; see [compatibility](../docs/compatibility.md).

This is an alpha engineering preview, not a stable release or an independent
security audit. `release/version.json` remains `published: false` until the
separate publisher-signing, provenance and verification requirements are met.
Unsigned-engineering Android APKs are not installable as-is. Windows and Linux
packages are unsigned; macOS packages are ad-hoc signed and are not Developer ID
signed or notarized.

Before relying on a deployment, test physical-device behavior, background
delivery and real cross-network calls. Retain identity and recovery backups
before upgrading.
