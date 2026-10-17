#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[loom-v2] required tool not found: $1" >&2
    exit 127
  }
}

run() {
  echo
  echo "+ $*"
  "$@"
}

need flutter
need dart
need cargo
need node
need npm

# Resolve every nested Dart/Flutter package first. IDE analyzers treat nested
# packages as package roots and each one needs its own .dart_tool/package_config.
run bash scripts/bootstrap-dart-workspace.sh

DART_PACKAGES=(
  packages/loom_identity
  packages/loom_sessions
  packages/loom_protocol
  packages/loom_storage
  packages/loom_dtn
  packages/loom_messaging
  packages/loom_transport
  packages/loom_session_vodozemac_poc
)

for package in "${DART_PACKAGES[@]}"; do
  echo
  echo "=== $package ==="
  (cd "$package" && run dart format --output=none --set-exit-if-changed lib test)
  (cd "$package" && run dart analyze)
  (cd "$package" && run dart test)
done

echo
echo "=== Flutter app ==="
(
  cd apps/loom
  run dart format --output=none --set-exit-if-changed lib test
  run flutter analyze
  run flutter test
)

echo
echo "=== Rust session provider candidate ==="
(
  cd native/loom_vodozemac_poc
  run cargo fmt --all -- --check
  run cargo clippy --all-targets --all-features -- -D warnings
  run cargo test --all-targets
  run cargo build --release
)

if [[ "${LOOM_VALIDATE_SKIP_NODE:-0}" != "1" ]]; then
  echo
  echo "=== Delivery Service v2 ==="
  (
    cd services/loom_server
    run npm install --ignore-scripts
    run node --experimental-strip-types --test test/v2_delivery_*.test.ts
  )
fi

if [[ "${LOOM_VALIDATE_SKIP_ANDROID:-0}" != "1" ]]; then
  echo
  echo "=== Android native bearers / host ==="
  if [[ ! -x apps/loom/android/gradlew ]]; then
    echo "[loom-v2] Android Gradle wrapper is missing or not executable" >&2
    exit 127
  fi
  (cd apps/loom/android && run ./gradlew :app:assembleDebug)
fi

echo
echo "[loom-v2] local Architecture v2 validation completed successfully"
