# ADR 0004 — Direct destination-node delivery

- Status: Accepted for Architecture V2
- Date: 2026-09-07

## Context

Loom historically routes an inter-node message through the sender's Home Node:

```text
Client A -> Home Node A -> Home Node B -> Client B
```

That topology makes a Node-to-Node path a mandatory dependency even when Client A can reach Home Node B directly. A selective or degraded route between two hosting networks can therefore break federation while both client-facing Nodes remain healthy.

Architecture V2 already has opaque mailbox capabilities, end-to-end encrypted envelopes, durable DTN custody, authenticated device keys, and verified Node identities. Those primitives are sufficient to add a direct destination-node path without trusting the destination Node with plaintext or making network route identity equivalent to user identity.

## Decision

A sender may deliver an already-encrypted, already-durable V2 packet directly to the recipient device's verified destination Node:

```text
Client A -> Destination Node B -> Client B
```

The sender's Home Node remains a fallback route rather than a mandatory hop.

### Route preference

For a packet with independently verified opportunities, the preferred order is:

1. authenticated direct recipient device;
2. verified destination Node for the recipient mailbox;
3. Home Node / recently verified gateway fallback;
4. claimed gateway when copy budget permits;
5. generic authenticated store-carry peer when copy budget permits.

A destination Node is a durable custody hop, not an end-to-end delivery receipt.

## Direct ingress

Destination Nodes expose:

```text
POST /api/v2/packets/direct
```

The request carries only opaque routing/custody material:

- PacketId;
- opaque mailbox token;
- opaque encrypted envelope bytes;
- packet expiry;
- priority;
- a device transport proof.

The destination Node does not need a local login/session for the sender and does not synchronously contact the sender's Home Node.

The mailbox token is an unguessable recipient capability. The Node accepts direct packets only for a live mailbox it already hosts, applies the same bounded packet lifetime, and counts normal plus direct packets against one per-mailbox pending quota.

## Device transport proof

The proof reuses the existing authorized Loom device Ed25519 signing key. No second device identity hierarchy is introduced.

The request includes:

```text
devicePublicKey
issuedAt
nonce
signature
```

The signature binds the exact direct request fields under the domain separator:

```text
<direct delivery proof domain>
```

The destination Node derives a self-certifying transport fingerprint:

```text
base64url(SHA-256(raw Ed25519 public key))
```

Possession of a fingerprint string is not authentication; the sender must prove possession of the corresponding private key by signing the canonical request.

### What this proof does not mean

The transport fingerprint is **not** a global account identity and is **not** sufficient by itself to assert that a sender is a particular Loom user. An attacker can generate a new keypair and therefore a new fingerprint.

End-to-end sender/account/device identity remains authenticated by Architecture V2 device-directory/session cryptography inside the opaque packet. The direct transport proof provides:

- proof of possession for a stable local device signing key;
- replay-resistant request binding;
- a stable transport-level key for abuse accounting/rate limiting;
- protection against changing PacketId/mailbox/ciphertext/expiry/priority after signing.

## Key storage

Production clients reuse `LoomDeviceSecurityCore` and its authorized device signing key. The current implementation persists the secret behind platform secure storage. Platform implementations should prefer hardware-backed Android Keystore, Secure Enclave, TPM, or equivalent non-exporting providers where available.

The direct transport layer receives only a signing interface. It does not require access to raw private-key bytes.

## Replay and idempotency

A proof contains a random nonce and a short-lived `issuedAt` timestamp. The server permits only a small clock-skew window.

PacketId remains the durable idempotency key:

- identical retries of an already accepted packet are successful and idempotent;
- reuse of the same PacketId with changed immutable packet content is rejected;
- the client re-signs a retry with a fresh proof when necessary without changing the packet itself.

## Storage and acknowledgements

Direct packets are stored in a separate custody table so the legacy/local-session packet schema and sender foreign keys remain unchanged during migration.

Recipient pull merges normal and direct custody queues and deduplicates by PacketId. The recipient does not need to know which ingress path was used.

A successful direct-ingress response means:

```text
destination_node_custody
```

It does **not** mean:

- recipient device received the packet;
- recipient decrypted the packet;
- recipient read the message.

Those remain end-to-end states.

## Connection management

Clients pool the destination-node HTTP client and reuse keep-alive connections. They do not maintain permanent connections to every Node in the network.

A typical client keeps its normal Home Node connection and opens/reuses destination-node connections on demand. Idle direct connections are bounded and closed by the transport pool.

## Federation interaction

Architecture V2 also removes synchronous reverse discovery from the hot path for already-known federation peers:

- a recently cryptographically verified peer binding is accepted for inbound signed traffic;
- soft-stale bindings refresh asynchronously;
- a hard verification TTL eventually requires live re-bootstrap;
- unknown peers, changed keys, or changed endpoints require live discovery and fail closed.

This prevents a one-way network failure from automatically becoming a two-way application-level federation failure for established peers.

Queued V1 federation retries use the current verified endpoint for the same NodeId instead of remaining permanently pinned to the endpoint captured when the row was enqueued.

## Security consequences

Positive:

- removes Home-Node availability from the direct delivery hot path;
- reduces Node-to-Node traffic and round trips;
- retains opaque/E2EE packet semantics;
- retains fail-closed Node identity verification;
- preserves durable DTN retry and custody semantics;
- enables future per-device transport reputation without equating it to account trust.

Tradeoffs:

- destination Nodes receive more direct client ingress and therefore need abuse controls;
- a leaked mailbox token can be used to consume that mailbox's bounded quota until expiry/revocation;
- a self-generated transport key does not prevent Sybil identities;
- direct transport reachability may expose the destination Node to the sender, which is already implicit in the advertised Node route.

## Backward compatibility

This is additive:

- existing `/api/v2/packets` Home-Node/session behavior remains available;
- V1 endpoints remain available;
- clients that do not support direct destination-node delivery continue using existing routes;
- route policy falls back to Home Node when the destination Node is unavailable or unverified.

## Rollout gate

Before production merge, validation must include Node tests, Dart package tests, Flutter integration tests, and at least one two-Node end-to-end test covering:

1. direct destination-node success;
2. destination-node failure with Home-Node fallback;
3. Home-Node-to-Home-Node failure while direct client delivery succeeds;
4. duplicate PacketId retry;
5. changed-content PacketId conflict;
6. expired/stale transport proof rejection;
7. recipient pull/ack across both normal and direct custody queues.
