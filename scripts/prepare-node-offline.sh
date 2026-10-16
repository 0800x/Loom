#!/usr/bin/env bash
# Prepare on a trusted, connected Linux workstation matching the target CPU.
# Does not install anything or copy production configuration/data.
set -euo pipefail
revision="${1:-}"
output="${2:-}"
[[ $# == 2 && "$revision" =~ ^[a-f0-9]{40}$ && -n "$output" ]] || { echo 'Usage: prepare-node-offline.sh TRUSTED_FULL_COMMIT_SHA NEW_OUTPUT_DIRECTORY' >&2; exit 2; }
for command in git docker go sha256sum; do command -v "$command" >/dev/null; done
docker info >/dev/null
root="$(git rev-parse --show-toplevel)"
git -C "$root" cat-file -e "$revision^{commit}"
[[ "$(git -C "$root" cat-file commit "$revision" | git hash-object -t commit --stdin)" == "$revision" ]]
[[ ! -e "$output" ]] || { echo 'Output already exists; choose a new directory.' >&2; exit 2; }
mkdir -m 700 -p "$output"
output="$(cd "$output" && pwd)"
stage="$(mktemp -d)"
trap 'rm -rf -- "$stage"' EXIT
git -C "$root" archive "$revision" | tar -x -C "$stage"
server="$stage/services/loom_server"
cp -a "$server" "$output/server"
for notice in LICENSE COPYRIGHT THIRD_PARTY_NOTICES.md; do
 if [[ -f "$stage/$notice" ]]; then cp "$stage/$notice" "$output/"; fi
done
# Archive contains checked-in files only. Never archive a live installation.
mkdir "$output/bin"
(cd "$stage/tools/loom_node_manager"; CGO_ENABLED=0 GOOS=linux go build -buildvcs=false -trimpath -ldflags="-s -w -X main.buildCommit=$revision" -o "$output/bin/loom-node-manager" .)
image="loom-node-offline:$revision"
docker build --build-arg "LOOM_BUILD_COMMIT=$revision" -t "$image" -f "$server/deploy/Dockerfile" "$server"
images=("$image" postgres:17-alpine minio/minio:latest minio/mc:latest caddy:2-alpine)
for image in "${images[@]:1}"; do docker pull "$image"; done
docker save -o "$output/images.tar" "${images[@]}"
printf '%s\n' "commit=$revision" "architecture=$(uname -m)" > "$output/build-info.txt"
docker image inspect --format '{{.Id}} {{json .RepoTags}} {{json .RepoDigests}}' "${images[@]}" > "$output/image-inventory.txt"
printf 'services:\n  loom-node:\n    image: loom-node-offline:%s\n' "$revision" > "$output/offline-image.yml"
(cd "$output"; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
printf 'Prepared %s\nVerify SHA256SUMS and transfer its digest through an authenticated channel.\n' "$output"
