#!/usr/bin/env bash
set -euo pipefail

LOOM_NODE_HOME="${LOOM_NODE_HOME:-/opt/loom-node}"
[[ "$LOOM_NODE_HOME" == /opt/loom-node ]] || { echo "Unapproved Node home" >&2; exit 2; }

usage() {
  cat <<'USAGE'
Loom command-line interface

Usage:
  loom                  Open the Loom Node Manager
  loom manager [args]   Open the Node Manager explicitly
  loom doctor           Diagnose startup without modifying services
  loom setup [options]  Open the guided Node setup wizard
  loom stop             Stop the Home Node without removing data or volumes
  loom start            Start the Home Node again
  loom uninstall [...]  Uninstall Loom Node
  loom help             Show this help

Examples:
  loom
  loom stop
  loom start
  loom setup
  loom uninstall
  loom uninstall --purge-data
  loom uninstall --purge-all --yes

Compatibility:
  loom-node is installed as an alias to loom.

Source checkout:
  Production setup requires an integrity-verified release. Run the pinned
  scripts/install-loom-node.sh bootstrap with LOOM_REF and LOOM_SOURCE_SHA256.
USAGE
}

command_name="${1:-manager}"
case "$command_name" in
  help|-h|--help)
    usage
    exit 0
    ;;
  manager|tui)
    [[ $# -gt 0 ]] && shift || true
    exec "$LOOM_NODE_HOME/scripts/linux/manager.sh" "$@"
    ;;
  doctor|diagnose)
    [[ $# -gt 0 ]] && shift || true
    if [[ $EUID -ne 0 ]]; then
      exec /usr/bin/sudo /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root /bin/bash /opt/loom-node/scripts/linux/diagnose-node.sh "$@"
    fi
    exec /bin/bash /opt/loom-node/scripts/linux/diagnose-node.sh "$@"
    ;;
  start|stop)
    [[ $# -eq 1 ]] || { usage; exit 2; }
    if [[ $EUID -ne 0 ]]; then
      exec /usr/bin/sudo /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root TERM="${TERM:-xterm}" /bin/bash --noprofile --norc /opt/loom-node/scripts/linux/loom-cli.sh "$command_name"
    fi
    helper="$LOOM_NODE_HOME/scripts/linux/install-safety.sh"
    [[ -f "$helper" && ! -L "$helper" && "$(stat -c %u -- "$helper")" == 0 ]] || { echo 'Unsafe installation safety helper.' >&2; exit 1; }
    helper_mode="$(stat -c %a -- "$helper")"
    (( (8#$helper_mode & 0022) == 0 )) || { echo 'Installation safety helper is writable by others.' >&2; exit 1; }
    source "$helper"
    loom_require_install_owner "$LOOM_NODE_HOME" || { echo 'Loom installation ownership check failed.' >&2; exit 1; }
    deploy_dir="$LOOM_NODE_HOME/deploy"
    env_file="$deploy_dir/.env"
    compose_file="$deploy_dir/docker-compose.production.yml"
    loom_require_root_owned "$deploy_dir" && loom_require_root_owned "$env_file" && loom_require_root_owned "$compose_file" || { echo 'Loom configuration is missing or unsafe.' >&2; exit 1; }
    compose=(docker compose --project-directory "$deploy_dir" --env-file "$env_file" -f "$compose_file")
    for overlay in storage-legacy turn group-calls; do
      overlay_file="$deploy_dir/docker-compose.$overlay.yml"
      if [[ -e "$overlay_file" ]]; then
        loom_require_root_owned "$overlay_file" || { echo "Unsafe Compose overlay: $overlay_file" >&2; exit 1; }
        compose+=(-f "$overlay_file")
      fi
    done
    proxy_mode="$(awk -F= '$1 == "LOOM_PROXY_MODE" { sub(/^[^=]*=/, ""); print; exit }' "$env_file")"
    if [[ "$proxy_mode" == caddy ]]; then compose+=(--profile caddy); fi
    command -v docker >/dev/null 2>&1 || { echo 'Docker is not installed.' >&2; exit 1; }
    docker info >/dev/null
    docker compose version >/dev/null
    if [[ "$command_name" == stop ]]; then
      printf 'Stopping Loom services. Persistent volumes and configuration will be kept.\\n'
      "${compose[@]}" stop
      printf 'Loom services stopped. Run "loom start" to bring them back.\\n'
    else
      printf 'Starting Loom services...\\n'
      "${compose[@]}" up -d --wait --wait-timeout 180
      printf 'Loom services are running.\\n'
    fi
    ;;
  setup|configure)
    [[ $# -gt 0 ]] && shift || true
    if [[ $EUID -ne 0 ]]; then
      exec /usr/bin/sudo /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root TERM="${TERM:-xterm}" /bin/bash --noprofile --norc /opt/loom-node/scripts/linux/loom-cli.sh setup "$@"
    fi
    source "$LOOM_NODE_HOME/scripts/linux/install-safety.sh"
    loom_require_install_owner "$LOOM_NODE_HOME"
    for file in .loom-verified-source .loom-source-sha256 scripts/linux/verified-bootstrap.sh; do
      loom_require_root_owned "$LOOM_NODE_HOME/$file" || { echo 'Installation pin is missing or unsafe. Rerun install.sh.' >&2; exit 1; }
    done
    export LOOM_REF="$(cat "$LOOM_NODE_HOME/.loom-verified-source")"
    export LOOM_SOURCE_SHA256="$(cat "$LOOM_NODE_HOME/.loom-source-sha256")"
    exec /bin/bash "$LOOM_NODE_HOME/scripts/linux/verified-bootstrap.sh" --wizard "$@"
    ;;
  uninstall|remove)
    shift
    exec "$LOOM_NODE_HOME/scripts/linux/uninstall-production.sh" "$@"
    ;;
  *)
    # Backward-compatible passthrough for existing Node Manager arguments.
    exec "$LOOM_NODE_HOME/scripts/linux/manager.sh" "$@"
    ;;
esac

