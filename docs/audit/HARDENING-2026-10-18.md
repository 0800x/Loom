# Phase 2 server admission hardening — 2026-10-18

Base: `24943028fd4fb95982db583194d4821bda8dedf3`.
Branch: `fix/server-hardening-2026-10-18`.
Only Phase 2 and its required setup/report were executed. No protocol, crypto,
key derivation, storage schema, secrets, wallets or donation values were changed.
The Windows build-bundle.ps1 CRLF/LF checkout difference is excluded from commits.

## Commits

```text
a4dd20bda1d5d83781c465a435c230cdbd1d9d0e fix(server): S2 admit delivery adapters before dispatch
ee1d768210e3e4a08ec3161285086a1fcb5b81b9 fix(server): S2 bound token buckets without active quota eviction
822c46947afd65339ea19afffbcabf81aaded9f6 fix(server): S2 scope forwarded client IPs to explicit proxy CIDRs
eedcf49c1b60938e85527dba081f87dce81e811e fix(server): S2 preserve account quota responses in v2 adapters
481e48b53837ab1ad513336d53300560eb95c182 fix(docs): S5 describe implemented device request proof boundaries
6dc419f9fae019f36238f4b56923e7461b588000 fix(docs): SETUP record discovered build and validation commands
42f5b18ffa03512c0d064d1c9bb3610834dbd351 fix(server): S2 recover idle overflow shard capacity after debt clears
```

This report is committed separately after those implementation commits.

## Findings and disposition

Server paths below are relative to services/loom_server.

| ID | Status | Severity | File:line | Change / why not |
| --- | --- | --- | --- | --- |
| S1 | VERIFIED, DEFERRED | High | src/storage/postgres_store.ts:131,165; src/storage/sqlite_store.ts:205,231; src/registration/approval_store.ts:167 | Default synchronous scrypt still exists. Required cost/parameter persistence migration changes KDF/storage representation. The original Phase 1–4 no-crypto-change rule and KDF stop condition conflict with implementing that migration in Phase 2. Await explicit exception/compatibility decision; no hash rewrite performed. |
| S2 / V3 | VERIFIED, FIXED within one process | High | src/bootstrap/server.ts:234,426–450; src/security/rate_limiter.ts:9–65; src/security/client_address.ts:13–39 | Common HTTP admission now precedes all delivery wrappers. Fixed-window limiter replaced by continuously refilled token buckets. Exact state stays bounded without eviction/reset; fixed overflow shards preserve debt and recover after idle. Account/device/IP/credential keys remain enforced. Trusted proxy CIDRs are explicit and default to none. Replicas/restarts still have independent/reset quota histories. |
| S3 / V2 | REFUTED as blanket missing-limit claim | Info | src/http/http.ts:28–49; src/bootstrap/server.ts:229; src/calls/group_call_gateway.ts:10,32 | Existing body and WS limits retained; no missing consumed-body endpoint established by Phase 1. No blanket protocol/body format changes. |
| S4 / V1 | REFUTED | Info | src/index.ts:6–8 | Startup reminder does not print the admin token; no speculative logging removal. |
| S4 / V4 | REFUTED | Info | src/storage/postgres_store.ts:365–370 | Identifier is drawn from a literal table array; no SQL rewrite. |
| S4 / V5 | VERIFIED, DEFERRED | Medium | src/calls/call_realtime_service.ts:140–142,321,389 | Limiter state itself is fixed, but call pending/dedup and group-call queues still need cardinality budgets. Most other Map/Set sites already have TTL/lifecycle/cardinality bounds. Choose resource budgets and overload behavior before changing accepted call work. |
| S4 / V6 | REFUTED as absent cleanup/proof claim | Info | src/security/device_bundle_store.ts:246–254; src/security/device_request_proof.ts:92–128 | Cleanup is lazy per nonce admission and proof enforcement exists. No new timer or proof behavior introduced. |
| S4 / V7 | VERIFIED, DEFERRED | High | src/federation/routing_store.ts:217–228; src/federation/service.ts:55–60 | Durable queue admission lacks per-peer/total byte/count budget. Needs accepted budgets plus retry/overload semantics; do not silently discard existing messages. |
| S5 | VERIFIED, FIXED | Low | SECURITY-FEDERATION.md:65–92 | Removed obsolete future requirement and documented actual canonical proof, time window, durable lazy nonce cleanup, initial key-binding exception and separate auth boundaries. |
| SETUP | VERIFIED, FIXED | Info | AGENTS.md:1–16 | Added discovered validation commands as required. |

## Regression evidence

- `http_admission.test.ts`: before change, saturated HTTP concurrency still returned
  200 from v2 discovery instead of 429. After change, eight adapter routes reject
  before dispatch with 429/Retry-After and public security headers; slots recover.
