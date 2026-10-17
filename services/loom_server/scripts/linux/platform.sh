#!/usr/bin/env bash
# Package selection is kept separate so it can be exercised without changing a host.
loom_platform() {
  case "${ID:-}" in
    ubuntu|debian|fedora|centos|rhel|rocky|almalinux|arch|manjaro|opensuse-leap|opensuse-tumbleweed|sles) printf '%s\n' "$ID" ;;
    *) echo "Unsupported distribution: ${ID:-unknown}. Install Docker Engine, Compose, curl, Git and OpenSSL before retrying." >&2; return 1 ;;
  esac
}
loom_packages() {
  local distro; distro="$(loom_platform)" || return 1
  case "$distro" in
    ubuntu|debian)
      export DEBIAN_FRONTEND=noninteractive
      if [[ "${LOOM_DOWNLOAD_PROFILE:-official}" != official ]]; then
        loom_mirror_apt "$@"
      else
        apt-get update && apt-get install -y "$@"
      fi ;;
    fedora|centos|rhel|rocky|almalinux) dnf -y install "$@" ;;
    arch|manjaro) pacman -Syu --needed --noconfirm "$@" ;;
    opensuse-*|sles) zypper --non-interactive install "$@" ;;
  esac
}
loom_require_systemd() {
  [[ "$(uname -s)" == Linux && -d /run/systemd/system ]] || {
    echo 'Use a Linux host booted with systemd (not a container or WSL without systemd).' >&2; return 1;
  }
  case "$(uname -m)" in x86_64|aarch64|arm64) ;; *) echo 'Home Node requires Linux x64 or arm64.' >&2; return 1 ;; esac
}
