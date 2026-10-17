#!/usr/bin/env bash
# Explicit per-install download policy. Never edit Docker daemon settings or
# disable TLS, distribution signatures or Go checksum verification.
loom_download_profile() {
  LOOM_DOWNLOAD_PROFILE="${1:-official}"
  LOOM_DOCKER_PREFIX=''
  LOOM_GO_PROXY='https://proxy.golang.org,direct'
  LOOM_NPM_REGISTRY='https://registry.npmjs.org/'
  LOOM_ALPINE_MIRROR=''
  case "$LOOM_DOWNLOAD_PROFILE" in
    official) ;;
    liara|arvan)
      LOOM_GO_PROXY='https://package-mirror.liara.ir/repository/go/'
      LOOM_NPM_REGISTRY='https://package-mirror.liara.ir/repository/npm/'
      LOOM_ALPINE_MIRROR='https://linux-mirror.liara.ir/repository/alpine'
      if [[ "$LOOM_DOWNLOAD_PROFILE" == liara ]]; then
        LOOM_DOCKER_PREFIX='docker-mirror.liara.ir/'
      else
        LOOM_DOCKER_PREFIX='docker.arvancloud.ir/'
        LOOM_ALPINE_MIRROR='https://mirror.arvancloud.ir/alpine'
      fi ;;
    *) echo 'Download source must be official, liara or arvan.' >&2; return 2 ;;
  esac
  export LOOM_DOWNLOAD_PROFILE LOOM_DOCKER_PREFIX LOOM_GO_PROXY LOOM_NPM_REGISTRY LOOM_ALPINE_MIRROR
}

# Override Go independently of Docker/npm/APT. Never fall back after errors.
loom_go_mirror() {
  LOOM_GO_MIRROR="${1:-profile}"
  case "$LOOM_GO_MIRROR" in
    profile) ;;
    official) LOOM_GO_PROXY='https://proxy.golang.org' ;;
    liara) LOOM_GO_PROXY='https://package-mirror.liara.ir/repository/go/' ;;
    runflare) LOOM_GO_PROXY='https://mirror-go.runflare.com' ;;
    goproxy-cn) LOOM_GO_PROXY='https://goproxy.cn' ;;
    *) echo 'Go mirror must be profile, official, liara, runflare or goproxy-cn.' >&2; return 2 ;;
  esac
  export LOOM_GO_MIRROR LOOM_GO_PROXY
}

# A temporary APT source file applies only to these package commands. Vendor
# keyrings and Release expiry/signature checks remain authoritative. Existing
# source files (including third-party repositories) are never rewritten.
loom_mirror_apt() (
  set -e
  local distro="${ID:-}" codename="${VERSION_CODENAME:-}" arch tmp base security key components
  [[ "$distro" == ubuntu || "$distro" == debian ]] || return 2
  [[ "$codename" =~ ^[a-z][a-z0-9-]+$ ]] || { echo 'Cannot determine distribution codename.' >&2; return 2; }
  arch="$(dpkg --print-architecture)"
  if [[ "$distro" == ubuntu ]]; then
    # The documented Ubuntu mirror is the archive, not Ubuntu Ports.
    [[ "$arch" == amd64 ]] || { echo 'Ubuntu mirror supports this installer on amd64 only; configure an ARM64 package mirror separately.' >&2; return 2; }
    base='http://linux-mirror.liara.ir/repository/ubuntu'
    security='http://linux-mirror.liara.ir/repository/ubuntu-security'
    key=/usr/share/keyrings/ubuntu-archive-keyring.gpg
    components='main restricted universe multiverse'
    if [[ "${LOOM_DOWNLOAD_PROFILE:-}" == arvan ]]; then base='http://mirror.arvancloud.ir/ubuntu'; security="$base"; fi
  else
    base='https://linux-mirror.liara.ir/repository/debian'
    security='https://linux-mirror.liara.ir/repository/debian-security'
    key=/usr/share/keyrings/debian-archive-keyring.gpg
    components='main'
  fi
  [[ -f "$key" ]] || { echo 'Distribution archive keyring is missing.' >&2; return 2; }
  tmp="$(mktemp -d /var/tmp/loom-apt.XXXXXXXX)"
  trap 'rm -rf -- "$tmp"' EXIT
  chmod 0755 "$tmp"
  printf 'deb [signed-by=%s] %s %s %s\ndeb [signed-by=%s] %s %s-updates %s\ndeb [signed-by=%s] %s %s-security %s\n' \
    "$key" "$base" "$codename" "$components" \
    "$key" "$base" "$codename" "$components" \
    "$key" "$security" "$codename" "$components" > "$tmp/sources.list"
  chmod 0644 "$tmp/sources.list"
  apt-get -o "Dir::Etc::sourcelist=$tmp/sources.list" -o Dir::Etc::sourceparts=- \
    -o Acquire::AllowInsecureRepositories=false update
  DEBIAN_FRONTEND=noninteractive apt-get -o "Dir::Etc::sourcelist=$tmp/sources.list" \
    -o Dir::Etc::sourceparts=- -o APT::Get::AllowUnauthenticated=false install -y "$@"
)
