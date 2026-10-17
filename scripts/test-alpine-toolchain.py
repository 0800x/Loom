#!/usr/bin/env python3
"""Verify actual pinned builder image and signed APK installation in isolation."""
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent
installer = (ROOT / 'services/loom_server/scripts/linux/install-production.sh').read_text()
storage = (ROOT / 'services/loom_server/deploy/Dockerfile.storage').read_text()
pattern = r'golang:1\.25\.14-alpine3\.23@sha256:[a-f0-9]{64}'
manager_image = re.search(pattern, installer).group()
assert manager_image == re.search(pattern, storage).group(), 'Builders use different toolchains'
assert 'golang:1.25.14-alpine"' not in installer, 'Floating builder image is forbidden'
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
    print('Native signed APK install: '+name+', Alpine 3.23', flush=True)
    subprocess.run(['docker', 'run', '--rm', '-e', 'LOOM_ALPINE_MIRROR='+mirror,
                    manager_image, 'sh', '-ec', command], check=True, timeout=180)
print('Pinned manager/storage builder and Liara Alpine packages verified')
