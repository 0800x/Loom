# Dependency pin patch; no cryptographic source changes

Source: crates.io hpke-rs-libcrux 0.7.0, upstream libcrux revision
c5fb80f37530ee9b2df9501ae5ff8cb4a973a4bd, path
crates/protocols/hpke/libcrux_provider. Upstream LICENSE and LICENSE-MIT are
preserved from that exact revision; package metadata declares MPL-2.0.

The only functional manifest change advances the exact libcrux-kem requirement
from 0.0.9 to the upstream 0.0.10 release fixing RUSTSEC-2026-0330 and
RUSTSEC-2026-0331. Cryptographic Rust source, tests and benches are unchanged.
Cargo.toml.orig retains the original upstream manifest for provenance. The
library's packaged Cargo.lock is not used by consuming crates and is not copied.

Loom uses the RustCrypto backend; the optional libcrux backend is not activated
by Loom's current feature graph. Nonetheless the vulnerable lockfile dependency
is repaired rather than hidden from scanners. Validate both the active MLS
integration and this provider's compilation/tests. Remove this metadata-only
vendor patch once an API-compatible upstream adapter release uses the fixed KEM.
Do not silently change backend, wire format, cipher suite or serialized MLS state.
