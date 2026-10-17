#!/usr/bin/env bash
set -euo pipefail

ORIGINAL_ARGS=("$@")
INSTALL_DIR="${LOOM_NODE_HOME:-/opt/loom-node}"
DOMAIN=""
OPERATOR_NAME="Loom Node"
JURISDICTION="Unspecified"
REGISTRATION="approval"
FEDERATION="trusted"
PROXY="auto"
CERTBOT_EMAIL=""
TURN_MODE="auto"
START_NOW=1
OPEN_MANAGER=1
ASSUME_YES=0
DOMAIN_SET=0
OPERATOR_SET=0
JURISDICTION_SET=0
REGISTRATION_SET=0
FEDERATION_SET=0
PROXY_SET=0
TURN_SET=0
VIDEO=yes
VIDEO_SET=0
GROUP_CALLS=on
GROUP_SET=0
PLAN=0
TEXT_UI=0
DOWNLOAD_PROFILE=official
DOWNLOAD_SET=0
GO_MIRROR=profile
GO_MIRROR_SET=0
TLS_MODE=public
TLS_SET=0
CALLS_ONLY=0

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  RESET=$'\033[0m'
  BOLD=$'\033[1m'
  DIM=$'\033[2m'
  PURPLE=$'\033[38;5;141m'
  CYAN=$'\033[38;5;45m'
  GREEN=$'\033[38;5;84m'
  YELLOW=$'\033[38;5;220m'
  RED=$'\033[38;5;203m'
else
  RESET="" BOLD="" DIM="" PURPLE="" CYAN="" GREEN="" YELLOW="" RED=""
fi

logo() {
  printf '%b' "$PURPLE$BOLD"
  printf '\nLoom · Home Node\n'
  printf '%b\n' "$RESET"
  printf '%bLoom Node Setup%b  %bsecure self-hosted messaging%b\n\n' "$BOLD" "$RESET" "$DIM" "$RESET"
}

usage() {
  cat <<'USAGE'
Loom Node setup wizard

Usage:
  setup.sh [options]

Options:
  --downloads official|liara|arvan  Per-install dependency sources
  --go-mirror profile|official|liara|runflare|goproxy-cn  Override Go downloads only
  --tls public|local    Public CA or explicitly trusted local certificate
  --domain HOSTNAME     Hostname or IPv4 address
  --operator-name NAME
  --jurisdiction TEXT
  --registration approval|open|closed
  --federation trusted|disabled|open|local|hybrid
  --proxy auto|nginx|caddy
  --certbot-email EMAIL
  --turn auto|manual|off  Local coturn setup (default: auto on new installs)
  --video yes|no        Allow video calls (default: yes)
  --group-calls on|off|keep  Provision group media (default: on for new installs, keep existing)
  --plan                Preview choices without changing this host
  --text                Use line prompts instead of the terminal menu
  --calls-only          Configure local TURN on an existing installation
  --no-start
  --no-manager
  --yes                 Accept the final installation summary
  -h, --help

Run without options for the interactive setup wizard.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --calls-only) CALLS_ONLY=1; shift ;;
    --tls) TLS_MODE="${2:-}"; TLS_SET=1; shift 2 ;;
    --go-mirror) GO_MIRROR="${2:-}"; GO_MIRROR_SET=1; shift 2 ;;
    --downloads) DOWNLOAD_PROFILE="${2:-}"; DOWNLOAD_SET=1; shift 2 ;;
    --domain) DOMAIN="${2:-}"; DOMAIN_SET=1; shift 2 ;;
    --operator-name) OPERATOR_NAME="${2:-}"; OPERATOR_SET=1; shift 2 ;;
    --jurisdiction) JURISDICTION="${2:-}"; JURISDICTION_SET=1; shift 2 ;;
    --registration) REGISTRATION="${2:-}"; REGISTRATION_SET=1; shift 2 ;;
    --federation) FEDERATION="${2:-}"; FEDERATION_SET=1; shift 2 ;;
    --proxy) PROXY="${2:-}"; PROXY_SET=1; shift 2 ;;
    --certbot-email) CERTBOT_EMAIL="${2:-}"; shift 2 ;;
    --turn) TURN_MODE="${2:-}"; TURN_SET=1; shift 2 ;;
    --video) VIDEO="${2:-}"; VIDEO_SET=1; shift 2 ;;
    --group-calls) GROUP_CALLS="${2:-}"; GROUP_SET=1; shift 2 ;;
    --text) TEXT_UI=1; shift ;;
    --plan) PLAN=1; shift ;;
    --no-start) START_NOW=0; shift ;;
    --no-manager) OPEN_MANAGER=0; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ $PLAN -eq 0 && ${EUID:-$(id -u)} -ne 0 ]]; then
  echo 'Run the top-level install.sh bootstrap; it verifies source before elevation.' >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$SCRIPT_DIR/install-production.sh"
