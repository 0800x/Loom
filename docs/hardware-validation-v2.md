# Loom Architecture v2 — real-device validation runbook

This runbook defines the evidence required before the Android Nearby implementation or endpoint behavior may be described as production-validated. It is intentionally separate from unit/integration tests: a mock radio, emulator, or successful compile is not evidence that BLE, Wi-Fi Aware, Wi-Fi Direct, Doze, OEM background policy, thermal behavior, or battery consumption is correct on real hardware.

## 1. Preconditions

Run the local software validator first:

```bash
bash scripts/validate-architecture-v2.sh
```

or on Windows:

```powershell
.\scripts\validate-architecture-v2.ps1
```

Record the exact commit SHA, app build/version, Android build fingerprints, device models, API levels and whether Developer Options/battery exemptions were changed. Do not grant special battery exemptions unless the individual test explicitly asks for them.

## 2. Minimum device matrix

Use at least three physical Android devices from different OEM families. The matrix must include:

- one Android 10/11 device for legacy BLE/location permission behavior when available;
- one Android 12 device or newer for Nearby Bluetooth runtime permissions;
- one Android 13 or newer device for `NEARBY_WIFI_DEVICES`;
- at least two devices that support Wi-Fi Aware for Aware tests;
- at least two devices that support Wi-Fi Direct;
- at least one OEM known to apply aggressive background/battery restrictions.

Unsupported hardware is a valid result and must be surfaced as a capability, not treated as a failed identity or peer.

## 3. Security invariants to observe on every bearer

For BLE, Wi-Fi Aware and Wi-Fi Direct:

1. discovery exposes only rotating rendezvous material and short-lived native handles;
2. MAC addresses, IP addresses, Android `PeerHandle`, PSM and socket endpoints never become Loom AccountId/DeviceId;
3. no DTN peer frame is accepted as authenticated until the Loom peer-authentication layer succeeds;
4. malformed/oversized frames close or reject the link without process crash;
5. disconnect/reconnect creates a new physical-link capability and does not create a new logical message identity;
6. PacketId/MessageId dedup survives bearer changes and process restart;
7. a raw bearer or hop ACK never changes UI state to Delivered.

Capture logs with private message content disabled/redacted.

## 4. BLE L2CAP CoC matrix

For every BLE pair:

- permission denied → operation fails cleanly;
- permission granted → bounded scan discovers rotating advertisement;
- advertiser restart changes physical/native handles without changing Loom identity;
- connect, bidirectional framed transfer, close and reconnect;
- transfer at minimum frame size, normal peer frame size and configured maximum;
- oversized frame rejection;
- Bluetooth toggled off during scan, connect and active transfer;
- permission revoked while app is backgrounded;
- peer disappears during L2CAP connect;
- process kill after DTN custody but before send, then reopen and resume exact packet;
- process kill after send but before hop ACK, then retry exact prepared bytes.

## 5. Wi-Fi Direct matrix

For every supported pair:

- DNS-SD discovery finds only the Loom rotating rendezvous service;
- connection negotiates without exporting device MAC as identity;
- dynamic TCP listener/accept path transfers bounded frames both directions;
- group-owner/client role changes do not change logical peer identity;
- Wi-Fi toggled off mid-transfer;
- peer service disappears between discovery and connect;
- repeated discovery does not leak stale native handles indefinitely;
- network handoff back to Internet/LAN/BLE leaves PacketId and message status stable.

## 6. Wi-Fi Aware matrix

For every supported pair:

- attach/publish/subscribe succeeds only when hardware reports support;
- discovery message carries rotating rendezvous information only;
- publisher opens the server data path and subscriber receives the negotiated network information;
- NDP/socket transfer works in both directions;
- publish/subscribe session termination tears down native state;
- peer lost before NDP establishment fails cleanly;
- Wi-Fi/Aware availability change tears down callbacks and sockets;
- repeated attach/detach does not leak callbacks, sockets or discovery sessions.

## 7. Store-Carry-Forward restart test

Use three devices A, B and C with Internet disabled.

1. A creates one urgent v2 text packet for C and gives a bounded copy to B.
2. Confirm B has durable SQLite custody.
3. Force-stop B. Do not keep the process alive with debugging tools.
4. Move B away from A if necessary; restart B.
5. Later bring B near C using a different supported bearer if possible.
6. B forwards the exact logical packet to C.
7. C decrypts once and emits the end-to-end receipt.
8. Duplicate PacketId replicas must not display duplicate MessageIds or inflate copy budget.

Evidence must show that the B restart occurred between custody operations.

## 8. Doze/background/foreground-service tests

Test without unrestricted-battery exemption first:

- enter Nearby/Emergency mode from a foreground user action;
- verify the connected-device foreground notification while sustained discovery/links are active;
- screen off for 5, 30 and 120 minutes;
- enter Doze with ADB or natural idle;
- verify bounded scanning/retry behavior rather than a tight wake loop;
- revoke notification/Nearby permissions and confirm clean degradation;
- stop the user-visible mode and confirm foreground service/radio sessions stop;
- reboot and verify Loom does not silently start an unrestricted mesh service.

## 9. Storage pressure and long-running chaos

Fill the configured DTN storage budget through test packets until elevated and critical pressure are reached. Verify:

- expired packets and old terminal tombstones are pruned first;
- live packets are not silently deleted;
- ordinary Store-Carry replication is reduced under elevated pressure;
- critical pressure favors direct delivery and urgent verified-gateway custody;
- restart preserves the same pressure-safe packet state.

Run an 8-hour and 24-hour malicious/noisy-peer soak with repeated malformed frames, disconnects, duplicate PacketIds, stale discovery handles and failed handshakes. Record crash count, ANRs, memory trend, open file/socket count and battery use.

## 10. Endpoint privacy checks

- lock screen must not reveal caller/message address or private text in public notification content;
- Android application backup must remain disabled for the app data domain containing crypto state;
- release manifest must keep cleartext traffic disabled;
- screenshots/logcat/tombstones must be reviewed for plaintext, recovery secrets, account/session pickle bytes and Keystore plaintext;
- uninstall/reinstall and device restore must not clone a live send-capable ratchet.

## 11. Pass/fail evidence

A bearer/platform is **validated** only when the matrix has a recorded physical-device result. Code presence, emulator success and hosted CI status are insufficient. Failures must record the exact OEM/API/build and whether the failure is capability absence, permission policy, platform bug, Loom bug, battery policy, or protocol failure.

An independent cryptographic/security audit is a separate release gate and cannot be replaced by this runbook.
