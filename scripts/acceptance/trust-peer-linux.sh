#!/usr/bin/env bash
set -euo pipefail

PEER_DOMAIN="${1:-}"
INSTALL_DIR="/opt/loom-node"
ENV_FILE="$INSTALL_DIR/deploy/.env"

usage() {
  echo "Usage: $0 node.example.test|peer.example.test" >&2
}

case "$PEER_DOMAIN" in
  node.example.test|peer.example.test) ;;
  *) usage; exit 2 ;;
esac

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Loom production environment not found: $ENV_FILE" >&2
  exit 1
fi

LOCAL_DOMAIN="$(sudo awk -F= '$1=="LOOM_PUBLIC_DOMAIN" {print $2; exit}' "$ENV_FILE")"
if [[ "$LOCAL_DOMAIN" == "$PEER_DOMAIN" ]]; then
  echo "Peer domain cannot be the local Node domain." >&2
  exit 2
fi

case "$LOCAL_DOMAIN:$PEER_DOMAIN" in
  node.example.test:peer.example.test|peer.example.test:node.example.test) ;;
  *)
    echo "This acceptance script is restricted to the two configured test Nodes." >&2
    exit 2
    ;;
esac

FEDERATION_MODE="$(sudo awk -F= '$1=="LOOM_FEDERATION_MODE" {print $2; exit}' "$ENV_FILE")"
if [[ "$FEDERATION_MODE" != "trusted" ]]; then
  echo "Local Node must use LOOM_FEDERATION_MODE=trusted before pairing." >&2
  exit 1
fi

ADMIN_TOKEN="$(sudo awk -F= '$1=="LOOM_ADMIN_TOKEN" {sub(/^[^=]*=/,""); print; exit}' "$ENV_FILE")"
if [[ -z "$ADMIN_TOKEN" ]]; then
  echo "LOOM_ADMIN_TOKEN is missing." >&2
  exit 1
fi

COMPOSE=(sudo docker compose --env-file "$ENV_FILE" -f "$INSTALL_DIR/deploy/docker-compose.production.yml")

curl -fsS --max-time 10 "https://$PEER_DOMAIN/readyz" >/dev/null
PEER_INFO="$(curl -fsS --max-time 10 "https://$PEER_DOMAIN/.well-known/loom/server")"
printf '%s' "$PEER_INFO" | "${COMPOSE[@]}" exec -T loom-node node -e '
const fs=require("fs");
const x=JSON.parse(fs.readFileSync(0,"utf8"));
if(!x.nodeId || !x.publicKey || !x.signature || !x.endpoint) process.exit(2);
process.stdout.write(`Peer public discovery OK: ${x.nodeId}\n`);
'

DISCOVERED="$(curl -fsS --max-time 20 \
  -X POST \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H 'Content-Type: application/json' \
  --data "{\"domain\":\"$PEER_DOMAIN\"}" \
  http://127.0.0.1:7483/admin/v1/federation/nodes)"

NODE_ID="$(printf '%s' "$DISCOVERED" | "${COMPOSE[@]}" exec -T loom-node node -e '
const fs=require("fs");
const x=JSON.parse(fs.readFileSync(0,"utf8"));
if(!x.nodeId) process.exit(2);
process.stdout.write(x.nodeId);
')"

curl -fsS --max-time 20 \
  -X POST \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  "http://127.0.0.1:7483/admin/v1/federation/nodes/$NODE_ID/trust"
echo

curl -fsS --max-time 20 \
  -X POST \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  "http://127.0.0.1:7483/admin/v1/federation/nodes/$NODE_ID/probe"
echo

echo "Trusted federation peer configured."
echo "Local: $LOCAL_DOMAIN"
echo "Peer:  $PEER_DOMAIN"
echo "Node:  $NODE_ID"
