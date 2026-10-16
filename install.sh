#!/usr/bin/env bash
set -euo pipefail

# Loom public bootstrap installer.
# Public usage:
#   curl -fsSL https://raw.githubusercontent.com/0800x/Loom/main/install.sh | sudo bash
#
# Pass setup options through stdin execution when desired:
#   curl -fsSL https://raw.githubusercontent.com/0800x/Loom/main/install.sh | sudo bash -s -- --domain chat.example.com
#
# Advanced/test overrides:
#   LOOM_INSTALL_REF=<branch-or-tag>
#   LOOM_REPO_URL=<git-url>
#   LOOM_SOURCE_DIR=<path>

REPO_URL="${LOOM_REPO_URL:-https://github.com/0800x/Loom.git}"
INSTALL_REF="${LOOM_INSTALL_REF:-main}"
SOURCE_DIR="${LOOM_SOURCE_DIR:-/opt/loom-src}"
SETUP_ARGS=("$@")

fail() {
  printf '\nLoom installer: %s\n' "$*" >&2
  exit 1
}

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  cat >&2 <<'EOF'
Loom installation needs root privileges.

Run the one-line installer with sudo, for example:
  curl -fsSL https://raw.githubusercontent.com/0800x/Loom/main/install.sh | sudo bash
EOF
  exit 1
fi

install_prerequisites() {
  if command -v git >/dev/null 2>&1; then
    return 0
  fi

  printf 'Preparing this server...\n'
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y git ca-certificates curl
  elif command -v dnf >/dev/null 2>&1; then
    dnf -y install git ca-certificates curl
  else
    fail "Git could not be installed automatically. Install git + CA certificates, then rerun."
  fi
}

normalize_origin() {
  local value="$1"
  value="${value%.git}"
  case "$value" in
    git@github.com:*) value="https://github.com/${value#git@github.com:}" ;;
    ssh://git@github.com/*) value="https://github.com/${value#ssh://git@github.com/}" ;;
  esac
  printf '%s' "$value"
}

archive_stale_source() {
  local reason="$1" stamp backup
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  backup="${SOURCE_DIR}.previous-${stamp}-$$"
  printf 'Existing source checkout is %s.\n' "$reason"
  printf 'Preserving it at: %s\n' "$backup"
  mv "$SOURCE_DIR" "$backup"
}

clone_source() {
  install -d -m 0755 "$(dirname "$SOURCE_DIR")"
  printf 'Downloading Loom...\n'
  git clone --depth 1 --branch "$INSTALL_REF" "$REPO_URL" "$SOURCE_DIR"
}

install_prerequisites

printf '\nLoom Node Installer\n'
printf '  Source: %s\n' "$REPO_URL"
printf '  Ref:    %s\n' "$INSTALL_REF"
printf '  Path:   %s\n\n' "$SOURCE_DIR"

# Fail before touching the destination if the requested branch/tag cannot be read.
if ! git ls-remote --exit-code --heads --tags "$REPO_URL" "$INSTALL_REF" >/dev/null 2>&1; then
  fail "Cannot read branch/tag '$INSTALL_REF' from $REPO_URL. Check network/repository access."
fi

if [[ -e "$SOURCE_DIR" && ! -d "$SOURCE_DIR/.git" ]]; then
  if [[ -d "$SOURCE_DIR" && -z "$(find "$SOURCE_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    rmdir "$SOURCE_DIR"
  else
    fail "$SOURCE_DIR exists but is not a Loom Git checkout; refusing to overwrite unrelated files."
  fi
fi

if [[ -d "$SOURCE_DIR/.git" ]]; then
  current_origin="$(git -C "$SOURCE_DIR" remote get-url origin 2>/dev/null || true)"
  [[ -n "$current_origin" ]] || fail "$SOURCE_DIR has no Git origin."

  if [[ "$(normalize_origin "$current_origin")" != "$(normalize_origin "$REPO_URL")" ]]; then
    fail "$SOURCE_DIR belongs to a different repository ($current_origin); refusing to overwrite it."
  fi

  if [[ -n "$(git -C "$SOURCE_DIR" status --porcelain)" ]]; then
    # /opt/loom-src is installer-managed source, not persistent Node data.
    # Preserve unexpected local edits instead of deleting them, then continue
    # with a clean checkout so the one-line installation remains reliable.
    archive_stale_source "modified"
    clone_source
  else
    printf 'Updating Loom source...\n'
    if git -C "$SOURCE_DIR" fetch --depth=1 origin "$INSTALL_REF" && \
       git -C "$SOURCE_DIR" checkout --detach FETCH_HEAD; then
      :
    else
      archive_stale_source "stale"
      clone_source
    fi
  fi
else
  clone_source
fi

[[ -f "$SOURCE_DIR/setup.sh" ]] || fail "Downloaded source does not contain setup.sh."

commit="$(git -C "$SOURCE_DIR" rev-parse --short=12 HEAD)"
printf 'Source ready: %s\n' "$commit"
printf 'Opening guided setup...\n\n'

exec bash "$SOURCE_DIR/setup.sh" "${SETUP_ARGS[@]}"
