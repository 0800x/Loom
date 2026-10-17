# Update Loom Node and prepare an offline transfer

The release repository is `0800x/Loom`, branch `main`, with source at
`/opt/loom-src`. Authenticate repository access before fetching releases.

## Update the existing Linux installation

Run in the authenticated, root-owned checkout. Review/trust the full revision
before running code as root. Replace `REVIEWED_FULL_COMMIT_SHA` with the full SHA of the reviewed release containing this updated helper (not a branch name):

```bash
set -euo pipefail
cd /opt/loom-src
git fetch origin main
revision=REVIEWED_FULL_COMMIT_SHA
git cat-file -e "$revision^{commit}"
git fsck --strict --no-dangling
stage=$(mktemp -d /root/loom-update.XXXXXXXX)
git archive "$revision" | tar -x -C "$stage"
bash "$stage/scripts/update-installed-loom.sh" "$revision" /opt/loom-src 0800x/Loom main
```

The helper takes an immutable Git snapshot without switching/resetting the checkout.
It tests/builds the TUI, backs up installed code, rebuilds/recreates **only** `loom-node`,
checks readiness and the image revision, then records the selected update channel.
The `.env`, Compose configuration, Nginx sites and persistent volumes are preserved.
The Node restarts; active calls/connections can be interrupted. Go modules, npm and
Docker images may require downloads. Failed updates retain the backup and **do not
automatically roll back**. Inspect the failure before retrying.

```bash
bash /opt/loom-node/scripts/linux/install-cli.sh
hash -r
loom
docker compose --env-file /opt/loom-node/deploy/.env \
  -f /opt/loom-node/deploy/docker-compose.production.yml ps
curl --max-time 5 -fsS http://127.0.0.1:7483/readyz
```

Check the public HTTPS address separately. Local readiness does not establish
that TLS, the reverse proxy or the provider's media firewall works. This update
avoids rerunning the full installer, which correctly refused to overwrite the
existing Nginx site during the rebrand. Do not delete that site to bypass the check.

## Source bundles versus offline runtime images

CI's `loom-node-<version>-linux-amd64.tar.gz`, `linux-arm64.tar.gz` and Windows
Docker ZIPs contain deployment source and a manager binary. They are **not fully
offline installers**: building Node still needs its base image and npm dependencies;
PostgreSQL, MinIO and optional Caddy images must also be available.

`scripts/prepare-node-offline.sh` prepares a runtime transfer on a trusted connected
**Linux** workstation with Git, Go, Docker and matching target CPU architecture:

```bash
bash scripts/prepare-node-offline.sh REVIEWED_FULL_COMMIT_SHA /tmp/loom-offline-release
cd /tmp/loom-offline-release
sha256sum SHA256SUMS
```

The new directory contains `images.tar`, source, a Linux manager binary,
`offline-image.yml`, image inventory, revision/architecture metadata, licensing and
`SHA256SUMS`. It contains no live `.env`, identities, attachment volumes or TLS keys.
Transfer the directory and authenticate the checksum-manifest digest independently.
Checksums detect modification; they do not authenticate an untrusted publisher.
Image tags such as `latest` are resolved during preparation and their actual image
IDs/digests are recorded; preserve the prepared archive for reproducibility.

## Apply prepared images to an existing installation

Back up the database/attachments and current image before an update. On the target,
verify the transferred manifest digest against the trusted value, then:

```bash
cd /root/loom-offline-release
sha256sum -c SHA256SUMS
docker load -i images.tar
# Inspect build-info.txt: CPU architecture and reviewed commit must match.
docker image inspect loom-node-offline:REVIEWED_FULL_COMMIT_SHA \
  --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}'
install -m 0644 offline-image.yml /opt/loom-node/deploy/offline-image.yml
docker compose --env-file /opt/loom-node/deploy/.env \
  -f /opt/loom-node/deploy/docker-compose.production.yml \
  -f /opt/loom-node/deploy/offline-image.yml \
  up -d --no-deps --no-build --pull never --force-recreate \
  --wait --wait-timeout 120 loom-node
curl --max-time 5 -fsS http://127.0.0.1:7483/readyz
```

This image-only procedure updates the running Node, not installed source, TUI or
update-state metadata. Keep the override in subsequent Compose commands until a
normal verified source update replaces the image. Do not claim a full installation
update based solely on the manager's version. No volume deletion is involved.

## Fresh offline installations and certificates

The transfer script does **not** provision a fresh offline host. Docker/Compose,
host dependencies, unique credentials, persistent volumes, domain configuration
and a trusted TLS certificate still need deliberate provisioning. It does not
include optional LiveKit/TURN images or provider firewall changes.

Public ACME issuance/renewal needs access to the certificate authority and domain
validation. A fully disconnected host cannot simply obtain a new publicly trusted
certificate. Provision a valid certificate through the existing trusted process,
or use a managed private CA and explicitly configure client trust. Do not disable
TLS verification or silently substitute a self-signed certificate.

No third-party Docker mirror is automatically trusted or selected. The current
transfer flow avoids registry access on the target; mirror support and fresh
isolated-host provisioning remain follow-up work.

## Verification of this tooling

The README/update arguments and Bash syntax were checked locally. Runtime Docker
image preparation/loading, Go-in-container compilation, fresh offline setup and
production deployment were not available in the editing environment. Test the
transfer on a disposable matching-architecture host before relying on it.
