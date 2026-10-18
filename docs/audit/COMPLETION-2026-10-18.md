# Security hardening completion — 2026-10-18

Branch: `fix/server-hardening-2026-10-18`; PR: https://github.com/0800x/Loom/pull/1.
Base: `24943028fd4fb95982db583194d4821bda8dedf3`.

This follow-up implements the remaining server/client/supply-chain work requested
by the maintainer after the earlier Phase 2 report. Protocol proposals remain ADRs.
It supersedes the deferred S1/S4 and unavailable-tool entries in
HARDENING-2026-10-18.md; that document remains a historical record. No message wire,
MLS serialized state, recovery format or identity derivation was changed. Server
password hashes now have an explicit versioned encoding in the existing column;
ADR 004 and compatibility.md document legacy verification and rollback limitations.
No wallet address was changed. The unrelated Windows build-bundle.ps1 checkout
line-ending difference is excluded from every commit.

**Verdict: BLOCKED for merge approval / signed distribution.** The OSV gate reports
RUSTSEC-2026-0173 (unmaintained proc-macro-error2 2.0.1, no fixed version returned).
No advisory is suppressed. Ten dependency notice texts remain unavailable, and
final hosted checks must be green. The implementation is suitable for further
alpha testing, not a security certification or beta recommendation.

## Findings and disposition

Paths are repository-relative. VERIFIED confirms the finding or described code
boundary, not that every external deployment/platform has been validated.

