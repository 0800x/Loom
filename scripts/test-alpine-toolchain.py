#!/usr/bin/env python3
"""Verify the pinned MinIO source builder and that installs never invoke it."""
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent
installer = (ROOT / 'services/loom_server/scripts/linux/install-production.sh').read_text()
storage = (ROOT / 'services/loom_server/deploy/Dockerfile.storage').read_text()
pattern = r'golang:1\.25\.14-alpine3\.23@sha256:[a-f0-9]{64}'
storage_builder = re.search(pattern, storage)
assert storage_builder, 'Pinned MinIO source builder is missing'
assert not re.search(pattern, installer), 'Production installer must not invoke a Go builder container'
assert 'go build' not in installer and 'go mod download' not in installer, 'Target server must not compile production components'
assert 'compose pull' in installer and 'compose up -d --wait' in installer, 'Installer must fetch and run prebuilt images'
assert 'ghcr.io/0800x/loom-node:' in (ROOT/'services/loom_server/deploy/docker-compose.production.yml').read_text()
assert 'ghcr.io/0800x/loom-minio:' in (ROOT/'services/loom_server/deploy/docker-compose.production.yml').read_text()
for name, mirror in [('official', ''), ('liara', 'https://linux-mirror.liara.ir/repository/alpine')]:
    command = r'''
set -eu
version=$(cut -d. -f1,2 /etc/alpine-release)
[ "$version" = 3.23 ]
if [ -n "$LOOM_ALPINE_MIRROR" ]; then
  printf '%s/v%s/main\n%s/v%s/community\n' "$LOOM_ALPINE_MIRROR" "$version" "$LOOM_ALPINE_MIRROR" "$version" > /etc/apk/repositories
fi
apk add --no-cache git curl ca-certificates
go version
git --version
'''
    print('Pinned storage builder package test: '+name+', Alpine 3.23', flush=True)
    subprocess.run(['docker', 'run', '--rm', '-e', 'LOOM_ALPINE_MIRROR='+mirror,
                    storage_builder.group()], check=True, timeout=180)
print('Installer is pull-only; pinned MinIO CI builder and Liara Alpine packages verified')
