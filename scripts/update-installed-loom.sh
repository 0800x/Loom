#!/usr/bin/env bash
# Existing installation only. Pin both Node and TUI to an operator-trusted commit.
set -euo pipefail
revision="${1:-}"
[[ $# -ge 1 && $# -le 4 && "$revision" =~ ^[a-f0-9]{40}$ ]] || { echo 'Usage: update-installed-loom.sh TRUSTED_FULL_COMMIT_SHA [CHECKOUT [REPOSITORY [BRANCH]]]' >&2; exit 2; }
[[ $EUID == 0 ]] || { echo 'Run as root on the existing Node host.' >&2; exit 2; }
export PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root
unset BASH_ENV ENV CDPATH GLOBIGNORE
installation=/opt/loom-node
checkout="${2:-/opt/loom-src}"
repository="${3:-0800x/Loom}"
branch="${4:-main}"
[[ "$checkout" == /* && "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "$branch" =~ ^[A-Za-z0-9_./-]+$ ]] || { echo "Invalid checkout or update channel" >&2; exit 2; }
[[ "$branch" != -* ]] || exit 2
for path in /opt "$installation" "$checkout" "$checkout/.git" "$installation/deploy" "$installation/deploy/.env" "$installation/deploy/docker-compose.production.yml"; do
 [[ -e "$path" && ! -L "$path" && "$(stat -c %u "$path")" == 0 ]] || { echo "Unsafe or missing installation path: $path" >&2; exit 1; }
 mode="$(stat -c %a "$path")"
 (( (8#$mode & 0022) == 0 )) || { echo "Path writable by others: $path" >&2; exit 1; }
done
for command in git docker flock; do command -v "$command" >/dev/null; done
docker info >/dev/null
docker compose version >/dev/null
exec 9>/run/lock/loom-node-update.lock
flock -n 9 || { echo 'Another Node update is running.' >&2; exit 1; }
# Use already fetched, authenticated objects; never switch or reset the checkout.
stage="$(mktemp -d /var/tmp/loom-node-update.XXXXXXXX)"
trap 'rm -rf -- "$stage"' EXIT
trap 'echo "Update not confirmed. Previous code backup: ${backup:-not needed; installed files were not changed yet}" >&2' ERR
chmod 700 "$stage"
cp -a "$checkout/.git" "$stage/git"
git_offline() {
 env -i PATH=/usr/bin:/bin HOME=/nonexistent GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
 git --git-dir="$stage/git" -c core.hooksPath=/dev/null -c core.fsmonitor=false \
 -c credential.helper= -c protocol.file.allow=never -c protocol.ext.allow=never "$@"
}
git_offline fsck --strict
[[ "$(git_offline cat-file commit "$revision" | git_offline hash-object -t commit --stdin)" == "$revision" ]]
git_offline archive --format=tar --output="$stage/source.tar" "$revision"
mkdir "$stage/source"
tar --no-same-owner --no-same-permissions -xf "$stage/source.tar" -C "$stage/source"
server="$stage/source/services/loom_server"
manager="$stage/source/tools/loom_node_manager"
source "$server/scripts/linux/update-metadata.sh"
case "$(uname -m)" in x86_64|amd64) goarch=amd64;; aarch64|arm64) goarch=arm64;; *) echo 'Unsupported architecture' >&2; exit 1;; esac
printf '\nBuilding and testing Node Manager at %s\n' "$revision"
docker run --rm -e CGO_ENABLED=0 -e GOOS=linux -e GOARCH="$goarch" \
 -e LOOM_SOURCE_COMMIT="$revision" -e LOOM_SOURCE_BRANCH="$branch" -e LOOM_SOURCE_REPOSITORY="$repository" -v "$manager:/work" -w /work golang:1.25-alpine \
 sh -c 'set -eu; apk add --no-cache git; go mod tidy; go test ./...; go build -buildvcs=false -mod=mod -trimpath -ldflags="-s -w -X main.buildCommit=$LOOM_SOURCE_COMMIT -X main.buildBranch=$LOOM_SOURCE_BRANCH -X main.buildRepository=$LOOM_SOURCE_REPOSITORY" -o /work/loom-node-manager .'
backup="$(mktemp -d "$installation/update-backup.XXXXXXXX")"
chmod 700 "$backup"
for item in package.json deploy/Dockerfile deploy/.env scripts/linux bin/loom-node-manager .loom-update-state; do
 if [[ -e "$installation/$item" ]]; then mkdir -p "$backup/$(dirname "$item")"; cp -a "$installation/$item" "$backup/$item"; fi
done
printf 'Previous code and manager saved in %s\n' "$backup"
# Keep the existing .env, Compose file, proxies and all persistent volumes.
if [[ -d "$installation/src" ]]; then mv "$installation/src" "$backup/previous-src"; fi
cp -a "$server/src" "$installation/src"
install -m 0644 "$server/package.json" "$installation/package.json"
install -m 0644 "$server/deploy/Dockerfile" "$installation/deploy/Dockerfile"
compose() { docker compose --project-directory "$installation/deploy" --env-file "$installation/deploy/.env" -f "$installation/deploy/docker-compose.production.yml" "$@"; }
compose config --quiet
compose build --build-arg "LOOM_BUILD_COMMIT=$revision" loom-node
compose up -d --no-deps --force-recreate --wait --wait-timeout 120 loom-node
compose exec -T loom-node node -e '
 const actual=require("node:fs").readFileSync("/app/.loom-build-commit","utf8").trim();
 if(actual!==process.argv[1]) process.exit(2);
 fetch("http://127.0.0.1:7483/readyz",{signal:AbortSignal.timeout(5000)})
 .then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1));
' "$revision"
install -d -m 0755 "$installation/bin" "$installation/scripts/linux"
# Atomic rename permits an existing TUI process to finish on its old executable.
loom_install_manager_binary "$manager/loom-node-manager" "$installation/bin/loom-node-manager"
for script in "$server"/scripts/linux/*.sh; do install -m 0755 "$script" "$installation/scripts/linux/$(basename "$script")"; done
printf '%s\n' 'loom-install-v1:/opt/loom-node' > "$installation/.loom-install-owner"
chmod 600 "$installation/.loom-install-owner"
version="$(sed -n 's/^const version = "\([^"]*\)"/\1/p' "$manager/main.go")"
loom_write_update_channel "$installation" "$repository" "$branch" "$checkout"
loom_write_install_state "$installation" "$repository" "$branch" "$checkout" "$revision" "$version"
"$installation/bin/loom-node-manager" --home "$installation" --version
printf '\nNode and TUI updated to %s\nOpen: /opt/loom-node/bin/loom-node-manager --home /opt/loom-node\n' "$revision"
