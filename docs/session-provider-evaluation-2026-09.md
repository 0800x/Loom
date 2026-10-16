# Loom Architecture v2 — session provider evaluation, September 2026

This note supplements ADR-0001. It is an engineering snapshot, not a cryptographic endorsement or dependency-selection approval.

## Current conclusion

Keep `LoomSessionCryptoProvider` implementation-neutral for production.

`vodozemac` remains the leading executable prototype candidate. The repository pins vodozemac `0.10.0` and now contains both the older inspectable JSON regression ABI and a newer **opaque-handle byte-state ABI candidate**. Neither fact approves Olm/vodozemac as Loom's shipping v2 session protocol.

The shipping Flutter composition root still supplies no reviewed provider by default. User-visible v2 sends therefore remain fail-closed; the legacy direct-message format remains the explicit legacy product path while provider/release gates are open.

## What the vodozemac evaluation now covers

The branch contains:

- `native/loom_vodozemac_poc`: Rust core pinned to vodozemac `0.10.0`;
- `packages/loom_session_vodozemac_poc`: Dart adapters, provider candidate, durable prekey lifecycle and authorization bridges;
- provider-neutral transaction/state/protection contracts in `packages/loom_sessions`.

Executable code/tests/contracts now cover:

1. asynchronous Account/OTK/fallback/session establishment;
2. first inbound prekey processing and OTK consumption;
3. atomic provider-account mutation + new inbound Session creation;
4. session advancement + exact immutable ciphertext/MessageId/PacketId staging;
5. crash rollback and exact retry after commit;
6. replay rejection;
7. remote-device revocation and receive-only delayed traffic policy;
8. protected provider/session state bound to `(contextId, revision)`;
9. Android Keystore state wrapping;
10. server OTK/fallback lifecycle and tombstones;
11. crash-safe durable publication batches;
12. OTK replenishment and fallback rotation;
13. safe previous-fallback retention for delayed DTN first messages;
14. device-authorized prekey canonical statement and strict wire carrier;
15. locally verified non-revoked device-key resolution;
16. Architecture-v2 AccountId/DeviceId/DeviceKeyVersion directory contracts and durable cache;
17. a separate locally pinned AccountId/AccountKeyVersion Ed25519 root store and directory signature verifier;
18. fail-closed backup policy that excludes live send-capable ratchet state;
19. malformed-input/panic-containment regression coverage;
20. provider-specific out-of-order/skipped-key characterization;
21. product `v2Required` no-downgrade policy.

## FFI status

### Legacy validation ABI

The original validation ABI serializes provider pickles through command JSON and Dart/Rust strings. It remains useful for regression/debugging, but it is explicitly non-shipping because it creates unnecessary transient secret copies.

### Opaque-handle ABI candidate

The newer ABI keeps live Account/Session objects inside Rust and exposes process-local opaque handles. It implements:

- Account create/import/export;
- public key inventory;
- OTK replenishment and fallback rotation;
- mark-published and previous-fallback cleanup;
- Session import/export/id;
- outbound/inbound establishment;
- encrypt/decrypt;
- explicit handle close;
- bounded status-returning operations with panic containment;
- Rust-owned output buffers zeroed before free;
- Dart native input allocation zeroing;
- byte-state provider persistence without converting secret Account/Session state to Dart `String`.

The byte-state provider uses the same durable CAS/outbox invariants as the older PoC provider. The durable handle-prekey lifecycle also performs publication/replenishment/fallback operations without secret Account state becoming a Dart string.

This **closes the architectural “we need opaque handles” gap**, but it does not close production review. Remaining FFI work is evidence/review oriented: actual multi-platform builds, ABI version/upgrade policy, memory-ownership review, upstream secret-zeroization assumptions, mobile packaging and independent review.

## Device/prekey trust status

The older migration adapter from Architecture-v2 AccountId to legacy `identityId` remains available only for compatibility.

The Architecture-v2 path now has the stronger model required for production migration:

- random stable `AccountId` independent of root key bytes;
- independent `DeviceId`;
- explicit `DeviceKeyVersion`;
- account-signed device authorization/revocation and monotonic directory snapshot;
- durable sticky revocation/version cache;
- separate locally pinned account-root key store;
- real Ed25519 account signature verifier resolving exact `(AccountId, AccountKeyVersion)` locally;
- device-authorized provider prekeys verified against the exact current non-revoked device key.

A Delivery Service remains an opaque carrier, not a root of trust.

## OTK/fallback retirement status

Bootstrap-only publication is no longer the current model. The handle-provider lifecycle has stable publication IDs, immutable pending batches, exact ACK-loss retry, replenishment, fallback rotation and retained previous fallback.

The generic retirement rule is:

```text
server expiry
+ maximum claim-to-first-packet delay
+ maximum DTN packet lifetime
+ safety margin
```

The current evaluation default is 1 day + 7 days + 2 days after server expiry.

