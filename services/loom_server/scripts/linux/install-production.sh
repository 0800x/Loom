#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="/opt/loom-node"
DOMAIN=""
OPERATOR_NAME="Loom Node"
JURISDICTION="Unspecified"
REGISTRATION="approval"
FEDERATION="disabled"
PROXY_MODE_REQUESTED="auto"
PROXY_MODE=""
CERTBOT_EMAIL=""
NO_START=0
NO_TUI=0
SKIP_DNS_CHECK=0
TLS_WAIT_SECONDS=90
UPDATE_BRANCH="${LOOM_UPDATE_BRANCH:-}"
UPDATE_REPOSITORY="${LOOM_UPDATE_REPOSITORY:-0800x/Loom}"
UPDATE_SOURCE_DIR="${LOOM_UPDATE_SOURCE_DIR:-}"
UPDATE_SOURCE_EXPLICIT=0
DOWNLOAD_PROFILE=""
GO_MIRROR=""
TLS_MODE=""

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  UI_RESET=$'\033[0m'
  UI_BOLD=$'\033[1m'
  UI_DIM=$'\033[2m'
  UI_PURPLE=$'\033[38;5;141m'
  UI_CYAN=$'\033[38;5;45m'
  UI_GREEN=$'\033[38;5;84m'
  UI_YELLOW=$'\033[38;5;220m'
  UI_RED=$'\033[38;5;203m'
  UI_MUTED=$'\033[38;5;245m'
else
  UI_RESET="" UI_BOLD="" UI_DIM="" UI_PURPLE="" UI_CYAN="" UI_GREEN="" UI_YELLOW="" UI_RED="" UI_MUTED=""
fi

ui_banner() {
  printf '\n%bLOOM%b  Home Node\n' "$UI_CYAN$UI_BOLD" "$UI_RESET"
  printf '%bInstall · configure · connect%b\n' "$UI_MUTED" "$UI_RESET"
}

ui_step() {
  local current="$1" total="$2" text="$3"
  printf '\n%b%s / %s%b  %b%s%b\n' "$UI_CYAN$UI_BOLD" "$current" "$total" "$UI_RESET" "$UI_BOLD" "$text" "$UI_RESET"
}

ui_ok() { printf '%b  ready%b  %s\n' "$UI_GREEN" "$UI_RESET" "$*"; }
ui_info() { printf '%b  info%b   %s\n' "$UI_MUTED" "$UI_RESET" "$*"; }
ui_warn() { printf '%b  note%b   %s\n' "$UI_YELLOW" "$UI_RESET" "$*" >&2; }
ui_fail() { printf '%b  error%b  %s\n' "$UI_RED" "$UI_RESET" "$*" >&2; }

usage() {
  cat <<'USAGE'
Loom Node production installer

Usage:
  ./install-production.sh [--domain chat.example.com] [options]

With no --domain on a first interactive install, the installer asks for it on
/dev/tty. It elevates with sudo when necessary.

Options:
  --tls public|local             Public CA or explicit local certificate
  --downloads official|liara|arvan Per-install dependency sources
  --go-mirror PROFILE             profile | official | liara | runflare | parspack | goproxy-cn
  --domain HOSTNAME               Public DNS hostname
  --operator-name NAME            Operator display name
  --jurisdiction TEXT             Network jurisdiction label
  --registration POLICY           open | approval | closed
  --federation MODE               disabled | trusted | open | local | hybrid
  --proxy MODE                    auto | caddy | nginx (default: auto)
  --certbot-email EMAIL           ACME account email for Nginx/Certbot mode
  --install-dir PATH              Installation directory (default: /opt/loom-node)
  --skip-dns-check                Do not compare the domain A record with public IPv4
  --tls-wait SECONDS              HTTPS verification window (default: 90)
  --no-start                      Install/configure without starting containers
  --no-tui                        Do not launch the TUI after installation
  --update-branch BRANCH          Persist the selected update channel
  --update-repository OWNER/REPO  GitHub update repository
  --update-source-dir PATH        Persistent checkout (empty for remote checks)
  -h, --help                      Show this help

Proxy auto mode preserves an existing Loom proxy choice. On a fresh install it
uses host Nginx when Nginx is already active (including servers where 80/443 are
occupied by Nginx); otherwise it uses the bundled Caddy reverse proxy.

Re-running the installer preserves deploy/.env secrets. Passing --domain on an
existing install updates only public endpoint configuration.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tls) TLS_MODE="${2:-}"; shift 2 ;;
    --go-mirror) GO_MIRROR="${2:-}"; shift 2 ;;
    --downloads) DOWNLOAD_PROFILE="${2:-}"; shift 2 ;;
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --operator-name) OPERATOR_NAME="${2:-}"; shift 2 ;;
    --jurisdiction) JURISDICTION="${2:-}"; shift 2 ;;
    --registration) REGISTRATION="${2:-}"; shift 2 ;;
    --federation) FEDERATION="${2:-}"; shift 2 ;;
    --proxy) PROXY_MODE_REQUESTED="${2:-}"; shift 2 ;;
    --certbot-email) CERTBOT_EMAIL="${2:-}"; shift 2 ;;
    --install-dir) INSTALL_DIR="${2:-}"; shift 2 ;;
    --skip-dns-check) SKIP_DNS_CHECK=1; shift ;;
    --tls-wait) TLS_WAIT_SECONDS="${2:-}"; shift 2 ;;
    --no-start) NO_START=1; shift ;;
    --no-tui) NO_TUI=1; shift ;;
    --update-branch) UPDATE_BRANCH="${2:-}"; shift 2 ;;
    --update-repository) UPDATE_REPOSITORY="${2:-}"; shift 2 ;;
    --update-source-dir) UPDATE_SOURCE_DIR="${2:-}"; UPDATE_SOURCE_EXPLICIT=1; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

