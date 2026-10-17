#!/usr/bin/env bash
set -euo pipefail
[[ "${LOOM_NODE_HOME-/opt/loom-node}" == /opt/loom-node ]] || exit 2
if [[ $EUID -ne 0 ]]; then
  exec /usr/bin/sudo /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root /bin/bash --noprofile --norc /opt/loom-node/scripts/linux/install-cli.sh
fi
source /opt/loom-node/scripts/linux/install-safety.sh
loom_require_install_owner /opt/loom-node || { echo 'Unowned installation' >&2; exit 1; }
loom_require_root_owned /opt/loom-node/scripts/linux/loom-cli.sh || exit 1
[[ -x /opt/loom-node/bin/loom-node-manager ]] || exit 1
install -m 0755 /opt/loom-node/scripts/linux/loom-cli.sh /usr/local/bin/loom
ln -sfn /usr/local/bin/loom /usr/local/bin/loom-node
echo 'Installed CLI for the verified production bundle.'
