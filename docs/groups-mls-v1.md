# MLS group infrastructure

The alpha client connects the Flutter UI to the native MLS engine.
Groups appear in the ordinary Chats list and participate in All, Groups, Unread, Pinned and custom folders. They open the same conversation pane, composer, wallpaper and media player as direct chats. The New group action opens creation directly from Chats; there is no separate encrypted-group catalogue. Invite completion and notifications navigate to the ordinary messenger with the group selected. Pin, mute and archive preferences persist on this device. Use Chats → Create → New group. Create a group with only yourself, add
Home Node usernames without saving contacts, or share a token invitation link.
Group members can send text, photos, videos, audio and files. The account-based
member list opens private conversations; role changes and removal apply to all
of that account's current group devices. Sending a new bubble uses the same
short rise/scale animation in groups and direct chats; the inserted row grows into place so earlier bubbles move upward smoothly. Reduced motion skips both movements.

Administrators create a seven-day link in either open or approval mode. Creating
another link revokes the previous one. Links can also be explicitly revoked.
Open requests are accepted automatically; approval requests require an admin's
Approve action. Actual membership still requires a device-generated MLS Welcome:
an administrator device processes accepted requests during foreground sync.
If no administrator device is online, the join screen shows the waiting state.
The server cannot issue group secrets. Invite previews expose the title, account
count and join mode, but no roster or previous messages. The token is hashed in
storage and contains no cryptographic group keys.

Android opens the HTTPS landing page's Open in Loom button through a custom
scheme, after onboarding and App Lock. Desktop users paste the HTTPS invitation
in Chats → Create → Join with link. Invitations must belong to the account's current Home
Node. Existing members' new devices still require separate MLS additions.
Invited devices publish credentials and single-use key packages when opening
this version. Removing a device prevents it decrypting later epochs; this client
does not reuse its old MLS state for rejoining and requires a new authorized
device. Revoking a link cancels outstanding additions, not existing memberships.

Groups remain same-Home-Node. There is no legacy migration, history transfer to
new members, group federation, self-leave or disband. Group calling uses the separate
operator-configured media service described in [group-calls.md](group-calls.md). Removed
devices retain old local history. Narrow screens return to the group list before
leaving; drafts survive switching groups and failed sends. Read cursors persist
across restart. Account recovery does not recover the native ratchet.

Attachments use the existing encrypted upload/download path: fresh AES-GCM keys
and metadata travel inside the MLS application plaintext, never in server message
metadata. Media is cleared on App Lock; generic files are saved only to a
user-selected destination (Android Storage Access Framework or desktop picker).
The Home Node attachment size limit still applies. Native iOS export/MLS
packaging is outside the Android/Windows workflow.

The Node advertises the MLS group protocol and `mls-groups-home-node`. Admin diagnostics
report `messagingReady: true` when MLS delivery storage is operational; this is
backend readiness, not a general native-client release approval. The engineering
client uses the separate MLS path only after its native engine and signed session
initialize.
Missing libraries, unavailable API routes and changed account/device keys remain visible
errors. Native Windows runtime QA and physical-device calling QA are still
required before a production release.

## Implemented

- OpenMLS 0.9.0 native core; RFC 9420 suite
  `MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519`.
- Per-device, Ed25519-authenticated MLS credentials and signed single-use key
  packages. Initial invitations and subsequent additions deliver device-scoped
  Welcomes. Removed devices get their removal commit but no later ciphertext.
- Creation, owner/admin/member permissions, ownership transfer through a role
  update, member addition/removal, title changes and epoch rotation.
- Server-side SQLite/PostgreSQL transaction adapters, revision/epoch CAS,
  immutable operation IDs with collision detection, bounded inbox pagination,
  revoked-device checks, and atomic membership/conversation changes.
- Client signed HTTP transport, off-isolate native byte ABI, authenticated
  encrypted native snapshots, device-local wrapping-key vault, SQLite CAS and
  immutable outbox, encrypted history callback, ordered inbox processing and
  restart/uncertain-delivery recovery.
