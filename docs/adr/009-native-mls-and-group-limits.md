# ADR C7/C8: MLS FFI and operational limits

Status: verified limits / proposed validation additions; no MLS wire/state change.

The catalog's unsafe blocks are in `native/loom_mls/src/ffi.rs`, not lib.rs.
The unwrap calls inspected in lib.rs occur under its test module, where they
assert expected success. Replacing those assertions with silent error handling
would weaken tests. Production operations already return typed errors through
the FFI boundary and use catch_unwind. Five MLS tests (including FFI tests) were
executed successfully during this completion; lib.rs alone has three test cases.
This does not prove memory safety or that every FFI ownership use is correct.

Keep bounded input parsing and stable status/error mapping, panic containment,
exact ownership/free rules, and reject malformed/stale handles. Any remaining
production unwrap/expect discovered in review must become a typed failure without
mutating MLS state on error. Fuzzing must pass only valid readable buffers to the
unsafe C ABI: arbitrary pointers are caller-contract violations, not safe fuzz
inputs. Add corpus-based malformed JSON/size/operation/state tests before a future
cargo-fuzz target, then run it in dedicated sanitized CI with reproducible seeds.
C7 implementation was optional; no speculative rewrite of audited MLS internals
or fake fuzz execution is included here.

Current group limits: membership coordination is same-Home-Node only; an admin
device must be online to produce a Welcome for joins. New members do not receive
past history automatically. Recovery entropy cannot recreate lost ratchet state.
Exported group state is sealed under a device-local wrapping key, not a shared
server escrow key. A cloned send-capable group state requires separate migration
analysis; do not equate recovery words with group-state backup.

`max_past_epochs(2)` bounds retained past epoch secrets and tolerates a small
amount of delayed traffic at the cost of retaining more historical key material.
It does not promise indefinite offline decryptability; validate reordered/late
packets across membership changes and show explicit unavailable-history errors.
Key-package publication must be replenished before exhaustion, consumes an
available package for each join, and must fail visibly when none is usable rather
than reuse invalid/expired membership material. Diagnostics and operator guides
must distinguish membership approval, admin Welcome creation and actual join.
