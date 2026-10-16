# Alpha verification

The tests below were rerun on the Loom namespace cutover source. The recorded
capture revision is in [image provenance](../docs/screenshots/loom-current/provenance.json).
Native platform builds must also pass on that source revision before draft assembly.

## Current results

| Scope | Result | Evidence |
| --- | --- | --- |
| Node server | 145 passed | Real local server tests, authenticated discovery, federation, groups, calls and delivery |
| Messenger | 455 passed, 24 opt-in older goldens skipped | Flutter unit/widget/controller tests, including native MLS with a real signed local server |
| Design system | 53 passed | LTR/RTL, light/dark/OLED, reverse history behind floating composer, resizing and input accessibility |
| Calls | 15 passed | Lifecycle, authorization, history and ICE tests; native WebRTC media mocked |
| Crypto bridge | 28 passed | Recovery, linking, protected storage and namespace rejection; platform channels mocked where needed |
| Transport | 70 passed | Includes native MLS/local server invitation, message, restart and removal integration |
| DTN | 50 passed | Custody, expiry and hop/copy limits; no physical radio |
| Identity / sessions / messaging | 5 / 18 / 28 passed | Real identity derivation and state/authorization tests |
| Models / protocol / federation / storage | 3 / 67 / 4 / 59 passed | Dart tests; real SQLite where applicable |
| Desktop Node UI | 1 passed | Widget render of disconnected state |
| Native MLS | 5 passed; host library built | Real Rust cryptography, membership, replay, removal, tamper and exporter tests |
| Evaluation vodozemac provider | 10 native Rust and 13 Dart tests passed; Clippy clean | Actual FFI library; adapter, round trips, crash rollback, publication and handle lifecycle. Remains nonshipping |
| Analyzers | Dart/Flutter analyzers, Rust Clippy and go vet passed | Fatal infos enabled across application and release packages |
| Go manager | 59 passed, 1 host-limited failure | Privilege-drop test cannot exec with changed credentials in this container; test is retained |
| Release checks | 9 guards, 3 assembly tests passed | Reject missing/wrong native ABI, stale namespace contract, tampered assets and wrong publishing repository |
| Installer fixtures | 6 install, 5 TLS repair, 4 pruning tests passed | Isolated fixture installations; no production services changed |
| Workflow checks | actionlint passed | All workflow files; linting does not prove native builds work |
| Captures | 10 widget capture tests passed; 25 PNGs | 20 actual widget renders, 4 Bubble Tea PTY captures, 1 Chromium local server capture |
| Attachment sheet with music state | Included in passing app suite | Six widget variants at 320px, 1.5× text, English/Persian and three themes; playback mocked |
| Node / manager packaging | Linux amd64/arm64 and Windows amd64 built | ELF/PE architecture checked; only Linux amd64 executed; bundles contain server source, not offline Docker images |

The namespace cutover is deliberately incompatible with the earlier application
protocol, discovery and protected-state envelopes. Identity key derivation and
application IDs remain unchanged. Unsupported protected data fails before
mutation, and storage errors no longer reset the vault. See
[compatibility](../docs/compatibility.md) for recovery and coordinated deployment limits.

Local tools: Flutter 3.47.0, Dart 3.13.0, Rust 1.99.1, Go 1.27.2, Node 24.19.0,
Chromium 155.0.8059.79 and Java 17. CI uses Node 22. SQLite tests use the system
library through its local development soname. Captures use fictional participants
and example domains; widget playback is mocked. Capture hashes and renderer
versions are recorded per image.

## Open native checks

No physical Android, Windows or macOS device is available here. Identity restore
and linking across real devices, camera/recording, actual music decode/background
playback, incoming call alerts, WebRTC media and Android Nearby still need device
acceptance. Unit and widget tests do not establish these behaviors.

The native GitHub run for `4c8ba9f03d83d9b7e81c4c9d5e54f0698df71bc4`
completed with the following results:

