#!/usr/bin/env bash
# No host mutations occur when this file is sourced.
loom_guard_persistent_install() {
  local env_file="$1" containers volumes
  [[ ! -L "$env_file" ]] || { echo 'Refusing a symlinked Node environment.' >&2; return 1; }
  [[ ! -f "$env_file" ]] || return 0
  containers="$(docker ps -aq --filter label=org.loom.installation=/opt/loom-node)" || return 1
  volumes="$(docker volume ls -q --filter label=org.loom.installation=/opt/loom-node)" || return 1
  # Also recognise retained volumes from older, unlabelled Compose bundles.
  if [[ -z "$volumes" ]]; then
    volumes="$(docker volume ls --format '{{.Name}}' | awk '/^loom_(loom-postgres|loom-objects|loom-node-data|postgres-data|node-data)$/')" || return 1
  fi
  if [[ -n "$containers$volumes" ]]; then
    echo 'Existing Loom containers or persistent volumes were found, but deploy/.env is missing.' >&2
    echo 'Restore the original configuration from your private backup before installing.' >&2
    echo 'No replacement credentials or identity will be generated; no volumes were removed.' >&2
    return 1
  fi
}

loom_write_release_approval() {
  local home="$1" revision="$2" digest="$3" directory="${4:-/etc/loom}" ledger policy temporary manual=0
  [[ "$revision" =~ ^[a-f0-9]{40}$ && "$digest" =~ ^[a-f0-9]{64}$ ]] || return 1
  [[ ! -L "$directory" ]] || return 1
  if [[ -e "$directory" ]]; then loom_require_root_owned "$directory" || return 1; else install -d -m 0700 "$directory"; fi
  ledger="$directory/approved-releases"; policy="$directory/update-policy"
  if [[ -e "$ledger" || -L "$ledger" ]]; then
    loom_require_root_owned "$ledger" && [[ -f "$ledger" && ! -L "$ledger" ]] || return 1
    [[ -e "$policy" ]] || manual=1
    if awk -v revision="$revision" -v digest="$digest" '$1=="0800x/Loom" && $2==revision && $3!=digest {bad=1} END {exit !bad}' "$ledger"; then
      echo 'An existing approval disagrees with the verified source digest.' >&2; return 1
    fi
  fi
  temporary="$(mktemp "$directory/.approved.XXXXXXXX")" || return 1
  chmod 0600 "$temporary"
  if [[ -f "$ledger" ]]; then cat "$ledger" > "$temporary"; fi
  if ! awk -v revision="$revision" -v digest="$digest" '$1=="0800x/Loom" && $2==revision && $3==digest {found=1} END {exit !found}' "$temporary"; then
    printf '0800x/Loom %s %s\n' "$revision" "$digest" >> "$temporary"
  fi
  mv -f -- "$temporary" "$ledger"
  if [[ ! -e "$policy" && ! -L "$policy" && $manual -eq 0 ]]; then
    temporary="$(mktemp "$directory/.policy.XXXXXXXX")"
    printf 'publisher\n' > "$temporary"; chmod 0600 "$temporary"; mv -f "$temporary" "$policy"
  fi
  # Existing manual policies are deliberately retained.
}

loom_classify_startup_failure() {
  local logs="$1"
  case "$logs" in
    *'password authentication failed'*|*'28P01'*) echo 'PostgreSQL rejected the saved credentials. Restore the original deploy/.env from backup; retained database volumes must use their original credentials.' ;;
    *'Invalid persisted Node identity'*) echo 'The persisted Node identity is invalid. Restore its identity backup; do not regenerate it.' ;;
    *'EACCES'*|*'permission denied'*) echo 'The Node cannot access a required file or volume. Check persistent-data ownership and permissions; do not replace identity files.' ;;
    *'Invalid production credential'*|*'production storage configuration is incomplete'*) echo 'Production configuration is incomplete or contains an invalid credential. Restore the matching configuration backup.' ;;
    *'AccessDenied'*|*'InvalidAccessKeyId'*|*'SignatureDoesNotMatch'*) echo 'Attachment storage rejected its credentials. Restore the matching storage configuration.' ;;
    *'ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX'*|*'ERR_MODULE_NOT_FOUND'*) echo 'The installed Node image cannot load its server modules. Use a verified repaired source build.' ;;
    *) echo 'Node startup failed. Open Logs in the manager to inspect the service; no credentials or identity have been replaced.' ;;
  esac
}

