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
  setup|configure)
    [[ $# -gt 0 ]] && shift || true
    echo "Setup requires a verified release; use scripts/install-loom-node.sh with LOOM_REF and LOOM_SOURCE_SHA256." >&2
    exit 1
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

