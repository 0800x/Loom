# ADR C1/C2: ratcheted direct messaging migration (design only)

Status: proposed; no production crypto or wire change authorized by this ADR.
Shipping `direct_message_codec.dart` and `relay_sealing.dart` use ephemeral
X25519 to each recipient device's long-term agreement key, HKDF-SHA256 and
AES-256-GCM under Loom-Direct-v1. This is sealed-box encryption, not a ratchet:
recorded traffic may become decryptable after static recipient-key compromise.
There is no ratchet forward secrecy or post-compromise security.

## Candidate and authorization

Evaluate the existing vodozemac/Olm native provider composition first, alongside a
supported Signal-style X3DH/PQXDH + Double Ratchet implementation if its licensing,
maintenance and platform support fit. Never implement a new ratchet or splice
unreviewed primitives together. Provider choice requires independent review of
this integration; audited constituent libraries alone do not audit Loom.

Directory-v2 account/device authorization remains outside provider bundles.
Prekeys must be signed by the authorized device and bind account, device/version,
protocol, key ID/type, validity and exact bundle digest. Unknown/revoked/superseded
keys fail. Consume OTKs transactionally once; return fallback only after OTK
exhaustion and retain previous fallback long enough for delayed packets. Persist
an immutable pending publication batch before publishing and retry exact bytes.

Private prekey retirement includes server expiry + maximum claim-to-first-packet
latency + maximum DTN custody lifetime + margin. Do not promise arbitrarily delayed
bootstrap. Retain keys rather than resetting unrelated state when the provider
cannot delete one precise key. Rate/quota bound key publication and claims;
key-package/prekey exhaustion must be visible and replenished deliberately.

## Offline and durable operation

Commit session advancement, exact ciphertext, MessageId/PacketId and operation ID
atomically before transport. Crash/retry must return committed ciphertext without
ratchet advancement. First inbound OTK consumption must atomically persist account
and session state plus replay/result state. A provider cannot expose raw secret
state in general message/DTN storage. Encrypt provider state under a device-local
wrapping key, with explicit revision/context binding.

Respect measured skipped-key/forward-gap/receiving-chain bounds in the candidate;
DTN can delay or reorder traffic beyond decryptability. Surface that failure,
retain diagnostic ciphertext privately, and establish a fresh authorized session
through an explicit workflow rather than silently downgrade. Recovery words do
not clone live send-capable ratchet state; new device migration establishes fresh
sessions. Historical receive-only state must never become send-capable on restore.

## No downgrade and compatibility

Keep legacyOnly and v2Required explicit. A conversation/device marked v2Required
must durably retain that requirement across restart, directory refresh and restore.
Missing provider, invalid proof, exhausted keys, replay, corrupt state, network
failure or unsupported version must fail rather than call legacy. A legacy capsule
inside a v2 routing envelope is still legacy crypto, not successful migration.

Rollout: gated developer interoperability -> reproducible native builds -> staged
explicit opt-in contacts -> independent composition review -> migration UI. Confirm
both endpoints' supported versions and binding before changing a conversation's
security level. Publish an ADR amendment and compatibility epoch/version plan
before implementation. Do not silently reinterpret old ciphertext or state files.

## C2 provider gates

Before production enablement: Android ABI matrix plus Windows/macOS/Linux FFI
builds; ABI version negotiation and incompatible-library rejection; integer handle
lifetime/stale-handle/concurrency review; precise allocation/ownership/free rules;
input/output size limits and panic containment; zeroization and platform-keystore
assumptions; serialized-provider-state upgrades; licensing/distribution approval;
independent review, physical platform evidence and signed artifact provenance.
Keep the current v2 production gate off until evidence exists for each item.

## Validation plan

Property/crash tests for exact resend, OTK at-most-once consumption, fallback
rotation/retirement windows, delayed first packet, out-of-order boundaries,
revocation, duplicate receipts and database rollback. Negative downgrade tests
cover every failure above, sticky v2Required after restore and malicious version
advertisements. Exercise malicious Home Node prekey replacement, multi-device
rotation, mixed old/new clients and DTN packets crossing the migration boundary.
Record exact provider version, native library digest and platform for each run.
