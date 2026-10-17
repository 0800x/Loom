#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${LOOM_NODE_HOME-/opt/loom-node}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/install-safety.sh"
source "$SCRIPT_DIR/install-state.sh"
loom_require_install_path "$INSTALL_DIR" || { echo 'Refusing unsafe installation deletion' >&2; exit 2; }
ENV_FILE="$INSTALL_DIR/deploy/.env"
COMPOSE_FILE="$INSTALL_DIR/deploy/docker-compose.production.yml"
PURGE_DATA=0
PURGE_BACKUPS=0
PURGE_TLS=0
YES=0
DOMAIN=""

usage() {
  cat <<'USAGE'
Loom Node uninstaller

Usage:
  loom uninstall [options]

Options:
  --purge-data      Delete Loom databases, attachments, Node identity and Docker volumes.
  --purge-backups   Delete /opt/loom-backups.
  --purge-tls       Delete the Let's Encrypt certificate for this Node domain when Certbot owns it.
  --purge-all       Equivalent to --purge-data --purge-backups --purge-tls.
  --yes             Skip the interactive destructive confirmation.
  -h, --help        Show this help.

Without --purge-data, persistent Docker volumes are preserved for a future reinstall.
Docker, Nginx and Certbot packages are never uninstalled because they may be shared
with unrelated services.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --purge-data) PURGE_DATA=1; shift ;;
    --purge-backups) PURGE_BACKUPS=1; shift ;;
    --purge-tls) PURGE_TLS=1; shift ;;
    --purge-all) PURGE_DATA=1; PURGE_BACKUPS=1; PURGE_TLS=1; shift ;;
    --yes) YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  if ! command -v sudo >/dev/null 2>&1; then
    echo "Uninstall requires root privileges and sudo is unavailable." >&2
    exit 1
  fi
  args=()
  [[ $PURGE_DATA -eq 1 ]] && args+=(--purge-data)
  [[ $PURGE_BACKUPS -eq 1 ]] && args+=(--purge-backups)
  [[ $PURGE_TLS -eq 1 ]] && args+=(--purge-tls)
  [[ $YES -eq 1 ]] && args+=(--yes)
  exec /usr/bin/sudo /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root /bin/bash --noprofile --norc /opt/loom-node/scripts/linux/uninstall-production.sh "${args[@]}"
fi

loom_require_install_owner "$INSTALL_DIR" || { echo 'Refusing unowned installation deletion' >&2; exit 2; }

read_env_value() {
  local path="$1" key="$2"
  [[ -f "$path" ]] || return 0
  awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$path"
}

DOMAIN="$(read_env_value "$ENV_FILE" LOOM_PUBLIC_DOMAIN)"
[[ -n "$DOMAIN" ]] || DOMAIN="unknown"
[[ "$DOMAIN" == unknown || ( "$DOMAIN" =~ ^[a-z0-9][a-z0-9.-]+[a-z0-9]$ && "$DOMAIN" != *..* ) ]] || exit 2

printf '\nLoom Node uninstall\n'
printf '  Home:    %s\n' "$INSTALL_DIR"
printf '  Domain:  %s\n' "$DOMAIN"
printf '  Data:    %s\n' "$([[ $PURGE_DATA -eq 1 ]] && echo DELETE || echo PRESERVE)"
printf '  Backups: %s\n' "$([[ $PURGE_BACKUPS -eq 1 ]] && echo DELETE || echo PRESERVE)"
printf '  TLS:     %s\n\n' "$([[ $PURGE_TLS -eq 1 ]] && echo DELETE || echo PRESERVE)"

if [[ $YES -ne 1 ]]; then
  expected="DELETE-LOOM"
  printf 'Type %s to continue: ' "$expected" >/dev/tty
  IFS= read -r answer </dev/tty || exit 1
  if [[ "$answer" != "$expected" ]]; then
    echo "Cancelled."
    exit 1
  fi
