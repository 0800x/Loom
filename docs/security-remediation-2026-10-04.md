# Security remediation — 2026-10-04

Target: `0800x/Loom`, **main only**. No changes or merge to `main`.

Starting commit: `f78ac8f2e6b4bdd8d230714f4cf3417aac43ec06` (remote branch verified before edits and again before publishing). The enclosing GitHub commit is the final immutable revision; its exact SHA is also supplied in the delivery message. Work was performed against an API-materialized source snapshot, not a local authenticated Git checkout.

## Findings and evidence

| Finding | Confirmed? | Previous behavior | Fix | Tests | Remaining risk |
|---|---|---|---|---|---|
| 1. Device-link trust | Yes | Authorization token was the HKDF root, so a relay seeing redemption could decrypt. Client/server token-hash encodings also disagreed. | Protocol v2 has independent random 32-byte authorization and encryption secrets; only QR carries encryption secret. Version/link/identity/device remain AAD-bound. Client/server hash token UTF8 text consistently. Server rejects legacy or secret-bearing envelopes. | Codec roundtrip, wrong secret, simulated relay token decryption rejection, wire redeem field allowlist, hash contract, server legacy rejection. | QR disclosure compromises pairing; Dart immutable strings cannot reliably be zeroed. Old QR/client flow must be replaced. |
| 2. Updater supply chain | Yes, although selected-commit/runtime checks already existed | Pinned checkout still trusted mutable branch discovery without independent approval; inherited environment/hooks and privileged fetch were possible. | Exact SHA plus independent root-protected archive digest approval; isolated fetch without root, hooks/helpers disabled, SHA256 validation before extraction/execution, clean installer environment, runtime revision verification retained. | Branch movement/hook fixture, malicious shell environment, digest substitution, approval file permissions/symlinks, runtime mismatch. | No official signing key supplied. Operator approval is the trust root; dependency registries and Docker base images remain separate trust boundaries. Actual privileged deployment not performed. |
| 3. Installer supply chain | Yes | Mutable branch clone followed by privileged shell; legacy acceptance bootstrap used SSH accept-new and an obsolete branch. | Full commit and authenticated SHA256 required; unprivileged exact fetch; privileged private-copy revalidation; root bootstrap refused; no SSH TOFU; strict error handling. | Invalid/mutable SHA and missing digest refusals; shell checks. | Bootstrap and approval metadata must themselves be obtained authentically. Root OS package/service work remains necessary. |
| 4. Privileged environment | Yes | Multiple sudo -E wrappers and arbitrary inherited source/search-path/Git controls. | No sudo -E in Linux/acceptance scripts; fixed paths, empty elevation env, validated Node home in binary, trusted installed CLI, clean Go child env and fixed Linux executable paths. | Environment allowlist, BASH_ENV execution marker, configuration guard, shell checks. | An already-compromised root process remains outside this boundary. UID-drop integration is blocked by this workspace; normal Linux deployment must verify it. |
| 5. Uninstall paths | Yes | Environment-selected recursive deletion root, no ownership marker. | Exact canonical /opt/loom-node only; rejects empty/shallow/traversal/symlink roots; root-owned non-writable marker; revalidation before removal; backup ownership required. | Destructive path cases and symlink marker refusal. | Legacy installs need a verified update to create marker. Shared filesystems and root compromise are not isolated by shell validation. |
| 6. Docker cleanup | Yes | Case-insensitive loom name/image matching could delete unrelated resources. | Exact installation ownership labels on services/volumes/network; no name-regex cleanup or shared-image removal. Existing Compose/volume names preserved. | Ownership/config guard and full server tests. | Unlabelled legacy resources deliberately remain; explicit administrator review required. Real Docker migration not run here. |
| 7. TLS fail-open | Yes | Certbot/HTTPS failure was ignored and success/HTTPS URL printed. | Mandatory setup/verification; success state persisted afterward; no-start explicitly unverified; HTTP bootstrap site returns 503 instead of proxying authenticated API. | Actual installer orchestration with certificate/HTTPS failure doubles; asserts no success URL/state. | Real DNS/ACME/Nginx/Caddy integration requires deployment testing. |
| 8. Default secrets | Yes | Long sample admin/TURN secrets passed length checks; database/S3 sample values were not rejected. | Explicit sentinel rejection; independent purpose credentials; database/S3 minimum lengths; sample TURN secret commented out. Existing installer random generation retained. | Production config tests for admin, TURN, database, S3 secret/access key and shared credentials. | Operators must rotate existing sample credentials; randomness cannot be proven from string shape. |
| 9. Android cleartext release | No production regression reproduced | Main manifest already uses cleartext=false; debug override broadly enabled HTTP. | Production secure default retained; debug-only XML permits exact loopback, denies LAN/public cleartext. | Production configuration assertions and CI guard. | Android runtime/manifest merge not built here. |
| 10. Android signing | Yes | Release used debug signing config. | Explicit keystore environment; release fails if missing; rejects debug alias/path/certificate subject. CI engineering release uses isolated disposable non-debug key. | Config regression and CI guard. | Actual Gradle/keystore/release APK build not executed; CI engineering key is not a distributable production identity. |
| 11. Transport consistency | Yes | Mixed private-LAN HTTP and loopback-only checks. | Shared HTTPS policy across discovery/challenge/login/security/link/user/messaging/calls/v2 clients and realtime setup. Production LAN HTTP removed; exact loopback only for development. Server config follows policy. | Protocol suite, loopback discovery/login/security tests, cross-client LAN rejection, HTTPS policy matrix and wire redeem. | No physical LAN/public TLS or Android end-to-end device run. A node signature alone does not encrypt HTTP credentials. |
| 12. Address identity MITM | Minimum protection already present; missing-TOFU claim ruled out | Existing persistent peer_identity_pins and messaging/offline pin checks reject changed keys. First contact remains TOFU. | Preserved existing behavior; added durable reopen/stable/substitution regression. | First-seen storage, reopen, unchanged key and malicious replacement refusal. | A malicious first-contact identity remains possible until out-of-band fingerprint verification; no transparency infrastructure added. |
| 13. Abuse resistance | Yes | No general endpoint quotas; existing per-feature caps insufficient for brute force. | Bounded source-IP/endpoint/token/account/device quotas, login username/refresh token limits, global request concurrency, socket/frame/connection caps, 429 Retry-After; forwarded headers ignored. | Burst/refill/state/concurrency unit tests; real HTTP login burst with forged forwarded headers; full server suite. | Limits are per process, not distributed. Reverse-proxy clients share TCP-peer quotas. Limiter saturation fails closed and can reduce availability. |
| 14. Sync poison | Reproduced on starting source | Unknown conversation/message byName throws; subsequent events stall. Earlier events can persist without page cursor commit. Unknown event kinds already skipped. | Unsupported kinds/types skipped with bounded content-free diagnostics; whole page state/dedupe/cursor transaction; malformed known data rolls back; non-advancing cursor rejected. Catalogue also filters unsupported kinds. | Both new regression cases fail on starting source and pass after fix: unknown type progression and full-page rollback. | Skipped future types are not later replayed automatically; malformed known events still fail closed pending protocol repair. |

