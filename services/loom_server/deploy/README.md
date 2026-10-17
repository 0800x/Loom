# Loom Node deployment

For a first installation, start with [Home Node setup](../../../docs/node-setup.md)
([فارسی](../../../docs/node-setup.fa.md)). The one-command wizard configures the
selected services and opens Node Manager. [Bundled storage](STORAGE.md) explains pinned source builds, retained images and
third-party licensing. This page covers deployment details,
manual source approval, proxies and non-Linux installations.


Loom has two intentionally different server experiences.

## Easy Mode

Easy Mode is for local development, a single machine, or an isolated LAN. It uses Node.js on the host, SQLite, filesystem attachment storage, and HTTP only on exact development loopback addresses; LAN endpoints require authenticated HTTPS. It is not the public Internet deployment path.

## Production Bundle

The production bundle runs the application stack in Docker Compose:

- `loom-node` — Loom Node runtime
- `postgres` — PostgreSQL 17
- `minio` — S3-compatible attachment storage
- `caddy` — optional bundled reverse proxy for automatic public HTTPS

The Node is also published on `127.0.0.1:7483` only. That loopback binding exists so an already-installed host reverse proxy such as Nginx can safely proxy to Loom without exposing port 7483 publicly.

Persistent Docker volumes store PostgreSQL data, attachments, Node identity/data, and (when Caddy mode is used) Caddy certificate state.

## Linux integrity-verified installation and updates

Obtain the bootstrap script itself through a trusted channel. From an unprivileged account, provide a full immutable commit and the SHA256 of its canonical **uncompressed Git tar archive**, obtained from authenticated release metadata or an independently reviewed trusted checkout:

```bash
export LOOM_REF='<40 lowercase hexadecimal commit characters>'
export LOOM_SOURCE_SHA256='<64 lowercase hexadecimal archive SHA256 characters>'
bash scripts/install-loom-node.sh --domain chat.example.com --proxy auto --no-tui
```

Do not resolve a branch and download a checksum from that same mutable/untrusted source as your approval process. Do not pipe downloaded shell code into root. On a trusted release workstation, the archive digest is produced by `git archive --format=tar "$LOOM_REF" | sha256sum`. Authenticate/review the revision and deliver its digest to the server through an independent trusted channel. No signing key or authenticated public release manifest is bundled with this repository; without explicit approval installation/update fails closed.

The bootstrap downloads Git objects without root, disables Git hooks/helpers and inherited Git configuration, fetches the exact SHA, verifies its archive, then elevates with an empty environment. The privileged side verifies its own private copy again before extracting/executing the installer. Direct elevation of a mutable working checkout is refused. Installation is restricted to `/opt/loom-node`.

For private source downloads, `LOOM_UPDATE_GITHUB_TOKEN` is accepted explicitly by the unprivileged bootstrap; SSH host-key TOFU and inherited Git helpers are not used. The privileged Node Manager reads its private `/opt/loom-node/.loom-update-token` file instead of inheriting a caller's token environment.

The Node Manager still checks the configured branch for availability, but execution requires a matching entry in root-owned, mode-0600 `/etc/loom/approved-releases`. Its directories must be root-owned and not writable by others. Each approved line is:

```text
0800x/Loom <40-character-commit-SHA> <64-character-Git-tar-SHA256>
```

Populate this file only after authenticating/reviewing the release. A branch moving during download cannot alter the selected revision. Update downloads run with non-root credentials; only digest-verified extraction, installation and service operations run privileged. Shell syntax checks are correctness checks, never authenticity checks. After installation, runtime readiness and the exact running commit must match the selected revision before success is persisted.

Run `loom` to open the installed Manager; `loom-node` remains an alias. Configuration/install changes requiring a source snapshot must use a freshly verified release, rather than an arbitrary `LOOM_SOURCE_ROOT`. The low-level installer supports `--proxy auto|caddy|nginx`, preserves existing configuration and volume names, and fails on TLS/certificate verification errors. `--no-start` reports configuration-only status without claiming a usable HTTPS URL.

`loom uninstall --purge-data --yes` never bypasses path/ownership checks. Recursive deletion requires the installer-created root-owned marker. Docker cleanup requires the exact `org.loom.installation=/opt/loom-node` label and retains shared images. Old unlabelled volumes are preserved for explicit operator review; do not relabel unrelated resources to force cleanup. Backups require their own explicit ownership marker before purge. Existing installations acquire the install marker during a verified update.

Proxy `auto` preserves the existing selection, uses active host Nginx when detected, otherwise Caddy, and refuses to steal ports from unknown services.

In Nginx mode the installer:

1. installs Nginx/Certbot only when missing,
2. refuses to overwrite an unrelated Nginx virtual host for the same domain,
3. writes a Loom reverse-proxy server block,
4. validates with `nginx -t` before reload,
5. requests the certificate with the Nginx Certbot plugin,
6. switches the site to HTTPS with HTTP-to-HTTPS redirect,
7. installs a Certbot renewal deploy hook that validates and reloads Nginx.

Certificate issuance still requires public DNS for the configured hostname to point to the server and inbound TCP 80/443 to be reachable.

## Windows production setup

Windows production continues to use the bundled Caddy profile. From the repository root:

```powershell
.\services\loom_server\scripts\windows\setup-production.ps1 `
  -Domain chat.example.com `
  -OperatorName "Example operator" `
  -NetworkJurisdiction "Example jurisdiction"
```

The setup tool generates strong random PostgreSQL, MinIO, and admin credentials in `deploy/.env`, validates Compose, builds the Node image, and starts the Caddy profile.

Do not commit `deploy/.env` or share it. It contains administrative and storage credentials.

## Registration policy

`approval` is the safe default. The Node Manager exposes pending registration requests for operator review. `open` should only be chosen deliberately because it allows automatic account creation.

## TLS / HTTPS

Both Linux proxy modes expose the same public `https://<LOOM_PUBLIC_DOMAIN>` endpoint. Caddy manages ACME automatically in Caddy mode. In Nginx mode Certbot obtains the certificate and its system timer plus Loom deploy hook handle renewal/reload.

Never disable client certificate validation to work around a deployment problem.

## Federation

`trusted` is the guided setup default. It does not automatically trust arbitrary Nodes; federation peers still need explicit discovery and trust. `open`, `local`, and `hybrid` should only be selected deliberately for their intended environments.

## Data and backup boundaries

The production bundle persists:

- `loom-postgres` — accounts, sessions, conversations, and message metadata/ciphertext
- `loom-objects` — attachment objects
- `loom-node-data` — Node identity and Node-local data
- `loom-caddy-data` — ACME account/certificate material when Caddy mode is used

A real backup policy must preserve the Node identity together with application data. Replacing a Node identity unexpectedly changes the fingerprint clients use for trust decisions.

## Manual Compose operation

For Caddy mode, include the profile:

```bash
cd services/loom_server/deploy
docker compose --env-file .env -f docker-compose.production.yml --profile caddy ps
docker compose --env-file .env -f docker-compose.production.yml --profile caddy logs -f
docker compose --env-file .env -f docker-compose.production.yml --profile caddy up -d --build
```

For host-Nginx mode, omit `--profile caddy` so the Caddy service remains disabled:

```bash
docker compose --env-file .env -f docker-compose.production.yml up -d --build
```

Use `down` without `-v` unless you intentionally want to destroy persistent Node data.

