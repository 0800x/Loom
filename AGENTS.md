# Repository checks

Read README.md, docs/README.md, docs/security-and-operations.md,
docs/architecture-v2.md and docs/compatibility.md before security changes.

- Flutter client: `cd apps/loom && flutter analyze && flutter test`.
- Node server: `cd services/loom_server && npm ci && npm test`.
- MLS: `cd native/loom_mls && cargo test`.
- Session provider PoC: `cd native/loom_vodozemac_poc && cargo test`.
- Go manager: `cd tools/loom_node_manager && go test ./...`.
- Repository security: `python3 scripts/validate-security-config.py` and
  `python3 scripts/repository_audit.py` from the root.

Record unavailable commands as NOT EXECUTED; do not infer success from source.
Keep protocol, crypto and persisted-state compatibility changes separate from
resource-admission fixes. Preserve secrets and existing signing material.
