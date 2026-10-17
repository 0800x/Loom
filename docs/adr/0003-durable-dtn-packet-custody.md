# ADR-0003: Durable DTN packet custody before transport

- Status: Accepted
- Date: 2026-09-05
- Scope: Architecture v2 client messaging / DTN boundary

## Context

Architecture v2 already commits ratchet/session advancement, stable `PacketId`, and the exact session ciphertext in the crypto-state transaction before encryption output can escape. That is necessary but not sufficient for disruption-tolerant delivery: the routable `OuterEnvelopeV2` also contains routing scope, opaque mailbox material, expiry, priority, hop budget, and replication budget.

If a transport can receive an assembled outer packet before those exact bytes reach durable custody, a process crash can create a packet that was transmitted but cannot be reconstructed identically. Re-encrypting is forbidden because it can reuse or incorrectly advance session state, and silently rebuilding a different outer packet under the same `PacketId` makes DTN deduplication ambiguous.

The same durability rule applies in the opposite direction. A peer must not receive a hop-local transfer acknowledgement merely because Loom parsed a packet in memory. The ACK is safe only after the next custodian has durably accepted the packet, or can prove that durable custody for the same immutable PacketId already exists.

## Decision

1. Introduce a separate `loom_dtn` package. Messaging may depend on it; transport does not gain access to session or plaintext APIs.
2. A local outbound packet becomes routable only after `LoomPacketStore.putLocalOutbound` commits the exact encoded `OuterEnvelopeV2` bytes.
3. The initial SQLite implementation uses WAL plus `PRAGMA synchronous=FULL` and a separate DTN database schema. It is not an ordinary UI/cache store.
4. Repeating the same `operationId` / `messageId` / `PacketId` with byte-identical outer data is idempotent. Reusing a `PacketId` or operation with different immutable data fails closed.
5. Local application correlation (`operationId`, `messageId`) is stored beside the packet but is never copied into `OuterEnvelopeV2`.
6. Stored routing columns are treated as indexes/cache only. Reads decode the stored outer bytes and verify the columns still match the wire representation before returning the packet.
7. Packet lifecycle is monotonic: `queued -> gatewayAccepted -> relayAccepted -> recipientConfirmed`, with `expired` and `cancelledLocal` terminal alternatives. Direct relay acceptance may skip the gateway state.
8. `gatewayAccepted` remains eligible for forwarding. `relayAccepted` means a minimally trusted delivery service has accepted custody and pauses automatic local forwarding; it does **not** mean the recipient decrypted the message. Only an end-to-end protected recipient delivery receipt can move the packet to `recipientConfirmed`.
9. Retry failures are stored only as bounded structured error codes, never arbitrary exception strings that may contain secrets or network details.
10. Terminal rows remain as PacketId tombstones after packet expiry. The initial default retention is 30 days to prevent late retries from resurrecting an already completed PacketId.
11. Spray-and-Wait forwarding uses a separate durable `dtn_transfers` record. The exact next-hop bytes are committed before a bearer may send them, and a packet may have only one `prepared` transfer at a time so concurrent bearers cannot overspend the local copy budget.
12. The source packet bytes remain immutable. Successful replica transfers reduce only the local runtime copy budget through compare-and-swap semantics; they do not rewrite the original stored envelope.
13. Receive-side carried replicas are accepted through a separate intake boundary over the same DTN database. Peer authentication must be established before intake. The first valid durable copy for a PacketId wins.
14. Later replicas with the same PacketId are ACKable duplicates only when the immutable packet identity matches: routing scope, opaque mailbox token, expiry, priority, initial hop limit, and encrypted payload. Forwarding hop/copy revisions may differ. A conflicting immutable identity fails closed.
15. A duplicate replica never increases local forwarding authority. Untrusted incoming copy counts are locally clamped, and later copies cannot inflate a budget already accepted for that PacketId.
16. Hop exhaustion is enforced by routing policy. A packet received at `hopsUsed == initialHopLimit` may remain durably stored/deduplicated but is never scheduled for another hop.
17. A hop-local transfer ACK is created only after durable receive custody exists. It means “this next hop has the PacketId,” not “the recipient decrypted the message.” Direct-recipient hop ACKs therefore pause immediate retry but do not transition to `recipientConfirmed`.
18. Prepared-transfer recovery is idempotent. If the process dies after sending but before recording the ACK, restart resends the same `transmissionId` and exact prepared bytes; the receiver can return a duplicate custody ACK without minting new copies.

## Forwarding-state consequence

`OuterEnvelopeV2.forwardingState` is mutable routing data while the encrypted payload and logical `PacketId` remain stable. Loom therefore does not overwrite an existing source packet in place when incrementing `hopsUsed` or splitting `copiesRemaining`.

The current implementation stores the immutable source packet plus explicit durable transfer revisions. A prepared transfer increments the hop value and carries only the copy budget granted to that next custodian. The sending custodian retains its original packet bytes and updates a separate local runtime copy budget only after transfer acceptance.

On receive, a carried transfer is stored byte-for-byte as that custodian's source revision. If another revision of the same PacketId later arrives, only immutable packet identity is compared; the first accepted forwarding revision remains authoritative for local copy budget. This prevents legitimate multi-path duplicates from being mistaken for PacketId collisions while preventing malicious or accidental replica amplification.

## Consequences

### Positive

- Crash recovery retries the same stored bytes rather than rebuilding packets opportunistically.
- Transport cannot become a hidden persistence layer.
- PacketId collision behavior is deterministic and testable.
- Spray-and-Wait copy spending is durable and race-resistant.
- Receive-side duplicate ACKs are safe after crashes and multi-path delivery.
- Relay/server and hop ACK semantics cannot accidentally masquerade as end-to-end delivery.
- The DTN layer remains independent from session keys and plaintext.

### Costs

- There are two durable commit boundaries on send: crypto state/outbox first, DTN packet custody second.
- Those commits cannot be one SQLite transaction because they intentionally live in separate security/storage domains. Recovery must therefore be idempotent: a pending crypto-outbox row may be assembled again, and `putLocalOutbound` must converge on the already stored packet.
- Forwarding has another durable boundary: a transfer revision commits before transport IO, then copy-budget state changes only after an authenticated hop ACK.
- Receive-side intake currently uses a second SQLite connection to the same DTN file so transports can be given a narrow custody surface. WAL/busy-timeout behavior and lifecycle ordering must remain tested on target platforms.

## Rejected alternatives

- **Send directly from the crypto outbox:** rejected because routing/expiry/replication metadata would not be crash-stable.
- **Rebuild OuterEnvelopeV2 on every retry:** rejected because the same `PacketId` could acquire different metadata after a crash or policy change.
- **Mutate the original stored envelope for every hop:** rejected because a crash or concurrent bearer could corrupt deduplication/copy accounting and destroy the exact source revision.
- **Accept every duplicate's copy count:** rejected because duplicate/malicious replicas could inflate forwarding authority.
- **ACK after parsing but before commit:** rejected because sender custody could be released while the receiver still has only volatile memory state.
- **Let transports persist their own queues:** rejected because every bearer would gain inconsistent retry/dedup semantics and transport independence would be lost.
- **Treat relay or hop acceptance as Delivered:** rejected because a malicious/failing delivery service or peer can accept bytes without recipient decryption.
