#!/usr/bin/env bash
set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root
unset BASH_ENV ENV CDPATH GLOBIGNORE
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/install-safety.sh"
source "$SCRIPT_DIR/install-state.sh"
[[ $EUID -eq 0 ]] || { echo 'Run loom doctor with sudo.' >&2; exit 2; }
loom_require_install_owner /opt/loom-node || { echo 'The installation ownership marker is missing or unsafe.' >&2; exit 2; }
home=/opt/loom-node
env_file="$home/deploy/.env"
[[ -f "$env_file" && ! -L "$env_file" ]] || { echo 'The original deploy/.env is missing. Restore it before installing again.' >&2; exit 1; }
loom_require_root_owned "$env_file" || exit 1
compose=(docker compose --env-file "$env_file" -f "$home/deploy/docker-compose.production.yml")
for overlay in storage-legacy turn group-calls; do
  [[ ! -f "$home/deploy/docker-compose.$overlay.yml" ]] || compose+=(-f "$home/deploy/docker-compose.$overlay.yml")
done
printf '\nLoom Node diagnostics (read-only)\n'
for service in postgres minio loom-node; do
  id="$("${compose[@]}" ps -aq "$service")"
  if [[ -z "$id" ]]; then printf '%-12s missing\n' "$service"; continue; fi
  state="$(docker inspect --format '{{.State.Status}}; exit={{.State.ExitCode}}{{if .State.Health}}; health={{.State.Health.Status}}{{end}}' "$id")"
  printf '%-12s %s\n' "$service" "$state"
done
logs="$("${compose[@]}" logs --no-color --tail 100 loom-node 2>/dev/null || true)"
loom_classify_startup_failure "$logs"
unset logs
printf '\nSource approvals: '
if [[ -f /etc/loom/approved-releases ]]; then echo available; else echo 'missing; rerun the trusted installer to configure verified updates'; fi
printf 'Diagnostics did not change services, credentials, volumes or identity.\n'