case "$PROXY_MODE_REQUESTED" in auto|caddy|nginx) ;; *) echo "--proxy must be auto, caddy or nginx." >&2; exit 2 ;; esac
if ! [[ "$TLS_WAIT_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "--tls-wait must be a non-negative integer." >&2
  exit 2
fi
if [[ -n "$CERTBOT_EMAIL" ]] && ! [[ "$CERTBOT_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
  echo "Invalid --certbot-email value." >&2
  exit 2
fi

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  if ! command -v sudo >/dev/null 2>&1; then
    echo "This installer needs root privileges and sudo is unavailable." >&2
    exit 1
  fi
  args=(
    --operator-name "$OPERATOR_NAME"
    --jurisdiction "$JURISDICTION"
    --registration "$REGISTRATION"
    --federation "$FEDERATION"
    --proxy "$PROXY_MODE_REQUESTED"
    --install-dir "$INSTALL_DIR"
    --tls-wait "$TLS_WAIT_SECONDS"
    --update-branch "$UPDATE_BRANCH"
    --update-repository "$UPDATE_REPOSITORY"
  )
  [[ $UPDATE_SOURCE_EXPLICIT -eq 1 ]] && args+=(--update-source-dir "$UPDATE_SOURCE_DIR")
  [[ -n "$DOMAIN" ]] && args=(--domain "$DOMAIN" "${args[@]}")
  [[ -n "$CERTBOT_EMAIL" ]] && args+=(--certbot-email "$CERTBOT_EMAIL")
  [[ $SKIP_DNS_CHECK -eq 1 ]] && args+=(--skip-dns-check)
  [[ $NO_START -eq 1 ]] && args+=(--no-start)
  [[ $NO_TUI -eq 1 ]] && args+=(--no-tui)
  echo "Use scripts/install-loom-node.sh with an authenticated commit and SHA256; direct unverified elevation is disabled." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SOURCE_ROOT/../.." && pwd)"
MANAGER_SOURCE="$REPO_ROOT/tools/loom_node_manager"
# Only a root-private, integrity-verified release snapshot may execute here.
source "$SCRIPT_DIR/install-safety.sh"
source "$SCRIPT_DIR/platform.sh"
source "$SCRIPT_DIR/download-sources.sh"
source "$SCRIPT_DIR/local-tls.sh"
loom_require_install_path "$INSTALL_DIR" || exit 2
loom_require_root_owned "$REPO_ROOT" &&
  loom_require_root_owned "$REPO_ROOT/.loom-verified-source" || { echo 'Unverified production source; use the pinned bootstrap' >&2; exit 1; }
[[ -f "$REPO_ROOT/.loom-verified-source" ]] || exit 1
VERIFIED_COMMIT="$(cat "$REPO_ROOT/.loom-verified-source")"
[[ "$VERIFIED_COMMIT" =~ ^[a-f0-9]{40}$ ]] || exit 1
unset BASH_ENV ENV CDPATH GLOBIGNORE
export PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

# Reject rerunning the copied installer against its own bundle before any
# removal/copy occurs. An update needs a fresh checkout or downloaded bundle.
if [[ "$(realpath -m "$SOURCE_ROOT")" == "$(realpath -m "$INSTALL_DIR")" ]]; then
  ui_fail "This is the installed bundle. Run the installer from a fresh Loom checkout to update /opt/loom-node."
  exit 1
fi
source "$SCRIPT_DIR/update-metadata.sh"
source "$SCRIPT_DIR/install-state.sh"
EXISTING_ENV="$INSTALL_DIR/deploy/.env"
FIRST_INSTALL=1
[[ -f "$EXISTING_ENV" ]] && FIRST_INSTALL=0

read_env_value() {
  local path="$1" key="$2"
  [[ -f "$path" ]] || return 0
  awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$path"
}

prompt_domain() {
  if [[ -r /dev/tty ]]; then
    printf '%bPublic domain%b %b(example: chat.example.com)%b: ' "$UI_CYAN$UI_BOLD" "$UI_RESET" "$UI_MUTED" "$UI_RESET" >/dev/tty
    IFS= read -r DOMAIN </dev/tty
  else
    echo "A domain is required on first install. Pass --domain chat.example.com." >&2
    exit 1
  fi
}

normalize_domain() {
  DOMAIN="$(printf '%s' "$DOMAIN" | tr '[:upper:]' '[:lower:]' | xargs)"
  local kind
  kind="$(loom_tls_name_kind "$DOMAIN")" || exit 2
  if [[ "${TLS_MODE:-public}" != local && ( "$kind" != DNS || "$DOMAIN" != *.* ) ]]; then
    echo 'Public HTTPS requires a DNS hostname. Select --tls local for an IPv4 address or LAN hostname.' >&2
    exit 2
  fi
}

if [[ -z "$TLS_MODE" && -f "$EXISTING_ENV" ]]; then TLS_MODE="$(read_env_value "$EXISTING_ENV" LOOM_TLS_MODE)"; fi
TLS_MODE="${TLS_MODE:-public}"
case "$TLS_MODE" in public|local) ;; *) echo 'TLS mode must be public or local.' >&2; exit 2 ;; esac
if [[ "$TLS_MODE" == local ]]; then
  [[ "$PROXY_MODE_REQUESTED" != caddy ]] || { echo 'Local HTTPS requires Nginx.' >&2; exit 2; }
  PROXY_MODE_REQUESTED=nginx
fi
if [[ $FIRST_INSTALL -eq 1 ]]; then
  [[ -z "$DOMAIN" ]] && prompt_domain
  normalize_domain
  case "$REGISTRATION" in open|approval|closed) ;; *) echo "Invalid registration policy" >&2; exit 1 ;; esac
  case "$FEDERATION" in disabled|trusted|open|local|hybrid) ;; *) echo "Invalid federation mode" >&2; exit 1 ;; esac
else
  ui_info "Existing Loom production configuration detected: $EXISTING_ENV"
  ui_info "Secrets and operator configuration will be preserved."
  if [[ -z "$DOMAIN" ]]; then
    DOMAIN="$(read_env_value "$EXISTING_ENV" LOOM_PUBLIC_DOMAIN)"
  else
    normalize_domain
  fi
fi

load_os_release() {
  if [[ ! -r /etc/os-release ]]; then
    echo "Unsupported Linux: /etc/os-release is missing." >&2
    exit 1
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
}

