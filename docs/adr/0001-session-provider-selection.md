# ADR-0001: Session crypto provider remains implementation-neutral

- Status: Accepted for Architecture v2 migration
- Date: 2026-09-05

## Context

Loom needs asynchronous 1:1 session establishment, forward secrecy, post-compromise recovery, bounded out-of-order handling, replay resistance, device-authorized prekeys, and durable ratchet state. The project must not invent a proprietary ratchet to satisfy this requirement.

`packages/loom_sessions` therefore defines `LoomSessionCryptoProvider` without selecting a production implementation. The repository now also contains an explicitly non-shipping vodozemac `0.10.0` Rust+Dart proof of concept behind that boundary. Its protocol tag is the evaluation-only Olm format; it is not the versioned session format and it is not instantiated by the production Flutter composition root.

Signal's `libsignal` remains an important reference implementation, but its upstream repository states that external use is unsupported and its current workspace license is `AGPL-3.0-only`. Vodozemac is easier to evaluate from a licensing/FFI perspective and has a memory-safe Rust core, but Olm is a different protocol family from Signal's current asynchronous-session stack and must be reviewed on its own properties.

References reviewed for this ADR:

- https://github.com/signalapp/libsignal/blob/main/README.md
- https://github.com/signalapp/libsignal/blob/main/Cargo.toml
- https://signal.org/docs/specifications/doubleratchet/
- https://github.com/matrix-org/vodozemac
- https://docs.rs/vodozemac/0.10.0/vodozemac/olm/struct.Account.html
- `docs/session-provider-evaluation-2026-09.md`

## Decision

Do not hard-code Loom production messaging to libsignal, vodozemac, a home-grown Double Ratchet, or any other provider yet.

All v2 messaging code must depend on provider-neutral Loom contracts. Provider-specific code may exist only behind that boundary until the production gate is closed.

The current vodozemac PoC is permitted because it validates composition rather than silently selecting the production protocol. It now covers:

- protected provider/account/session state through Loom's crash-safe transaction boundary;
- exact ciphertext/PacketId retry after crash;
- first-inbound asynchronous session creation with atomic local-account one-time-key mutation;
- one-time-key replenishment plus fallback-key publication/rotation semantics;
- immutable pending publication batches so a lost network acknowledgement retries identical PrekeyIds/bundles/expiry rather than generating new private keys;
- canonical device-authorized prekey statements signed by a Loom device key and verified through an injected authorized/non-revoked device resolver;
- replay rejection, delayed/out-of-order delivery characterization, and remote-device revocation send blocking;
- explicit fail-closed backup policy: live ratchet state is not restored as sendable state;
- malformed-input regression coverage for the validation FFI boundary.

## Production-provider gate

A provider can be enabled for user-visible v2 sends only after all of the following are resolved and reviewed:

1. **Protocol/composition review.** Authentication, forward secrecy, post-compromise behavior, reset/recovery, device authorization and delayed multi-path semantics must be reviewed for the exact selected protocol, not inferred from an algorithm name.
2. **Device-authorized prekeys.** The product trust cache must verify every prekey against the exact authorized `(accountId, deviceId, deviceKeyVersion)` and sticky revocation state; the Delivery Service is not the trust root.
3. **Prekey lifecycle.** One-time/fallback replenishment and rotation must be safe across lost acknowledgements, exhaustion, server expiry and the claimed-but-delayed first-message race. The PoC implements the normal replenishment/rotation path, but long-lived unused OTK retirement remains a reviewed-policy gate.
4. **Crash-safe persistence.** Provider/account/session advancement and exact send ciphertext must commit atomically through `LoomCryptoStateStore`; hidden provider writes outside that boundary are forbidden.
5. **Bounded reordering.** The selected implementation's real skipped-key/message-gap limits must fit Loom's DTN availability requirements. For vodozemac `0.10.0`, the evaluated implementation currently retains 40 skipped keys per receiving chain, permits a forward gap up to 2000, and retains 5 receiving chains; Loom does not pretend those are configurable to a larger project constant.
6. **State migration.** Provider serialization/schema upgrades need executable old→new fixtures and rollback/failure behavior before shipping updates.
7. **Backup/restore anti-cloning.** Generic backups must not clone one live ratchet onto two independently sending endpoints. Restored devices establish fresh sessions; any historical session archive is receive-only by explicit policy.
8. **Production FFI ownership.** The current JSON/pickle validation ABI is non-shipping because it creates transient secret copies. A production bridge needs reviewed memory ownership/zeroization or opaque native state handles, stable ABI/versioning and panic/error mapping.
9. **Platform packaging.** The same reviewed core must build and execute on Android, iOS, macOS, Windows and Linux. Host desktop builds alone are not equivalent to mobile packaging/lifecycle validation.
10. **Parser/provider robustness.** Deterministic malformed-input regression tests exist, but a production provider still needs sustained fuzzing and malicious-input coverage for every untrusted prekey/ciphertext/native boundary.
11. **Licensing/SBOM/reproducibility.** Distribution obligations, dependency inventory and reproducible native builds must be accepted for the final client model.
12. **Independent review and working CI.** The exact Loom composition needs independent security review, and configured tests must actually execute on healthy CI runners before merge/release decisions treat them as validation evidence.

A provider owns protocol-specific account/session state and message-key evolution. Loom orchestration owns device authorization binding, atomic persistence, PacketId/logical-message identity, DTN routing, delivery receipts and transport selection.

## Consequences

- the legacy direct-message format remains a legacy compatibility format, not the v2 ratcheting protocol.
- the evaluation-only Olm format remains evaluation-only even though it is executable.
- No Forward Secrecy, Post-Compromise Security, Signal compatibility, anonymity or production-grade Double Ratchet claim is allowed until a production provider is approved, integrated and reviewed.
- A server-returned public prekey is insufficient by itself; the device-authorization/trust layer must verify it before provider establishment.
- DTN may reorder opaque packets, but it cannot promise decryptability beyond the selected provider's retained skipped-key policy.
- Generic account backup excludes live ratchet state; recovery establishes fresh sendable sessions.
- A different reviewed provider may replace the current PoC without changing DTN, transport or Delivery Service trust semantics.

## Rejected alternatives

- Implement a Loom-specific ratchet in Dart.
- Couple transports directly to a Signal/vodozemac session object.
- Treat the Delivery Service as authority for recipient prekeys.
- Invent a larger skipped-key window in Loom documentation than the selected implementation actually provides.
- Copy private agreement keys or live ratchet state between devices to simulate continuity.
- Retry prekey publication by regenerating private keys after an ambiguous network failure.
- Advertise FS/PCS before the production provider is actually wired, executed in CI, independently reviewed and field validated.
