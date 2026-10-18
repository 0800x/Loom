# ADR: repair an optional transitive KEM dependency without changing MLS

Status: accepted for security completion, 2026-10-18.

Cargo audit found RUSTSEC-2026-0330/0331 in libcrux-kem 0.0.9. Cargo tree showed no
active dependency path in the current MLS build: openmls_rust_crypto enables the
RustCrypto backend, not the optional libcrux backend. Its hpke-rs 0.7.0 adapter
nevertheless locks libcrux-kem exactly to the affected release. Compatible cargo
update attempts could not select the fixed release because of that exact pin.

Preserve the upstream hpke-rs-libcrux 0.7.0 source verbatim with provenance and
licenses, changing only its manifest pin to upstream libcrux-kem 0.0.10. Use a local
Cargo patch so lockfiles and scanners resolve the fixed version. Do not alter
cryptographic Rust code, activate the alternate backend, or suppress advisories.
The active provider, suite, wire and persisted MLS state remain unchanged. No
migration is required for the active provider. If optional backend enablement is
later proposed, it needs its own compatibility/security review and platform gates.

Validate cargo test for MLS and the patched provider, cargo audit without ignored
advisories, source equality of vendored .rs files and explicit feature-graph review.
Retain the patch until upstream supplies a compatible release; no new crypto is
invented by this manifest-only fix.