## Submitted UI failures

The Action Sheet used a coloured Container between ListTile and its Material ancestor. It now supplies its own Material ink surface. Added `action_sheet_material_test.dart`; existing conversation test still asserts no framework exceptions. Gallery test checks both actual Gallery labels. Search test opens the search control first; tab switching preserves its draft/search mode, and the current Close search action clears it. Widget tests were statically analyzed, **not executed** here.

## Validation actually performed

- Node v24.19.0 strip-only TypeScript runtime: **107/107 tests pass**, including all server/security tests and source-loader validation.
- Independent Dart SDK: **10/10 focused security tests pass** after final Device Link changes.
- Broad protocol/storage/transport run: **167 passed, 6 failed**. Every one of those six failures was reproduced against the unchanged starting snapshot. See baseline failures below. This is not an all-green Flutter/Dart suite.
- Modified Dart code/new UI tests: static analysis with fatal infos passed with **no issues**; formatter passed. Package mappings were assembled from public dependencies for this environment, not from a successful Flutter pub get.
- Go: **35 tests pass, one integration test is blocked**: TestNetworkWorkerDropsRootPrivileges returns fork/exec /usr/bin/id: operation not permitted when requesting non-root credentials in this workspace. The test is kept; no skip or unsafe root fallback was added. Credential selection, approval integrity, hooks, environment and checksum tests pass. `go vet ./...` passes.
- All fetched Linux/acceptance shell scripts pass bash -n; production configuration Python guard passes. These syntax checks do not authenticate releases.
- Flutter execution previously received an automatic approval rejection because it unexpectedly accessed a link-local cloud metadata endpoint. It was not retried/bypassed. No Flutter widget suite, Android build, physical device run, destructive production uninstall, Docker deployment or real ACME provisioning was executed.

### Pre-existing broad Dart failures (also reproduced at starting SHA)

1. nearby_direct_delivery_test: fixture uses a fixed September 1 timestamp, which is outside the receiver's seven-day freshness window on this run.
2. routed_messaging_api_test: Test A obsolete-generation route ends with SocketException offline.
3. messaging_engine_test: failure recovery fixture expects delivered from destination-domain custody without recipient-device evidence.
4. nearby_internet_gateway_test: generic PublicKey fixture accesses nonexistent bytes getter.
5. nearby_dtn_peer_bootstrap_test: same generic PublicKey bytes compilation failure.
6. nearby_dtn_encounter_test: same generic PublicKey bytes compilation failure.

These were not weakened/disabled or changed outside the requested security/UI remediation. They remain follow-up work.

## Operator consequences

