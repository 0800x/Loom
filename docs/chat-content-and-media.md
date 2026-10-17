# Chat content and media (0.0.10+16)

Update both clients and the Home Node from `main`. Existing
text and encrypted history remain readable. Older clients cannot render the new
rich document format. No database migration or data reset is needed.

## Replies and status

The authenticated message plaintext contains a versioned document. A reply has
an encrypted snapshot (up to 1024 characters), the original sender and stable
client ID. Local history can supply the full quote; missing history and differing
node row IDs no longer prevent new replies from showing their quote. Historical
replies without a snapshot still need the original message in local history.
Pending local messages can be quoted using their stable client ID.

Swipe toward the reading direction to reply (right in English, left in Persian).
Vertical scrolling and short drags do not trigger a reply. Long press and the
accessible Reply action remain available. Message actions use compact rows and
attachment choices use round colored icons on an opaque sheet.

The conversation menu contains the status guide. Gray single check = Home Node
acceptance; gray double = recipient-device delivery; blue double = read. Nearby
is an icon describing the observed route, never a substitute for delivery/read.

## Media

Pick one photo/video or capture on Android/iOS. Review the preview and optional
caption before sending. Limit: 32 MiB per file. Photos are downscaled to 2560px by
mobile pickers; video recording is limited to one minute, with the same size cap.
Windows supports library selection and explicit Save and open for video playback.
Android/iOS/macOS play video in the app. Download is explicit, with retry on
network or authenticated-decryption failure.

Each file gets a fresh random AES-256-GCM key and nonce. Binary layout is
`nonce(12) || ciphertext || authentication-tag(16)`, with AAD `loom.media.v1`.
The URL/key/size/kind/caption are inside device-bound E2EE, never message metadata.
Uploads are opaque octet streams. The new GET endpoint streams ciphertext from
filesystem or S3 with no-store/nosniff headers. A random 256-bit ID is a download
capability carried inside E2EE; foreign-node recipients do not forward account
credentials to the sender's node. Knowledge of the URL does not reveal a file
key. Clients require HTTPS, the authenticated sender's Home Node host, an exact
capability path and expected length; redirects are disabled. LAN/DTN can carry
the encrypted descriptor, but downloading the blob requires its Home Node.

Decrypted images remain in RAM. Native video playback needs an ephemeral app
cache file, deleted when playback closes or App Lock activates. Interrupted
processes can leave a cache file, cleaned on the next messaging initialization;
app cache is not a secure archive. Export on
Windows is an explicit decrypted copy selected by the user. An OS picker may
pause Android and activate App Lock: only its selected file reference survives
in the session; reopen that conversation after unlocking and tap the selected
media banner to preview. A process killed by Android may require selecting again.

## Location

Current GPS location can be sent after permission and preview. Live sharing is
15 minutes or one hour, with authenticated encrypted updates every 30 seconds.
A sender/session pair renders as one latest-position card. Stop, expiry,
backgrounding, logout/dispose and App Lock stop starting new fixes; late in-flight results are discarded. Live sharing
is foreground-only; the duration is a maximum, not a background tracking promise.
A remote viewer follows new authenticated positions while open. Last-update time
is visible, and an absent stop packet cannot extend the advertised expiry.

The cross-platform viewer uses OpenStreetMap tiles with attribution and a Google
Maps navigation button; it does not need a Google Maps API key. Tiles are loaded
only when opening/previewing the map, not while scrolling message cards. Map tile
requests disclose the viewed region to the tile provider; opening Google Maps is
an explicit handoff to that service. Chat coordinates themselves are inside E2EE.

## Verification

- Node: `node --experimental-strip-types --test test/encrypted_attachment.test.ts`
- Flutter app: `flutter test test/chat_content_security_test.dart test/chat_reply_gesture_test.dart`
- Transport: `dart test test/messaging_engine_test.dart`
- Real devices: reply across two different accounts and absent original history;
  swipe/scroll in Persian and English; camera with App Lock; gallery/video;
  permission denied; offline/oversize/tampered file; 15-minute live session,
  updates with map open, Stop, background, lock and expiry; Windows map/video.

Node's four focused tests were executed locally. Dart source syntax/format and
native configuration XML were checked. Flutter tests and handset behavior need
a Flutter SDK/CI and devices; no claim of a successful release build is made.