- `rate_limiter_saturation.test.ts`: failed on the old fixed-window limiter.
  Covers continuous refill, boundary bursts, fresh-subject overflow admission,
  no active quota reset/promotion, 10,000-subject churn with fixed memory, and
  recovery of an idle shard's capacity only after debt clears.
- `client_address.test.ts`: failed before client_address module existed; passes
  with explicit proxy CIDRs, untrusted/spoofed chains, multi-hop right-to-left walk,
  IPv4-mapped loopback, malformed/oversized chains and invalid startup config.
- Additional HTTP regression: a v2 authenticated account limiter exception was
  caught by adapters and turned into HTTP 500. Before correction test reproduced
  500; after correction both tested v2 adapter paths preserve 429/Retry-After.
- Existing quota test now admits a fresh subject into overflow and still asserts
  its next over-quota request is rejected. Exhausted exact/overflow quota checks
  remain; no tests were deleted or security proofs weakened.
- S5/AGENTS: no executable test possible for prose alone. Text reviewed against
  current verifier/store implementations; existing four proof/bundle tests pass.

## Commands and results

| Command | Result |
| --- | --- |
| `npm ci && npm test` before edits | PASS, 149 tests, 0 failed/skipped on Node 24.19.0 |
| Focused admission/proxy/limiter/proof suites | PASS; failing-before evidence described above |
| Final `npm test` | PASS, 158 tests, 0 failed/skipped on Node 24.19.0 |
| `npm exec --yes --package=node@22.16.0 -- node --experimental-strip-types --test test/*.test.ts` | PASS, 158 tests, 0 failed/skipped on CI's Node 22.16.0 |
| `npm audit --json` | PASS, zero reported vulnerabilities, 74 production dependencies |
| `python3 scripts/validate-security-config.py` | PASS |
| `python3 scripts/repository_audit.py` | PASS |
| `git diff --check main HEAD` | PASS |

Initial command-entry mistakes used the wrong working directory for two focused
suite invocations; those commands did not execute tests, were corrected, and are
not counted as successful validation. Baseline tests themselves did not fail.

- NOT EXECUTED: `flutter analyze && flutter test` in apps/loom — Flutter unavailable.
- NOT EXECUTED: `cargo test` in native/loom_mls and native/loom_vodozemac_poc — Cargo unavailable.
- NOT EXECUTED: `go test ./...` in tools/loom_node_manager — Go unavailable.
- NOT EXECUTED: `flutter pub outdated` — Flutter unavailable.
- NOT EXECUTED: `cargo audit` / `cargo deny` — Cargo unavailable.
- NOT EXECUTED: gitleaks/trufflehog — scanner executables unavailable.
- NOT EXECUTED: production Postgres flood/load test or real Caddy/Nginx deployment
  — no production database/proxy fixture supplied. Easy-mode integration and
  address-policy tests ran locally. Hosted CI status must be read from the PR;
  local tests are not hosted CI evidence.

## NEW ISSUES

| ID | Status | Severity | File:line | Disposition |
| --- | --- | --- | --- | --- |
| N3 | VERIFIED, FIXED | Medium | src/delivery/v2_delivery_routes.ts:461; src/delivery/attach_v2_delivery.ts:321 | Adapter catches converted account/device quota exceptions to 500; now rethrow typed RateLimitError to common admission for 429. Regression included. |

## DECISIONS NEEDED

1. Approve a narrowly scoped exception for password KDF/hash-format migration
   with ADR/compatibility note, legacy verification/rehash and concurrency budget;
   otherwise S1 must remain report-only under the original stop rule.
2. Set per-peer and global federation pending bytes/items, retention/retry policy
   and the expected operator-visible action when capacity is full. Define pending
   call/dedup/group-control queue ceilings and rejection semantics.
3. If multiple Node replicas must share quotas, select a shared authority and
   failure policy. This patch deliberately documents process-local operation and
   restart reset instead of claiming distributed protection.
4. Phase 3 client and Phase 4 supply-chain issues remain separate. Sensitive-screen
   capture, unscoped imported TLS trust, mutable image tags, license/provenance and
   end-to-end DTN admission review are not fixed by this server patch.

## Verdict

**BLOCKED** for closing the complete security catalog or merging the whole audit
as resolved. This PR is a tested, scoped server-admission patch with unchanged
wire/crypto/storage contracts. Exact remaining blockers: S1 migration conflict,
S4 resource budgets (V5/V7), unexecuted platform/scanner checks, and separate
Phase 3/4 findings. Keep the PR draft while assessing those blockers and hosted
checks. Do not merge it under a claim that all requested phases are complete.