| ID | Status | Severity | File:line | Change / why not |
| --- | --- | --- | --- | --- |
| V1 | REFUTED | Info | services/loom_server/src/index.ts:6 | Startup reminder does not print the generated admin token. No speculative token-log removal. Retention by systemd/Docker remains an operational concern for other logs. |
| V2 | REFUTED as blanket missing-limits claim | Info | services/loom_server/src/http/http.ts:28; src/bootstrap/server.ts:229 | Existing bounded body reader and 768 KiB WebSocket maxPayload retained. No consumed-body endpoint without a reader limit established. See S3. |
| V3 | VERIFIED | High | services/loom_server/src/security/rate_limiter.ts:10; src/security/client_address.ts:13 | Common admission precedes delivery adapters; token buckets, bounded overflow and explicit proxy CIDRs replace unsafe saturation/proxy handling. Process-local quotas reset with the process and do not coordinate replicas. |
| V4 | REFUTED | Info | services/loom_server/src/storage/postgres_store.ts:372 | COUNT table identifiers come from a literal five-table array. |
| V5 | VERIFIED | Medium | services/loom_server/src/security/bounded_map.ts:1; src/calls/call_realtime_service.ts:1 | Call pending/dedup state and group control admission now have hard cardinality/concurrency ceilings; expiry/lifecycle cleanup retained. No live quota history is evicted to admit attackers. |
| V6 | REFUTED as absent cleanup/all-auth-proof allegation | Info | services/loom_server/src/security/device_bundle_store.ts:246; src/security/device_request_proof.ts:92 | Nonces are lazily deleted on admission, not by a periodic job. Proof boundaries and initial binding/session/federation exceptions are documented in SECURITY-FEDERATION.md. It is not claimed that every route uses device proof. |
| V7 | VERIFIED | High | services/loom_server/src/federation/queue_limits.ts:3; src/federation/routing_store.ts:229 | Global/per-peer durable queue count/byte limits are admitted transactionally, with PostgreSQL advisory serialization; peer request admission added after signature verification. Delivered history is not silently deleted. |
| V8 | VERIFIED review; unsafe-backup allegation REFUTED | Medium | apps/loom/android/app/src/main/AndroidManifest.xml:10,58,63 | allowBackup already false; storage maxSdk already 32. Launcher/deep-link and media components are intentionally exported. Removed showWhenLocked/turnScreenOn; full-screen intent remains for incoming calls. Physical deep-link/notification abuse review remains external. |
| V9 | VERIFIED, fixed | High | packages/loom_transport/lib/src/local_certificate_policy.dart:8 | Replaced process-wide root insertion with exact HTTPS origin/leaf fingerprint exceptions, manual fingerprint confirmation, CA:TRUE rejection and immediate tracked-client revocation. Legacy unscoped PEM trust is not silently migrated. |
| V10 | VERIFIED, fixed in source | High | apps/loom/android/app/src/main/kotlin/app/loom/messenger/MainActivity.kt:54; LoomAppLockBridge.kt:184 | FLAG_SECURE is set before Flutter startup and retained independently of App Lock. Recovery UI has no word-to-clipboard action; public call notifications are generic. No claim of physical Android screenshot/Doze testing. |
| V11 | VERIFIED, unchanged format | High residual | packages/loom_crypto_bridge/lib/src/recovery_file_codec.dart:8; apps/loom/lib/features/onboarding/presentation/recovery_screen.dart:91 | Encrypted codec uses Argon2id 19456 KiB, two iterations, p=1, AES-256-GCM, random salt and password minimum 12. Shipping onboarding file/PDF/QR exports instead use plaintext words with explicit warning. Password/chats and device-local MLS/session ratchet state are not restored by identity recovery. No recovery-format change authorized here. |
| V12 | VERIFIED partial gap, fixed for production images | High | services/loom_server/deploy/Dockerfile:1; deploy/docker-compose.production.yml:6; scripts/validate-security-config.py:17 | Newly pinned previously mutable Node/Alpine/Postgres/Caddy tags to registry-verified digests; existing pins untouched. Local source images require build rather than mutable-tag pull. npm integrity, Go sums and signed package verification retained. Reachability of every censorship-region mirror is UNCONFIRMED. |
| V13 | UNCONFIRMED comprehensive compliance | Medium | THIRD_PARTY_NOTICES.md:1; docs/license-compatibility.md:1 | Generated 562-entry inventory and preserved upstream texts with byte-digest validation. Ten notice texts and final binary/platform attribution need review. Namespace change does not establish new authorship; no blanket provenance/license clearance. |
| V14 | VERIFIED bounded paths; exhaustive adversarial coverage UNCONFIRMED | Medium | packages/loom_dtn/lib/src/replica_intake_store.dart:131; packages/loom_transport/lib/src/nearby_legacy_message_gateway.dart:379; apps/loom/lib/features/messaging/application/product_messaging_policy.dart:32 | Existing expiry/seven-day custody/hop limits, storage-pressure handling and bounded gateway concurrency retained. v2Required dispatch forbids legacy fallback. Legacy compatibility still exists deliberately; real radio/hostile-carrier stress is not claimed. |
| S1 | VERIFIED, implemented | High | services/loom_server/src/security/password_hash.ts:3 | Async scrypt N=131072,r=8,p=1; two concurrent jobs/eight queued; strict descriptors, canonical hash encoding, legacy N=16384 verification and successful-login CAS rehash in SQLite/Postgres. ADR 004 records compatibility. |
| S2 | VERIFIED, implemented | High | services/loom_server/src/security/rate_limiter.ts:10; src/bootstrap/server.ts:234 | Earlier S2 commits retained; per-IP/class/account/device keys and trusted-proxy policy, saturation/debt and v2 429 regressions tested. Distributed/persistent quota coordination is not implemented. |
| S3 | REFUTED as missing existing limits | Info | services/loom_server/src/bootstrap/server.ts:229; src/http/http.ts:28 | Existing body/attachment/WebSocket limits retained; no check weakened. |
| S4 | VERIFIED, implemented | High | services/loom_server/src/federation/queue_limits.ts:5; src/security/bounded_map.ts:1 | Added bounded call/group admission and 8192-item/256 MiB total, 1024-item/64 MiB peer queue defaults with validated overrides. Exact retries stay idempotent. |
| S5 | VERIFIED, implemented | Low | services/loom_server/SECURITY-FEDERATION.md:65 | Removed obsolete future-proof requirement; docs match implemented proof/nonce boundaries. |
| K1 | REFUTED in part; documentation added | Low | apps/loom/android/app/src/main/AndroidManifest.xml:10; docs/android-permissions.md:1 | Existing storage SDK caps and opt-in Nearby retained. Permission purpose/point-of-use boundaries documented; real OS rationale/radio matrix not exercised here. |
| K2 | VERIFIED, implemented | High | packages/loom_transport/lib/src/local_certificate_policy.dart:8,191 | Origin-scoped leaf pins, CA rejection and revoke/forget tests. No persisted server-delete action currently exists; future deletion must call this removal boundary. Native/plugin TLS is outside Dart HttpOverrides. |
| K3 | REFUTED original release exposure; defense added | Low | apps/loom/lib/app/dev_surface_policy.dart:1; scripts/check-release-routes.dart:1 | Design Lab already had debug guards; central product/profile-disabled constant and CI guard added, obsolete ASSET_PHASE_TODO removed. |
| K4 | VERIFIED, implemented | High | apps/loom/android/app/src/main/kotlin/app/loom/messenger/LoomAppLockBridge.kt:184 | Whole-window privacy protection and keyguard behavior corrected; static regression included. |
| K5 | VERIFIED, implemented | Low | release/version.json:4; scripts/sync-release-metadata.py:1 | Generated app/server labels derive alpha from release metadata; published remains false. Drift check added. |
| O1 | VERIFIED, docs changed | High | README.md:290; release/README.md:1 | Moving-main installer execution replaced with signed-tag verification contract. No invented signing key/hash or claim that signed assets already exist. |
| O2 | VERIFIED, implemented | Medium | SECURITY.md:1; CONTRIBUTING.md:1; .github/CODEOWNERS:1; docs/threat-model.md:1 | Disclosure targets/support scope, ownership, contribution requirements and six-adversary threat model with Home Node metadata visibility. Maintainer must monitor the published channel. |
| O3 | VERIFIED partial implementation | Medium | THIRD_PARTY_NOTICES.md:1; scripts/check-third-party-notices.py:1 | Inventory, verbatim notices, upstream immutable-source references and license/App Store compatibility note added. Ten unresolved notice texts remain a signed-distribution blocker. |
| O4 | VERIFIED, implemented | Low | README.md:1; README.fa.md:1 | Removed hits counter/stale public-badge sentence; documented shipping sealed-box v1, disabled production v2 and published:false. |
| O5 | VERIFIED, implemented | Medium | services/loom_server/src/config/project_support.json:1; src/http/landing_page.ts:1 | Wallet values preserved in one default source; operator display opt-in, optional validated override. README/page networks aligned; default node page does not advertise project wallets. |
| O6 | VERIFIED, implemented; gate blocked | Medium | .github/workflows/security-completion.yml:1; .gitleaks.toml:1 | Added npm/Rust/OSV/secret/fatal-info/release-route/notice-integrity gates without removing existing jobs. Only exact reviewed synthetic/literal false positives are exempted. OSV maintenance advisory remains failing. |
| O7 | VERIFIED, documented | Medium | release/README.md:1 | Proposed minisign/cosign, checksums, SBOM/provenance and key distribution process; no assertion it is operational. |
| C1 | VERIFIED, ADR only | High | docs/adr/006-ratcheted-direct-messaging.md:4 | Sealed boxes lack ratchet FS/PCS; migration/prekey lifecycle/offline/retry/no-downgrade plan and negative tests specified. |
| C2 | VERIFIED, ADR only | High | docs/adr/006-ratcheted-direct-messaging.md:1 | Multi-platform FFI/ABI/ownership/zeroization/independent-review gates; no production v2 enablement. |
| C3 | VERIFIED, ADR only | Medium | docs/adr/007-relay-tag-privacy.md:1 | Public-key-derived relay-tag recognizability and secret/blinding/rotation alternatives with residual leakage. |
| C4 | VERIFIED, ADR only | Medium | docs/adr/008-hpke-and-deniable-authentication.md:1 | HPKE RFC 9180 context migration proposal; current KDF/wire unchanged. |
| C5 | VERIFIED, ADR only | Medium | docs/adr/008-hpke-and-deniable-authentication.md:1 | Signature non-repudiation and deniable-authentication tradeoffs; no improvised replacement. |
| C7 | REFUTED production-lib.rs unwrap allegation; ADR review | Medium | native/loom_mls/src/lib.rs:1; docs/adr/009-native-mls-and-group-limits.md:1 | lib.rs unwrap/expect occurrences reviewed were test assertions. Existing typed FFI errors/catch_unwind retained. Optional cargo-fuzz implementation not attempted; no MLS state/wire changes. |
| C8 | VERIFIED, documented | Medium | docs/adr/009-native-mls-and-group-limits.md:1 | Same-node groups, online admin joins, local wrapping/ratchet non-recovery, past-epoch and key-package replenishment limits documented. |
| G5 | VERIFIED design need, ADR only | Medium | docs/adr/010-censorship-resilient-transports.md:1 | Tor/pluggable transports, CDN/fronting feasibility and endpoint diversity evaluated without promising censorship resistance. |

