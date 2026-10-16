#!/usr/bin/env python3
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import release

platform, architecture = sys.argv[1:]
if (platform, architecture) not in [('linux', 'amd64'), ('linux', 'arm64'), ('windows', 'amd64')]:
    raise ValueError('Unsupported node build')
root = release.ROOT
out = root / 'dist'; out.mkdir(exist_ok=True)
name = f'Loom-{release.version()["version"]}-node-{platform}-{architecture}-source-bundle'
suffix = '.exe' if platform == 'windows' else ''
manager = out / f'Loom-{release.version()["version"]}-manager-{platform}-{architecture}{suffix}'
env = dict(os.environ, GOOS=platform, GOARCH=architecture, CGO_ENABLED='0')
subprocess.run(['go', 'build', '-mod=readonly', '-trimpath', '-buildvcs=false',
    '-ldflags=-s -w -X main.buildCommit=' + release.git('rev-parse', 'HEAD') +
    ' -X main.buildRepository=0800x/Loom -X main.buildBranch=main', '-o', str(manager), '.'],
    cwd=root / 'tools/loom_node_manager', env=env, check=True)
expected = 'arm64' if architecture == 'arm64' else 'x64'
if release.native_arch(manager.read_bytes()) != expected: raise ValueError('Manager architecture mismatch')
with tempfile.TemporaryDirectory(prefix='loom-bundle-') as temp:
    folder = Path(temp) / name; folder.mkdir()
    server = root / 'services/loom_server'
    shutil.copy2(server / 'package.json', folder)
    for part in ('src', 'deploy', 'scripts'):
        shutil.copytree(server / part, folder / part, ignore=shutil.ignore_patterns('.env', '*.log', 'node_modules'))
    (folder / 'bin').mkdir()
    shutil.copy2(manager, folder / 'bin' / ('loom-node-manager' + suffix))
    for legal in ('LICENSE', 'COPYRIGHT'): shutil.copy2(root / legal, folder)
    (folder / 'BUNDLE.md').write_text('Loom source server bundle with a compiled manager.\nNo Docker images or Node dependencies are included.\nAn online installation needs Docker/Compose, images and dependencies; this is not an offline-image bundle.\n')
    archive = out / name
    shutil.make_archive(str(archive), 'zip' if platform == 'windows' else 'gztar', temp, name)
