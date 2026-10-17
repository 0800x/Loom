#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v flutter >/dev/null 2>&1; then
  echo "[loom-bootstrap] required tool not found: flutter" >&2
  exit 127
fi

CLEAN=0
if [[ "${1:-}" == "--clean" ]]; then
  CLEAN=1
fi

mapfile -t PUBSPECS < <(
  find packages apps -type f -name pubspec.yaml \
    ! -path '*/build/*' \
    ! -path '*/.dart_tool/*' \
    ! -path '*/node_modules/*' \
    2>/dev/null | sort -u
)

if [[ ${#PUBSPECS[@]} -eq 0 ]]; then
  echo "[loom-bootstrap] no Dart/Flutter pubspec.yaml files found" >&2
  exit 1
fi

echo "[loom-bootstrap] resolving ${#PUBSPECS[@]} Dart/Flutter packages"

for pubspec in "${PUBSPECS[@]}"; do
  package_dir="$(dirname "$pubspec")"
  echo
  echo "=== $package_dir ==="
  if [[ "$CLEAN" == "1" ]]; then
    rm -rf "$package_dir/.dart_tool"
  fi
  (cd "$package_dir" && flutter pub get)
done

echo
echo "[loom-bootstrap] package graph resolved for the whole monorepo"
echo "[loom-bootstrap] restart the Dart Analysis Server / reload the IDE if stale diagnostics remain"
