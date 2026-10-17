#!/usr/bin/env bash
set -euo pipefail
umask 077

# Updated only after the referenced source has passed the Node installer checks.
# This first-party bootstrap is the trust entry point; its pins verify all later code.
LOOM_INSTALL_REVISION='fc49bdfc25e4eac66f25faf4df06240cb82ff203'
LOOM_INSTALL_ARCHIVE_SHA256='dfccfc7dba29b9f9413d08e586c79a1d2f2b910d624df2ef553c96f08415baae'
LOOM_INSTALL_BOOTSTRAP_SHA256='30a8aedb246bb00da4790cc5828290330f89bb3bcd7c9f7b27c8a91c5c2e1ed4'

if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  cat <<'HELP'
Loom Home Node

Run install.sh on a Linux server. Select download sources, type your domain,
then use Up/Down and Enter for HTTPS, registration, federation and calling options. Docker, storage, HTTPS and the
terminal manager are configured automatically. Use --plan for a read-only preview.

Requires systemd and x64/arm64. Public HTTPS needs a domain pointing directly to
this server and public TCP 80/443; local HTTPS supports a LAN hostname or IPv4.
Call media needs additional ports shown by setup. A sudo-capable user
or root is required. Existing data and identity are preserved.

  bash install.sh
  bash install.sh --plan
  bash install.sh --downloads liara
  bash install.sh --downloads liara --go-mirror runflare
  bash install.sh --downloads arvan
  bash install.sh --tls local --domain 192.0.2.24
  bash install.sh --diagnose
  bash install.sh --yes --domain chat.example.org --turn off --group-calls off
HELP
  exit 0
fi
[[ "$(uname -s)" == Linux ]] || { echo 'Home Node installation requires Linux.' >&2; exit 2; }
case "$(uname -m)" in x86_64|aarch64|arm64) ;; *) echo 'Use an x64 or arm64 Linux server.' >&2; exit 2 ;; esac
[[ "$LOOM_INSTALL_REVISION" =~ ^[a-f0-9]{40}$ && "$LOOM_INSTALL_ARCHIVE_SHA256" =~ ^[a-f0-9]{64}$ && "$LOOM_INSTALL_BOOTSTRAP_SHA256" =~ ^[a-f0-9]{64}$ ]] || {
  echo 'This checkout has not yet selected a verified installer revision.' >&2; exit 2;
}
preview=0
for arg in "$@"; do [[ "$arg" != --plan && "$arg" != --diagnose ]] || preview=1; done
if [[ $preview -eq 0 && ! -d /run/systemd/system ]]; then
  echo 'Use a Linux host booted with systemd, not an unprivileged container.' >&2; exit 2
fi
root=()
if [[ $EUID -ne 0 ]]; then
  command -v sudo >/dev/null || { echo 'Run as root, or install/configure sudo first.' >&2; exit 2; }
  root=(sudo)
fi
if ! command -v git >/dev/null || ! command -v curl >/dev/null || ! command -v openssl >/dev/null || ! command -v ss >/dev/null; then
  [[ $preview -eq 0 ]] || { echo 'Preview needs Git, curl, OpenSSL and iproute/ss installed.' >&2; exit 2; }
  . /etc/os-release
  case "${ID:-}" in
    ubuntu|debian)
      "${root[@]}" apt-get update
      "${root[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl git openssl iproute2 ;;
    fedora|centos|rhel|rocky|almalinux) "${root[@]}" dnf -y install ca-certificates curl git openssl iproute ;;
    arch|manjaro) "${root[@]}" pacman -Syu --needed --noconfirm ca-certificates curl git openssl iproute2 ;;
    opensuse-leap|opensuse-tumbleweed|sles) "${root[@]}" zypper --non-interactive install ca-certificates curl git openssl iproute2 ;;
    *) echo 'Install Git, curl, OpenSSL and iproute/ss for this distribution, then retry.' >&2; exit 2 ;;
  esac
fi
stage="$(mktemp -d)"
trap 'rm -rf -- "$stage"' EXIT
curl --proto '=https' --tlsv1.2 -fsSL --retry 3 \
  "https://raw.githubusercontent.com/0800x/Loom/$LOOM_INSTALL_REVISION/scripts/install-loom-node.sh" -o "$stage/bootstrap.sh"
printf '%s  %s\n' "$LOOM_INSTALL_BOOTSTRAP_SHA256" "$stage/bootstrap.sh" | sha256sum -c - >/dev/null
printf '\nLoom Home Node · downloading verified source %s\n' "${LOOM_INSTALL_REVISION:0:12}"
# Preview never elevates or provisions. It still verifies the pinned source.
entry=(--wizard)
if [[ $preview -eq 1 ]]; then entry=(--preview-wizard); fi
for arg in "$@"; do
  if [[ "$arg" == --diagnose ]]; then entry=(); break; fi
done
env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME="${HOME:-/tmp}" TERM="${TERM:-xterm}" \
  LOOM_REF="$LOOM_INSTALL_REVISION" LOOM_SOURCE_SHA256="$LOOM_INSTALL_ARCHIVE_SHA256" \
  /bin/bash --noprofile --norc "$stage/bootstrap.sh" "${entry[@]}" "$@"
