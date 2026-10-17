# Loom 1:1 WebRTC calling

For a new Home Node, use the [installation wizard](node-setup.md). Choose `auto`
for voice calls, then select video and group calls. It provisions the selected
TURN/media services. `loom setup` reopens these choices later. The manual
configuration below is for an existing operator-managed TURN service.


Loom calling reuses the existing `LoomCallEngine`, `flutter_webrtc`, verified Loom identity/device model, Home Node authentication, and federation stack. It does **not** introduce a second calling architecture or a fake media layer.

## Client architecture

`LoomCallSessionController` is app-scoped and survives MessengerShell route/tab changes. It owns one `LoomCallEngine`, the authenticated call API/signaling connection, incoming-call state, verified peer metadata, and local SQLite call history.

The production UI exposes calls from:

- the direct-conversation header (Audio and Video buttons);
- People search results and saved Contacts;
- the verified peer profile screen;
- the Calls history screen (`Call again`).

Calling is rejected with a visible error instead of silently doing nothing when the conversation is not 1:1, the Home Node/session is unavailable, the verified peer has no active compatible devices, the peer identity no longer matches, or another call is already active.

The active call route uses the existing real `RTCVideoRenderer`s. Remote video fills the main surface, local video is a draggable picture-in-picture preview, camera-off/remote-video-not-yet-available states fall back to the peer avatar/identity surface, and the controls include microphone mute, camera toggle, camera switch, speaker, and hang up. Leaving the route keeps the call alive and shows the app-level minimized call bar.

## Call lifecycle

Outgoing UI state:

`idle -> preparing -> calling -> ringing -> connecting -> connected -> ended`

The shared engine represents both `calling` and `ringing` with its ringing lifecycle plus the authenticated remote-ringing hint (`remoteRinging=false/true`). This keeps the existing model compatible while presenting the distinct user states required by the product.

Incoming UI state:

`incoming ringing -> accept/reject -> connecting -> connected -> ended`

The engine also exposes `reconnecting`, explicit end reasons, answered/ended timestamps, remote camera/video state, and a WebRTC stats-derived connection-quality indicator. Network/peer-connection disruption performs bounded ICE restart attempts before failing cleanly.

## Authenticated signaling

Client signaling uses authenticated WSS at:

`/realtime/v1`

The WebSocket upgrade uses the same bearer session plus Loom device-bound request proof used by authenticated Home Node operations. The server derives the sender identity from the authenticated session; the client does not get to choose a trusted sender identity or caller display name.

Every routed signal is tied to:

- call ID;
- direct conversation;
- authenticated sender identity ID;
- verified target identity ID;
- canonical Loom sender/recipient addresses;
- monotonically supplied sequence value and replay/deduplication key.

Malformed call frames are ignored/rejected without SDP/ICE details being reflected into diagnostics. Duplicate `(sender identity, call ID, sequence)` frames are idempotent.

The pending-call recovery endpoint is:

`GET /api/v1/calls/pending`

Pending offers expire after the call timeout and are revalidated when the client resumes.

## Same-Node and federated signaling

Same-Node and federated calls use the same client UX.

Same-Node signals remain inside the verified Home Node process and are mapped to the recipient account's direct-conversation ID before delivery.

Federated call signaling uses the dedicated signed call-federation envelope envelope over the existing verified Node-to-Node federation path. The destination Home Node:

1. verifies the originating Node identity/signature;
2. verifies the destination Node/domain;
3. resolves the canonical sender address through the normal federation identity path;
4. verifies that the resolved identity ID equals `senderIdentityId`;
5. verifies that the local recipient canonical address resolves to `targetIdentityId` before local delivery.

There is no unauthenticated direct cross-node signaling endpoint and Home Node verification is not bypassed.

## Operator controls

Node Manager 0.8.0 adds a Calls page and a guided TURN configuration command:

```bash
sudo /opt/loom-node/bin/loom-node-manager --home /opt/loom-node --configure-calls
```

