# ADR 012: backport upstream Hax compiler diagnostics

Status: accepted for the current dependency graph; no protocol migration.

## Problem

The optional libcrux dependency graph retains hax-lib-macros 0.3.7, whose
extraction-only diagnostic wrapper depends on unmaintained proc-macro-error2
2.0.1 (RUSTSEC-2026-0173). There is no compatible patched 0.3 release. Advancing
all Hax or HPKE dependencies across semver boundaries is unnecessary here.

## Decision

Vendor hax-lib-macros 0.3.7 and backport the two `syn::Error` diagnostic helpers
from upstream 0.4.2. Remove the obsolete proc_macro_error wrappers/import and
qualifiers, and their dependency. All other macro bodies, including the entire
normal-runtime dummy implementation and shared source files, remain unchanged.
Preserve upstream source provenance and Apache-2.0 notices. Cargo resolves this
patch only for 0.3.7; the independent 0.4.2 package remains unchanged.

This is compiler error reporting, not cryptography. No cipher, provider selection,
MLS state, wire format, recovery material or key derivation changes. Invalid
extraction inputs must continue to produce compile errors, with matching error
messages and primary spans. Nightly is required only for testing Hax's existing
extraction-only feature; shipping builds retain their stable toolchain.

## Validation and limits

Test ordinary annotation runtime behavior and malformed extraction attributes
(invalid verification mode, lemma return, named refinement field, public
refinement field, backend item mode). Compare diagnostics against pristine 0.3.7
locally, compile the active MLS and optional libcrux paths, and run the unchanged
Rust/OSV scans. CI verifies unchanged normal/shared source hashes and rejects
reintroducing the removed diagnostic dependency. A successful macro compile is
not a claim that Loom's composition has undergone formal verification.

Remove this patch when the dependency chain adopts a compatible upstream release
without the abandoned wrapper. Do not hide the advisory or change crypto to
make a scanner pass.
