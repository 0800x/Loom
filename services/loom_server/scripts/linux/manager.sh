#!/usr/bin/env bash
set -euo pipefail

LOOM_NODE_HOME="${LOOM_NODE_HOME:-/opt/loom-node}"
[[ "$LOOM_NODE_HOME" == /opt/loom-node ]] || { echo 'Unapproved Node home' >&2; exit 2; }
MANAGER="$LOOM_NODE_HOME/bin/loom-node-manager"

# Do not synthesize LOOM_AUTO_UPDATE here. The manager resolves an explicit
# process environment override first, then deploy/.env, and finally applies its
# branch-aware default. Setting a wrapper default would mask an operator's
# LOOM_AUTO_UPDATE=false value from deploy/.env.

if [[ ! -x "$MANAGER" ]]; then
  echo "Loom Node Manager binary was not found: $MANAGER" >&2
  echo "Use a packaged Linux Node bundle or set LOOM_NODE_HOME to the installation directory." >&2
  exit 1
fi

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    exec /usr/bin/sudo /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root TERM="${TERM:-xterm}" "$MANAGER" --home /opt/loom-node "$@"
  fi
  echo "Loom Node Manager needs root privileges to manage the Docker stack and protected configuration." >&2
  exit 1
fi

exec /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root TERM="${TERM:-xterm}" "$MANAGER" --home /opt/loom-node "$@"