vodozemac does not expose arbitrary exact deletion of one unused private OTK. Loom therefore does not fake retirement by resetting the Account or deleting unrelated keys. Such keys may remain private/unpublished until the provider safely evicts them. This trades local private-state size for delayed-first-message availability and must be part of the provider approval decision.

## Exact vodozemac 0.10.0 DTN/reordering limits

The evaluated implementation is characterized at approximately:

- maximum forward message gap: **2000**;
- retained skipped message keys per receiving chain: **40**;
- retained receiving chains: **5**.

These are not configurable Loom constants. DTN replication cannot enlarge the cryptographic skipped-key window. A valid unexpired packet can still become undecryptable if its session ordering lands outside provider retention.

Provider approval must decide whether those limits match Loom's emergency-text disruption model or whether another reviewed provider/fork is needed.

## Backup/restore rule

Generic backup must not copy live provider Account/Session ratchet state into another concurrently active endpoint.

- active/establishing/reset-required sessions: excluded from ordinary backup;
- explicit historical/revoked archive: receive-only at most;
- restore must never silently promote historical state to send-capable;
- a new/restored endpoint establishes fresh sessions under its own authorized device identity.

## Candidate comparison

### Signal libsignal

Upstream reviewed in September 2026:

- repository: https://github.com/signalapp/libsignal
- official README states external use is unsupported and bridge/API changes are not promised to external consumers;
- workspace license reviewed as `AGPL-3.0-only` at the time of this evaluation;
- Rust core with official Java/Swift/TypeScript surfaces.

Strengths: mature Signal protocol implementation family and deployment experience.

Current blockers for Loom: distribution/license decision, unsupported external-consumer stance, bridge stability and Loom-specific durable/offline composition work.

Decision: **do not integrate by default today**.

### vodozemac

- repository: https://github.com/matrix-org/vodozemac
- PoC pin: `0.10.0`;
- Rust Olm/Megolm core;
- Apache-2.0 core license reviewed for this evaluation;
- maintained Matrix ecosystem implementation and upstream audit history.

Strengths: memory-safe Rust core, async Account/OTK/fallback/session model, state serialization and comparatively straightforward embedding evaluation.

Remaining gates before shipping selection:

1. explicit security review of Olm semantics versus Loom's desired authentication/FS/PCS/reset/recovery claims;
2. accept/reject the characterized DTN reordering limits;
3. run the opaque-handle ABI/provider tests and builds on the actual supported release toolchains;
4. create executable provider-state upgrade fixtures across real provider versions before shipping an upgrade path;
5. finalize mobile/desktop packaging, signing, SBOM and reproducible-build process;
6. execute real-device lifecycle/Doze/chaos validation;
7. independent review of the exact Loom composition, including multipath, prekey authorization, backup and endpoint protection.

Decision: **preferred prototype candidate, not approved shipping provider**.

### libolm

Deprecated Matrix direction, C/C++ implementation and historical security/maintenance concerns make it unsuitable for new Loom work.

Decision: **rejected for new work**.

### Third-party Flutter wrappers

May be useful as build references. They must not become the cryptographic trust boundary without independent source, maintenance and license review.

Decision: **do not adopt as production trust boundary**.

## Provider-selection gate

Before a user-visible `v2Required` messaging surface may ship, the exact selected provider/composition must demonstrate with actual executed evidence:

1. account-root → Directory-v2 → device-authorized prekey verification;
2. OTK/fallback replenishment/rotation/exhaustion/retirement and ACK-loss behavior;
3. outbound establishment from verified cached prekey material while offline;
4. atomic provider/session advancement + exact ciphertext/PacketId commit;
5. crash-after-commit exact retry without re-encryption;
6. first-inbound Account+Session atomicity;
7. delayed/out-of-order behavior within explicit provider-supported bounds and safe failure outside them;
8. durable replay rejection;
9. remote-device revocation blocking new sends while preserving the defined delayed receive window;
10. protected byte-state serialization and executable upgrade/migration fixtures;
11. backup/restore that cannot create two send-capable clones;
12. opaque-handle FFI builds/packaging on every selected shipping platform;
13. fuzz/property/chaos coverage plus real-device long-running validation;
14. exact license/SBOM/reproducibility obligations;
15. independent review of the exact Loom composition.

## Validation rule

The repository provides `scripts/validate-architecture-v2.sh` and `.ps1` so provider/Architecture-v2 checks can be run locally without relying on hosted CI. The existence of those scripts or test source files is not validation evidence; release evidence must record actual successful executions on the selected toolchains and devices.

## Current implementation rule

Until the provider-selection gates are accepted:

- the legacy direct-message format remains explicit legacy compatibility;
- vodozemac protocol tags remain evaluation tags, not an audited Loom Session-v2 claim;
- production Flutter must not silently instantiate the evaluation provider;
- a `v2Required` surface must fail closed rather than downgrade to v1;
- Delivery Service v2 remains an opaque carrier;
- no UI/README may claim production FS, PCS, Signal compatibility, anonymity or independent Loom audit merely because the foundation is implemented.