- A confirmed old-epoch message rejection preserves the advanced ratchet state
  and an encrypted retry draft. An uncertain result retains the exact outbox.
  A definitively rejected membership commit restores its encrypted checkpoint
  under a new local database CAS version. It is never restored after a timeout.
- Two previous native message epochs are retained to handle application messages
  ordered immediately before an accepted local commit. Historical catalogue
  membership advances when the commit echo reaches the inbox cursor; the sender
  does not skip older inbox messages when accepting its own commit receipt.

## Trust and persistence

The delivery server never receives native secret state, group keys or message
plaintext. It does see group titles, membership, roles, sizes and timing. Roles
and titles are Home-Node-authoritative metadata; this is not an end-to-end
metadata secrecy or malicious-server permissions guarantee.

The app supplies a `LoomGroupTrustedDeviceResolver` using the same verified
Home Node identity directory and trust-on-first-use root/device pins as direct
chat. A saved contact is optional; previously pinned changed roots or revoked
devices block membership. First use trusts the directory response, not an
out-of-band identity verification.
`verifyLoomGroupMember` cannot establish trust from an invitation's public key.
The MLS leaf signature key must match its device-signed certificate. The native
engine checks the actual MLS roster against those device pins at join/commit.
Application senders are taken from the authenticated MLS credential, not the
server's sender label.

A group session serializes operations across the device's whole native store.
A second instance still has to win the durable SQLite CAS. Successful native
operations return sealed candidate state; validation failures return no candidate
state. A controller must persist the state and outbox together before transport.
All local history must be encrypted by the injected history sealer. No plaintext
history may be passed to `LoomGroupStore`.

`LoomMlsStateKeyVault` uses App-Lock-aware OS secret storage and a file lock for
initial wrapping-key creation. The native database and wrapping key are device
state: **exclude both from recovery PDFs, account recovery exports and device
linking**. Missing wrapping keys require a new authorized device and a fresh
Welcome, never resetting the live ratchet or silently generating a replacement
key for an existing native database. Generic recovery does not restore group
sending state.

## HTTP surface

All API routes require the existing bearer session and device-bound request proof.
The public `/g/:token` landing page contains no group metadata.
The server accepts only devices registered on this Home Node.

| Method | Route | Purpose |
| --- | --- | --- |
| GET | `/api/v1/groups` | Device inbox group IDs and account conversation IDs |
| POST / GET | `/api/v1/groups/devices/:deviceId/credential` | Publish own / read active device's MLS certificate |
| GET | `/api/v1/groups/devices/:deviceId/profile` | Active device account identity and public username |
| POST / DELETE | `/api/v1/groups/:id/invites` | Create/replace an admin-controlled link / revoke links |
| GET / POST | `/api/v1/groups/invites/:token` / `.../:token/join` | Preview / request membership |
| GET | `/api/v1/groups/:id/join-requests` | Admin pending/accepted queue |
| POST | `/api/v1/groups/:id/join-requests/:deviceId` | Approve or decline a request |
| POST / GET | `/api/v1/groups/key-packages` | Publish a signed package / count own available packages |
| POST | `/api/v1/groups/key-packages/:deviceId/claim` | Atomically reserve for ten minutes |
| POST / GET | `/api/v1/groups/:id` | Create / read authorized state |
| POST | `/api/v1/groups/:id/commits` | CAS-protected epoch and membership change |
| POST | `/api/v1/groups/:id/messages` | Deliver opaque application ciphertext |
| GET | `/api/v1/groups/:id/inbox?after=N` | Ordered, device-scoped events |

Invite additions carry `joinRequestDeviceId` on the normal MLS commit. The
server checks current approval, expiry/revocation and the exact addition under
the same group transaction, before consuming any key package. The request
cannot elevate roles or change existing roster metadata.

No group ciphertext is sent through `/api/v1/messages` or the legacy direct codec.
The existing refusal of that path remains intentional. Adding a newly linked
account device is an explicit MLS addition; account membership alone does not
make its new device a cryptographic member. Revoking a member device blocks
further group sends until an authorized admin removes it and rotates the epoch.
Current reservations are bounded by the normal authenticated device rate limit;
expired reservations can be reclaimed and consumed packages cannot be reused.

