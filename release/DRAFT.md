# Loom 0.6.0 — Alpha Preview

Loom 0.6.0 is a major alpha update across the Flutter clients, Android integration, messaging and MLS flows, reverse DTN delivery, the Node Home Node runtime, maps, and the release pipeline.

> **Release status:** Alpha preview for testing. This is not a stable release or an independent security audit. Keep recovery exports and do not rely on alpha builds for critical communications.

## Highlights

- More reliable group calls, Android message notifications, onboarding and recovery flows.
- Smoother chat rendering under rapid typing and realtime event bursts.
- Multi-message offline queuing and more resilient MLS group synchronization.
- Reverse DTN delivery improvements for reaching an offline phone through a nearby online device.
- Server resilience fixes for long-running nodes, attachment downloads, rate limiting and PostgreSQL.
- Runtime-selectable map tile sources and a self-hostable OSM-compatible tile cache.
- Rebuilt release metadata and multi-platform client, Node Manager, Node runtime and MinIO artifacts.

## Client, Android and user experience

- Fixed group-call video mirroring so only the local participant is mirrored; stabilized video tiles and participant rows, improved speaker and hand-raise indicators, and reduced unnecessary animations.
- Reworked the floating group-call mini bar, call duration display, dark call stage, call error retry affordance and 1:1 call transitions.
- Fixed Android notification warm-start navigation and POST_NOTIFICATIONS permission-result delivery; notification settings now reflect the operating-system state.
- Improved onboarding and recovery verification, including clearer failure states, recovery fallback navigation and server identity confirmation.
- Added system-default language selection and consistent Vazirmatn fallback for Persian text.
- Improved audio focus, seek-slider behavior, voice-session queue handling, camera permission recovery and media time formatting.
- Updated chat bubbles, music attachments, folder unread counts, delete confirmations, group timestamps and group exit/delete actions.
- Fixed a glass-sheen layout overflow and removed continuous presence animations that wasted battery and frame time.

## Messaging, MLS and call verification

- Failed encrypted MLS message events can be quarantined so one malformed message does not permanently block group synchronization. Structural MLS failures still surface for recovery/resynchronization.
- Offline outbox handling now supports multiple queued messages, typing frames and key packages while preserving the rule that an unacknowledged commit blocks dependent operations.
- Added a call-verification code derived from the 1:1 DTLS certificate fingerprints or the group-call MLS key. Participants can compare the same four-digit and three-emoji code to detect a mismatch.
- Realtime typing updates now use a dedicated notifier; chat refreshes are coalesced and decrypted-message results are cached to avoid rebuilding and decrypting entire conversation windows for every event.

## Reverse DTN delivery

The Node-to-nearby-device-to-offline-phone path now has coordinated radio windows and roles:

- Offline receivers keep their rendezvous advertisement alive for the receiver window.
- Online devices scan as gateways; offline devices advertise as receivers, avoiding conflicting roles when connectivity is known.
- Receiver rendezvous and gateway scan windows are extended, and maintenance scheduling gives offline receivers useful rendezvous time.
- A yield signal releases the radio promptly when a send, persist or disable operation needs it.

The gateway relays encrypted payloads and does not receive message plaintext. Delivery timing still depends on Android hardware, permissions, background restrictions and radio scheduling; it is not guaranteed.

## Node Home Node runtime and storage

- Attachment downloads use a separate bounded 16-slot admission gate and a 30-second socket-idle deadline, so suspended clients cannot occupy the shared API admission pool indefinitely.
- Idle rate-limit buckets are swept to prevent random or expired authorization tokens from permanently filling the limiter map.
- Health and readiness probes bypass request admission and continue to report process health during API saturation.
- PostgreSQL pool capacity is increased to 40, with statement, lock and idle-transaction timeouts to bound stalled work.
- Fire-and-forget routing counters now handle rejected promises; process-level failure handling logs unhandled rejections and performs orderly shutdown for uncaught exceptions.
- The Docker deployment provides a trusted-proxy CIDR default for the private Docker bridge. Operators using a different proxy network must set `LOOM_TRUSTED_PROXY_CIDRS` to the actual trusted proxy CIDRs; do not trust public or tenant networks.
- Added attachment admission resilience tests and map tile cache tests.

## Maps

- Map tile source is now configurable at runtime: OpenStreetMap, Snap Map, CARTO, a self-hosted Loom node, or a custom XYZ endpoint.
- The Node runtime can cache OSM-compatible raster tiles, enforce image content and size limits, warm country bounding boxes and serve cached tiles when the upstream is unavailable.
- Admin endpoints expose cache status, warm-up and purge operations. The service is for raster basemaps; satellite and Google tile sources are intentionally not included.

## Server images and Home Node deployment

The release workflow builds and publishes the Loom Node runtime and MinIO images for **linux/amd64** and **linux/arm64**. The MinIO image is built from a pinned upstream source revision; the Home Node installer pulls the published images rather than compiling them on the VPS. The Node Manager is built for Linux amd64 and arm64 and packaged with the release.

The production Compose stack uses the image tag recorded for the exact source revision. Keep the Node and MinIO image tags aligned when deploying or rolling back.

## Regression coverage

The review report for this revision records the following suite sizes:

| Suite | Tests |
| --- | ---: |
| Node server | 176 |
| `loom_transport` | 74 |
| `loom_dtn` | 50 |
| `loom_messaging` | 28 |
| `loom_storage` | 63 |

GitHub Actions is the authoritative build gate for this release. A release candidate is published only after its required validation and artifact jobs succeed. Check the workflow run and each artifact manifest for the exact commit and toolchain used.

## Known limitations

- Push delivery after the application process has been killed still requires a push transport such as UnifiedPush or a self-hosted push service.
- Audio output-route selection (speaker, headset and Bluetooth) does not yet have a dedicated UI.
- Background Nearby behavior and cross-network calls require testing on physical devices and real deployments.
- Upload progress for attachments is currently indeterminate rather than byte-accurate.

## Build and signing status

Artifact filenames and manifests identify platform, architecture and signing mode. Unsigned-engineering Android APKs are not installable as-is. Windows and Linux desktop packages are unsigned. macOS packages are ad-hoc signed and are not Developer ID signed or notarized. Do not interpret a successful compile as a production signing or independent security-audit result.

Keep identity and recovery backups before upgrading. See the README and compatibility documentation before connecting older installations.
