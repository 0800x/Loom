#!/usr/bin/env bash
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
target="${1:-host}"
manifest="$root/native/loom_mls/Cargo.toml"
command -v cargo >/dev/null || { echo 'Install Rust with rustup, then restart your terminal.' >&2; exit 1; }
case "$target" in
  host)
    cargo build --manifest-path "$manifest" --release --locked
    echo "Native MLS library: $root/native/loom_mls/target/release"
    ;;
  android)
    : "${ANDROID_NDK_HOME:?Set ANDROID_NDK_HOME to the installed Android NDK directory.}"
    cargo ndk --version >/dev/null || { echo 'Install the cross-build tool: cargo install cargo-ndk --locked' >&2; exit 1; }
    rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
    export RUSTFLAGS="${RUSTFLAGS:-} -C link-arg=-Wl,-z,max-page-size=16384 -C link-arg=-Wl,-z,common-page-size=16384"
    cd -- "$root/native/loom_mls"
    cargo ndk -t arm64-v8a -t armeabi-v7a -t x86_64 -P 24 \
      -o "$root/apps/loom/android/app/src/main/jniLibs" \
      build --manifest-path "$manifest" --release --locked
    ;;
  *) echo 'Usage: build-mls.sh [host|android]' >&2; exit 2 ;;
esac