- Update clients and recreate old pairing QR codes. The v1 design is intentionally not accepted.
- LAN deployments require authenticated HTTPS; debug Android allows only exact loopback exceptions.
- Release APK builds require LOOM_ANDROID_KEYSTORE, LOOM_ANDROID_STORE_PASSWORD, LOOM_ANDROID_KEY_ALIAS and LOOM_ANDROID_KEY_PASSWORD. Never commit keystores/passwords. Engineering CI keys must not be used for production distribution.
- Installer defaults no longer trust a mutable branch. Use the pinned bootstrap and independently approved Git-tar digest described in the deployment README. Node Manager updates fail closed without a matching protected approval record.
- Uninstall is fixed to the approved production location and refuses legacy installations without the ownership marker. Verify/upgrade first. Unlabelled legacy Docker volumes and unowned backups are intentionally retained.
- Production config rejects sample credentials even if long; remove unused sample TURN configuration or replace it with a genuinely independent secret.

## Exact modified paths

- `.github/workflows/flutter-ci.yml`
- `.github/workflows/security-hygiene.yml`
- `README.md`
- `apps/loom/android/app/build.gradle.kts`
- `apps/loom/android/app/src/debug/AndroidManifest.xml`
- `apps/loom/android/app/src/debug/res/xml/network_security_config.xml`
- `apps/loom/lib/features/home/presentation/messenger_shell.dart`
- `apps/loom/lib/features/onboarding/application/device_link_service.dart`
- `apps/loom/test/conversation_ux_test.dart`
- `docs/security-remediation-2026-10-04.md`
- `packages/loom_crypto_bridge/lib/src/device_link_codec.dart`
- `packages/loom_crypto_bridge/test/device_link_codec_test.dart`
- `packages/loom_design/lib/src/components/loom_action_sheet.dart`
- `packages/loom_design/test/action_sheet_material_test.dart`
- `packages/loom_protocol/lib/loom_protocol.dart`
- `packages/loom_protocol/lib/src/call_client.dart`
- `packages/loom_protocol/lib/src/device_bound_session_client.dart`
- `packages/loom_protocol/lib/src/device_link_client.dart`
- `packages/loom_protocol/lib/src/messaging_client.dart`
- `packages/loom_protocol/lib/src/node_client.dart`
- `packages/loom_protocol/lib/src/node_identity_challenge.dart`
- `packages/loom_protocol/lib/src/security_client.dart`
- `packages/loom_protocol/lib/src/transport_security.dart`
- `packages/loom_protocol/lib/src/user_security_client.dart`
- `packages/loom_protocol/lib/src/v2_delivery_client.dart`
- `packages/loom_protocol/test/transport_security_regression_test.dart`
- `packages/loom_storage/lib/src/messaging_store.dart`
- `packages/loom_storage/test/peer_identity_pinning_test.dart`
- `packages/loom_transport/lib/src/messaging_engine.dart`
- `packages/loom_transport/test/sync_poison_regression_test.dart`
- `scripts/acceptance/bootstrap-node-linux.sh`
- `scripts/acceptance/purge-node-linux.sh`
- `scripts/install-loom-node.sh`
- `scripts/validate-security-config.py`
- `services/loom_server/deploy/.env.example`
- `services/loom_server/deploy/README.md`
- `services/loom_server/deploy/docker-compose.production.yml`
- `services/loom_server/scripts/linux/loom-cli.sh`
- `services/loom_server/scripts/linux/install-cli.sh`
- `services/loom_server/scripts/linux/install-production.sh`
- `services/loom_server/scripts/linux/install-safety.sh`
- `services/loom_server/scripts/linux/manager.sh`
- `services/loom_server/scripts/linux/setup.sh`
- `services/loom_server/scripts/linux/uninstall-production.sh`
- `services/loom_server/src/bootstrap/server.ts`
- `services/loom_server/src/calls/call_realtime_service.ts`
- `services/loom_server/src/config/config.ts`
- `services/loom_server/src/messaging/account_realtime_service.ts`
- `services/loom_server/src/security/device_link_store.ts`
- `services/loom_server/src/security/rate_limiter.ts`
- `services/loom_server/test/config.test.ts`
- `services/loom_server/test/device_link_store.test.ts`
- `services/loom_server/test/security_remediation.test.ts`
- `services/loom_server/test/server.test.ts`
- `tools/loom_node_manager/go.mod`
- `tools/loom_node_manager/go.sum`
- `tools/loom_node_manager/main.go`
- `tools/loom_node_manager/update_auth.go`
- `tools/loom_node_manager/update_auth_test.go`
- `tools/loom_node_manager/update_security.go`
- `tools/loom_node_manager/update_security_linux.go`
- `tools/loom_node_manager/update_security_linux_test.go`
- `tools/loom_node_manager/update_security_other.go`
- `tools/loom_node_manager/update_security_test.go`
- `tools/loom_node_manager/updater.go`
- `tools/loom_node_manager/updater_progress.go`
