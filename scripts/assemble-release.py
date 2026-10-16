"""Flatten verified per-platform assets into a reviewable release directory."""
import json
from pathlib import Path
import shutil
import sys
import release

source, destination = map(Path, sys.argv[1:3])
if destination.exists() and any(destination.iterdir()):
    raise ValueError('Release directory must be empty')
destination.mkdir(parents=True, exist_ok=True)
aggregate = json.loads((source / 'BUILD-MANIFEST.json').read_text())
if aggregate['revision'] != release.git('rev-parse', 'HEAD'):
    raise ValueError('Stale aggregate manifest')
seen = set()
release_builds = []
for path in sorted(source.rglob('build-manifest.json')):
    manifest = json.loads(path.read_text())
    slug = manifest['platform'] + '-' + manifest['architecture'].replace(',', '-')
    for item in manifest['files']:
        original = item['name']
        name = 'Loom-' + slug + '-identity-audit.json' if original == 'identity-audit.json' else original
        if name in seen or Path(name).name != name:
            raise ValueError('Duplicate or unsafe release asset: ' + name)
        seen.add(name)
        asset = path.parent / original
        if release.sha(asset) != item['sha256'] or asset.stat().st_size != item['size']:
            raise ValueError('Asset checksum mismatch: ' + name)
        shutil.copy2(asset, destination / name)
        item['name'] = name
    (destination / ('Loom-' + slug + '-build-manifest.json')).write_text(json.dumps(manifest, indent=2) + '\n')
    release_builds.append(manifest)
aggregate['builds'] = release_builds
(destination / 'BUILD-MANIFEST.json').write_text(json.dumps(aggregate, indent=2) + '\n')
release.checksums(destination)
print('Prepared individually downloadable release assets with SHA256SUMS')
