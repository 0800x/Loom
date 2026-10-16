#!/usr/bin/env bash
set -euo pipefail

SKIP_DEPENDENCIES=0
SKIP_TUI=0
for arg in "$@"; do
  case "$arg" in
    --skip-dependency-install) SKIP_DEPENDENCIES=1 ;;
    --skip-tui) SKIP_TUI=1 ;;
    -h|--help)
      cat <<'EOF'
Validate Loom Node server and cross-platform TUI.

Usage:
  ./validate-node.sh [--skip-dependency-install] [--skip-tui]
EOF
      exit 0
      ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SERVER_ROOT/../.." && pwd)"
TUI_ROOT="$REPO_ROOT/tools/loom_node_manager"

require_command() {
  command -v "$1" >/dev/null 2>&1 || { echo "$2" >&2; exit 1; }
}

require_command node "Node.js 22.16+ is required to validate the Loom Node server."
require_command npm "npm is required to validate the Loom Node server."

node -e "const [major,minor]=process.versions.node.split('.').map(Number);if(major<22||(major===22&&minor<16)){console.error('Node.js 22.16+ required; found '+process.versions.node);process.exit(1)}"

cd "$SERVER_ROOT"
if [[ $SKIP_DEPENDENCIES -eq 0 ]]; then
  echo "== Install Node server dependencies =="
  npm install --ignore-scripts --no-audit --no-fund
fi

echo "== Node server tests =="
npm test

if [[ $SKIP_TUI -eq 0 ]]; then
  require_command go "Go 1.25+ is required to validate the Node Manager TUI. Use --skip-tui only for intentional server-only validation."
  cd "$TUI_ROOT"
  echo "== Download TUI Go modules =="
  go mod download
  echo "== TUI tests =="
  go test ./...
  echo "== TUI vet =="
  go vet ./...
  output="${TMPDIR:-/tmp}/loom-node-manager-validation"
  echo "== TUI Linux build =="
  go build -buildvcs=false -trimpath -o "$output" .
  rm -f "$output"
fi

echo "Loom Node validation passed."