install_docker_debian_like() {
  local distro="$1" codename
  if [[ "${LOOM_DOWNLOAD_PROFILE:-official}" != official ]]; then
    # No Docker Inc. GPG/repository request is made on this selected path.
    # An existing CE installation must never be silently replaced by docker.io.
    if dpkg-query -W -f='${Status}' docker-ce 2>/dev/null | grep -q 'install ok installed'; then
      echo 'Existing Docker CE needs repair through its configured repository; refusing an automatic engine replacement.' >&2
      return 1
    fi
    case "$distro:${VERSION_CODENAME:-}" in
      ubuntu:*) loom_packages docker.io docker-compose-v2 docker-buildx ;;
      debian:trixie|debian:forky) loom_packages docker.io docker-compose docker-buildx ;;
      *) echo 'This release does not provide the required Compose v2 packages through the selected distribution mirror. Use Debian 13+/Ubuntu 22.04+ or an existing supported Docker Engine and Compose.' >&2; return 1 ;;
    esac
    systemctl enable --now docker
    return
  fi
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl openssl git
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${distro}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  if [[ "$distro" == "ubuntu" ]]; then
    codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
  else
    codename="${VERSION_CODENAME:-}"
  fi
  [[ -n "$codename" ]] || { echo "Could not determine Linux release codename." >&2; exit 1; }
  cat >/etc/apt/sources.list.d/docker.sources <<DOCKER_REPO
Types: deb
URIs: https://download.docker.com/linux/${distro}
Suites: ${codename}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
DOCKER_REPO
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
}

install_docker_rpm() {
  local repo="$1"
  dnf -y install dnf-plugins-core ca-certificates curl openssl git
  # DNF 5 and DNF 4 use different config-manager syntax.
  if dnf config-manager --help 2>&1 | grep -q addrepo; then
    dnf config-manager addrepo --from-repofile "https://download.docker.com/linux/$repo/docker-ce.repo"
  else
    dnf config-manager --add-repo "https://download.docker.com/linux/$repo/docker-ce.repo"
  fi
  dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
}

ensure_docker() {
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    ui_ok "Docker Engine and Compose v2 are available"
    return
  fi
  load_os_release
  loom_require_systemd
  case "${ID:-}" in
    ubuntu) install_docker_debian_like ubuntu ;;
    debian) install_docker_debian_like debian ;;
    fedora) install_docker_rpm fedora ;;
    centos|rocky|almalinux) install_docker_rpm centos ;;
    rhel) install_docker_rpm rhel ;;
    arch|manjaro) loom_packages docker docker-compose; systemctl enable --now docker ;;
    opensuse-leap|opensuse-tumbleweed|sles) loom_packages docker docker-compose; systemctl enable --now docker ;;
    *)
      echo "Automatic Docker installation is unavailable for this distribution." >&2
      echo "Install Docker Engine + Compose v2 manually, then rerun this installer." >&2
      exit 1
      ;;
  esac
  docker info >/dev/null
  docker compose version >/dev/null
  ui_ok "Docker Engine and Compose v2 installed"
}

ensure_runtime_tools() {
  if command -v curl >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1 && command -v git >/dev/null 2>&1 && command -v ss >/dev/null 2>&1; then
    return
  fi
  load_os_release
  case "${ID:-}" in
    fedora|centos|rhel|rocky|almalinux|opensuse-*|sles) loom_packages ca-certificates curl openssl git iproute ;;
    *) loom_packages ca-certificates curl openssl git iproute2 ;;
  esac

}

random_secret() {
  openssl rand -base64 "$1" | tr -d '\n=' | tr '+/' '-_'
}

port_in_use() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltnH "sport = :$port" 2>/dev/null | grep -q .
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)$port$"
  else
    return 1
  fi
}

nginx_is_active() {
  command -v nginx >/dev/null 2>&1 || return 1
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nginx 2>/dev/null; then
    return 0
  fi
  pgrep -x nginx >/dev/null 2>&1
}

caddy_container_running() {
  command -v docker >/dev/null 2>&1 || return 1
  docker ps --format '{{.Image}} {{.Names}}' 2>/dev/null | grep -Eqi '(^|[ /])caddy(:|@|[[:space:]])|loom.*caddy'
}

select_proxy_mode() {
  local existing=""
  [[ -f "$EXISTING_ENV" ]] && existing="$(read_env_value "$EXISTING_ENV" LOOM_PROXY_MODE)"

  if [[ "$PROXY_MODE_REQUESTED" != "auto" ]]; then
    PROXY_MODE="$PROXY_MODE_REQUESTED"
  elif [[ "$existing" == "caddy" || "$existing" == "nginx" ]]; then
    PROXY_MODE="$existing"
  elif caddy_container_running; then
    PROXY_MODE="caddy"
  elif nginx_is_active; then
    PROXY_MODE="nginx"
  elif port_in_use 80 || port_in_use 443; then
    echo "Ports 80/443 are already in use, but active host Nginx was not detected." >&2
    echo "Refusing to steal the ports. Free them or rerun with --proxy nginx after configuring/installing Nginx." >&2
    exit 1
  else
    PROXY_MODE="caddy"
  fi

  if [[ "$PROXY_MODE" == "caddy" ]] && nginx_is_active && { port_in_use 80 || port_in_use 443; }; then
    echo "Caddy mode cannot bind 80/443 because Nginx is active." >&2
    echo "Use --proxy nginx (or the default --proxy auto)." >&2
    exit 1
  fi
  if [[ "$PROXY_MODE" == "nginx" ]] && ! nginx_is_active && { port_in_use 80 || port_in_use 443; }; then
    echo "Nginx mode was selected, but 80/443 are occupied by another active service." >&2
    echo "Refusing to overwrite or stop the unknown listener." >&2
    exit 1
  fi
  ui_ok "Reverse proxy selected: $PROXY_MODE"
}