CLI_INSTALLER="$SCRIPT_DIR/install-cli.sh"
ENV_FILE="$INSTALL_DIR/deploy/.env"
EXISTING_INSTALL=0
source "$SCRIPT_DIR/platform.sh"
source "$SCRIPT_DIR/download-sources.sh"
source "$SCRIPT_DIR/local-tls.sh"
if [[ $PLAN -eq 0 ]]; then
  source "$SCRIPT_DIR/install-safety.sh"
  loom_require_install_path "$INSTALL_DIR"
  REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
  loom_require_root_owned "$REPO_ROOT" && loom_require_root_owned "$REPO_ROOT/.loom-verified-source" || {
    echo 'Unverified setup source. Use install.sh.' >&2; exit 1;
  }
  loom_require_systemd
fi

[[ -f "$INSTALLER" ]] || { echo "Missing installer: $INSTALLER" >&2; exit 1; }
[[ -f "$CLI_INSTALLER" ]] || { echo "Missing CLI installer: $CLI_INSTALLER" >&2; exit 1; }

read_env_value() {
  local path="$1" key="$2"
  [[ -f "$path" ]] || return 0
  awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$path"
}

set_env_value() {
  local path="$1" key="$2" value="$3" tmp
  [[ -f "$path" && ! -L "$path" && "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 1
  tmp="$(mktemp "${path}.XXXXXX")"
  LOOM_SETUP_VALUE="$value" awk -F= -v key="$key" '
    BEGIN { found=0; value=ENVIRON["LOOM_SETUP_VALUE"] }
    $1 == key { if (!found) print key "=" value; found=1; next }
    { print }
    END { if (!found) print key "=" value }
  ' "$path" >"$tmp"
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$path"
}

load_existing_default() {
  local flag="$1" variable="$2" key="$3" current
  [[ "$flag" -eq 0 && -f "$ENV_FILE" ]] || return 0
  current="$(read_env_value "$ENV_FILE" "$key")"
  if [[ -n "$current" ]]; then printf -v "$variable" '%s' "$current"; fi
}

normalize_domain() {
  DOMAIN="$(printf '%s' "$DOMAIN" | tr '[:upper:]' '[:lower:]' | xargs)"
  local kind
  kind="$(loom_tls_name_kind "$DOMAIN")" || return
  [[ "$DOMAIN" != chat.example.com ]] || return 2
  [[ "$TLS_MODE" == local || ( "$kind" == DNS && "$DOMAIN" == *.* ) ]]
}

valid_turn_secret() {
  local value="${1:-}"
  [[ "$value" =~ ^[A-Za-z0-9._~-]{32,512}$ ]]
}

configure_local_turn() {
  [[ -f "$ENV_FILE" ]] || { echo "Missing Node environment: $ENV_FILE" >&2; return 1; }

  local secret public_ip="" external_ip="" tmp=""
  local deploy="$INSTALL_DIR/deploy"
  # Never take over another relay, including an earlier host-managed coturn.
  if [[ ! -f "$deploy/docker-compose.turn.yml" ]] &&
     { systemctl is-active --quiet coturn 2>/dev/null || systemctl is-active --quiet turnserver 2>/dev/null ||
       ss -H -lntu 'sport = :3478' 2>/dev/null | grep -q .; }; then
    echo 'Port 3478 or a host TURN service is already in use. Keep it with --turn manual; no service was replaced.' >&2
    return 1
  fi
  secret="$(read_env_value "$ENV_FILE" LOOM_TURN_SHARED_SECRET)"
  if [[ -n "$secret" ]] && ! valid_turn_secret "$secret"; then
    echo 'Existing TURN secret is invalid. Restore its backup; it will not be regenerated.' >&2
    return 1
  fi
  [[ -n "$secret" ]] || secret="$(openssl rand -hex 32)"

  # When the machine is behind provider NAT, coturn needs its public address.
  # The production installer already depends on curl; never derive this from a
  # proxied DNS record because a CDN address would be wrong for TURN.
  public_ip=""
  if [[ "${TLS_MODE:-public}" != local ]]; then
    public_ip="$(curl -4fsS --retry 2 --max-time 10 https://api.ipify.org)"
    [[ "$public_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo 'Could not detect public IPv4 for TURN.' >&2; return 1; }
  fi
  if [[ "$public_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && command -v ip >/dev/null 2>&1; then
    if ! ip -o -4 addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$public_ip"; then
      external_ip="$public_ip"
    fi
  fi

  tmp="$(mktemp "$deploy/.turnserver.XXXXXX")"
  {
    cat <<EOF
listening-port=3478
fingerprint
use-auth-secret
static-auth-secret=$secret
realm=$DOMAIN
min-port=49160
max-port=49200
no-cli
no-tls
no-dtls
no-multicast-peers
denied-peer-ip=10.0.0.0-10.255.255.255
denied-peer-ip=172.16.0.0-172.31.255.255
denied-peer-ip=192.168.0.0-192.168.255.255
denied-peer-ip=169.254.0.0-169.254.255.255
denied-peer-ip=::ffff:0:0-::ffff:ffff:ffff
denied-peer-ip=fc00::-fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff
denied-peer-ip=fe80::-febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff
EOF
    if [[ -n "$external_ip" ]]; then printf 'external-ip=%s\n' "$external_ip"; fi
  } >"$tmp"
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$deploy/turnserver.conf"
  cat >"$deploy/docker-compose.turn.yml" <<'TURN_COMPOSE'
services:
  turn:
    image: ${LOOM_DOCKER_PREFIX:-}coturn/coturn:4.18.0-r0@sha256:bbefd3e1fdfdc0d58770fe01b581fd8b00d9f3a5580d00acb77cf719a6bc78e3
    labels:
      org.loom.installation: /opt/loom-node
    restart: unless-stopped
    network_mode: host
    user: "0:0"
    cap_drop: [ALL]
    cap_add: [NET_BIND_SERVICE]
    security_opt: [no-new-privileges:true]
    entrypoint: ["/bin/sh", "-ec", 'test -s /etc/coturn/turnserver.conf; test -r /etc/coturn/turnserver.conf; exec /usr/bin/turnserver "$$@"', "--"]
    command: ["-c", "/etc/coturn/turnserver.conf", "--use-auth-secret", "--log-file=stdout"]
    healthcheck:
      test: ["CMD", "turnutils_stunclient", "-p", "3478", "127.0.0.1"]
      interval: 10s
      timeout: 5s
      retries: 6
      start_period: 10s
    volumes:
      - ./turnserver.conf:/etc/coturn/turnserver.conf:ro,Z
TURN_COMPOSE
  chmod 0600 "$deploy/docker-compose.turn.yml"
  docker compose --env-file "$ENV_FILE" -f "$deploy/docker-compose.production.yml" \
    -f "$deploy/docker-compose.turn.yml" up -d --wait --wait-timeout 90 turn

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    ufw allow 3478/tcp >/dev/null
    ufw allow 3478/udp >/dev/null
    ufw allow 49160:49200/udp >/dev/null
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port=3478/tcp >/dev/null
    firewall-cmd --permanent --add-port=3478/udp >/dev/null
    firewall-cmd --permanent --add-port=49160-49200/udp >/dev/null
    firewall-cmd --reload >/dev/null
  fi

  set_env_value "$ENV_FILE" LOOM_TURN_URLS "turn:$DOMAIN:3478?transport=udp,turn:$DOMAIN:3478?transport=tcp"
  set_env_value "$ENV_FILE" LOOM_STUN_URLS "stun:$DOMAIN:3478"
  set_env_value "$ENV_FILE" LOOM_TURN_SHARED_SECRET "$secret"
  set_env_value "$ENV_FILE" LOOM_CALLS_ENABLED "true"
  set_env_value "$ENV_FILE" LOOM_VOICE_CALLS_ENABLED "true"
  set_env_value "$ENV_FILE" LOOM_VIDEO_CALLS_ENABLED "$([[ "$VIDEO" == yes ]] && echo true || echo false)"
  set_env_value "$ENV_FILE" LOOM_TURN_MANAGED_LOCAL "true"

  printf '%bLocal TURN started%b\n' "$GREEN$BOLD" "$RESET"
  printf '  %-18s %s\n' 'TURN' "turn:$DOMAIN:3478 (UDP/TCP)"
  printf '  %-18s %s\n' 'STUN' "stun:$DOMAIN:3478"
  printf '  %-18s %s\n' 'Relay ports' '49160-49200/udp'
  printf '%bThe shared secret was generated/preserved automatically and is not printed.%b\n' "$DIM" "$RESET"
  printf '%bIf your VPS provider has a separate cloud firewall, allow 3478/tcp+udp and 49160-49200/udp there too.%b\n' "$YELLOW" "$RESET"
}

disable_calls() {
  [[ -f "$ENV_FILE" ]] || return 0
  set_env_value "$ENV_FILE" LOOM_CALLS_ENABLED "false"
  set_env_value "$ENV_FILE" LOOM_VOICE_CALLS_ENABLED "false"
  set_env_value "$ENV_FILE" LOOM_VIDEO_CALLS_ENABLED "false"
  # Keep the ownership marker and secret for a future re-enable.
}

if [[ -f "$ENV_FILE" ]]; then
  EXISTING_INSTALL=1
  if [[ $GO_MIRROR_SET -eq 0 ]]; then GO_MIRROR="$(read_env_value "$ENV_FILE" LOOM_GO_MIRROR)"; GO_MIRROR="${GO_MIRROR:-profile}"; fi
  if [[ $TLS_SET -eq 0 ]]; then TLS_MODE="$(read_env_value "$ENV_FILE" LOOM_TLS_MODE)"; TLS_MODE="${TLS_MODE:-public}"; fi
  if [[ $DOWNLOAD_SET -eq 0 ]]; then DOWNLOAD_PROFILE="$(read_env_value "$ENV_FILE" LOOM_DOWNLOAD_PROFILE)"; DOWNLOAD_PROFILE="${DOWNLOAD_PROFILE:-official}"; fi
  load_existing_default "$DOMAIN_SET" DOMAIN LOOM_PUBLIC_DOMAIN
  load_existing_default "$OPERATOR_SET" OPERATOR_NAME LOOM_OPERATOR_NAME
  load_existing_default "$JURISDICTION_SET" JURISDICTION LOOM_NETWORK_JURISDICTION
  load_existing_default "$REGISTRATION_SET" REGISTRATION LOOM_REGISTRATION_POLICY
  load_existing_default "$FEDERATION_SET" FEDERATION LOOM_FEDERATION_MODE
  load_existing_default "$PROXY_SET" PROXY LOOM_PROXY_MODE
  [[ $GROUP_SET -eq 1 ]] || GROUP_CALLS=keep
  if [[ $VIDEO_SET -eq 0 && "$(read_env_value "$ENV_FILE" LOOM_VIDEO_CALLS_ENABLED)" == false ]]; then VIDEO=no; fi
  if [[ "$TURN_SET" -eq 0 ]]; then
    managed_turn="$(read_env_value "$ENV_FILE" LOOM_TURN_MANAGED_LOCAL)"
    existing_turn_urls="$(read_env_value "$ENV_FILE" LOOM_TURN_URLS)"
    if [[ "$(read_env_value "$ENV_FILE" LOOM_CALLS_ENABLED)" == false ]]; then
      TURN_MODE=off
    elif [[ "$managed_turn" == "true" ]]; then
      TURN_MODE="auto"
    elif [[ -n "$existing_turn_urls" ]]; then
      # Preserve an operator-managed/external TURN service unless auto mode is
      # explicitly selected on a later setup run.
      TURN_MODE="manual"
    fi
  fi
fi

case "$REGISTRATION" in approval|open|closed) ;; *) echo "Invalid registration policy: $REGISTRATION" >&2; exit 2 ;; esac
case "$FEDERATION" in trusted|disabled|open|local|hybrid) ;; *) echo "Invalid federation mode: $FEDERATION" >&2; exit 2 ;; esac
case "$PROXY" in auto|nginx|caddy) ;; *) echo "Invalid proxy mode: $PROXY" >&2; exit 2 ;; esac
case "$TURN_MODE" in auto|manual|off) ;; *) echo "Invalid TURN mode: $TURN_MODE" >&2; exit 2 ;; esac
case "$VIDEO" in yes|no) ;; *) echo 'Invalid video choice' >&2; exit 2 ;; esac
case "$GROUP_CALLS" in on|off|keep) ;; *) echo 'Invalid group calls choice' >&2; exit 2 ;; esac

