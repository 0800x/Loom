#!/usr/bin/env python3
"""Require all platform manifests; verify hashes; reject debug Android on tags."""
import json
from pathlib import Path
import sys
import release

root = Path(sys.argv[1])
engineering = '--engineering' in sys.argv[2:]
expected = {('android', 'armeabi-v7a,arm64-v8a,x86_64'), ('linux', 'x64'), ('windows', 'x64'),
            ('macos', 'x64'), ('macos', 'arm64'), ('node-linux', 'amd64'), ('node-linux', 'arm64'), ('node-windows', 'amd64')}
seen = set()
manifests = []
for path in root.rglob('build-manifest.json'):
    m = json.loads(path.read_text())
    key = m['platform'], m['architecture']
    if key in seen or key not in expected: raise ValueError('Duplicate/unexpected manifest: ' + str(key))
    seen.add(key)
    manifests.append(m)
    if m['revision'] != release.git('rev-parse', 'HEAD') or m['version'] != release.version()['version']:
        raise ValueError('Stale revision/version: ' + str(path))
    if key[0] == 'android':
        allowed = {'existing-production-key', 'unsigned-engineering'} if engineering else {'existing-production-key'}
        if m['signing'] not in allowed:
            raise ValueError('Android distribution requires existing production signing')
    if not m['toolchains'] or not m['files']: raise ValueError('Incomplete manifest')
    for f in m['files']:
        p = path.parent / f['name']
        if p.parent != path.parent or release.sha(p) != f['sha256'] or p.stat().st_size != f['size']:
            raise ValueError('Artifact mismatch: ' + str(p))
if seen != expected: raise ValueError('Missing required platforms: ' + str(expected - seen))
(root / 'BUILD-MANIFEST.json').write_text(json.dumps({'product': 'Loom', 'version': release.version()['version'],
    'revision': release.git('rev-parse', 'HEAD'), 'builds': manifests}, indent=2) + '\n')
print('All required platform manifests and artifact hashes verified')
