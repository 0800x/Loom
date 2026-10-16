# Alpha artifact and signing matrix

Artifact version is `0.1.0-alpha.1`; component versions are checked against
`version.json`. Architecture labels below refer to the actual native target.
The evidence column records checks available while preparing this source. Final
results are the exact revision's [Actions jobs](https://github.com/0800x/Loom/actions/workflows/loom-alpha.yml)
and generated artifact manifests; earlier builds do not certify a newer revision.

| Platform | Architecture / format | Automation | Distribution/signing policy | Recorded evidence before this build |
| --- | --- | --- | --- | --- |
| Android | armeabi-v7a APK | Required | Approved existing certificate on tag; unsigned engineering on main/dispatch; existing protected key selectable on dispatch | All three APKs compiled; MLS/Flutter ABIs and unsigned status verified. Prior packages rejected for AOT build paths; current build splits debug information. |
| Android | arm64-v8a APK | Required | Same | Same |
| Android | x86_64 APK | Required | Same; this is **64-bit** x86 | Same |
| Android | Universal APK / AAB | Not assembled by this workflow | Optional; existing signed local build scripts remain available | Not verified |
| Android | 32-bit x86 | Not advertised | No claim of plugin/MLS support | Not built |
| Windows | x64 portable ZIP + Inno Setup installer | Required | Unsigned engineering | ZIP and installer built with valid manifests; prior ZIP omitted C++ runtimes. Current build installs and verifies app-local CRT DLLs. |
| Windows | ARM64 | Not advertised | Requires native dependency/build evidence | Not built |
| Linux | x64 complete app bundle | Required | Unsigned engineering; includes `lib/`, `data/`, runtime guide and builder ldd output | Bundle compiled; prior plugin/AOT payload paths blocked output. Current build requires relative RPATH and split debug information. |
| Linux | ARM64 messenger | Not advertised | Requires supported Flutter/runner/plugin build evidence | Not built |
| macOS | Intel x64 full .app ZIP + DMG | Required | Ad-hoc engineering, not Developer ID / notarized | Application compiled and ad-hoc verification passed with Xcode 26.3. Current build corrects lipo argument order and requires packaging/audit success. |
| macOS | Apple Silicon arm64 full .app ZIP + DMG | Required | Same | Application compiled and ad-hoc verification passed with Xcode 26.3. Current build corrects lipo argument order and requires packaging/audit success. |
| macOS | Universal .app | Not advertised | Optional only after verifying every binary slice | Not built |
| Node / TUI | Linux amd64 manager + source server bundle | Required | Unsigned engineering | CI passed; ELF x64 verified |
| Node / TUI | Linux arm64 manager + source server bundle | Required | Unsigned engineering | CI passed; ELF arm64 verified; no ARM64 runtime execution |
| Node / TUI | Windows amd64 manager + source server bundle | Required | Unsigned engineering | CI passed; PE x64 verified; no Windows runtime execution |
| Node | Offline Docker image bundle | Not included | A source bundle is not an offline installer | Not assembled |

The native MLS library is required for each advertised messenger architecture.
APK checks validate its ABI and the Flutter runtime; desktop checks validate the
native MLS binary in the complete bundle. macOS copies MLS into Frameworks and
loads it by its application-relative path. Missing libraries fail packaging.
The experimental vodozemac provider is not advertised as a production component.

Every built platform gets deterministic filenames, SHA256SUMS and a manifest
with revision, native architecture, actual toolchain versions and signing status.
Draft assembly requires every platform manifest from the same approved revision;
it checks hashes before collecting individually downloadable assets. Configuration/lint validation
alone does not establish a successful native build.