loom_preserve_storage_image() {
  local home="$1" id image temporary
  [[ -f "$home/deploy/.env" && ! -f "$home/deploy/docker-compose.storage-legacy.yml" ]] || return 0
  id="$(docker ps -aq --filter label=com.docker.compose.project=loom --filter label=com.docker.compose.service=minio)" || return 1
  [[ -n "$id" ]] || return 0
  [[ "$id" != *$'\n'* ]] || { echo 'Multiple MinIO containers found; inspect storage before updating.' >&2; return 1; }
  image="$(docker inspect --format '{{.Image}}' "$id")" || return 1
  [[ "$image" =~ ^sha256:[a-f0-9]{64}$ ]] || return 1
  temporary="$(mktemp "$home/deploy/.storage-legacy.XXXXXXXX")" || return 1
  # Keep the existing binary; source builds must not silently migrate its data format.
  printf 'services:\n  minio:\n    build: !reset null\n    image: %s\n    pull_policy: never\n' "$image" > "$temporary"
  chmod 0600 "$temporary"
  mv -f "$temporary" "$home/deploy/docker-compose.storage-legacy.yml"
}

loom_require_compose_version() {
  local version
  version="$(docker compose version --short)" || return 1
  version="${version#v}"
  if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || [[ "$(printf '%s\n' 2.24.4 "$version" | sort -V | head -n1)" != 2.24.4 ]]; then
    echo 'Docker Compose 2.24.4 or newer is required. Upgrade the Compose plugin before continuing.' >&2
    return 1
  fi
}

loom_backup_retained_configuration() {
  local home="$1" root="${2:-/opt/loom-backups}" backup file
  [[ -f "$home/deploy/.env" && ! -L "$home/deploy/.env" ]] || {
    echo 'The original configuration is missing; retained data cannot be safely reinstalled without it.' >&2; return 1;
  }
  loom_require_root_owned "$home/deploy/.env" || return 1
  if [[ -e "$root" || -L "$root" ]]; then
    loom_require_root_owned "$root" && loom_require_root_owned "$root/.loom-backup-owner" &&
      [[ "$(cat "$root/.loom-backup-owner")" == loom-backup-v1 ]] || { echo 'Backup directory is not owned by this installation.' >&2; return 1; }
  else
    install -d -m 0700 "$root"
    printf 'loom-backup-v1\n' > "$root/.loom-backup-owner"; chmod 0600 "$root/.loom-backup-owner"
  fi
  backup="$(mktemp -d "$root/config-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXXXX")" || return 1
  chmod 0700 "$backup"; install -d -m 0700 "$backup/deploy"
  for file in deploy/tls-local/fullchain.pem deploy/tls-local/privkey.pem deploy/.env deploy/livekit.yaml deploy/turnserver.conf deploy/docker-compose.group-calls.yml deploy/docker-compose.turn.yml deploy/docker-compose.storage-legacy.yml .loom-source-sha256 .loom-verified-source .loom-update-state .loom-publisher-state .loom-update-token; do
    if [[ -e "$home/$file" || -L "$home/$file" ]]; then
      loom_require_root_owned "$home/$file" && [[ -f "$home/$file" && ! -L "$home/$file" ]] || return 1
      install -d -m 0700 "$(dirname -- "$backup/$file")"
      install -m 0600 "$home/$file" "$backup/$file" || return 1
    fi
  done
  printf 'Private reinstall configuration saved: %s\n' "$backup"
}
