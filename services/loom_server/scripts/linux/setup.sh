#!/usr/bin/env bash
set -uo pipefail

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
  cat <<'LOGO'
        CCCCCCCCCCCCChhhhhhh                                       tttt          NNNNNNNN        NNNNNNNNUUUUUUUU     UUUUUUUU
     CCC::::::::::::Ch:::::h                                    ttt:::t          N:::::::N       N::::::NU::::::U     U::::::U
   CC:::::::::::::::Ch:::::h                                    t:::::t          N::::::::N      N::::::NU::::::U     U::::::U
  C:::::CCCCCCCC::::Ch:::::h                                    t:::::t          N:::::::::N     N::::::NUU:::::U     U:::::UU
 C:::::C       CCCCCC h::::h hhhhh         aaaaaaaaaaaaa  ttttttt:::::ttttttt    N::::::::::N    N::::::N U:::::U     U:::::U
C:::::C               h::::hh:::::hhh      a::::::::::::a t:::::::::::::::::t    N:::::::::::N   N::::::N U:::::D     D:::::U
C:::::C               h::::::::::::::hh    aaaaaaaaa:::::at:::::::::::::::::t    N:::::::N::::N  N::::::N U:::::D     D:::::U
C:::::C               h:::::::hhh::::::h            a::::atttttt:::::::tttttt    N::::::N N::::N N::::::N U:::::D     D:::::U
C:::::C               h::::::h   h::::::h    aaaaaaa:::::a      t:::::t          N::::::N  N::::N:::::::N U:::::D     D:::::U
C:::::C               h:::::h     h:::::h  aa::::::::::::a      t:::::t          N::::::N   N:::::::::::N U:::::D     D:::::U
C:::::C               h:::::h     h:::::h a::::aaaa::::::a      t:::::t          N::::::N    N::::::::::N U:::::D     D:::::U
 C:::::C       CCCCCC h:::::h     h:::::ha::::a    a:::::a      t:::::t    ttttttN::::::N     N:::::::::N U::::::U   U::::::U
  C:::::CCCCCCCC::::C h:::::h     h:::::ha::::a    a:::::a      t::::::tttt:::::tN::::::N      N::::::::N U:::::::UUU:::::::U
   CC:::::::::::::::C h:::::h     h:::::ha:::::aaaa::::::a      tt::::::::::::::tN::::::N       N:::::::N  UU:::::::::::::UU
     CCC::::::::::::C h:::::h     h:::::h a::::::::::aa:::a       tt:::::::::::ttN::::::N        N::::::N    UU:::::::::UU
        CCCCCCCCCCCCC hhhhhhh     hhhhhhh  aaaaaaaaaa  aaaa         ttttttttttt  NNNNNNNN         NNNNNNN      UUUUUUUUU
LOGO
  printf '%b\n' "$RESET"
  printf '%bLoom Node Setup%b  %bsecure self-hosted messaging%b\n\n' "$BOLD" "$RESET" "$DIM" "$RESET"
}

usage() {
  cat <<'USAGE'
Loom Node setup wizard

Usage:
  setup.sh [options]

Options:
  --domain HOSTNAME
  --operator-name NAME
  --jurisdiction TEXT
  --registration approval|open|closed
  --federation trusted|disabled|open|local|hybrid
  --proxy auto|nginx|caddy
  --certbot-email EMAIL
  --turn auto|manual|off  Local coturn setup (default: auto on new installs)
  --no-start
  --no-manager
  --yes                 Accept the final installation summary
  -h, --help

Run without options for the interactive setup wizard.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; DOMAIN_SET=1; shift 2 ;;
    --operator-name) OPERATOR_NAME="${2:-}"; OPERATOR_SET=1; shift 2 ;;
    --jurisdiction) JURISDICTION="${2:-}"; JURISDICTION_SET=1; shift 2 ;;
    --registration) REGISTRATION="${2:-}"; REGISTRATION_SET=1; shift 2 ;;
    --federation) FEDERATION="${2:-}"; FEDERATION_SET=1; shift 2 ;;
    --proxy) PROXY="${2:-}"; PROXY_SET=1; shift 2 ;;
    --certbot-email) CERTBOT_EMAIL="${2:-}"; shift 2 ;;
    --turn) TURN_MODE="${2:-}"; TURN_SET=1; shift 2 ;;
    --no-start) START_NOW=0; shift ;;
    --no-manager) OPEN_MANAGER=0; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  if ! command -v sudo >/dev/null 2>&1; then
    echo "Loom setup needs root privileges and sudo is unavailable." >&2
    exit 1
  fi
  exec /usr/bin/sudo /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root TERM="${TERM:-xterm}" /bin/bash --noprofile --norc /opt/loom-node/scripts/linux/setup.sh "${ORIGINAL_ARGS[@]}"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$SCRIPT_DIR/install-production.sh"
