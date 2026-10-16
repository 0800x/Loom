#!/usr/bin/env bash
set -euo pipefail

BRANCH="codex/federation-routing-tui-v2"
TARGET="${1:-auto}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
APP_DIR="$REPO_ROOT/apps/loom"
ARTIFACT_DIR="$REPO_ROOT/artifacts/acceptance"

cd "$REPO_ROOT"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Refusing to build from a dirty worktree. Commit/stash local changes first." >&2
  exit 1
fi

git fetch origin "$BRANCH"
git switch "$BRANCH"
git pull --ff-only origin "$BRANCH"

if ! grep -Fq "'/messenger': (_) => const LoomLiveMessengerScreen()" "$APP_DIR/lib/app/loom_app.dart"; then
  echo "This branch is not acceptance-ready yet: /messenger is not wired to LoomLiveMessengerScreen." >&2
  echo "Do not test federation/E2EE with this build yet." >&2
  exit 2
fi

if ! command -v flutter >/dev/null 2>&1; then
  echo "Flutter is not installed or not in PATH. CI uses Flutter 3.47.0." >&2
  exit 1
fi

flutter --version
mkdir -p "$ARTIFACT_DIR"

pushd "$APP_DIR" >/dev/null
flutter pub get
flutter analyze --fatal-infos
flutter test

if [[ "$TARGET" == "auto" ]]; then
  case "$(uname -s)" in
    Darwin) TARGET="macos" ;;
    Linux) TARGET="linux" ;;
    *) echo "Auto target is unsupported on this OS; pass android explicitly." >&2; exit 2 ;;
  esac
fi

SHA="$(git -C "$REPO_ROOT" rev-parse --short=12 HEAD)"
case "$TARGET" in
  android)
    flutter build apk --release
    cp build/app/outputs/flutter-apk/app-release.apk "$ARTIFACT_DIR/loom-android-$SHA.apk"
    ;;
  linux)
    flutter build linux --release
    tar -C build/linux/x64/release -czf "$ARTIFACT_DIR/loom-linux-x64-$SHA.tgz" bundle
    ;;
  macos)
    flutter build macos --release
    APP_PATH="$(find build/macos/Build/Products/Release -maxdepth 1 -name '*.app' -print -quit)"
    test -n "$APP_PATH"
    ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ARTIFACT_DIR/loom-macos-$SHA.zip"
    ;;
  *)
    echo "Usage: $0 [auto|android|linux|macos]" >&2
    exit 2
    ;;
esac
popd >/dev/null

echo
echo "Acceptance client built from commit $SHA"
echo "Artifact directory: $ARTIFACT_DIR"
