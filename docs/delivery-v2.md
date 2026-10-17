# Loom Delivery Service v2

> **Status:** additive migration implementation. `/api/v2` does not replace `/api/v1` yet. This API is a minimally trusted opaque delivery service; it does not by itself imply Forward Secrecy, Post-Compromise Security or a production-approved session provider.

## Purpose

Delivery Service v2 provides:

- rotating opaque mailboxes;
- opaque device prekey storage/claim;
- opaque packet enqueue/pull;
- relay/mailbox custody acknowledgement.

It is intentionally not a conversation server or cryptographic device-authorization authority.

The service may observe authenticated account/device sessions, mailbox ownership/activity, packet timing/size, opaque routing tokens, coarse priority/expiry and current sender accounting fields. It must not receive message plaintext, conversation IDs, reply metadata, plaintext message type, session private keys, ratchet state or account/device private keys.

## Authentication

`GET /api/v2/server/info` is public.

All other endpoints reuse the existing bearer session and device-bound request proof. For JSON bodies, the signed content-hash header is verified against the SHA-256 of the actual received bytes before parsed data is trusted. Device/session mismatch, stale proof, replayed nonce or body-hash mismatch fails authentication.

The delivery service authenticates who is using an endpoint. It does **not** become the authority that tells a sender which cryptographic prekey belongs to a remote device.

## Server info

### `GET /api/v2/server/info`

Protocol identifier:

```text
<delivery protocol domain>
```

Current capabilities include:

- opaque packet mailboxes;
- one-time opaque prekeys;
- fallback opaque prekeys;
- idempotent packet enqueue;
- mailbox-transfer acknowledgement.

## Mailboxes

### `PUT /api/v2/mailboxes`

Registers or refreshes a rotating mailbox token for the authenticated device.

```json
{
  "mailboxToken": "<canonical base64url opaque token>",
  "expiresAt": "2026-09-07T12:00:00.000Z"
}
```

Rules:

- decoded token size: 16–128 bytes;
- ownership cannot be rebound to a different account/device;
- registration lifetime currently capped at 14 days;
- a packet may not outlive the mailbox token it targets;
- clients should rotate with enough overlap for the maximum packet TTL.

A mailbox token is routing material, not an account ID, username, conversation ID, stable public key or permanent device identity.

## Prekeys

### Trust model

The server treats prekey material as opaque. A successful publish/claim does **not** prove that the provider key belongs to an authorized Loom device.

Architecture v2 defines a device-authorized prekey envelope:

```text
canonical signed statement:
  AccountId
  DeviceId
  device-key version
  provider protocol version
  PrekeyId
  key kind (one_time/fallback)
  validity interval
  SHA-256(exact provider bundle)
        |
        v
  signed by authorized device Ed25519 key
        |
        v
strict versioned carrier envelope
        |
        v
stored opaquely as bundleBase64 by Delivery Service
```

The recipient must decode the claimed opaque envelope, resolve the exact currently authorized/non-revoked device signing key from its authenticated/sticky local trust state, verify the signature/expiry/protocol/digest, and only then pass provider bytes to session establishment.

The service deliberately does not perform that end-to-end device authorization verification.

### `PUT /api/v2/prekeys`

Publishes an opaque prekey batch for the authenticated local device.

```json
{
  "prekeys": [
    {
      "prekeyId": "vpk_<stable opaque id>",
      "keyKind": "one_time",
      "bundleBase64": "<canonical base64url opaque authorized-prekey wire bytes>",
      "expiresAt": "2026-10-03T12:00:00.000Z"
    },
    {
      "prekeyId": "vpk_<fallback id>",
      "keyKind": "fallback",
      "bundleBase64": "<canonical base64url opaque authorized-prekey wire bytes>",
      "expiresAt": "2026-10-03T12:00:00.000Z"
    }
  ]
}
```

Rules:

- 1–100 items per request;
- decoded opaque bundle limit: 64 KiB;
- maximum server lifetime: 30 days;
- `keyKind` is `one_time` or `fallback`;
- missing `keyKind` remains migration-compatible and means `one_time`;
- at most one fallback is accepted in one publication batch;
- duplicate PrekeyIds inside one batch fail;
- exact re-publication of the same PrekeyId/kind/bundle/expiry is idempotent;
- reusing a PrekeyId with different material fails closed;
- consumed/retired identifiers remain tombstones until expiry.

Publishing a new fallback atomically retires the previous **server-visible** fallback. Endpoints may retain the previous private fallback locally for a bounded DTN safety window so already-claimed but delayed first messages are not broken merely by server rotation.