loom_download_profile "$DOWNLOAD_PROFILE"
loom_go_mirror "$GO_MIRROR"
case "$TLS_MODE" in public|local) ;; *) echo "TLS mode must be public or local" >&2; exit 2 ;; esac
if [[ "$TLS_MODE" == local && $EXISTING_INSTALL -eq 0 && $GROUP_SET -eq 0 ]]; then GROUP_CALLS=off; fi

interactive=0
if [[ $ASSUME_YES -eq 0 ]] && ( : <> /dev/tty ) 2>/dev/null; then
  interactive=1
fi

# These helpers set the destination variable directly. Avoiding command
# substitution keeps /dev/tty attached to the foreground shell on SSH sessions.
prompt_into() {
  local target="$1" label="$2" default="$3" value=""
  if [[ -n "$default" ]]; then
    printf '%b%s%b %b[%s]%b: ' "$CYAN$BOLD" "$label" "$RESET" "$DIM" "$default" "$RESET" >/dev/tty
  else
    printf '%b%s%b %b[optional]%b: ' "$CYAN$BOLD" "$label" "$RESET" "$DIM" "$RESET" >/dev/tty
  fi
  IFS= read -r value </dev/tty || { echo "Setup input closed" >&2; exit 2; }
  [[ -n "$value" ]] || value="$default"
  printf -v "$target" '%s' "$value"
}