CLI_INSTALLER="$SCRIPT_DIR/install-cli.sh"
ENV_FILE="$INSTALL_DIR/deploy/.env"
EXISTING_INSTALL=0

[[ -f "$INSTALLER" ]] || { echo "Missing installer: $INSTALLER" >&2; exit 1; }
[[ -f "$CLI_INSTALLER" ]] || { echo "Missing CLI installer: $CLI_INSTALLER" >&2; exit 1; }

read_env_value() {
  local path="$1" key="$2"
  [[ -f "$path" ]] || return 0
  awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$path"
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

load_existing_default() {
  local flag="$1" variable="$2" key="$3" current
  [[ "$flag" -eq 0 && -f "$ENV_FILE" ]] || return 0
  current="$(read_env_value "$ENV_FILE" "$key")"
  [[ -n "$current" ]] && printf -v "$variable" '%s' "$current"
}

normalize_domain() {
  DOMAIN="$(printf '%s' "$DOMAIN" | tr '[:upper:]' '[:lower:]' | xargs)"
  [[ "$DOMAIN" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] \
    && [[ "$DOMAIN" != *".."* ]] \
    && [[ "$DOMAIN" == *.* ]] \
    && [[ "$DOMAIN" != "chat.example.com" ]]
}

valid_turn_secret() {
  local value="${1:-}"
  [[ "$value" =~ ^[A-Za-z0-9._~-]{32,512}$ ]]
}

configure_local_turn() {
  [[ -f "$ENV_FILE" ]] || { echo "Missing Node environment: $ENV_FILE" >&2; return 1; }

  local os_id="" secret public_ip="" external_ip="" tmp=""
  if [[ -r /etc/os-release ]]; then
    os_id="$(. /etc/os-release; printf '%s' "${ID:-}")"
  fi

  if ! command -v turnserver >/dev/null 2>&1; then
    printf '%bInstalling coturn for automatic voice/video relay...%b\n' "$CYAN" "$RESET"
    case "$os_id" in
      ubuntu|debian)
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y coturn openssl
        ;;
      fedora)
        dnf -y install coturn openssl
        ;;
      *)
        echo "Automatic coturn installation currently supports Ubuntu, Debian and Fedora. Use --turn manual on this host." >&2
        return 1
        ;;
    esac
  fi

  secret="$(read_env_value "$ENV_FILE" LOOM_TURN_SHARED_SECRET)"
  # First-time takeover of a manually configured TURN service gets a fresh
  # secret automatically. Later managed setup runs preserve the secret so
  # active short-lived TURN credentials are not invalidated unnecessarily.
  if [[ "$(read_env_value "$ENV_FILE" LOOM_TURN_MANAGED_LOCAL)" != "true" ]] ||
     ! valid_turn_secret "$secret"; then
    secret="$(openssl rand -hex 32)"
  fi

  # When the machine is behind provider NAT, coturn needs its public address.
  # The production installer already depends on curl; never derive this from a
  # proxied DNS record because a CDN address would be wrong for TURN.
  public_ip="$(curl -4fsS --max-time 6 https://api.ipify.org 2>/dev/null || true)"
  if [[ "$public_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && command -v ip >/dev/null 2>&1; then
    if ! ip -o -4 addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$public_ip"; then
      external_ip="$public_ip"
    fi
  fi

  tmp="$(mktemp)"
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
EOF
    [[ -n "$external_ip" ]] && printf 'external-ip=%s\n' "$external_ip"
  } >"$tmp"
  install -m 0640 "$tmp" /etc/turnserver.conf
  rm -f "$tmp"
  if getent group turnserver >/dev/null 2>&1; then
    chown root:turnserver /etc/turnserver.conf
  elif getent group coturn >/dev/null 2>&1; then
    chown root:coturn /etc/turnserver.conf
  fi

  if [[ -f /etc/default/coturn ]]; then
    if grep -Eq '^[#[:space:]]*TURNSERVER_ENABLED=' /etc/default/coturn; then
      sed -i -E 's/^[#[:space:]]*TURNSERVER_ENABLED=.*/TURNSERVER_ENABLED=1/' /etc/default/coturn
    else
      printf '\nTURNSERVER_ENABLED=1\n' >>/etc/default/coturn
    fi
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable coturn >/dev/null
    systemctl restart coturn
    if ! systemctl is-active --quiet coturn; then
      echo "coturn did not become active. Check: journalctl -u coturn --no-pager -n 80" >&2
      return 1
    fi
  else
    service coturn restart
  fi

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
  set_env_value "$ENV_FILE" LOOM_VIDEO_CALLS_ENABLED "true"
  set_env_value "$ENV_FILE" LOOM_TURN_MANAGED_LOCAL "true"

  printf '%b✓ Local TURN configured%b\n' "$GREEN$BOLD" "$RESET"
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
  set_env_value "$ENV_FILE" LOOM_TURN_MANAGED_LOCAL "false"
}