### `POST /api/v2/prekeys/claim`

```json
{
  "deviceId": "dev_..."
}
```

Claim behavior:

1. choose an unexpired, non-retired OTK belonging to a non-revoked target device;
2. transactionally mark that OTK consumed and return it exactly once;
3. when no eligible OTK exists, return the current unexpired/non-retired fallback without consuming it;
4. if neither exists, return `prekey_unavailable`.

Response includes `deviceId`, `prekeyId`, `keyKind`, opaque `bundleBase64` and expiry.

SQLite claims use an immediate transaction. PostgreSQL uses row locking / `SKIP LOCKED` for one-time claims.

The current live `/api/v2/prekeys` route uses the dedicated `V2PrekeyPool`. The older experimental one-shot prekey table may remain in the migration database for compatibility/testing but is not the authoritative OTK/fallback lifecycle for the route.

## Packets

### `POST /api/v2/packets`

Durably accepts one encoded `OuterEnvelopeV2` for an opaque mailbox.

```json
{
  "packetId": "packet-opaque-id",
  "mailboxToken": "<canonical base64url token>",
  "envelopeBase64": "<canonical base64url exact OuterEnvelopeV2 bytes>",
  "expiresAt": "2026-09-06T12:00:00.000Z",
  "priority": "normal"
}
```

Rules:

- packet lifetime capped at seven days;
- packet may not outlive target mailbox token;
- priority is `normal` or `urgent`;
- current mailbox quota: 5,000 pending unexpired packets;
- PacketId is idempotent inside the delivery store;
- exact retry is accepted only when mailbox, envelope bytes, expiry and priority match;
- conflicting PacketId reuse fails closed;
- acknowledged PacketIds remain dedup tombstones until original expiry.

First durable acceptance returns HTTP 202. Exact retry returns HTTP 200 with `idempotent: true`.

`receiptType: relay_acceptance` means **this delivery service has custody**. It does not mean recipient delivery.

### `POST /api/v2/packets/pull`

```json
{
  "mailboxToken": "<canonical base64url token>",
  "limit": 50
}
```

Returns owned, unacknowledged, unexpired packets. Current limit: 1–100. Urgent sorts before normal.

The mailbox token is carried in the body rather than URL to reduce routine URL/proxy log exposure. This is metadata minimization, not anonymity.

### `POST /api/v2/packets/{packetId}/ack`

Marks packet transfer from mailbox/relay to the owning authenticated device.

```json
{
  "acknowledged": true,
  "receiptType": "mailbox_transfer_ack",
  "recipientDeliveryConfirmed": false
}
```

This ACK is weaker than `Delivered`. Only an authenticated end-to-end recipient receipt after durable endpoint decrypt/commit can drive the user-facing Delivered state.

## Storage backends

Easy Mode uses `loom.sqlite3`; production mode may use PostgreSQL.

Relevant additive v2 tables include:

- `v2_mailboxes`;
- `v2_delivery_packets`;
- `v2_prekey_pool_v2` for current OTK/fallback lifecycle;
- older experimental v2 prekey rows may remain as migration artifacts until cleanup policy is finalized.

Existing `/api/v1` conversation/message/read tables remain unchanged.

## JSON/binary boundary

HTTP is JSON during migration. Binary packet/prekey authorization envelopes are carried as canonical base64url strings.

The configured HTTP request-size ceiling therefore applies to expanded JSON/base64 representation. A future binary HTTP body can reduce overhead but must preserve the same authentication, TTL, quota, ownership and idempotency rules.

The server does not parse InnerEnvelope/session ciphertext or device-authorized prekey cryptographic content. Endpoint clients own those validations.

## Metadata limitations

Delivery Service v2 is not an anonymity system. It may observe:

- source connection/IP metadata available to the service/network;
- authenticated account/device sessions;
- mailbox-token activity;
- timestamps;
- packet/prekey sizes;
- coarse expiry/priority;
- current abuse/accounting fields.

Even after a production session provider is approved, the intended claim is message-content confidentiality/integrity against intermediate delivery infrastructure assuming endpoint/provider state is uncompromised—not unlinkability or traffic-analysis resistance.

## Migration lifecycle

`attachV2DeliveryService` installs the v2 adapter before `listen()`. Non-`/api/v2/` requests delegate to the existing v1 dispatcher. Regression coverage checks that `/healthz` and `/api/v1/server/info` remain reachable while `/api/v2/server/info` is exposed separately.

This attachment model is transitional; the external opaque contract is intended to survive eventual server-internal refactoring.