build_or_install_manager() {
  local packaged="$SOURCE_ROOT/bin/loom-node-manager"
  local target="$INSTALL_DIR/bin/loom-node-manager"
  if [[ ! -f "$MANAGER_SOURCE/go.mod" && -x "$packaged" ]]; then
    loom_install_manager_binary "$packaged" "$target"
    ui_ok "Installed packaged Loom Node Manager"
    return
  fi
  if [[ ! -f "$MANAGER_SOURCE/go.mod" ]]; then
    echo "Node Manager source/binary is missing; cannot provide the loom-node command." >&2
    exit 1
  fi
  local goarch build_dir
  case "$(uname -m)" in
    x86_64|amd64) goarch=amd64 ;;
    aarch64|arm64) goarch=arm64 ;;
    *) echo "Unsupported CPU architecture for Node Manager: $(uname -m)" >&2; exit 1 ;;
  esac
  build_dir="$(mktemp -d)"
  trap 'rm -rf "${build_dir:-}"' RETURN
  mkdir -p "$build_dir/src"
  cp -a "$MANAGER_SOURCE/." "$build_dir/src/"
  ui_info "Building Loom Node Manager TUI for linux/$goarch"
  docker run --rm \
    -e GOPROXY="$LOOM_GO_PROXY" -e GOSUMDB=sum.golang.org -e LOOM_ALPINE_MIRROR="$LOOM_ALPINE_MIRROR" \
    -e CGO_ENABLED=0 -e GOOS=linux -e GOARCH="$goarch" \
    -e LOOM_SOURCE_COMMIT="$INSTALL_COMMIT" -e LOOM_SOURCE_BRANCH="$UPDATE_BRANCH" -e LOOM_SOURCE_REPOSITORY="$UPDATE_REPOSITORY" \
    -e PATH=/usr/local/go/bin:/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    -v "$SCRIPT_DIR/go-build-resources.sh:/usr/local/lib/loom/go-build-resources.sh:ro,Z" \
    -v "$build_dir:/work:Z" -w /work/src "${LOOM_DOCKER_PREFIX}golang:1.25.14-alpine3.23@sha256:27b3069b25647beacd3745b0b2c83e2f9b8d3935455a32cd4531236ee1c960e0" \
    sh -c 'set -eu; if [ -n "$LOOM_ALPINE_MIRROR" ]; then v=$(cut -d. -f1,2 /etc/alpine-release); printf "%s/v%s/main\n%s/v%s/community\n" "$LOOM_ALPINE_MIRROR" "$v" "$LOOM_ALPINE_MIRROR" "$v" > /etc/apk/repositories; fi; apk add --no-cache git; /usr/local/go/bin/go version; echo "Downloading manager modules from $GOPROXY (10-minute limit)"; timeout -s TERM -k 10 600 /usr/local/go/bin/go mod download -x; . /usr/local/lib/loom/go-build-resources.sh; loom_go_build_resources; /usr/local/go/bin/go test -p "$LOOM_GO_BUILD_JOBS" -mod=readonly ./...; /usr/local/go/bin/go build -p "$LOOM_GO_BUILD_JOBS" -buildvcs=false -mod=readonly -trimpath -ldflags="-s -w -X main.buildCommit=$LOOM_SOURCE_COMMIT -X main.buildBranch=$LOOM_SOURCE_BRANCH -X main.buildRepository=$LOOM_SOURCE_REPOSITORY" -o /work/loom-node-manager .'
  loom_install_manager_binary "$build_dir/loom-node-manager" "$target"
  rm -rf "$build_dir"
  trap - RETURN
  ui_ok "Loom Node Manager built and installed"
}

write_launcher() {
  bash "$INSTALL_DIR/scripts/linux/install-cli.sh"
}

copy_bundle() {
  install -d -m 0755 "$INSTALL_DIR" "$INSTALL_DIR/deploy" "$INSTALL_DIR/scripts/linux" "$INSTALL_DIR/bin"
  install -m 0644 "$SOURCE_ROOT/package.json" "$INSTALL_DIR/package.json"
  install -m 0644 "$SOURCE_ROOT/package-lock.json" "$INSTALL_DIR/package-lock.json"
  rm -rf "$INSTALL_DIR/src"
  cp -a "$SOURCE_ROOT/src" "$INSTALL_DIR/src"
  install -m 0644 "$SOURCE_ROOT/deploy/Dockerfile.storage" "$INSTALL_DIR/deploy/Dockerfile.storage"
  install -m 0644 "$SOURCE_ROOT/deploy/Dockerfile" "$INSTALL_DIR/deploy/Dockerfile"
  install -m 0644 "$SOURCE_ROOT/deploy/docker-compose.production.yml" "$INSTALL_DIR/deploy/docker-compose.production.yml"
  install -m 0644 "$SOURCE_ROOT/deploy/Caddyfile.example" "$INSTALL_DIR/deploy/Caddyfile.example"
  install -m 0644 "$SOURCE_ROOT/deploy/STORAGE.md" "$INSTALL_DIR/deploy/STORAGE.md"
  [[ -f "$SOURCE_ROOT/deploy/README.md" ]] && install -m 0644 "$SOURCE_ROOT/deploy/README.md" "$INSTALL_DIR/deploy/README.md"
  [[ -f "$SOURCE_ROOT/deploy/.env.example" ]] && install -m 0644 "$SOURCE_ROOT/deploy/.env.example" "$INSTALL_DIR/deploy/.env.example"
  install -m 0644 "$SCRIPT_DIR/update-metadata.sh" "$INSTALL_DIR/scripts/linux/update-metadata.sh"
  install -m 0755 "$SCRIPT_DIR/install-production.sh" "$INSTALL_DIR/scripts/linux/install-production.sh"
  [[ -f "$SCRIPT_DIR/manager.sh" ]] && install -m 0755 "$SCRIPT_DIR/manager.sh" "$INSTALL_DIR/scripts/linux/manager.sh"
  [[ -f "$SCRIPT_DIR/validate-node.sh" ]] && install -m 0755 "$SCRIPT_DIR/validate-node.sh" "$INSTALL_DIR/scripts/linux/validate-node.sh"
  for component in go-build-resources.sh local-tls.sh download-sources.sh install-state.sh diagnose-node.sh platform.sh install-safety.sh manager.sh uninstall-production.sh setup.sh install-cli.sh loom-cli.sh repair-update.sh; do
    install -m 0755 "$SCRIPT_DIR/$component" "$INSTALL_DIR/scripts/linux/$component"
  done
  printf '%s\n' 'loom-install-v1:/opt/loom-node' > "$INSTALL_DIR/.loom-install-owner"
  chmod 0600 "$INSTALL_DIR/.loom-install-owner"
  install -m 0755 "$REPO_ROOT/scripts/install-loom-node.sh" "$INSTALL_DIR/scripts/linux/verified-bootstrap.sh"
  local source_digest=""
  if [[ -f "$REPO_ROOT/.loom-source-sha256" ]]; then
    loom_require_root_owned "$REPO_ROOT/.loom-source-sha256" || return 1
    source_digest="$(cat "$REPO_ROOT/.loom-source-sha256")"
  elif loom_require_root_owned /etc/loom && loom_require_root_owned /etc/loom/approved-releases; then
    source_digest="$(awk -v rev="$VERIFIED_COMMIT" '$1 == "0800x/Loom" && $2 == rev { print $3; exit }' /etc/loom/approved-releases)"
  fi
  install -m 0644 "$REPO_ROOT/.loom-verified-source" "$INSTALL_DIR/.loom-verified-source"
  if [[ "$source_digest" =~ ^[a-f0-9]{64}$ ]]; then
    printf '%s\n' "$source_digest" > "$INSTALL_DIR/.loom-source-sha256"
    chmod 0644 "$INSTALL_DIR/.loom-source-sha256"
    loom_write_release_approval "$INSTALL_DIR" "$VERIFIED_COMMIT" "$source_digest"
  else
    rm -f -- "$INSTALL_DIR/.loom-source-sha256"
    ui_warn 'Setup pin unavailable. Reopen setup through the verified public bootstrap.'
  fi
  build_or_install_manager
  if [[ -f "$REPO_ROOT/release/node-channel.json" ]]; then
    local source_sequence
    source_sequence="$(sed -n 's/.*"sequence":[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$REPO_ROOT/release/node-channel.json")"
    [[ "$source_sequence" =~ ^[1-9][0-9]*$ ]] || return 1
    "$INSTALL_DIR/bin/loom-node-manager" --home "$INSTALL_DIR" --record-installed-source-sequence "$source_sequence"
  fi
  write_launcher
}