if [[ -f "$ENV_FILE" ]]; then
  EXISTING_INSTALL=1
  load_existing_default "$DOMAIN_SET" DOMAIN LOOM_PUBLIC_DOMAIN
  load_existing_default "$OPERATOR_SET" OPERATOR_NAME LOOM_OPERATOR_NAME
  load_existing_default "$JURISDICTION_SET" JURISDICTION LOOM_NETWORK_JURISDICTION
  load_existing_default "$REGISTRATION_SET" REGISTRATION LOOM_REGISTRATION_POLICY
  load_existing_default "$FEDERATION_SET" FEDERATION LOOM_FEDERATION_MODE
  load_existing_default "$PROXY_SET" PROXY LOOM_PROXY_MODE
  if [[ "$TURN_SET" -eq 0 ]]; then
    managed_turn="$(read_env_value "$ENV_FILE" LOOM_TURN_MANAGED_LOCAL)"
    existing_turn_urls="$(read_env_value "$ENV_FILE" LOOM_TURN_URLS)"
    if [[ "$managed_turn" == "true" ]]; then
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

interactive=0
if [[ -r /dev/tty && -w /dev/tty && $ASSUME_YES -eq 0 ]]; then
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
  IFS= read -r value </dev/tty || value=""
  [[ -n "$value" ]] || value="$default"
  printf -v "$target" '%s' "$value"
}

prompt_choice_into() {
  local target="$1" label="$2" default="$3" allowed="$4" value=""
  while true; do
    printf '%b%s%b %b(%s)%b %b[%s]%b: ' "$CYAN$BOLD" "$label" "$RESET" "$DIM" "$allowed" "$RESET" "$DIM" "$default" "$RESET" >/dev/tty
    IFS= read -r value </dev/tty || value=""
    [[ -n "$value" ]] || value="$default"
    case " $allowed " in
      *" $value "*) printf -v "$target" '%s' "$value"; return 0 ;;
    esac
    printf '%bInvalid choice:%b %s\n' "$RED" "$RESET" "$value" >/dev/tty
  done
}

prompt_yes_no() {
  local label="$1" default="$2" answer="" suffix
  [[ "$default" == "yes" ]] && suffix="Y/n" || suffix="y/N"
  printf '%b%s%b %b[%s]%b: ' "$CYAN$BOLD" "$label" "$RESET" "$DIM" "$suffix" "$RESET" >/dev/tty
  IFS= read -r answer </dev/tty || answer=""
  [[ -n "$answer" ]] || answer="$default"
  case "${answer,,}" in y|yes) return 0 ;; *) return 1 ;; esac
}

logo

if [[ $EXISTING_INSTALL -eq 1 ]]; then
  printf '%bExisting Loom installation detected.%b\n' "$YELLOW$BOLD" "$RESET"
  printf '%bCurrent settings are shown as defaults. Secrets and persistent data will be preserved.%b\n' "$DIM" "$RESET"
  printf '%bFor a clean-room reinstall, run: loom uninstall --purge-all --yes%b\n\n' "$DIM" "$RESET"
fi

if [[ $interactive -eq 1 ]]; then
  printf '%bConfiguration%b\n' "$BOLD" "$RESET"
  printf '%bPress Enter to accept the value shown in brackets.%b\n\n' "$DIM" "$RESET"

  if [[ $DOMAIN_SET -eq 0 ]]; then
    while true; do
      prompt_into DOMAIN "Public domain" "${DOMAIN:-chat.example.com}"
      if normalize_domain; then
        break
      fi
      printf '%bEnter a real DNS hostname, for example chat.example.org.%b\n' "$RED" "$RESET" >/dev/tty
    done
  fi

  prompt_into OPERATOR_NAME "Operator name" "$OPERATOR_NAME"
  prompt_into JURISDICTION "Network jurisdiction" "$JURISDICTION"
  prompt_choice_into REGISTRATION "Registration policy" "$REGISTRATION" "approval open closed"
  prompt_choice_into FEDERATION "Federation mode" "$FEDERATION" "trusted disabled open local hybrid"
  prompt_choice_into PROXY "HTTPS proxy" "$PROXY" "auto nginx caddy"
  prompt_choice_into TURN_MODE "Voice/video TURN" "$TURN_MODE" "auto manual off"

  if [[ "$PROXY" == "nginx" || "$PROXY" == "auto" ]]; then
    prompt_into CERTBOT_EMAIL "Let's Encrypt email" "$CERTBOT_EMAIL"
  fi

  if prompt_yes_no "Start the Node after setup?" "yes"; then START_NOW=1; else START_NOW=0; fi
  if [[ $START_NOW -eq 1 ]]; then
    if prompt_yes_no "Open Node Manager when setup finishes?" "yes"; then OPEN_MANAGER=1; else OPEN_MANAGER=0; fi
  else
    OPEN_MANAGER=0
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