It requires an interactive terminal, hides the TURN secret, validates endpoints, requests confirmation, recreates only the Node and rolls back configuration if readiness checks fail. It configures an existing TURN service; it does not provision coturn. A ready RTC configuration is not proof that relay ports are reachable. Test audio/video on different networks and configure both Nodes for federated calls.

The master switch defaults off. Voice/video switches default on and govern new signaling offers; video-off also rejects `camera-on` upgrades. Policies are applied to local and verified federated signaling. Applying configuration restarts the Node and interrupts active calls. These are application signaling policies, not a media firewall. The Groups page reports the missing production MLS engine; group messaging and group calling remain unavailable.

## STUN / TURN

The authenticated RTC configuration endpoint is:

`GET /api/v1/calls/rtc-config`

Production calling is opt-in and Node configuration validation refuses to enable it without authenticated TURN.

Environment variables:

```text
LOOM_CALLS_ENABLED=true
LOOM_VOICE_CALLS_ENABLED=true
LOOM_VIDEO_CALLS_ENABLED=true
LOOM_STUN_URLS=stun:turn.example.org:3478
LOOM_TURN_URLS=turn:turn.example.org:3478?transport=udp,turn:turn.example.org:3478?transport=tcp,turns:turn.example.org:5349?transport=tcp
LOOM_TURN_SHARED_SECRET=<at-least-32-random-characters>
LOOM_TURN_CREDENTIAL_TTL_SECONDS=600
```

The Node generates coturn REST-style short-lived credentials using `expiration:identityId:deviceId` as the TURN username and an HMAC credential derived from the server-only shared secret. The shared secret is never returned to clients or written to call diagnostics.

Deploy TURN so at least UDP relay is available and, for restrictive networks, TCP and TLS relay endpoints are reachable. Testing only two peers on the same LAN is not sufficient; the manual acceptance test below requires an off-LAN relay/NAT traversal scenario.

## Security claims

Accurate statement in the UI:

> Encrypted WebRTC call

This means WebRTC's normal DTLS-SRTP media protection is in use between WebRTC endpoints/relay path. TURN relays encrypted WebRTC packets and does not require Loom Node application storage to receive plaintext media.

Loom call signaling itself is protected by authenticated HTTPS/WSS and verified Loom identity/Home Node routing.

**Not implemented/claimed:** an additional Loom application-layer media E2EE transform (for example WebRTC encoded transforms/SFrame-style application encryption) on top of normal WebRTC peer transport. Do not label that as implemented until it actually exists and is independently tested.

The Loom Node application does not store audio/video media payloads as call content.

## Diagnostics

Call diagnostics deliberately separate broad failure domains without logging SDP, ICE candidates, TURN passwords/shared secrets, access tokens, or media:

- signaling/authentication failure;
- microphone/camera/media acquisition failure;
- ICE/reconnect failure;
- TURN configuration/credential failure;
- peer-connection failure;
- malformed/replayed signaling counters;
- federation call-signaling failures.

Client UI maps permission/media failures to understandable recovery guidance rather than leaving the engine half initialized.

## Android native integration

Android includes:

- `CAMERA` and `RECORD_AUDIO` only for media capture;
- audio settings and Bluetooth-connect permissions for call routing where supported;
- a high-importance incoming-call notification channel;
- Accept/Decline notification actions;
- full-screen incoming intent only where Android permits it (`canUseFullScreenIntent()` on Android 14+);
- an ongoing call foreground service started for a genuinely active call, with microphone/camera foreground-service types as appropriate;
- notification permission requested when calling is used rather than at unrelated app startup.

Android can restrict full-screen intents and background/foreground-service starts depending on OS version, user settings, app state, and store policy. Loom treats those native surfaces as capability-gated; a failure to show one must not destroy an otherwise active WebRTC call.

## Background / terminated-app boundary

A foreground WebSocket cannot wake an app process that the OS has suspended or terminated.

The Node therefore exposes `LoomCallPushGateway`. The default `DisabledLoomCallPushGateway` intentionally does nothing and reports `available=false`; pending calls remain retrievable when the app resumes. A deployment that requires reliable terminated-app incoming calls must connect a real device-token/push provider (for example FCM/APNs or an equivalent platform service) to this boundary. Do not claim terminated-app incoming calling until that provider and device registration path are deployed and tested.