## Building and tests

Rust, Cargo and cargo-ndk 4.x (Android) are prerequisites. The committed lockfile pins native dependencies.

```bash
cargo test --locked --manifest-path native/loom_mls/Cargo.toml
cargo clippy --locked --manifest-path native/loom_mls/Cargo.toml --all-targets -- -D warnings
bash scripts/build-mls.sh host
```

On Windows, `scripts/build-mls.ps1 -Target Windows` builds the DLL. Install
`cargo-ndk` and the Android Rust targets for cross-building; the script installs
those targets, but does not install Rust, cargo-ndk or the NDK. With a configured
NDK, `scripts/build-mls.ps1 -Target Android -NdkPath PATH` or
`bash scripts/build-mls.sh android` places three ABI libraries in Android's
standard `jniLibs` directory and requests 16 KB ELF alignment. Native Android and
Windows packaging still needs platform build verification before activation.
Host compilation alone is not Android/Windows verification.

Server tests:

```bash
cd services/loom_server
npm ci
npm test
```

Client persistence tests: `dart test test/group_store_test.dart` from
`packages/loom_storage`. The end-to-end test runs actual native MLS, three Dart
clients, signed HTTP requests and an ephemeral real Node server:

```bash
cd packages/loom_transport
dart pub get
LOOM_TEST_MLS_LIBRARY=/absolute/path/to/libloom_mls.so \
  dart test test/group_session_integration_test.dart
```

The fixture generates disposable identities and tokens. It tests key-package
publication, device certificates, creation, messaging, lost acknowledgement and
exact retry after reopening SQLite, a message racing a membership commit,
addition, removal and post-removal send denial. Normal test runs skip this case
unless the native library environment variable is supplied. Linux needs a
loadable `libsqlite3.so`; Flutter mobile applications use their bundled SQLite.

## Remaining activation work

- Package and verify the native library on Android/Windows, exercise background
  sync and device revocation, and complete the independent MLS integration review.
  iOS/macOS native packaging is not supplied by the Android/Windows build helpers.
- Verify PostgreSQL against a real multi-worker PostgreSQL server. The common
  transaction code uses row locks, advisory creation locks and CAS; the executed
  end-to-end tests cover SQLite, not PostgreSQL deployment.
- Group federation, self-leave proposal orchestration, group disbanding and group history transfer remain outside
  this first infrastructure layer. Individual MLS additions and removals work;
  combined add/remove operations are intentionally separate epochs.

This is not a cryptographic audit or a claim that the complete group product is
shipping. Preserve the explicit capability gate until those activation items are
implemented and verified.

## Application integration validation

`apps/loom/test/groups_controller_native_test.dart` launches the real Node
fixture and uses the actual Rust library through the production controller.
It tests encrypted messages, unread alerts, encrypted on-disk history, restart,
add/remove commits, post-removal send denial, owner-only creation, open and
moderated invite joins, encrypted attachment metadata, profile resolution,
link revocation, no earlier-message delivery and App Lock teardown. Set
`LOOM_TEST_MLS_LIBRARY` to the built host library; without it this integration
test explicitly skips. The `mls-native-integration` CI job supplies that library.
The transport integration additionally covers lost acknowledgements and racing
commits. `groups_ux_test.dart` covers Persian/English, 320/700/1280px, large text,
failed-send drafts and narrow-screen back navigation.

Android Gradle, Android PowerShell helpers and CI build all three native ABIs.
Windows CMake builds and installs the DLL beside the executable. The build
requires the installed Android NDK; the helper uses cargo-ndk's `-P 24` platform
flag and runs from the Rust manifest directory. Generated binaries are ignored.
A stock of five single-use key packages is replenished after initialization and
periodically during foreground group synchronization.


## Node operator administration

