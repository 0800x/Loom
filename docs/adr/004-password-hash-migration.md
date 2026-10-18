# ADR: versioned asynchronous password hashes

Status: accepted for the maintainer-authorized security completion on 2026-10-18.
This concerns server account passwords, not E2EE identity/recovery/session KDFs.

Use Node crypto.scrypt asynchronously with N=131072, r=8, p=1, a 32-byte key,
16 random salt bytes and 160 MiB maxmem. A shared per-process admission gate allows
two computations and eight waiting requests; excess receives HTTP 429. Across
replicas memory budgets remain per process. Run Node test workers two at a time
to prevent each test process allocating two 128 MiB computations simultaneously.

Existing password_hash TEXT stores either canonical 32-byte base64 (legacy
N=16384/r=8/p=1), or `scrypt$131072$8$1$<canonical-base64-key>`.
password_salt stays unchanged. No database column/schema or message wire changes.
A successful legacy login performs a compare-and-swap upgrade before issuing a
session; incorrect passwords never upgrade. Approval requests store the same
versioned representation and approval preserves it. Unknown/corrupt descriptors
are rejected without allowing attacker-selected resource parameters. Salts and
parameter descriptors are not secret, but derived temporary buffers are cleared.

Compatibility: current code reads old and new hashes. Previous binaries cannot
read upgraded/new hashes; do not roll back software against a migrated database.
Retain a pre-upgrade coordinated database/config backup; restoring it also rolls
back account changes since that snapshot. Do not rewrite hashes without knowing
the password. Test old-account login, failed login, upgrade idempotency, approval,
Postgres update predicates, concurrency rejection and malformed descriptors.