## Tests and command evidence

The initial baseline and subsequent corrections were run before the runtime
restart during this conversation. Temporary toolchains/logs did not survive that
restart; these are recorded executed results, not fresh reruns or inferred passes.
The repository remains unchanged by that reset. Server tests and Python guards
were rerun after resuming. No tests were deleted or security checks relaxed.

| Command / scope | Observed result |
| --- | --- |
| Baseline npm ci / npm test before completion edits | PASS, 158 tests (earlier Phase 2 baseline 149 is in the historical report). |
| Baseline flutter analyze / flutter test | Analyze passed. Initial test environment lacked libsqlite3.so; provided a local symlink to installed system SQLite, then current full suite passed below. |
| flutter analyze --fatal-infos, apps/loom | PASS, no issues. |
| flutter test, apps/loom | PASS, 456 passed, 25 explicitly skipped, zero failed; SQLite library path configured. Skips are not claimed as tested. |
| npm test, services/loom_server | PASS, 167/167, no skipped tests; rerun after resuming also 167/167. |
| Node 22.16.0 --experimental-strip-types --test --test-concurrency=2 test/*.test.ts | PASS, 167/167. |
| Password legacy/CAS/queue regressions | PASS, three focused cases; failed before the new implementation existed. |
| Resource/federation quota regressions | PASS; admission/idempotence/byte/count cases failed before quotas and passed afterward. |
| Local TLS policy integration | PASS: real local TLS handshake, exact origin, CA rejection, confirmation/reload/revoke and legacy-pin rejection. One pure Dart case plus two Flutter wrapper cases. |
| dart analyze --fatal-infos / dart test in loom_models, loom_protocol, loom_federation, loom_storage, loom_transport | PASS in all five packages after offline dependency resolution. Initial no-resolution analyzer invocation was invalid, corrected and not counted as a pass. |
| dart format --output=none --set-exit-if-changed for resolved validation projects | Initial failures reproduced; formatter corrections committed after each project's pub get. Relevant source checks passed; three pre-existing vendored loom_video_compress formatting differences remain excluded from edits and from the validation matrices. |
| cargo test, native/loom_mls | PASS, five tests; rerun after optional dependency patch also passed. |
| cargo test, native/loom_vodozemac_poc | PASS, eight unit and two regression tests. |
| cargo test, third_party/hpke-rs-libcrux | Compiled successfully; upstream package has zero unit/doc tests. This is compilation evidence, not new cryptographic validation. Vendored .rs files byte-identical to upstream checked. |
| go test ./..., tools/loom_node_manager | FAILED in this local sandbox: TestNetworkWorkerDropsRootPrivileges cannot fork /usr/bin/id after dropping UID (operation not permitted). Test preserved. Hosted Go test/vet/privilege-isolation job at a603c033 passed. |
| npm audit | PASS, zero reported vulnerabilities. |
| cargo audit, MLS | Initial RUSTSEC-2026-0330/0331 in optional libcrux-kem 0.0.9 fixed via upstream 0.0.10 manifest pin. No ignored advisories. Final audit exits successfully with unmaintained proc-macro-error2 warning. |
| cargo audit, vodozemac | PASS, zero reported vulnerabilities. |
| osv-scanner scan source --recursive . | FAIL, RUSTSEC-2026-0173 unmaintained proc-macro-error2 2.0.1; no fixed version returned. Kept as failing gate. |
| flutter pub outdated | EXECUTED: 62 upgradable locked dependencies, six constrained below resolvable versions, lists discontinued. This is not a vulnerability result or authorization for mass major upgrades. |
| gitleaks git --redact | PASS after exact reviewed false-positive handling; final local scan covered 52 commits before final documentation changes. No broad file/rule exclusions. Hosted final-head result must be checked. |
| Python notice digest / release metadata / security config / repository audit guards | PASS; notice/security/repository guards rerun after resume. |
| dart -Ddart.vm.product=true scripts/check-release-routes.dart | PASS. |
| git diff --check excluding preserved upstream third_party/licenses text | PASS. Full whitespace check reports upstream CRLF/trailing spaces deliberately preserved for verbatim notice integrity. |

Failing-before regressions are meaningful for behavior changes (password legacy
migration, saturation/proxy admission, resource ceilings, scoped TLS, native
privacy source gate, funding default). Documentation/ADR-only changes have no
executable behavioral test possible: source/provenance review and consistency
checks apply. No false green result is claimed for external release gates.

### NOT EXECUTED / external validation

- NOT EXECUTED: cargo deny — cargo audit and OSV were used instead.
- NOT EXECUTED: trufflehog — gitleaks was used instead.
- NOT EXECUTED: local full Docker production/TURN fixture — Docker runtime unavailable;
  hosted run initially failed on a stale unpinned-image expectation, now corrected
  to assert the exact digest and source-build policy. Final hosted rerun required.
- NOT EXECUTED: real PostgreSQL concurrent-flood/load fixture — no database fixture;
  SQLite and fake-PG auth regressions plus transactional SQL review executed.
- NOT EXECUTED: physical Android capture/lockscreen/Doze/radio/permission matrix,
  signed APK/device install — Android device/build/signing fixture unavailable.
- NOT EXECUTED: signed release/SBOM/provenance publication or production v2 protocol
  enablement — keys, independent review and platform gates are not established.
- NOT EXECUTED after runtime restart: Flutter/Rust/Go/scanner reruns whose temporary
  toolchains disappeared; previously executed results above remain distinguished.

## NEW ISSUES

| ID | Status | Severity | File:line | Disposition |
| --- | --- | --- | --- | --- |
| N4 | VERIFIED, fixed | Medium | native/loom_mls/Cargo.lock:1; docs/adr/011-optional-kem-dependency-patch.md:1 | Optional KEM lock included RUSTSEC-2026-0330/0331. Upstream adapter Rust unchanged; manifest selects fixed KEM. Active RustCrypto provider unchanged. |
| N5 | VERIFIED, open | Low maintenance / OSV unknown | native/loom_mls/Cargo.lock:1 | RUSTSEC-2026-0173 has no reported fixed version; inactive optional dependency chain, cargo tree had no active path. Do not silently suppress or rewrite crypto to force green. |
| N6 | VERIFIED, fixed | Low | .github/workflows/flutter-ci.yml:1; scripts/test-node-production.py:87 | Per-project formatter context, cross-package design resolution and exact pinned-image fixture expectations corrected after hosted evidence. Final rerun pending. |
| N7 | VERIFIED residual | High if artifact stolen | apps/loom/lib/features/onboarding/presentation/recovery_screen.dart:91 | Shipping recovery file/QR/PDF is plaintext, despite separate encrypted codec existing. UI explicitly warns. No claim all exports use Argon2id; changing this product/format boundary needs its own decision and ADR. |
| N8 | VERIFIED, open | Medium distribution | THIRD_PARTY_NOTICES.md:1 | Ten locked dependencies lack verified notice text; names/versions are explicit in inventory. Final platform binary attribution remains unverified. |

## DECISIONS NEEDED

1. Choose an upstream-supported resolution for the unmaintained optional dependency
   chain, or document a separately reviewed maintenance-risk policy. This run does
   not suppress the OSV gate or invent a cryptographic replacement.
2. Resolve the ten missing dependency notices and review binary/platform/license
   obligations, including Apple distribution, before signing a release.
3. Establish publisher signing identity/key distribution, monitored private
   disclosure, independent security review and real-device/platform test ownership.
4. Decide separately whether plaintext paper/file recovery remains the intended
   export product or needs an encrypted default; preserve compatibility through an
   ADR rather than silently changing existing recovery behavior.
5. Protocol/provider/tag/authentication/anti-censorship choices remain proposals;
   implementation requires an explicit protocol migration decision.

Merge approval is withheld while the security gate is red or final-head CI is
unverified. No production deployment, signing, wallet rewrite or main merge was
performed. The following commit list records the published implementation; this
report itself is committed afterward.

## Published commits

```text
eb356ef8070da95c187aeb724013088351064041 fix(server): S2 admit delivery adapters before dispatch
46922e7535e2cf65966f5edbd2dc36cf174ff7e4 fix(server): S2 bound token buckets without active quota eviction
e4cacb36c7509e080bd2b191af5ff404e6dd65ce fix(server): S2 scope forwarded client IPs to explicit proxy CIDRs
d984e353081d6ce404a443a0846a1943bb3651d6 fix(server): S2 preserve account quota responses in v2 adapters
27460d09efab3c268b89030350a627e59cf999b3 fix(docs): S5 describe implemented device request proof boundaries
7d0cfd62b753105643e807cc200e01ca778d7b5b fix(docs): SETUP record discovered build and validation commands
c96b35868b49cac05158a77624dfcfab5a395594 fix(server): S2 recover idle overflow shard capacity after debt clears
62293bed7a73127f8b4044520a23e08ef0aa9c8e fix(audit): PHASE2 record regression evidence and remaining decisions
871ce282222b188b05814f27c1e55a6c888acc7c fix(audit): PHASE2 link published commits to validated source trees
6444e14d50bb4b6c753198a78144241513ee7e18 fix(audit): PHASE2 record unrelated hosted Dart formatting blockers
f99a86433573993b20ffb66e2993a7db6982fc0b fix(auth): S1 migrate legacy passwords to bounded asynchronous scrypt
0cc0a5256c62b5ae72378bfc339f5477059d9db9 fix(server): S4 enforce transactional federation and call resource ceilings
1c2b6c24c298f756ca14f492b31bd9aa56045b20 fix(client): K2 bind imported TLS leaves to confirmed HTTPS origins
895c51ae6c38b1fd9350c12d931be5a125dc596d fix(android): K4 protect recovery windows independently of App Lock
5aadcb7adaf52c3ea0e6fdcc84e484badb8a4fd6 fix(client): K3 enforce a compile-time development surface gate
ec3761aec7405545422ed46924303c93dcd974f8 fix(release): K5 derive product channel labels from release metadata
a4c9e6c163884afdd26877262cf153dbc4f0d0db fix(server): O5 make project funding configurable and operator opt-in
5f4bcddab990916811d79ddccb95a200402eca87 fix(ci): FORMAT normalize Dart sources for the pinned SDK formatter
d9d7e7f8c588859f5270dc04dafd446babc9e6a5 fix(deps): O6 replace the vulnerable optional KEM dependency pin
89d89826d4972d001cdef2569f87e35e1e303ddb fix(supply): V12 require content-addressed production container images
2e57f170b7fa4b67e6938dee0c2cdf2a50c7da93 fix(docs): O1 document verified release installation and current alpha limits
aa181049e2b58963b2c91f5c2c1638664bfed052 fix(docs): O2 define disclosure ownership and explicit threat boundaries
2e5691901143dea6cce0fee067b17b14b7b374c4 fix(design): C1 document protocol migration and censorship review gates
9c8deb6d947ae89134204cb7445a9f487ab1b0ba fix(ci): O6 add dependency secret and release surface security gates
a603c0334902a26d1e5c3f1a42482ed492d016b9 fix(supply): V12 build local images instead of pulling mutable local tags
af9a73fdbc8e542358a7adfb31313860570bfe11 fix(ci): O6 constrain scanner exceptions to reviewed dependency literals
7d2246a077ab04d669ad40be9fe61bcd8b41b742 fix(ci): FORMAT honor each resolved package language version
39dcbb367b2293d7957435982bf809ce915214a9 fix(licenses): O3 preserve locked dependency notices and unresolved attribution
a9097da1821a9a31fc34cd7dc38df5588e6ee631 fix(licenses): O3 preserve original notice bytes and validate content digests
524091371f29ae177a14d8953a6d36ecbdf94e18 fix(ci): O3 verify preserved third-party notice integrity
7524ae62ca0c80c0216fac6cdd2b10b4fdc71131 fix(ci): CHECKS resolve cross-package analysis and assert immutable mirrors
df1e62370d0169d646b8dc323125334fe5691ec6 fix(ci): FORMAT resolve every validation project before formatting
```