Server 0.10.6 and Node Manager 0.8.2 provide MLS administration in the Groups
screen. Refresh shows group titles, IDs, epochs, roster counts, MLS revisions,
message sequences, stored inbox record counts and available key-package stock.
Inspect members shows account/device roles and whether devices are revoked or
missing. A revoked device still requires a client-generated removal commit.

All endpoints below require the Node admin bearer token. Ordinary client session
credentials cannot authorize these operations. The manager reads the admin token
inside the Node container; it does not put the secret in command arguments.

| Endpoint | Operation |
| --- | --- |
| `GET /admin/v1/groups?limit=50&after=<group-id>` | Metadata list; limit 1–100, keyset pagination using `nextAfter` |
| `GET /admin/v1/groups/<id>` | Redacted metadata and device roster |
| `POST /admin/v1/groups/<id>/policy` | `{ "paused": true, "expectedPolicyRevision": 0 }` |
| `POST /admin/v1/groups/key-packages/cleanup` | Delete at most 1000 expired, unused, unreserved packages |

Pause/resume persists in an additive policy table and uses a separate policy
revision. A stale operator action receives `409 group_policy_conflict`. Policy
changes lock the same group row as message delivery. While paused, new messages
receive `423 group_paused`; previously accepted retries return their original
receipt. Inbox reads and client-generated MLS commits remain available. Changing
policy does not change the MLS epoch, roster, revision or keys. The TUI asks for
confirmation before changing policy or cleaning packages.

Cleanup preserves live reservations, consumed-package tombstones, inbox records
and operation history. Inbox record counts include retained per-device ciphertext
records; they are not unread counts or delivery acknowledgements. Admin responses
never include key-package payloads, MLS signing keys/signatures, commits,
Welcomes, application ciphertext or client secrets.

Admin diagnostics and status report backend MLS delivery readiness, scope and
stock counts. `/readyz` includes MLS storage readiness. These signals describe the
Node API, not a cryptographic audit, native packaging, group calls or cross-node
MLS federation. The Node Manager is an operator console; encrypted conversation
creation, sending and membership key rotation run in the native client.

## Client/server update requirements

Invitation routes require Home Node 0.10.6 or later. An HTTP 404 with `not_found`
(including an HTML proxy 404) is reported as an unavailable group API with an
explicit server update instruction. `group_invite_unavailable`,
`group_not_found`, and other resource errors stay distinct. Client updates alone
cannot install routes on an older server. The deployment Caddy configuration
proxies every path, including `/g/` and `/api/v1/groups/`.

The shared conversation surface is a memory-only view of decrypted MLS history.
It never inserts group plaintext, attachment keys or group messages into legacy
messaging tables. Durable local preference rows use the group ID, independently
of the dedicated MLS inbox/outbox and read cursor. Unchanged group syncs reuse
the same visible message snapshots.

AES-GCM encryption/decryption of files of 256 KiB or more runs in a worker
isolate. Transfer buffers contain ciphertext or ephemeral plaintext only;
worker plaintext buffers are cleared after transfer. Download progress updates
are coalesced before repainting the media tile.

## Group details and invitations in the client

The Chats create menu contains New group. Joining a group happens by tapping its
invitation in a conversation (or opening an invitation deep link). A tapped link
opens the group preview directly, without asking the user to paste it again.
Joining or completing approval returns to the ordinary messenger route.

Tapping the group header opens a full group information page with searchable
Members and Administrators tabs. Each account appears once, regardless of its
device count. Profile names and addresses must match the account and identity in
the authenticated MLS roster; these labels stay in memory and clear on app lock.
Refreshing retries failed profile lookups. Presence is not inferred from group
membership. Tapping another member opens a private chat without saving a contact.

Admins can add members, manage invitations, review join requests, rename the
group and remove ordinary members. Only the owner sees role changes, removal of
other admins and ownership transfer. Destructive changes still require explicit
confirmation, a current group revision and backend authorization. Join requests
are displayed per account and a decision applies to its pending device requests.

Group details also expose the existing notification preference and a shared
media browser backed by the same memory-only MLS message projection. Photos,
videos, files and music do not create legacy message or plaintext records.