printf '\n%bReady to %s%b\n' "$BOLD" "$([[ $EXISTING_INSTALL -eq 1 ]] && echo reconfigure || echo install)" "$RESET"
printf '  %-18s %s\n' 'Domain' "$DOMAIN"
printf '  %-18s %s\n' 'Operator' "$OPERATOR_NAME"
printf '  %-18s %s\n' 'Jurisdiction' "$JURISDICTION"
printf '  %-18s %s\n' 'Registration' "$REGISTRATION"
printf '  %-18s %s\n' 'Federation' "$FEDERATION"
printf '  %-18s %s\n' 'HTTPS proxy' "$PROXY"
printf '  %-18s %s\n' "Let's Encrypt" "${CERTBOT_EMAIL:-automatic/no email}"
printf '  %-18s %s\n' 'Voice/video TURN' "$TURN_MODE"
printf '  %-18s %s\n' 'Start now' "$([[ $START_NOW -eq 1 ]] && echo yes || echo no)"
printf '  %-18s %s\n' 'Install directory' "$INSTALL_DIR"
printf '\n'

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
  --domain "$DOMAIN"
  --operator-name "$OPERATOR_NAME"
  --jurisdiction "$JURISDICTION"
  --registration "$REGISTRATION"
  --federation "$FEDERATION"
  --proxy "$PROXY"
  --no-tui
)
[[ -n "$CERTBOT_EMAIL" ]] && args+=(--certbot-email "$CERTBOT_EMAIL")
[[ $START_NOW -eq 0 ]] && args+=(--no-start)

printf '\n%bInstalling Loom Node...%b\n' "$PURPLE$BOLD" "$RESET"
if ! bash "$INSTALLER" "${args[@]}"; then
  printf '\n%bSetup failed.%b Review the error above; persistent data was not intentionally removed.\n' "$RED$BOLD" "$RESET" >&2
  exit 1
fi

if [[ -f "$ENV_FILE" ]]; then
  set_env_value "$ENV_FILE" LOOM_OPERATOR_NAME "$OPERATOR_NAME"
  set_env_value "$ENV_FILE" LOOM_NETWORK_JURISDICTION "$JURISDICTION"
  set_env_value "$ENV_FILE" LOOM_REGISTRATION_POLICY "$REGISTRATION"
  set_env_value "$ENV_FILE" LOOM_FEDERATION_MODE "$FEDERATION"
fi

case "$TURN_MODE" in
  auto)
    if ! configure_local_turn; then
      printf '%bAutomatic TURN setup failed.%b The Node installation is intact; rerun with --turn manual to keep an external TURN configuration.\n' "$RED$BOLD" "$RESET" >&2
      exit 1
    fi
    ;;
  manual)
    if [[ -f "$ENV_FILE" ]]; then
      set_env_value "$ENV_FILE" LOOM_TURN_MANAGED_LOCAL "false"
    fi
    printf '%bTURN left under operator control.%b Use Node Manager → Calls → Configure TURN when ready.\n' "$DIM" "$RESET"
    ;;
  off)
    disable_calls
    printf '%bVoice/video calling disabled by setup choice.%b\n' "$DIM" "$RESET"
    ;;
esac

if ! bash "$CLI_INSTALLER"; then
  printf '%bNode installed, but the `loom` CLI could not be installed.%b\n' "$YELLOW" "$RESET" >&2
  exit 1
fi

if [[ $START_NOW -eq 1 && -f "$ENV_FILE" ]]; then
  printf '%bApplying Node policy and call configuration...%b\n' "$CYAN" "$RESET"
  compose=(docker compose --env-file "$ENV_FILE" -f "$INSTALL_DIR/deploy/docker-compose.production.yml")
  "${compose[@]}" up -d --force-recreate loom-node
fi

printf '\n%b✓ Loom Node is ready%b\n' "$GREEN$BOLD" "$RESET"
printf '  %-18s https://%s\n' 'Public URL' "$DOMAIN"
printf '  %-18s %s\n' 'Manager' 'loom'
printf '  %-18s %s\n' 'Configure again' 'loom setup'
printf '  %-18s %s\n' 'Uninstall' 'loom uninstall'
printf '\n'

if [[ $OPEN_MANAGER -eq 1 && $START_NOW -eq 1 ]]; then
  printf '%bOpening Node Manager...%b\n' "$CYAN" "$RESET"
  exec /usr/local/bin/loom manager
fi

printf '%bRun `loom` anytime to open Node Manager.%b\n' "$DIM" "$RESET"

