# ADR-0002: Protobuf wire format for v2 envelopes; canonical encoding for signatures

- Status: Accepted for Architecture v2 migration
- Date: 2026-09-05

## Context

Loom Architecture v2 needs a compact versioned binary format for InnerEnvelope, SessionCiphertext, OuterEnvelope and delivery receipts. Those objects cross Dart, native mobile code, Node delivery services and future DTN simulators.

Protocol Buffers provides stable numeric field tags and language-neutral binary encoding, but protobuf serialization is not a canonical signing representation. Field ordering and serialization details must not become an accidental signature contract.

## Decision

`packages/loom_protocol/proto/loom_envelope_v2.proto` is the normative v2 field-number map for:

- `InnerEnvelopeV2`;
- `SessionCiphertextV2`;
- `OuterEnvelopeV2`;
- `RoutingHintV2`;
- `ForwardingStateV2`;
- `DeliveryReceiptV2`.

The current Dart bootstrap codec is wire-compatible with that schema and applies a deliberately strict application profile: bounded messages, bounded strings, minimal positive varints, valid UTF-8, no duplicate singular fields, no enum zero defaults, and no unknown fields for a known v2 envelope version.

The protobuf bytes from these envelopes MUST NOT be used as the canonical bytes for account/device authorization, revocation, key rotation or other signed identity objects. Those signed structures require a separately specified deterministic canonical encoding such as deterministic CBOR with an explicit signing domain.

## Versioning rules

1. Field numbers are never reused for a different meaning.
2. Removed field numbers are reserved in a future generated schema rather than recycled.
3. A decoder never guesses the meaning of an unknown envelope/session version.
4. Unknown fields in a known v2 envelope currently fail closed; a future safe opaque-forwarding rule requires an explicit protocol revision.
5. Enum zero is always `UNSPECIFIED` and is rejected at the application boundary.
6. Protobuf ordering must never be relied on for authentication or signatures.

## Bootstrap codec

The hand-written Dart wire codec exists to establish the contract without introducing generated-code/toolchain churn during the migration slice. It adds parser audit surface and is therefore not a permanent security advantage.

Before production release, Loom must either:

- replace it with reviewed/generated bindings that preserve the same field map and strict validation wrapper; or
- retain it only after parser fuzzing, cross-language golden vectors and independent review.

## Consequences

- DTN transports can forward exact opaque outer bytes without knowing message semantics.
- Endpoint implementations can independently decode session payloads after outer delivery.
- Signed identity material remains insulated from non-canonical protobuf serialization.
- Cross-language golden vectors become mandatory protocol tests.