# Bash's single-character read keeps terminal state scoped to each read. No
# external UI package, raw-mode trap or downloaded executable is needed.
choice_description() {
  case "$1:$2" in
    'HTTPS mode:public') echo 'Public certificate for an internet domain' ;;
    'HTTPS mode:local') echo 'Offline certificate; import and verify it on clients' ;;
    'Download sources:official') echo 'Upstream registries and configured OS repositories' ;;
    'Download sources:liara') echo 'Iran: Liara Docker, Go, npm and package mirrors' ;;
    'Download sources:arvan') echo 'Iran: Arvan Docker; Liara Go, npm and packages' ;;
    Registration:approval) echo 'Review registration requests' ;;
    Registration:open) echo 'Anyone can create an account' ;;
    Registration:closed) echo 'Existing accounts only' ;;
    Federation:trusted) echo 'Connect to peers you approve' ;;
    Federation:disabled) echo 'Standalone Home Node' ;;
    Federation:open) echo 'Allow verified compatible peers' ;;
    'Voice calls:auto') echo 'Set up the local call relay' ;;
    'Voice calls:manual') echo 'Use a relay you manage' ;;
    'Voice calls:off') echo 'Disable voice and video calls' ;;
    *:yes|*:on) echo 'Enabled' ;;
    *:no|*:off) echo 'Disabled' ;;
    *:keep) echo 'Keep current configuration' ;;
    *:install) echo 'Apply the settings above' ;;
    *:cancel) echo 'Exit without installing' ;;
    *) echo "$2" ;;
  esac
}

