#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

python3 scripts/repository_audit.py
node scripts/chaos_node.mjs

command -v flutter >/dev/null || { echo "ERROR: flutter is not installed or not on PATH" >&2; exit 127; }
command -v dart >/dev/null || { echo "ERROR: dart is not installed or not on PATH" >&2; exit 127; }
command -v node >/dev/null || { echo "ERROR: node is not installed or not on PATH" >&2; exit 127; }
command -v npm >/dev/null || { echo "ERROR: npm is not installed or not on PATH" >&2; exit 127; }

flutter doctor -v

cd "$ROOT/services/loom_server"
npm install --ignore-scripts
npm test

for dir in packages/loom_models packages/loom_protocol packages/loom_federation packages/loom_storage packages/loom_transport; do
  echo "==> Validating $dir"
  cd "$ROOT/$dir"
  dart pub get
  dart format --output=none --set-exit-if-changed .
  dart analyze
  dart test
done

for dir in packages/loom_crypto_bridge packages/loom_design packages/loom_calls apps/loom apps/loom_node_ui; do
  echo "==> Validating $dir"
  cd "$ROOT/$dir"
  flutter pub get
  dart format --output=none --set-exit-if-changed .
  flutter analyze
  flutter test
done

cd "$ROOT"
for platform in android ios windows macos linux; do
  if [ ! -d "apps/loom/$platform" ]; then
    echo "NOTICE: apps/loom/$platform scaffold is absent. Generate it with Flutter before platform builds."
  fi
done
for platform in windows macos linux; do
  if [ ! -d "apps/loom_node_ui/$platform" ]; then
    echo "NOTICE: apps/loom_node_ui/$platform scaffold is absent. Generate it with Flutter before Node Manager builds."
  fi
done
