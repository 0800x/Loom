"""Publish version tags and successful main builds as public prereleases.

Publication is idempotent: a retry verifies an existing release and its assets
instead of failing merely because an earlier attempt created it.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import release

REPOSITORY = '0800x/Loom'
if os.getenv('GITHUB_REPOSITORY') != REPOSITORY:
    raise ValueError('Release publication is restricted to ' + REPOSITORY)
directory = Path(sys.argv[1])
revision = release.git('rev-parse', 'HEAD')
if os.getenv('GITHUB_SHA') != revision:
    raise ValueError('Workflow and checked-out revision differ')
manifest = json.loads((directory / 'BUILD-MANIFEST.json').read_text())
if manifest['revision'] != revision:
    raise ValueError('Release assets are stale')


def gh(*arguments):
    return subprocess.check_output(['gh', *arguments], text=True).strip()


def api_json(*arguments):
    return json.loads(gh('api', *arguments))


def resolve_tag_commit(tag):
    ref = api_json('repos/' + REPOSITORY + '/git/ref/tags/' + tag)
    target = ref['object']
    if target['type'] == 'tag':
        target = api_json('repos/' + REPOSITORY + '/git/tags/' + target['sha'])['object']
    if target['type'] != 'commit':
        raise ValueError('Release tag does not resolve to a commit: ' + tag)
    return target['sha']


def verify_release(info, tag, assets):
    if info['tag_name'] != tag or info['draft'] or not info['prerelease']:
        raise ValueError('Release is not the expected published prerelease: ' + tag)
    if resolve_tag_commit(tag) != revision:
        raise ValueError('Release tag points to a different source revision: ' + tag)
    expected = {path.name: 'sha256:' + release.sha(path) for path in assets}
    actual = {item['name']: item.get('digest') for item in info.get('assets', [])}
    if set(actual) != set(expected):
        raise ValueError('Release asset names do not match the verified build: ' + tag)
    for name, digest in expected.items():
        if actual[name] != digest:
            raise ValueError('Published release asset digest mismatch: ' + name)


def publish_or_verify(tag, title, assets, notes, extra):
    releases = api_json('--paginate', 'repos/' + REPOSITORY + '/releases?per_page=100')
    existing = next((item for item in releases if item['tag_name'] == tag), None)
    if existing is None:
        with tempfile.TemporaryDirectory() as folder:
            note_file = Path(folder) / 'release-notes.md'
            note_file.write_text(notes)
            subprocess.run([
                'gh', 'release', 'create', tag, *map(str, assets), '--repo', REPOSITORY,
                '--prerelease', '--title', title, '--notes-file', str(note_file), *extra,
            ], check=True)
        releases = api_json('--paginate', 'repos/' + REPOSITORY + '/releases?per_page=100')
        existing = next((item for item in releases if item['tag_name'] == tag), None)
        if existing is None:
            raise ValueError('GitHub did not return the newly created release: ' + tag)
    verify_release(existing, tag, assets)
    print('Published and verified prerelease: ' + existing['html_url'])
    return existing


is_tag = os.getenv('GITHUB_REF_TYPE') == 'tag'
if is_tag:
    release.preflight()
    tag = os.environ['GITHUB_REF_NAME']
    title = 'Loom ' + release.version()['version']
    primary_extra = ['--verify-tag']
else:
    if os.getenv('GITHUB_REF_NAME') != 'main':
        raise ValueError('Preview releases require main')
    current = gh('api', 'repos/' + REPOSITORY + '/git/ref/heads/main', '--jq', '.object.sha')
    if current != revision:
        raise ValueError('Main advanced; refusing a stale release')
    tag = 'preview-' + release.version()['version'] + '-' + revision[:12]
    title = 'Loom ' + release.version()['version'] + ' — alpha preview'
    primary_extra = ['--target', revision]

assets = sorted(path for path in directory.iterdir() if path.is_file())
if not assets:
    raise ValueError('No release assets')

# Validate the manager payload before publishing either release. This prevents
# a primary prerelease from being published when the installer payload is absent.
version = release.version()['version']
manager_tag = 'node-manager-' + version + '-' + revision[:12]
manager_names = [
    f'Loom-{version}-manager-linux-amd64',
    f'Loom-{version}-manager-linux-arm64',
    'Loom-node-linux-amd64-build-manifest.json',
    'Loom-node-linux-arm64-build-manifest.json',
    'node-channel.json',
]
manager_assets = [directory / name for name in manager_names]
missing = [path.name for path in manager_assets if not path.is_file()]
if missing:
    raise ValueError('Missing prebuilt Node Manager release assets: ' + ', '.join(missing))

notes = (release.ROOT / 'release/DRAFT.md').read_text()
if not is_tag:
    notes = (
        'Alpha preview for revision `' + revision + '`.\n\n'
        'Android APKs labeled unsigned-engineering cannot be installed as-is. '
        'Windows/Linux artifacts are unsigned. macOS is ad-hoc signed, '
        'without Developer ID or notarization. No production signing key is generated.\n\n'
        + notes
    )
publish_or_verify(tag, title, assets, notes, primary_extra)

manager_notes = (
    'Public prebuilt Loom Node Manager binaries for source revision `' + revision + '`.\n\n'
    'The Home Node installer downloads these verified binaries and pulls prebuilt Node and MinIO images from GHCR.\n'
    'It does not compile Go or build Docker images on the target server.'
)
publish_or_verify(
    manager_tag,
    'Loom Node Manager ' + version + ' (' + revision[:12] + ')',
    manager_assets,
    manager_notes,
    ['--target', revision],
)