write_env() {
  local env_path="$INSTALL_DIR/deploy/.env" pg admin s3_access s3_secret
  pg="$(random_secret 36)"
  admin="$(random_secret 48)"
  s3_access="loom_$(random_secret 12)"
  s3_secret="$(random_secret 36)"
  umask 077
  cat >"$env_path" <<ENV_FILE
LOOM_MODE=production
LOOM_HOST=0.0.0.0
LOOM_PORT=7483
LOOM_HOST_PORT=7483
LOOM_PROXY_MODE=$PROXY_MODE
LOOM_PUBLIC_DOMAIN=$DOMAIN
LOOM_PUBLIC_BASE_URL=https://$DOMAIN
LOOM_OPERATOR_NAME=$OPERATOR_NAME
LOOM_NETWORK_JURISDICTION=$JURISDICTION
LOOM_REGISTRATION_POLICY=$REGISTRATION
LOOM_FEDERATION_MODE=$FEDERATION
LOOM_ADMIN_TOKEN=$admin
POSTGRES_PASSWORD=$pg
LOOM_DATABASE_URL=postgres://loom:$pg@postgres:5432/loom
LOOM_S3_ENDPOINT=http://minio:9000
LOOM_S3_REGION=us-east-1
LOOM_S3_BUCKET=loom-attachments
LOOM_S3_ACCESS_KEY_ID=$s3_access
LOOM_S3_SECRET_ACCESS_KEY=$s3_secret
LOOM_S3_FORCE_PATH_STYLE=true
ENV_FILE
  chmod 0600 "$env_path"
}

set_env_value() {
  local path="$1" key="$2" value="$3" tmp
  tmp="$(mktemp)"
  awk -F= -v key="$key" -v value="$value" '
    BEGIN { found=0 }
    $1 == key { print key "=" value; found=1; next }
    { print }
    END { if (!found) print key "=" value }
  ' "$path" >"$tmp"
  cat "$tmp" >"$path"
  rm -f "$tmp"
  chmod 0600 "$path"
}

configure_existing_env() {
  [[ $FIRST_INSTALL -eq 0 ]] || return 0
  local old_domain
  old_domain="$(read_env_value "$EXISTING_ENV" LOOM_PUBLIC_DOMAIN)"
  if [[ "$old_domain" != "$DOMAIN" ]]; then
    ui_info "Updating public domain: ${old_domain:-<unset>} -> $DOMAIN"
    set_env_value "$EXISTING_ENV" LOOM_PUBLIC_DOMAIN "$DOMAIN"
    set_env_value "$EXISTING_ENV" LOOM_PUBLIC_BASE_URL "https://$DOMAIN"
  fi
  set_env_value "$EXISTING_ENV" LOOM_PROXY_MODE "$PROXY_MODE"
  if [[ -z "$(read_env_value "$EXISTING_ENV" LOOM_HOST_PORT)" ]]; then
    set_env_value "$EXISTING_ENV" LOOM_HOST_PORT "7483"
  fi
}

compose() {
  local cmd=(docker compose --env-file "$INSTALL_DIR/deploy/.env" -f "$INSTALL_DIR/deploy/docker-compose.production.yml")
  for overlay in storage-legacy turn group-calls; do
    [[ ! -f "$INSTALL_DIR/deploy/docker-compose.$overlay.yml" ]] || cmd+=(-f "$INSTALL_DIR/deploy/docker-compose.$overlay.yml")
  done
  [[ "$PROXY_MODE" == "caddy" ]] && cmd+=(--profile caddy)
  "${cmd[@]}" "$@"
}

stop_embedded_caddy_for_nginx() {
  [[ "$PROXY_MODE" == "nginx" ]] || return 0
  docker compose --env-file "$INSTALL_DIR/deploy/.env" -f "$INSTALL_DIR/deploy/docker-compose.production.yml" --profile caddy stop caddy >/dev/null 2>&1 || true
  docker compose --env-file "$INSTALL_DIR/deploy/.env" -f "$INSTALL_DIR/deploy/docker-compose.production.yml" --profile caddy rm -f caddy >/dev/null 2>&1 || true
}

open_firewall_ports() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    ui_info "Opening HTTP/HTTPS in UFW"
    ufw allow 80/tcp >/dev/null
    ufw allow 443/tcp >/dev/null
    [[ "$PROXY_MODE" == "caddy" ]] && ufw allow 443/udp >/dev/null
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    ui_info "Opening HTTP/HTTPS in firewalld"
    firewall-cmd --permanent --add-service=http >/dev/null
    firewall-cmd --permanent --add-service=https >/dev/null
    [[ "$PROXY_MODE" == "caddy" ]] && firewall-cmd --permanent --add-port=443/udp >/dev/null
    firewall-cmd --reload >/dev/null
  fi
}

public_ipv4() {
  curl -4fsS --max-time 6 https://api.ipify.org 2>/dev/null || true
}

resolved_ipv4s() {
  if command -v getent >/dev/null 2>&1; then
    getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u
  fi
}

