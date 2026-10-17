# English Loom product captures

The capture target is `apps/loom/test/product_screenshots_test.dart`.
It renders the production messenger shell with explicit preview fixtures:
Maya Brooks, Ethan Cole, Leo Hart, Iris Lane and Finn Wells. These are fictional
names, not contacts loaded from an account. Domains use reserved `.example` names.
No account credentials, phone notifications, build paths or real conversations
should appear in published images.

## Capture on the Windows development machine

From the repository root, with Flutter and dependencies available:

```powershell
Set-Location .\apps\loom
flutter pub get
if ($LASTEXITCODE -ne 0) { throw 'Dependency resolution failed' }
$env:LOOM_UX_EVIDENCE = '..\..\docs\screenshots\loom-current'
try {
    flutter test test/product_screenshots_test.dart
    if ($LASTEXITCODE -ne 0) { throw 'Product capture failed' }
} finally {
    Remove-Item Env:LOOM_UX_EVIDENCE -ErrorAction SilentlyContinue
}
```

Linux/macOS:

```bash
cd apps/loom
flutter pub get
LOOM_UX_EVIDENCE=../../docs/screenshots/loom-current \
  flutter test test/product_screenshots_test.dart
```

Outputs cover English/LTR chat list and conversation, light/dark/OLED, mobile
390×844 and desktop 1440×960. Fonts are loaded from the app's actual font manifest.
Glass quality is disabled for deterministic widget captures: these are not GPU
blur/native-runner screenshots. They also do not prove camera, calls or recording
integration works. Visually inspect every generated PNG before publishing.

Fresh PNGs were not generated in the editing environment: Flutter was unavailable
and its SDK download endpoint failed. The test target is prepared but has not run
here. Do not substitute generated mockups or outdated captures and label them
as current Loom screenshots. After reviewing the captures, add the chosen PNGs
and their revision to the root README; retain this provenance distinction.

The `English product captures` CI workflow runs this same target and uploads PNGs
with revision/renderer provenance. A successful artifact must be downloaded and
visually reviewed before README inclusion; merely configuring the workflow does
not establish that any image was generated.
