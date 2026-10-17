# Encrypted group voice and video

The [Home Node wizard](node-setup.md) can provision this service during first
installation: enable voice calls and select group calls `on`. `loom setup`
reopens the same choices. Allow the media ports in your provider firewall too.
The steps below cover configuration through the TUI or advanced scripts.


Client **0.0.21+27**, Node **0.10.8**, Manager **0.8.3**. Group calls use a self-hosted LiveKit SFU;
there is no LiveKit Cloud dependency. Updating Node alone does not enable the
optional SFU. Existing one-to-one calls retain their TURN configuration.

## Installed server

Update Node and Node Manager together, then open **Calls → Set up group calls**.
Enter the server public IPv4, select participant capacity and video policy, and
review before applying. The Manager generates independent private credentials,
writes `.env`, `livekit.yaml` and the Compose overlay, saves a private backup,
starts the media service, recreates the Node and checks the authenticated media
API. No shell setup commands or environment-file editing are needed. Existing
credentials and unrelated settings are preserved. Failed startup restores the
previous files and restarts the previous services; recovery errors show the
backup path. Calls end during restart. Video policy also applies to direct calls.

**Check group media service**, **Group media logs** and **Disable group calls**
are available in Calls. Disabling keeps the configuration for later. Readiness
checks verify configuration/private API, not media reachability through NAT.
Provider firewalls remain external; the review page shows the required ports.

For installations needing scripted setup instead, from the updated
source checkout, run as the installation owner/root:

```sh
sudo bash /opt/loom-src/scripts/enable-group-calls.sh SERVER_PUBLIC_IPV4
```

Replace `SERVER_PUBLIC_IPV4` with the server's reachable public IPv4. Python 3
and Docker Compose are required. The helper backs up settings, preserves existing
SFU credentials, creates independent keys when absent, and starts the pinned
`livekit/livekit-server:v1.13.9` on the existing Compose network. It preserves
other environment values, including `LOOM_VIDEO_CALLS_ENABLED=false`.

Allow **TCP 7881 and UDP 50000–50100** through host/cloud firewalls and NAT.
Keep **TCP 7880 private**: never publish or directly reverse-proxy it. HTTPS/WSS
`/conference/rtc` and `/conference/rtc/validate` go to the Node through the normal
Caddy proxy. Signed SFU webhooks go privately to
`http://loom-node:7483/api/v1/group-calls/webhook`.

The updater preserves the existing Compose/environment files and running SFU.
Include both files when restarting the whole stack:

```sh
cd /opt/loom-node/deploy
docker compose --env-file .env -f docker-compose.production.yml -f docker-compose.group-calls.yml up -d
```

Use the same Compose options with `logs --tail=100 livekit loom-node` to inspect
startup failures. Do not share `.env`, `livekit.yaml`, tokens, or raw signaling.

## Manual configuration

Set `LOOM_CALLS_ENABLED=true`, `LOOM_GROUP_CALLS_ENABLED=true`,
`LOOM_GROUP_CALLS_API_URL` to the private SFU HTTP origin,
`LOOM_GROUP_CALLS_API_KEY`, and an independent
`LOOM_GROUP_CALLS_API_SECRET` of at least 32 characters. Optional
`LOOM_GROUP_CALLS_MAX_PARTICIPANTS` accepts 2–32, default 16. Configure the same
credentials and signed webhook in the SFU. Never reuse admin, S3, or TURN secrets.
Calling policy and SFU environment overrides apply to existing JSON configs too.

## Call experience

Open the ordinary group chat and tap its call button. Owners/admins start a voice
or video call, choose everyone-can-speak or approval-to-speak, lock admission and
end the call for everyone. Members join an existing call and raise/lower a hand.
Admins grant/revoke speaking, block microphone/camera, decline requests or remove
an account. Only owners moderate other admins. Removal lasts for that room.

Joining leaves microphone/camera off. Granting permission never enables capture;
the user turns it on explicitly. Minimize to chat, then tap the ongoing call banner
to return. One account joins on one device. Group and one-to-one calls cannot
overlap. Requests have endpoint limits and a ten-second hand cooldown. While no
admin is admitted, one seat stays reserved for moderation.

## Encryption and revocation

Native MLS exports a 32-byte media key bound to the group epoch and room UUID.
It stays on clients. Node/SFU store room metadata and route frame ciphertext.
Native LiveKit E2EE admits encrypted Opus/VP8/H264 microphone/camera tracks;
unencrypted/AV1 publications are not subscribed. No screen sharing, server
recording, data publishing or unencrypted fallback is enabled. Web clients are
not supported for these encrypted calls in this release.

Any MLS epoch change, including membership/role edits, ends the call. Start a new
room with current group keys; in-place key rotation is not implemented. App Lock
leaves locally and destroys the media-key provider. Clients close media after
eight seconds without authorization; server leases expire after fifteen seconds
with a three-second enforcement sweep.

The Node gateway verifies current device, membership, room and lease for every
connection and periodically afterwards. Even SFU-refreshed JWTs are reissued with
zero grants; signed join webhooks apply fresh source permissions. Revocation
removes publications; removal closes signaling and evicts the participant.
Control-plane outages can delay remote enforcement: this is not atomic revocation
across network partitions. Previously admitted recipients cannot be made to
forget keys or media. Node/SFU can still observe membership, timings and speaking
activity.

## Validation

Automated validation: client analyzer clean; 379 Flutter tests passed, 24 existing
hardware/platform skips; 70 transport tests including the real MLS exporter and
signed Node API; 15 one-to-one call-package tests; 5 Rust tests; 144 Node policy and
real WebSocket gateway tests. The setup helper and Manager setup/rollback paths were checked with Docker mocked. Manager tests passed with race detection except the existing root privilege-drop test, which cannot execute in the restricted environment.
The Persian interface was rendered with production fonts.

Android/Windows release builds, physical multi-device SFU calls, container startup
on an actual host and a formal security audit were not run in this environment.