dns_preflight() {
  [[ $SKIP_DNS_CHECK -eq 0 ]] || { ui_warn "DNS preflight skipped"; return 0; }
  local public_ip resolved
  public_ip="$(public_ipv4)"
  resolved="$(resolved_ipv4s || true)"
  ui_info "DNS preflight"
  printf '  %-14s %s\n' "Domain" "$DOMAIN"
  printf '  %-14s %s\n' "Public IPv4" "${public_ip:-unknown}"
  printf '  %-14s %s\n' "DNS A" "${resolved//$'\n'/, }"
  if [[ -z "$resolved" ]]; then
    ui_warn "No IPv4 A record is visible yet. TLS issuance needs DNS to reach this server."
    return 1
  fi
  if [[ -n "$public_ip" ]] && ! grep -Fxq "$public_ip" <<<"$resolved"; then
    ui_warn "DNS does not currently point to this server ($public_ip)."
    ui_warn "Set an A record for $DOMAIN -> $public_ip, then rerun if initial TLS issuance fails."
    return 1
  fi
  ui_ok "DNS matches this server"
}

ensure_nginx_certbot() {
  if [[ "$TLS_MODE" == local ]]; then
    if ! command -v nginx >/dev/null 2>&1; then load_os_release; loom_packages nginx; fi
    systemctl enable --now nginx
    return
  fi
  local ready=0
  if command -v nginx >/dev/null 2>&1 && command -v certbot >/dev/null 2>&1 && certbot plugins 2>/dev/null | grep -qi nginx; then
    ready=1
  fi
  if [[ $ready -eq 0 ]]; then
    load_os_release
    case "${ID:-}" in
      ubuntu|debian|fedora|centos|rhel|rocky|almalinux)
        loom_packages nginx certbot python3-certbot-nginx
        ;;
      arch|manjaro) loom_packages nginx certbot certbot-nginx ;;
      opensuse-leap|opensuse-tumbleweed|sles) loom_packages nginx certbot python3-certbot-nginx ;;
      *)
        echo "Automatic Nginx/Certbot installation supports Ubuntu, Debian and Fedora." >&2
        exit 1
        ;;
    esac
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now nginx
  elif ! nginx_is_active; then
    nginx
  fi
}

nginx_site_path() {
  if [[ -d /etc/nginx/sites-available && -d /etc/nginx/sites-enabled ]]; then
    printf '%s\n' /etc/nginx/sites-available/loom-node.conf
  else
    printf '%s\n' /etc/nginx/conf.d/loom-node.conf
  fi
}

