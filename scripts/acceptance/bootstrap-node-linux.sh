#!/usr/bin/env bash
set -euo pipefail
domain="${1:-}"
[[ "$domain" =~ ^[a-z0-9][a-z0-9.-]+[a-z0-9]$ && "$domain" != *..* ]] || { echo 'Valid domain required' >&2; exit 2; }
shift
# HTTPS plus independently verified immutable revision/digest; no SSH TOFU.
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec /bin/bash --noprofile --norc "$script_dir/../install-loom-node.sh" --domain "$domain" "$@"