fi

if [[ $PURGE_DATA -eq 0 ]]; then
  [[ $PURGE_BACKUPS -eq 0 ]] || { echo 'Keeping data requires keeping its private reinstall configuration. Do not combine --purge-backups with retained data.' >&2; exit 2; }
  loom_backup_retained_configuration "$INSTALL_DIR"
fi

if command -v docker >/dev/null 2>&1; then
  echo "Removing Loom containers..."

  # Exact installation ownership label; never regex-match names or image tags.
  # Images may be shared and are deliberately retained.
  mapfile -t containers < <(docker ps -aq --filter 'label=org.loom.installation=/opt/loom-node')
  ((${#containers[@]} == 0)) || docker rm -f "${containers[@]}"
  if [[ $PURGE_DATA -eq 1 ]]; then
    mapfile -t volumes < <(docker volume ls -q --filter 'label=org.loom.installation=/opt/loom-node')
    ((${#volumes[@]} == 0)) || docker volume rm "${volumes[@]}"
  fi
  mapfile -t networks < <(docker network ls -q --filter 'label=org.loom.installation=/opt/loom-node')
  ((${#networks[@]} == 0)) || docker network rm "${networks[@]}"

fi

echo "Removing Loom-managed reverse-proxy configuration..."
nginx_changed=0
for site in \
  /etc/nginx/sites-available/loom-node.conf \
  /etc/nginx/conf.d/loom-node.conf; do
  if [[ -f "$site" ]] && grep -Fq 'Managed by Loom Node installer.' "$site"; then
    rm -f "$site"
    nginx_changed=1
  fi
done
if [[ -L /etc/nginx/sites-enabled/loom-node.conf ]]; then
  rm -f /etc/nginx/sites-enabled/loom-node.conf
  nginx_changed=1
fi
rm -f /etc/letsencrypt/renewal-hooks/deploy/loom-nginx-reload.sh

if [[ $nginx_changed -eq 1 ]] && command -v nginx >/dev/null 2>&1; then
  if nginx -t; then
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nginx; then
      systemctl reload nginx || true
    else
      nginx -s reload 2>/dev/null || true
    fi
  else
    echo "WARNING: nginx -t failed after removing the Loom site; Nginx was not reloaded." >&2
  fi
fi

if [[ $PURGE_TLS -eq 1 && "$DOMAIN" != "unknown" ]]; then
  echo "Deleting TLS certificate for $DOMAIN..."
  if command -v certbot >/dev/null 2>&1 && [[ -f "/etc/letsencrypt/renewal/$DOMAIN.conf" ]]; then
    certbot delete --non-interactive --cert-name "$DOMAIN" || true
  fi
fi

if [[ $PURGE_BACKUPS -eq 1 ]]; then
  echo "Deleting /opt/loom-backups..."
  [[ ! -L /opt/loom-backups ]] && loom_require_root_owned /opt/loom-backups &&
    loom_require_root_owned /opt/loom-backups/.loom-backup-owner &&
    [[ "$(cat /opt/loom-backups/.loom-backup-owner)" == 'loom-backup-v1' ]] || { echo 'Unowned backups; refusing purge' >&2; exit 1; }
  rm -rf -- /opt/loom-backups
fi

echo "Removing installed Loom Node files and CLI launchers..."
rm -f /usr/local/bin/loom-node /usr/local/bin/loom
loom_require_install_owner "$INSTALL_DIR" || exit 2
rm -rf --one-file-system -- "$INSTALL_DIR"

if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed >/dev/null 2>&1 || true
fi

printf '\nLoom Node uninstalled.\n'
if [[ $PURGE_DATA -eq 1 ]]; then
  echo "Labelled Loom persistent resources were deleted. Legacy unlabelled volumes were retained and require explicit operator review."
else
  echo "Persistent Loom Docker volumes and private reinstall configuration were preserved."
fi