enable_nginx_site() {
  local site="$1"
  if [[ "$site" == /etc/nginx/sites-available/* ]]; then
    ln -sfn "$site" /etc/nginx/sites-enabled/loom-node.conf
  fi
}

check_nginx_domain_conflict() {
  local conflict=""
  if [[ -d /etc/nginx/sites-enabled ]]; then
    conflict="$(grep -RslF "server_name $DOMAIN" /etc/nginx/sites-enabled 2>/dev/null | grep -v '/loom-node.conf$' | head -n1 || true)"
  fi
  if [[ -z "$conflict" && -d /etc/nginx/conf.d ]]; then
    conflict="$(grep -RslF "server_name $DOMAIN" /etc/nginx/conf.d 2>/dev/null | grep -v '/loom-node.conf$' | head -n1 || true)"
  fi
  if [[ -n "$conflict" ]]; then
    echo "Nginx already has another active server block for $DOMAIN: $conflict" >&2
    echo "Refusing to overwrite an unrelated Nginx site." >&2
    exit 1
  fi
}

write_nginx_http_site() {
  local site="$1"
  cat >"$site" <<NGINX_HTTP
# Managed by Loom Node installer.
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    client_max_body_size 100m;

    # Certbot's nginx authenticator temporarily installs its challenge route.
    # Until TLS is verified, never expose the authenticated API over HTTP.
    location / { return 503; }
}
NGINX_HTTP
  enable_nginx_site "$site"
  nginx -t
  systemctl reload nginx
}

issue_nginx_certificate() {
  local cert_args=(certonly --nginx --non-interactive --agree-tos --no-eff-email --keep-until-expiring -d "$DOMAIN")
  if [[ -n "$CERTBOT_EMAIL" ]]; then
    cert_args+=(--email "$CERTBOT_EMAIL")
  else
    cert_args+=(--register-unsafely-without-email)
  fi
  certbot "${cert_args[@]}"
}

write_nginx_https_site() {
  local site="$1"
  local cert_dir="${LOOM_CERT_DIR:-/etc/letsencrypt/live/$DOMAIN}"
  [[ -s "$cert_dir/fullchain.pem" && -s "$cert_dir/privkey.pem" ]] || return 1
  cat >"$site" <<NGINX_HTTPS
# Managed by Loom Node installer.
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate $cert_dir/fullchain.pem;
    ssl_certificate_key $cert_dir/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer" always;

    client_max_body_size 100m;

    location / {
        proxy_pass http://127.0.0.1:7483;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
    }
}
NGINX_HTTPS
  nginx -t
  systemctl reload nginx
}

install_certbot_renewal_hook() {
  install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
  cat >/etc/letsencrypt/renewal-hooks/deploy/loom-nginx-reload.sh <<'HOOK'
#!/usr/bin/env bash
set -e
nginx -t
if command -v systemctl >/dev/null 2>&1; then
  systemctl reload nginx
else
  nginx -s reload
fi
HOOK
  chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/loom-nginx-reload.sh
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files certbot.timer >/dev/null 2>&1; then
    systemctl enable --now certbot.timer >/dev/null 2>&1 || true
  fi
}

nginx_certificate_is_valid() {
  local cert_dir="${1:-/etc/letsencrypt/live/$DOMAIN}"
  [[ -s "$cert_dir/fullchain.pem" && -s "$cert_dir/privkey.pem" ]] || return 1
  openssl x509 -in "$cert_dir/fullchain.pem" -noout -checkend 0 >/dev/null 2>&1 &&
    openssl verify -partial_chain -CAfile "$cert_dir/fullchain.pem" \
      -verify_hostname "$DOMAIN" "$cert_dir/fullchain.pem" >/dev/null 2>&1
}

configure_nginx_tls() {
  ensure_nginx_certbot
  check_nginx_domain_conflict
  if [[ "$TLS_MODE" == local ]]; then
    LOOM_CERT_DIR="$INSTALL_DIR/deploy/tls-local"
    loom_local_certificate "$LOOM_CERT_DIR" "$DOMAIN"
    local local_site
    local_site="$(nginx_site_path)"
    enable_nginx_site "$local_site"
    write_nginx_https_site "$local_site"
    ui_ok "Local HTTPS configured; clients must explicitly trust its certificate."
    return
  fi
  local site
  site="$(nginx_site_path)"
  # Updates must not remove working HTTPS merely because another Certbot
  # process holds its lock. The renewal timer maintains existing certificates.
  if nginx_certificate_is_valid; then
    enable_nginx_site "$site"
    write_nginx_https_site "$site"
    install_certbot_renewal_hook
    ui_ok "Existing valid Nginx certificate reused for $DOMAIN"
    return 0
  fi
  write_nginx_http_site "$site"
  ui_info "Requesting/refreshing Let's Encrypt certificate for $DOMAIN through Nginx"
  # A concurrent issuer may have completed even if this invocation failed.
  if issue_nginx_certificate || nginx_certificate_is_valid; then
    if ! nginx_certificate_is_valid; then
      ui_warn "Certbot finished without a valid certificate for $DOMAIN."
      return 1
    fi
    write_nginx_https_site "$site"
    install_certbot_renewal_hook
    ui_ok "Nginx HTTPS is configured for $DOMAIN"
  else
    ui_warn "Certbot could not issue the certificate yet."
    ui_warn "The HTTP bootstrap site returns 503. Check the Certbot error above; if another instance is running, wait for it to finish and retry. Check DNS/firewall when issuance reports a challenge failure."
    return 1
  fi
}

verify_https() {
  [[ $TLS_WAIT_SECONDS -gt 0 ]] || return 1
  if [[ "$TLS_MODE" == local ]]; then
    curl --fail --silent --show-error --connect-timeout 4 --max-time 15 \
      --cacert "$INSTALL_DIR/deploy/tls-local/fullchain.pem" \
      --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/readyz" >/dev/null
    ui_ok 'Local HTTPS and readiness verified against the generated certificate.'
    return
  fi
  local deadline=$((SECONDS + TLS_WAIT_SECONDS))
  ui_info "Waiting up to ${TLS_WAIT_SECONDS}s for public HTTPS"
  while (( SECONDS < deadline )); do
    if curl -fsS --connect-timeout 4 --max-time 8 "https://$DOMAIN/readyz" >/dev/null 2>&1; then
      local cert
      cert="$(echo | openssl s_client -servername "$DOMAIN" -connect "$DOMAIN:443" 2>/dev/null | openssl x509 -noout -issuer -enddate 2>/dev/null || true)"
      ui_ok "HTTPS is ready: https://$DOMAIN"
      [[ -n "$cert" ]] && printf '%s\n' "$cert" | sed 's/^/  /'
      return 0
    fi
    sleep 5
  done
  ui_warn "HTTPS is not verified yet."
  if [[ "$PROXY_MODE" == "caddy" ]]; then
    ui_info "Caddy remains running and will keep retrying automatic certificate issuance."
  else
    ui_info "Check Nginx, Certbot, DNS and provider/cloud firewall; rerun after fixing DNS if issuance failed."
  fi
  return 1
}

launch_tui() {
  [[ $NO_TUI -eq 0 && $NO_START -eq 0 ]] || return 0
  if [[ -r /dev/tty && -w /dev/tty ]]; then
    ui_info "Launching Loom Node Manager"
    /usr/local/bin/loom-node </dev/tty >/dev/tty 2>/dev/tty || true
  else
    ui_info "Run 'loom-node' in an interactive terminal to open the manager."
  fi
}

INSTALL_COMMIT="$VERIFIED_COMMIT"
if ! [[ "$INSTALL_COMMIT" =~ ^[a-fA-F0-9]{40}$ ]]; then
  INSTALL_COMMIT="${LOOM_SOURCE_COMMIT:-$(read_env_value "$SOURCE_ROOT/build-info.env" commit)}"
fi
if ! [[ "$INSTALL_COMMIT" =~ ^[a-fA-F0-9]{40}$ ]]; then INSTALL_COMMIT=""; fi
SOURCE_BRANCH="$(git -C "$REPO_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
UPDATE_BRANCH="${UPDATE_BRANCH:-$SOURCE_BRANCH}"
UPDATE_BRANCH="${UPDATE_BRANCH:-$(read_env_value "$SOURCE_ROOT/build-info.env" branch)}"
UPDATE_BRANCH="${UPDATE_BRANCH:-$(read_env_value "$EXISTING_ENV" LOOM_UPDATE_BRANCH)}"
UPDATE_BRANCH="${UPDATE_BRANCH:-main}"
if ! [[ "$UPDATE_REPOSITORY" =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ ]] ||
   ! [[ "$UPDATE_BRANCH" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_./-]*$ ]] || [[ "$UPDATE_BRANCH" == *..* || "$UPDATE_BRANCH" == */ || "$UPDATE_BRANCH" == *.lock ]]; then
  ui_fail "Invalid update repository or branch."
  exit 1
fi
if [[ $UPDATE_SOURCE_EXPLICIT -eq 0 && -z "$UPDATE_SOURCE_DIR" && -d "$REPO_ROOT/.git" ]]; then
  UPDATE_SOURCE_DIR="$REPO_ROOT"
fi
MANAGER_VERSION="$(sed -n 's/^const version = "\([^"]*\)"/\1/p' "$MANAGER_SOURCE/main.go" 2>/dev/null || true)"
MANAGER_VERSION="${MANAGER_VERSION:-$(read_env_value "$SOURCE_ROOT/build-info.env" manager_version)}"

ui_banner
printf '%bInstallation plan%b\n' "$UI_BOLD" "$UI_RESET"
printf '  %-14s %s\n' "Install dir" "$INSTALL_DIR"
printf '  %-14s %s\n' "Domain" "$DOMAIN"
if [[ $FIRST_INSTALL -eq 1 ]]; then
  printf '  %-14s %s\n' "Registration" "$REGISTRATION"
  printf '  %-14s %s\n' "Federation" "$FEDERATION"
fi

if [[ -z "$DOWNLOAD_PROFILE" && -f "$EXISTING_ENV" ]]; then
  DOWNLOAD_PROFILE="$(read_env_value "$EXISTING_ENV" LOOM_DOWNLOAD_PROFILE)"
fi
loom_download_profile "${DOWNLOAD_PROFILE:-official}"
if [[ -z "$GO_MIRROR" && -f "$EXISTING_ENV" ]]; then GO_MIRROR="$(read_env_value "$EXISTING_ENV" LOOM_GO_MIRROR)"; fi
loom_go_mirror "${GO_MIRROR:-profile}"
ui_info "Go module downloads: $LOOM_GO_PROXY"
ui_step 1 7 "Ensuring Docker Engine + Compose v2"
ensure_docker
ensure_runtime_tools
loom_require_compose_version
loom_guard_persistent_install "$EXISTING_ENV"
loom_preserve_storage_image "$INSTALL_DIR"

ui_step 2 7 "Selecting reverse proxy without stealing existing ports"
select_proxy_mode

ui_step 3 7 "Installing/updating Loom Node bundle and TUI"
copy_bundle

if [[ $FIRST_INSTALL -eq 1 ]]; then
  ui_step 4 7 "Generating production configuration and secrets"
  write_env
else
  ui_step 4 7 "Preserving production secrets and updating endpoint configuration"
  configure_existing_env
fi
write_launcher
set_env_value "$EXISTING_ENV" LOOM_TLS_MODE "$TLS_MODE"
set_env_value "$EXISTING_ENV" LOOM_DOWNLOAD_PROFILE "$LOOM_DOWNLOAD_PROFILE"
set_env_value "$EXISTING_ENV" LOOM_DOCKER_PREFIX "$LOOM_DOCKER_PREFIX"
set_env_value "$EXISTING_ENV" LOOM_GO_PROXY "$LOOM_GO_PROXY"
set_env_value "$EXISTING_ENV" LOOM_GO_MIRROR "$LOOM_GO_MIRROR"
set_env_value "$EXISTING_ENV" LOOM_NPM_REGISTRY "$LOOM_NPM_REGISTRY"
set_env_value "$EXISTING_ENV" LOOM_ALPINE_MIRROR "$LOOM_ALPINE_MIRROR"
set_env_value "$EXISTING_ENV" LOOM_BUILD_COMMIT "${INSTALL_COMMIT:-unknown}"
set_env_value "$EXISTING_ENV" LOOM_UPDATE_BRANCH "$UPDATE_BRANCH"
set_env_value "$EXISTING_ENV" LOOM_UPDATE_REPOSITORY "$UPDATE_REPOSITORY"
set_env_value "$EXISTING_ENV" LOOM_UPDATE_SOURCE_DIR "$UPDATE_SOURCE_DIR"
export LOOM_BUILD_COMMIT="${INSTALL_COMMIT:-unknown}"

ui_step 5 7 "Checking DNS and host firewall"
open_firewall_ports
[[ "$TLS_MODE" == local ]] || dns_preflight || true

compose config --quiet

if [[ $NO_START -eq 0 ]]; then
  ui_step 6 7 "Building and starting Loom Node"
  stop_embedded_caddy_for_nginx
  if ! compose up -d --build; then
    ui_fail 'Container build/start failed. No database credentials or identity were reset.'
    ui_info 'If module downloads report 403, this host cannot reach a dependency source. Do not uninstall or delete data; resolve outbound access and rerun the same installer.'
    exit 1
  fi
  compose ps
  ui_info "Verifying the running Node revision and local readiness"
  node_ready=0
  for ((attempt=0; attempt<45; attempt++)); do
    if compose exec -T loom-node node -e '
      const expected=process.argv[1];
      const actual=require("node:fs").readFileSync("/app/.loom-build-commit","utf8").trim();
      if(expected && actual!==expected) process.exit(2);
      fetch("http://127.0.0.1:7483/readyz",{signal:AbortSignal.timeout(3000)})
        .then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1));
    ' "$INSTALL_COMMIT" >/dev/null 2>&1; then node_ready=1; break; fi
    sleep 2
  done
  if [[ $node_ready -ne 1 ]]; then
    startup_logs="$(compose logs --no-color --tail 100 loom-node 2>/dev/null || true)"
    ui_fail "$(loom_classify_startup_failure "$startup_logs")"
    unset startup_logs
    ui_fail "Node readiness/revision verification failed. Run: sudo loom doctor"
    exit 1
  fi

  if [[ "$PROXY_MODE" == "nginx" ]]; then
    ui_info "Configuring host Nginx reverse proxy and Certbot"
    configure_nginx_tls
  fi

  ui_step 7 7 "Verifying public HTTPS certificate"
  verify_https
  loom_write_install_state "$INSTALL_DIR" "$UPDATE_REPOSITORY" "$UPDATE_BRANCH" "$UPDATE_SOURCE_DIR" "$INSTALL_COMMIT" "$MANAGER_VERSION"
else
  ui_step 6 7 "Start skipped (--no-start)"
  ui_step 7 7 "Reverse-proxy/TLS setup skipped"
fi

printf '\n%b╭──────────────────────────────────────────────╮%b\n' "$UI_GREEN$UI_BOLD" "$UI_RESET"
[[ $NO_START -eq 0 ]] && install_status='Installation complete' || install_status='Configured only; HTTPS unverified'
printf '%b│ %-44s │%b\n' "$UI_GREEN$UI_BOLD" "$install_status" "$UI_RESET"
printf '%b╰──────────────────────────────────────────────╯%b\n' "$UI_GREEN$UI_BOLD" "$UI_RESET"
printf '  %-14s %s\n' "Home" "$INSTALL_DIR"
printf '  %-14s %s\n' "Secrets" "$INSTALL_DIR/deploy/.env (mode 0600)"
if [[ $NO_START -eq 0 ]]; then printf '  %-14s %s\n' "Public URL" "https://$DOMAIN"; else ui_warn 'Containers were not started and HTTPS is unavailable/unverified.'; fi
printf '  %-14s %s\n' "Manager" "loom-node"
printf '  %-14s %s\n' "Proxy" "$PROXY_MODE"
if [[ "$PROXY_MODE" == "caddy" ]]; then
  printf '  %-14s %s\n' "TLS" "Caddy automatic HTTPS + renewal"
else
  printf '  %-14s %s\n' "Upstream" "http://127.0.0.1:7483 (loopback only)"
  printf '  %-14s %s\n' "TLS" "Nginx + Let's Encrypt/Certbot renewal"
fi
if [[ "$REGISTRATION" == "approval" && $FIRST_INSTALL -eq 1 ]]; then
  ui_info "Registration approvals: loom-node → Registration"
fi
if [[ "$FEDERATION" != "disabled" && $FIRST_INSTALL -eq 1 ]]; then
  ui_warn "Federation routing remains experimental/incomplete in this branch."
fi

launch_tui
