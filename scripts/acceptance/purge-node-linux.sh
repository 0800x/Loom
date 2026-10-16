#!/usr/bin/env bash
set -euo pipefail
domain="${1:-}"; shift || exit 2
[[ "$domain" =~ ^[a-z0-9][a-z0-9.-]+[a-z0-9]$ && "$domain" != *..* ]] || exit 2
confirmed=0; args=(--purge-data --yes)
for option in "$@"; do
  case "$option" in
    --yes-delete-loom-data) confirmed=1 ;;
    --purge-backups|--purge-tls) args+=("$option") ;;
    *) exit 2 ;;
  esac
done
[[ $confirmed -eq 1 ]] || exit 2
exec /bin/bash --noprofile --norc /opt/loom-node/scripts/linux/uninstall-production.sh "${args[@]}"