Android native notifications in this change handle calls once the Flutter process receives/retrieves the incoming offer. They are not a substitute for the missing server-to-device push provider.

## Windows limitation

The Flutter/WebRTC call engine, call state/history, and foreground incoming surface remain cross-platform. Native Windows toast activation for a terminated Loom process is not implemented in this change because the repository does not yet contain a Windows push/device-registration provider equivalent to the server push boundary. When the app is running/resumed, pending-call recovery supplies the incoming state.

This limitation is explicit rather than pretending that a foreground WebSocket is sufficient.

## Avatars

Call surfaces consume the existing `LoomAvatar` component. That component renders a supplied real image when an `ImageProvider` is available and otherwise falls back to initials. The current verified user/federation profile payload in this repository does not expose an avatar image field, so the call feature does not invent or fetch an unverified avatar URL. When the verified avatar profile field is added, pass it through `LoomCallPeer` and these call surfaces rather than adding a call-only avatar system.

## Automated validation added with this feature

Focused tests cover:

- persisted answered call history and duration;
- missed-call filtering and history transition updates;
- call snapshot lifecycle and control-state transitions;
- Calling vs remote Ringing state;
- malformed call signaling ignored safely;
- duplicate signaling processed once;
- target identity spoofing rejected;
- STUN-only development configuration;
- authenticated short-lived TURN credentials;
- TURN UDP/TCP/TLS URL propagation;
- production TURN readiness;
- incoming-call EN/FA/RTL surface;
- MessengerShell audio/video action presence;
- Calls screen removal of production preview fixtures.

Real WebRTC media/device behavior still requires platform/device validation because desktop/unit runners cannot prove microphone, camera, audio-route, codec, NAT, and OS interruption behavior.

## Required manual acceptance test

A PR must **not** claim real-device calling is validated until the following is executed and recorded.

### Audio

Device A / Account A:

1. Open a direct conversation with Account B.
2. Tap **Audio Call**.
3. Confirm A shows Calling and then Ringing only after B receives the offer.
4. Confirm Device B receives the incoming-call UI/notification with the correct verified caller identity/address.
5. Accept on B.
6. Confirm both sides transition through Connecting to Connected.
7. Confirm A can hear B and B can hear A.
8. Mute/unmute each side and verify remote audio behavior.
9. Toggle speaker/earpiece where the platform supports it.
10. Connect/disconnect Bluetooth or a wired headset where available and verify routing recovers without ending the call.
11. Hang up from each side in separate runs.
12. Confirm both devices persist the correct history entry, direction, timestamps, outcome, and duration.

### Video

Repeat with **Video Call** and verify:

1. Remote video becomes visible on both sides.
2. Local preview is visible and draggable.
3. Hide/show call chrome.
4. Disable camera: the remote side sees the avatar/camera-off state, not a broken black surface.
5. Re-enable camera.
6. Switch front/back camera.
7. Rotate the device and verify video orientation/aspect remains usable.
8. Background/foreground the app and verify call continuity permitted by the OS.
9. Interrupt camera availability where practical and verify graceful recovery/failure.

### Network/TURN

At least one acceptance run must put the peers on different networks, for example:

- Device A on home Wi-Fi;
- Device B on cellular data or a different restrictive Wi-Fi.

Use WebRTC/coturn diagnostics to confirm that a relay candidate is selected in at least one run. Also switch Wi-Fi <-> cellular during an active call and verify the UI enters Reconnecting and either recovers through ICE restart or ends with a clear connection failure.

### Failure cases

Verify separately:

- microphone denied;
- camera denied (audio remains usable; video offers recovery guidance);
- caller cancels before answer;
- receiver declines;
- receiver is already in another call -> Busy;
- no answer / pending-call expiry;
- malformed/duplicate signaling does not create duplicate incoming UI;
- peer device/identity change blocks calling rather than silently calling the wrong identity.

Record device models, OS versions, Node commit, TURN server/version, network types, selected ICE candidate type, and pass/fail notes with the PR before declaring the acceptance test complete.