terminal_choice_into() {
  local target="$1" label="$2" default="$3" allowed="$4"
  local -a choices
  local selected=0 i key tail lines=0 rows cols rendered
  read -r -a choices <<< "$allowed"
  for i in "${!choices[@]}"; do
    [[ "${choices[i]}" != "$default" ]] || selected=$i
  done
  while true; do
    read -r rows cols < <(stty size </dev/tty) || true
    [[ "${cols:-}" =~ ^[1-9][0-9]*$ ]] || cols=80
    cols=$((cols - 1))
    if (( lines > 0 )); then printf '\033[%sA' "$lines" >/dev/tty; fi
    rendered="$label  (Up/Down, Enter; Esc cancels)"
    printf '\r\033[K%.*s\n' "$cols" "$rendered" >/dev/tty
    for i in "${!choices[@]}"; do
      if (( i == selected )); then
        rendered="  > ${choices[i]} - $(choice_description "$label" "${choices[i]}")"
      else
        rendered="    ${choices[i]} - $(choice_description "$label" "${choices[i]}")"
      fi
      printf '\r\033[K%.*s\n' "$cols" "$rendered" >/dev/tty
    done
    lines=$((${#choices[@]} + 1))
    key=''
    IFS= read -r -s -n 1 key </dev/tty || { echo 'Setup input closed' >&2; exit 2; }
    case "$key" in
      '') printf -v "$target" '%s' "${choices[selected]}"; return ;;
      $'\033')
        tail=''
        IFS= read -r -s -n 2 -t 0.3 tail </dev/tty || true
        case "$tail" in
          '[A'|'OA') selected=$(((selected + ${#choices[@]} - 1) % ${#choices[@]})) ;;
          '[B'|'OB') selected=$(((selected + 1) % ${#choices[@]})) ;;
          '') echo 'Setup cancelled.' >&2; exit 130 ;;
        esac ;;
      k) selected=$(((selected + ${#choices[@]} - 1) % ${#choices[@]})) ;;
      j) selected=$(((selected + 1) % ${#choices[@]})) ;;
      q) echo 'Setup cancelled.' >&2; exit 130 ;;
    esac
  done
}

prompt_choice_into() {
  local target="$1" label="$2" default="$3" allowed="$4" value=""
  if [[ $TEXT_UI -eq 0 && "${TERM:-dumb}" != dumb ]]; then
    terminal_choice_into "$target" "$label" "$default" "$allowed"
    return
  fi
  while true; do
    printf '%b%s%b %b(%s)%b %b[%s]%b: ' "$CYAN$BOLD" "$label" "$RESET" "$DIM" "$allowed" "$RESET" "$DIM" "$default" "$RESET" >/dev/tty
    IFS= read -r value </dev/tty || { echo "Setup input closed" >&2; exit 2; }
    [[ -n "$value" ]] || value="$default"
    case " $allowed " in
      *" $value "*) printf -v "$target" '%s' "$value"; return 0 ;;
    esac
    printf '%bInvalid choice:%b %s\n' "$RED" "$RESET" "$value" >/dev/tty
  done
}

prompt_yes_no() {
  local label="$1" default="$2" answer="" suffix
  if [[ $TEXT_UI -eq 0 && "${TERM:-dumb}" != dumb ]]; then
    terminal_choice_into answer "$label" install 'install cancel'
    [[ "$answer" == install ]]
    return
  fi
  [[ "$default" == "yes" ]] && suffix="Y/n" || suffix="y/N"
  printf '%b%s%b %b[%s]%b: ' "$CYAN$BOLD" "$label" "$RESET" "$DIM" "$suffix" "$RESET" >/dev/tty
  IFS= read -r answer </dev/tty || return 1
  [[ -n "$answer" ]] || answer="$default"
  case "${answer,,}" in y|yes) return 0 ;; *) return 1 ;; esac
}

logo

if [[ $EXISTING_INSTALL -eq 1 ]]; then
  printf '%bExisting Loom installation detected.%b\n' "$YELLOW$BOLD" "$RESET"
  printf '%bCurrent settings are shown as defaults. Secrets and persistent data will be preserved.%b\n' "$DIM" "$RESET"

fi

if [[ $interactive -eq 1 ]]; then
  printf '%bConfiguration%b\n' "$BOLD" "$RESET"
  printf '%bType your domain. Use Up/Down and Enter for the remaining choices. Use --text for line prompts.%b\n\n' "$DIM" "$RESET"

  if [[ $DOWNLOAD_SET -eq 0 ]]; then
    printf '\nChoose download sources. This does not change Docker or repository settings for other applications.\n'
    prompt_choice_into DOWNLOAD_PROFILE "Download sources" "$DOWNLOAD_PROFILE" 'official liara arvan'
    loom_download_profile "$DOWNLOAD_PROFILE"
    loom_go_mirror "$GO_MIRROR"
  fi

  if [[ $TLS_SET -eq 0 ]]; then
    prompt_choice_into TLS_MODE "HTTPS mode" "$TLS_MODE" 'public local'
  fi
  if [[ "$TLS_MODE" == local && $EXISTING_INSTALL -eq 0 && $GROUP_SET -eq 0 ]]; then GROUP_CALLS=off; fi
  if [[ $DOMAIN_SET -eq 0 ]]; then
    while true; do
      prompt_into DOMAIN "Server hostname or IPv4" "${DOMAIN:-chat.example.com}"
      if normalize_domain; then
        break
      fi
      printf '%bEnter a real DNS hostname, for example chat.example.org.%b\n' "$RED" "$RESET" >/dev/tty
    done
  fi

  printf '\nChoose who can use this Home Node. Approval lets you review requests in Loom.\n'
  prompt_choice_into REGISTRATION "Registration" "$REGISTRATION" "approval open closed"
  printf '\nFederation connects verified Loom nodes. Trusted mode needs you to approve peers.\n'
  prompt_choice_into FEDERATION "Federation" "$FEDERATION" "trusted disabled open"
  printf '\nCalls need live connectivity. Auto installs a local TURN relay; off disables calls.\n'
  prompt_choice_into TURN_MODE "Voice calls" "$TURN_MODE" "auto manual off"
  if [[ "$TURN_MODE" != off ]]; then
    prompt_choice_into VIDEO "Video calls" "$VIDEO" "yes no"
    prompt_choice_into GROUP_CALLS "Group calls (installs media service)" "$GROUP_CALLS" "on off keep"
  else
    GROUP_CALLS=off
  fi
fi

if [[ -z "$DOMAIN" ]]; then
  echo "--domain is required when setup is non-interactive." >&2
  exit 2
fi
if ! normalize_domain; then
  echo "Invalid public domain: $DOMAIN" >&2
  exit 2
fi

if [[ "$TURN_MODE" == off ]]; then
  VIDEO=no
  [[ $GROUP_SET -eq 1 ]] || GROUP_CALLS=off
fi
if [[ "$GROUP_CALLS" == on && ( "$TURN_MODE" == off || $START_NOW -eq 0 ) ]]; then
  echo 'Group-call provisioning requires calls and a running Node.' >&2; exit 2
fi

if [[ "$TLS_MODE" == local ]]; then
  [[ "$PROXY" != caddy ]] || { echo 'Local certificates use the Nginx proxy; select auto or nginx.' >&2; exit 2; }
  PROXY=nginx
fi
printf '\n%bReady to %s%b\n' "$BOLD" "$([[ $EXISTING_INSTALL -eq 1 ]] && echo reconfigure || echo install)" "$RESET"
printf '  %-18s %s\n' 'Download sources' "$DOWNLOAD_PROFILE"
printf '  %-18s %s\n' 'Go mirror' "$GO_MIRROR"
printf '  %-18s %s\n' 'Go proxy' "$LOOM_GO_PROXY"
printf '  %-18s %s\n' 'Domain' "$DOMAIN"
printf '  %-18s %s\n' 'Operator' "$OPERATOR_NAME"
printf '  %-18s %s\n' 'Jurisdiction' "$JURISDICTION"
printf '  %-18s %s\n' 'Registration' "$REGISTRATION"
printf '  %-18s %s\n' 'Federation' "$FEDERATION"
printf '  %-18s %s\n' 'HTTPS proxy' "$PROXY"
printf '  %-18s %s\n' 'HTTPS mode' "$TLS_MODE"
printf '  %-18s %s\n' 'Voice/video TURN' "$TURN_MODE"
printf '  %-18s %s\n' 'Video calls' "$VIDEO"
printf '  %-18s %s\n' 'Group calls' "$GROUP_CALLS"
printf '  %-18s %s\n' 'Start now' "$([[ $START_NOW -eq 1 ]] && echo yes || echo no)"
printf '  %-18s %s\n' 'Install directory' "$INSTALL_DIR"
printf '\n'

[[ $PLAN -eq 0 ]] || { echo 'Preview only. Nothing was changed.'; exit 0; }
if [[ $ASSUME_YES -eq 0 ]]; then
  if [[ $interactive -eq 0 ]]; then
    echo "Use --yes to confirm a non-interactive setup." >&2
    exit 2
  fi
  if ! prompt_yes_no "Continue with this setup?" "yes"; then
    printf '%bSetup cancelled. Nothing was changed.%b\n' "$YELLOW" "$RESET"
    exit 0
  fi
fi

args=(
  --tls "$TLS_MODE"
  --downloads "$DOWNLOAD_PROFILE"
  --go-mirror "$GO_MIRROR"
  --domain "$DOMAIN"
  --operator-name "$OPERATOR_NAME"
  --jurisdiction "$JURISDICTION"
  --registration "$REGISTRATION"
  --federation "$FEDERATION"
  --proxy "$PROXY"
  --no-tui
  --update-source-dir ''
)
[[ -n "$CERTBOT_EMAIL" ]] && args+=(--certbot-email "$CERTBOT_EMAIL")
[[ $START_NOW -eq 0 ]] && args+=(--no-start)

printf '\n%bInstalling Loom Node...%b\n' "$PURPLE$BOLD" "$RESET"
if [[ $CALLS_ONLY -eq 1 ]]; then
  [[ $EXISTING_INSTALL -eq 1 && $START_NOW -eq 1 && "$TURN_MODE" == auto ]] || { echo 'Automatic TURN requires an existing running Node and --turn auto.' >&2; exit 2; }
  loom_require_install_owner "$INSTALL_DIR" || exit 2
else
  bash "$INSTALLER" "${args[@]}"
fi

if [[ -f "$ENV_FILE" ]]; then
  set_env_value "$ENV_FILE" LOOM_OPERATOR_NAME "$OPERATOR_NAME"
  set_env_value "$ENV_FILE" LOOM_NETWORK_JURISDICTION "$JURISDICTION"
  set_env_value "$ENV_FILE" LOOM_REGISTRATION_POLICY "$REGISTRATION"
  set_env_value "$ENV_FILE" LOOM_FEDERATION_MODE "$FEDERATION"
fi

case "$TURN_MODE" in
  auto)
    configure_local_turn
    # Installation stops on any TURN error.
    ;;
  manual)
    if [[ -f "$ENV_FILE" ]]; then
      set_env_value "$ENV_FILE" LOOM_TURN_MANAGED_LOCAL "false"
    fi
    printf '%bTURN left under operator control.%b Use Node Manager → Calls → Configure TURN when ready.\n' "$DIM" "$RESET"
    ;;
  off)
    disable_calls
    if [[ -f "$INSTALL_DIR/deploy/docker-compose.turn.yml" ]]; then
      docker compose --env-file "$ENV_FILE" -f "$INSTALL_DIR/deploy/docker-compose.production.yml" -f "$INSTALL_DIR/deploy/docker-compose.turn.yml" stop turn
    fi
    printf '%bVoice/video calling disabled by setup choice.%b\n' "$DIM" "$RESET"
    ;;
esac

if [[ "$TURN_MODE" != off ]]; then
  set_env_value "$ENV_FILE" LOOM_VIDEO_CALLS_ENABLED "$([[ "$VIDEO" == yes ]] && echo true || echo false)"
fi

if ! bash "$CLI_INSTALLER"; then
  printf '%bNode installed, but the `loom` CLI could not be installed.%b\n' "$YELLOW" "$RESET" >&2
  exit 1
fi

if [[ $START_NOW -eq 1 && -f "$ENV_FILE" ]]; then
  printf '%bApplying Node policy and call configuration...%b\n' "$CYAN" "$RESET"
  compose=(docker compose --env-file "$ENV_FILE" -f "$INSTALL_DIR/deploy/docker-compose.production.yml")
  [[ ! -f "$INSTALL_DIR/deploy/docker-compose.storage-legacy.yml" ]] || compose+=(-f "$INSTALL_DIR/deploy/docker-compose.storage-legacy.yml")
  [[ ! -f "$INSTALL_DIR/deploy/docker-compose.turn.yml" ]] || compose+=(-f "$INSTALL_DIR/deploy/docker-compose.turn.yml")
  [[ ! -f "$INSTALL_DIR/deploy/docker-compose.group-calls.yml" ]] || compose+=(-f "$INSTALL_DIR/deploy/docker-compose.group-calls.yml")
  "${compose[@]}" up -d --no-deps --force-recreate --wait --wait-timeout 120 loom-node
fi

if [[ "$GROUP_CALLS" == off && $START_NOW -eq 0 ]]; then
  set_env_value "$ENV_FILE" LOOM_GROUP_CALLS_ENABLED false
elif [[ "$GROUP_CALLS" != keep ]]; then
  media_args=(--setup-group-calls "$GROUP_CALLS" --group-video="$VIDEO")
  if [[ "$GROUP_CALLS" == on ]]; then
    public_ip="$(curl -4fsS --max-time 10 https://api.ipify.org)"
    media_args+=(--group-public-ip "$public_ip")
    if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -qi '^Status: active'; then
      ufw allow 7881/tcp >/dev/null; ufw allow 50000:50100/udp >/dev/null
    fi
    if command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
      firewall-cmd --permanent --add-port=7881/tcp >/dev/null
      firewall-cmd --permanent --add-port=50000-50100/udp >/dev/null
      firewall-cmd --reload >/dev/null
    fi
  fi
  "$INSTALL_DIR/bin/loom-node-manager" --home "$INSTALL_DIR" "${media_args[@]}"
fi
printf '\nProvider firewall: allow TCP 80/443, plus selected media ports.\n'
[[ "$TURN_MODE" != auto ]] || printf 'TURN: TCP+UDP 3478 and UDP 49160-49200.\n'
[[ "$GROUP_CALLS" != on ]] || printf 'Group media: TCP 7881 and UDP 50000-50100.\n'
printf 'Verify a call between two devices on different networks before inviting users.\n'

printf '\n%b✓ Loom Node is ready%b\n' "$GREEN$BOLD" "$RESET"
printf '  %-18s https://%s\n' 'Public URL' "$DOMAIN"
if [[ "$TLS_MODE" == local ]]; then
  printf '\nLocal HTTPS certificate (public file): %s/deploy/tls-local/fullchain.pem\n' "$INSTALL_DIR"
  openssl x509 -in "$INSTALL_DIR/deploy/tls-local/fullchain.pem" -noout -fingerprint -sha256
  printf 'Transfer only fullchain.pem to your device. Verify this fingerprint before trusting it in Loom.\n'
  printf 'Keep privkey.pem on the server. Native media/calling clients may also need operating-system certificate trust.\n'
fi
printf '\nConnect your phone\n'
printf '  1. Open Loom and choose Find your home server.\n'
printf '  2. Scan the QR on https://%s or enter that address.\n' "$DOMAIN"
printf '  3. Create an identity, or restore your existing recovery backup.\n'
[[ "$REGISTRATION" != approval ]] || printf '  4. Approve the account in Node Manager > Registration.\n'
printf '\nServer commands\n'
printf '  %-18s %s\n' 'Manager' 'loom'
printf '  %-18s %s\n' 'Diagnostics' 'sudo loom doctor'
printf '  %-18s %s\n' 'Updates' 'loom > Updates > Check now / Install update'
printf '  %-18s %s\n' 'Configure again' 'loom setup'
printf '  %-18s %s\n' 'Uninstall' 'loom uninstall'
printf '\n'

if [[ $OPEN_MANAGER -eq 1 && $START_NOW -eq 1 ]]; then
  printf '%bOpening Node Manager...%b\n' "$CYAN" "$RESET"
  exec /usr/local/bin/loom manager </dev/tty >/dev/tty 2>/dev/tty
fi

printf '%bRun `loom` anytime to open Node Manager.%b\n' "$DIM" "$RESET"

