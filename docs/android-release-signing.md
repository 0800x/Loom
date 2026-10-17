# Android distribution signing

Loom's Android application ID is `app.loom.messenger`. Updates must use
the same distribution key. Builds never create or replace that key, and
missing credentials never fall back to debug signing.

## First key: one-time owner setup

This repository has not yet configured its first Android distribution key.
From a reviewed checkout, use PowerShell 7, Java 17 or newer (with
`keytool` on PATH), and GitHub CLI authenticated as `0800x`:

```powershell
gh auth login
pwsh -NoProfile -File .\scripts\setup-first-android-key.ps1
```

The helper checks the GitHub account and existing environment configuration
before generating anything. It creates an RSA-4096 PKCS12 key with a generic
Loom certificate in the private local application-data directory, outside
the checkout. It restricts the directory's Windows permissions and prompts
for a password of at least 16 characters. No password is saved in source or
passed in command-line arguments.

It uploads these four encrypted GitHub Actions environment secrets to
`loom-release-signing`:

| Secret | Value |
| --- | --- |
| LOOM_ANDROID_KEYSTORE_BASE64 | Base64-encoded private keystore |
| LOOM_ANDROID_STORE_PASSWORD | Keystore password |
| LOOM_ANDROID_KEY_PASSWORD | Private-key password |
| LOOM_ANDROID_KEY_ALIAS | Key alias |

It also sets environment variable `LOOM_ANDROID_CERT_SHA256` to the public
certificate fingerprint. The workflow verifies every APK against that
fingerprint. Repository owners should restrict the signing environment to
approved release branches/tags and configure required reviewers where
available. The helper preserves existing environment settings.

Back up `loom-release.p12` and its password privately before distributing
APKs. Keep an independent backup; GitHub Secrets are not a key-recovery
service. Never commit the keystore, publish it as an artifact, or paste
its contents or password into a chat.

If uploading is interrupted, keep the already-created key. The helper
refuses to overwrite both local keys and existing remote signing settings.
Reconcile any partially uploaded settings in GitHub, then upload the same
local key using:

```powershell
pwsh -NoProfile -File .\scripts\setup-first-android-key.ps1 -UseExistingKey
```

Use `-SigningDirectory` to select a private directory outside the checkout.
This setup helper is run explicitly by the owner; CI only parses its syntax
and never executes key generation.

## CI and release eligibility

After setup, rerun the failed Android job on the reviewed revision, or run
the candidate workflow with `existing-production-key`. The keystore is
decoded only into the ephemeral runner's temporary directory and removed
afterward. Each ABI APK must pass native-library inspection, payload
identity audit, APK signature verification and certificate pinning.

When all signing secrets are absent, main-branch builds may compile unsigned
diagnostics, but the signed-candidate check fails and draft assembly remains
blocked. Partial signing credentials fail immediately. An explicitly
requested `unsigned-engineering` validation is labeled accordingly;
unsigned APKs cannot be installed as-is.

Android signing does not provide Windows Authenticode or Apple Developer ID.
The Windows installer/portable bundle remain unsigned engineering builds;
macOS ZIP/DMG builds are ad-hoc signed and are not notarized distributions.

## Local builds using an existing key

For an existing key, provide all four environment credentials:
`LOOM_ANDROID_KEYSTORE` (file path), `LOOM_ANDROID_STORE_PASSWORD`,
`LOOM_ANDROID_KEY_PASSWORD` and `LOOM_ANDROID_KEY_ALIAS`.
Alternatively, create the ignored `apps/loom/android/key.properties` with
`storeFile`, `storePassword`, `keyAlias` and `keyPassword`.
Use forward slashes for Windows paths; relative paths resolve from the
Android directory. Environment credentials take precedence as a complete
set. Partial sets, missing private keys, wrong passwords and debug
certificates are rejected.

```powershell
pwsh -NoProfile -File .\scripts\build-android.ps1
```

This build helper reuses signing configuration and never generates a key.
