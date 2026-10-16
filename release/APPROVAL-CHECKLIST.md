# Loom 0.1.0-alpha.1 approval checklist

Source publication does not publish a binary release. Complete the checks below
before approving a version tag or making a draft release public.

## Evidence to review

- [ ] Review the fixed-source revision and clean-export digest in the delivered manifest.
- [ ] Review [verification](VERIFICATION.md), the current README captures and their
  [per-image provenance](../docs/screenshots/loom-current/provenance.json).
- [ ] Verify included licenses and compatibility contracts.
- [ ] Complete native Android/Windows/Linux/macOS builds on appropriate hosts;
  inspect actual artifacts, cryptographic libraries and per-platform manifests.
- [ ] Complete physical-device identity creation/restoration/linking, direct and
  MLS group messaging, invitations, media, live calls and Android Nearby checks.
  Exercise locked-screen audio and incoming calls, permissions and unavailable routes.
- [ ] Resolve the Go privilege-dropping test in a host that supports the required
  process credential changes. Do not disable it in release validation.

## Target repository and signing

- [x] Confirm write access to `0800x/Loom` using the intended release account.
- [ ] Inspect all existing refs/releases. Confirm `v0.1.0-alpha.1` is unused.
  Never move an existing version tag or replace a published release.
- [x] Verify the owner-approved fresh import has one initial commit under the
  release account. The original source repository and history remain intact.
- [ ] Configure protected `loom-release-signing` and `loom-alpha-publishing`
  environments, with required owner review and access restricted to the intended ref.
- [ ] Configure the Android distribution key and its credentials as
  `LOOM_ANDROID_KEYSTORE_BASE64`, `LOOM_ANDROID_STORE_PASSWORD`,
  `LOOM_ANDROID_KEY_PASSWORD`, `LOOM_ANDROID_KEY_ALIAS`. For Loom's first key,
  the owner explicitly runs the [one-time local setup](../docs/android-release-signing.md).
  Build jobs never generate or replace signing keys. Existing distributions
  must retain their original key.
- [ ] Set environment variable `LOOM_ANDROID_CERT_SHA256` to the distribution
  certificate's SHA256 digest. Every signed APK must match it exactly.
- [ ] Inspect the main-branch candidate workflow, or run workflow_dispatch.
  Configured Android candidates use the pinned distribution key. When credentials
  are absent, compilation may produce explicitly unsigned diagnostics, but the
  signed-candidate gate fails and prevents draft assembly. Unsigned APKs are
  not installable as-is. Debug signing is never substituted.
- [ ] Verify all required platform jobs and artifacts. Windows/Linux are unsigned
  engineering builds; macOS is ad-hoc engineering output without Developer ID
  signing/notarization. Do not describe these as signed distribution.

## Final owner approval, then tag/draft

- [ ] Owner explicitly approves the concrete revision, export, artifacts,
  signing matrix and outstanding alpha limitations.
- [ ] Set `APPROVED_LOOM_REVISION` to the exact **target repository** commit SHA
  and `APPROVED_LOOM_TAG` to `v0.1.0-alpha.1`. Importing without history creates a
  new commit; verify its content against the reviewed export before approval.
- [ ] Only after that approval, create and push the unused version tag.
  Tag validation rejects another repository, revision or version.
- [ ] Successful required checks/builds can assemble a **draft prerelease** only
  in `0800x/Loom`; the workflow refuses to replace any existing release.
- [ ] Inspect the draft's individually downloadable assets, `SHA256SUMS`, aggregate
  build manifest and signing labels. Owner approval is still required to make
  the draft public. Nothing in this candidate auto-publishes a draft.
