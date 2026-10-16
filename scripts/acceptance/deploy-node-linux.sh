#!/usr/bin/env bash
set -euo pipefail

BRANCH="codex/federation-routing-tui-v2"
DOMAIN="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALL_DIR="/opt/loom-node"
ENV_FILE="$INSTALL_DIR/deploy/.env"
BACKUP_ROOT="/opt/loom-backups"

usage() {
  echo "Usage: $0 node.example.test|peer.example.test" >&2
}

case "$DOMAIN" in
  node.example.test|peer.example.test) ;;
  *) usage; exit 2 ;;
esac

if [[ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]]; then
  echo "Refusing to deploy from a dirty worktree. Commit/stash local changes first." >&2
  exit 1
fi

git -C "$REPO_ROOT" fetch origin "$BRANCH"
git -C "$REPO_ROOT" switch "$BRANCH"
git -C "$REPO_ROOT" pull --ff-only origin "$BRANCH"

SHA="$(git -C "$REPO_ROOT" rev-parse --short=12 HEAD)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="$BACKUP_ROOT/$DOMAIN-$STAMP-$SHA"

sudo mkdir -p "$BACKUP_DIR"
sudo chmod 0700 "$BACKUP_DIR"

if [[ -f "$ENV_FILE" ]]; then
  echo "Backing up current Node configuration and persistent identity..."
  sudo cp -a "$ENV_FILE" "$BACKUP_DIR/loom.env"
  sudo chmod 0600 "$BACKUP_DIR/loom.env"

  COMPOSE=(sudo docker compose --env-file "$ENV_FILE" -f "$INSTALL_DIR/deploy/docker-compose.production.yml")
  if "${COMPOSE[@]}" ps --status running postgres 2>/dev/null | grep -q postgres; then
    "${COMPOSE[@]}" exec -T postgres pg_dump -U loom -d loom | sudo tee "$BACKUP_DIR/loom.sql" >/dev/null
    sudo chmod 0600 "$BACKUP_DIR/loom.sql"
  fi
  if "${COMPOSE[@]}" ps --status running loom-node 2>/dev/null | grep -q loom-node; then
    "${COMPOSE[@]}" exec -T loom-node sh -c 'tar -czf - -C /app/data .' | sudo tee "$BACKUP_DIR/loom-node-data.tgz" >/dev/null
    sudo chmod 0600 "$BACKUP_DIR/loom-node-data.tgz"
  fi
fi

echo "Installing/updating Loom Node $DOMAIN from $BRANCH @ $SHA"
sudo "$REPO_ROOT/services/loom_server/scripts/linux/install-production.sh" \
  --domain "$DOMAIN" \
  --proxy auto \
  --federation trusted \
  --no-tui

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Expected production environment was not created: $ENV_FILE" >&2
  exit 1
fi

# Install the unified `loom` command and keep `loom-node` as a compatibility alias.
sudo "$REPO_ROOT/services/loom_server/scripts/linux/install-cli.sh"

# Existing installations intentionally preserve operator settings, so enforce
# the acceptance federation policy explicitly after the installer has preserved
# all generated secrets.
if sudo grep -q '^LOOM_FEDERATION_MODE=' "$ENV_FILE"; then
  sudo sed -i 's/^LOOM_FEDERATION_MODE=.*/LOOM_FEDERATION_MODE=trusted/' "$ENV_FILE"
else
  echo 'LOOM_FEDERATION_MODE=trusted' | sudo tee -a "$ENV_FILE" >/dev/null
fi
sudo chmod 0600 "$ENV_FILE"

PROXY_MODE="$(sudo awk -F= '$1=="LOOM_PROXY_MODE" {print $2; exit}' "$ENV_FILE")"
COMPOSE=(sudo docker compose --env-file "$ENV_FILE" -f "$INSTALL_DIR/deploy/docker-compose.production.yml")
if [[ "$PROXY_MODE" == "caddy" ]]; then
  COMPOSE+=(--profile caddy)
fi

"${COMPOSE[@]}" up -d --build

for _ in $(seq 1 30); do
  if curl -fsS --max-time 5 "https://$DOMAIN/readyz" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

curl -fsS --max-time 10 "https://$DOMAIN/readyz"
echo
curl -fsS --max-time 10 "https://$DOMAIN/.well-known/loom/server"
echo

echo "Node deployment complete: $DOMAIN"
echo "Commit: $SHA"
echo "Backup: $BACKUP_DIR"
echo "Federation policy: trusted"
echo "CLI: loom (loom-node remains a compatibility alias)"
echo "Next: after BOTH Nodes are updated, run scripts/acceptance/trust-peer-linux.sh on each server."