| Job | Observed result |
| --- | --- |
| Complete validation | Passed: server, Go, native MLS, native evaluation bridge, Dart/Flutter analyzers and tests, widget captures |
| Repository security/hygiene | Passed |
| Node Linux amd64 / arm64 and Windows amd64 | All three passed; downloadable CI artifacts include manifests and SHA256SUMS |
| Windows x64 | Application, portable ZIP and Inno Setup installer compiled; manifest recording then failed to resolve the Flutter batch command, so no reviewed desktop artifact was uploaded |
| Linux x64 | Application and complete bundle compiled; artifact identity audit blocked packaging. The builder dependency report included build paths; full payload diagnostics are required to rule out further findings |
| macOS Intel / Apple Silicon | Failed compiling connectivity_plus against the selected Xcode 16.4 SDK; no DMG produced |
| Android | Native dependency compilation proceeded; optimized APK assembly failed when runner disk space was exhausted. No APK was uploaded |
| Draft | Correctly skipped because required native builds failed |

The subsequent run for `f06e08bc00293cff7ee0d3437ea99444a24cd25a`
passed complete validation and all three node jobs again. Windows ZIP and installer
packaging, manifest recording and payload audit also passed. Inspection of that
ZIP found missing app-local Microsoft C++ runtime DLLs, so it is not accepted as
a complete portable release. CMake now installs the compiler's redistributable
runtime and packaging verifies the required DLLs and their architecture.

Android also compiled all three APKs and passed the MLS/Flutter architecture and
unsigned-signature checks. The remaining rejection was an embedded build path in
each AOT library; split debug information is now required for these artifacts.

Both macOS targets use the selected Xcode 26.3 SDK. Both applications compiled
and ad-hoc signature verification passed; the next lipo command had incorrect
argument ordering. This is corrected before the next build. Linux compiled but
the retained audit identified build paths in copied plugin shared objects and
Dart AOT code. The plugin build now uses relative build/install RPATHs, while
Flutter debug information is split outside the distributable on all targets.
Compiler path remapping is also applied to native macOS compilation.

The RPATH correction passed a real CMake/C/ELF fixture: the old copied plugin
retained its build directory, and the corrected installed executable loaded its
two relocated shared libraries successfully. This fixture is not a native
messenger runtime test. Metadata and release guard tests, workflow lint and
source audit pass. The Windows runtime, macOS packaging and final payload changes must pass the
current revision's required CI builds before draft assembly. Its build manifests
and Actions results are authoritative. No payload audit is disabled.

A later payload inspection isolated Flutter's generated plugin registrant URI in
Dart AOT runtime data. Splitting debug information alone does not remove this
runtime URI. Native packaging now gives the generated registrant a stable
`package:` URI through the ephemeral package configuration, checks the canonical
round trip using Dart's package resolver, and builds with `--no-pub`. Plugin
registration and compiled runtime data are not patched. macOS removes debug-only
Mach-O symbol tables before ad-hoc signing. Linux uses link-time `-rpath-link`
searches for indirect plugin dependencies without embedding those directories.

Windows batch resolution is exercised by the metadata tests on the Windows
runner. The payload audit also checks slash-normalized and UTF-16 build paths;
inspection identified a forward-slash AOT path in the earlier Windows ZIP. Missing runtime libraries still fail report generation. Main
branch builds cancel stale engineering runs; version-tag builds are retained.
Version tags and public release publication still require owner approval.

Existing protected Android credentials are required for installable distributable
APKs; no key is created. Engineering macOS artifacts use ad-hoc signing, without
Developer ID or notarization. Windows/Linux engineering artifacts are unsigned.
The Go privilege-drop failure must pass on a host that supports credential changes.

See [artifact matrix](ARTIFACT-MATRIX.md) and [approval checklist](APPROVAL-CHECKLIST.md).

The engineering run for `92d037b35ba6f4b4807e15e57143e19ee4387afa`
passed full validation, all node bundles and Linux/Windows client packaging,
including the final payload identity audits. The registrant package URI resolved
in the real application configuration. macOS compiled but broad debug stripping
failed on an already-stripped FFmpeg framework's LINKEDIT layout. Debug cleanup
now inspects Mach-O N_STAB entries and only invokes Apple's strip for actual
debug symbol tables; failures remain fatal and the final byte audit is unchanged.
The four TUI images were recaptured from that CI manager using xterm's terminal
parser, removing stale terminal cells left by the previous capture parser.

Android's `--no-pub` build retained a debug native registrant referencing the
nonshipping integration-test plugin, while Gradle correctly excluded that plugin
from release dependencies. Android now runs Flutter's normal release plugin
generation. A Gradle settings init hook then adds the same stable Dart package URI
before compilation. Runtime plugins and generated Java registration are not
manually removed, and the final ABI, signature and payload checks remain required.
