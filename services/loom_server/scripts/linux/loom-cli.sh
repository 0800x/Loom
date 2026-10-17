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
  loom uninstall [...]  Uninstall Loom Node
  loom help             Show this help

Examples:
  loom
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

