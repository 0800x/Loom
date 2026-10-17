#!/usr/bin/env bash
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# Isolated package installation, not a host Docker replacement. The fixture uses
# Ubuntu's signed upstream archive; mirror URL selection has separate tests.
docker run --rm -v "$root:/loom:ro" ubuntu:24.04 bash -euo pipefail -s <<'FIXTURE'
source <(sed -n '/^install_docker_debian_like() {/,/^install_docker_rpm() {/p' /loom/services/loom_server/scripts/linux/install-production.sh | sed '$d')
LOOM_DOWNLOAD_PROFILE=liara
VERSION_CODENAME=noble
loom_packages(){ apt-get update -qq; DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"; }
systemctl(){ :; }
curl(){ echo 'Unexpected external Docker repository request' >&2; return 90; }
install_docker_debian_like ubuntu
version="$(docker compose version --short | sed 's/^v//')"
[[ "$(printf '%s\n' 2.24.4 "$version" | sort -V | head -n1)" == 2.24.4 ]]
docker buildx version
printf 'Signed Ubuntu Docker/Compose packages installed successfully; Compose %s\n' "$version"
FIXTURE
