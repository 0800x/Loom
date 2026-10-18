# Contributing

Read AGENTS.md and the architecture, compatibility and security documents. Open
a focused change from a branch and include reproduction, validation commands and
actual results. Use synthetic contacts/messages, never production keys or logs.
Keep one issue per commit and preserve upstream copyright/license notices.

Changes are GPL-3.0-only under the repository license. By submitting a patch you
confirm you have the right to contribute it under that license. Identify copied
or adapted third-party code with its source, version and license; do not replace
upstream authorship during namespace changes. Generated assets need provenance.

Protocol, crypto, key derivation and persisted-state changes require an ADR and
explicit compatibility/rollback notes. Use existing reviewed crypto libraries;
do not introduce bespoke cryptographic primitives. Regression tests should fail
before the fix and pass after. Never weaken verification or delete failing tests.
Record missing toolchains/network/device checks as NOT EXECUTED.

Run the relevant commands in AGENTS.md, metadata/notices checks and security CI.
Maintainer review and green relevant checks precede merge. Signed release and
physical-device requirements are separate from source contribution acceptance.
Report vulnerabilities through SECURITY.md instead of public exploit issues.
