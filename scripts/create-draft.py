"""Publish version tags and successful main builds as public prereleases.

Publication is idempotent: a retry verifies an existing release and its assets
instead of failing merely because an earlier attempt created it. Preview
publication is restricted to the current main head so queued builds from older
commits cannot create stale releases.
"""
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import tempfile
import release

REPOSITORY = '0800x/Loom'
if os.getenv('GITHUB_REPOSITORY') != REPOSITORY:
    raise ValueError('Release publication is restricted to ' + REPOSITORY)
directory = Path(sys.argv[1])
manager_only = '--manager-only' in sys.argv[2:]
manifest = json.loads((directory / 'BUILD-MANIFEST.json').read_text())
revision = manifest['revision']
requested_revision = os.getenv('LOOM_BUILD_REVISION')
if requested_revision:
    if requested_revision != revision:
        raise ValueError('Saved artifacts do not match the requested source revision')
else:
    if release.git('rev-parse', 'HEAD') != revision or os.getenv('GITHUB_SHA') != revision:
        raise ValueError('Workflow, checked-out and artifact revisions differ')


def gh(*arguments):
    return subprocess.check_output(['gh', *arguments], text=True).strip()


def api_json(*arguments):
    return json.loads(gh('api', *arguments))


def require_revision_on_main(source_revision):
    comparison = api_json(
        'repos/' + REPOSITORY + '/compare/' + source_revision + '...main'
    )
    if comparison.get('status') not in ('ahead', 'identical') or comparison.get('behind_by') != 0:
        raise ValueError('Build revision is not an ancestor of the current main branch')


def require_current_main(source_revision):
    current = api_json('repos/' + REPOSITORY + '/git/ref/heads/main')['object']['sha']
    if current != source_revision:
        raise ValueError('Preview build is stale; only the current main HEAD may publish')


def resolve_tag_commit(tag):
    ref = api_json('repos/' + REPOSITORY + '/git/ref/tags/' + tag)
    target = ref['object']
    if target['type'] == 'tag':
        target = api_json('repos/' + REPOSITORY + '/git/tags/' + target['sha'])['object']
    if target['type'] != 'commit':
        raise ValueError('Release tag does not resolve to a commit: ' + tag)
    return target['sha']


def verify_release(info, tag, assets, expected_revision):
    if info['tag_name'] != tag or info['draft'] or not info['prerelease']:
        raise ValueError('Release is not the expected published prerelease: ' + tag)
    if resolve_tag_commit(tag) != expected_revision:
        raise ValueError('Release tag points to a different source revision: ' + tag)
    expected = {path.name: 'sha256:' + release.sha(path) for path in assets}
    actual = {item['name']: item.get('digest') for item in info.get('assets', [])}
    if set(actual) != set(expected):
        raise ValueError('Release asset names do not match the verified build: ' + tag)
    for name, digest in expected.items():
        if actual[name] != digest:
            raise ValueError('Published release asset digest mismatch: ' + name)


def publish_or_verify(tag, title, assets, notes, extra, expected_revision=None):
    expected_revision = expected_revision or revision
    releases = api_json('repos/' + REPOSITORY + '/releases?per_page=100')
    existing = next((item for item in releases if item['tag_name'] == tag), None)
    if existing is None:
        with tempfile.TemporaryDirectory() as folder:
            note_file = Path(folder) / 'release-notes.md'
            note_file.write_text(notes)
            subprocess.run([
                'gh', 'release', 'create', tag, *map(str, assets), '--repo', REPOSITORY,
                '--prerelease', '--title', title, '--notes-file', str(note_file), *extra,
            ], check=True)
        releases = api_json('repos/' + REPOSITORY + '/releases?per_page=100')
        existing = next((item for item in releases if item['tag_name'] == tag), None)
        if existing is None:
            raise ValueError('GitHub did not return the newly created release: ' + tag)
    verify_release(existing, tag, assets, expected_revision)
    print('Published and verified prerelease: ' + existing['html_url'])
    return existing


def verify_existing_release(tag, expected_revision, expected_names):
    releases = api_json('repos/' + REPOSITORY + '/releases?per_page=100')
    existing = next((item for item in releases if item['tag_name'] == tag), None)
    if existing is None:
        raise ValueError('Expected previously published Node Manager release is missing: ' + tag)
    if existing['draft'] or not existing['prerelease']:
        raise ValueError('Existing Node Manager release is not a published prerelease: ' + tag)
    if resolve_tag_commit(tag) != expected_revision:
        raise ValueError('Existing Node Manager release points to an unexpected source revision')
    actual = {item['name']: item.get('digest') for item in existing.get('assets', [])}
    if set(actual) != set(expected_names):
        raise ValueError('Existing Node Manager release asset names do not match the expected set')
    for name, digest in actual.items():
        if not isinstance(digest, str) or not re.fullmatch(r'sha256:[0-9a-f]{64}', digest):
            raise ValueError('Existing Node Manager release has no valid SHA-256 digest: ' + name)
    print('Reused and verified existing Node Manager release: ' + existing['html_url'])
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
    require_revision_on_main(revision)
    require_current_main(revision)
    tag = 'preview-' + release.version()['version'] + '-' + revision[:12]
    title = 'Loom ' + release.version()['version'] + ' — Alpha Preview'
    primary_extra = ['--target', revision]

assets = sorted(path for path in directory.iterdir() if path.is_file())
if not assets:
    raise ValueError('No release assets')

# Validate the manager payload before publishing either release. This prevents
# a primary prerelease from being published when the installer payload is absent.
version = release.version()['version']
manager_revision = manifest.get('node_manager_revision', revision)
if not re.fullmatch(r'[0-9a-f]{40}', manager_revision):
    raise ValueError('Invalid Node Manager source revision in release manifest')
require_revision_on_main(manager_revision)
manager_tag = 'node-manager-' + version + '-' + manager_revision[:12]
manager_names = [
    f'Loom-{version}-manager-linux-amd64',
    f'Loom-{version}-manager-linux-arm64',
    f'Loom-node-linux-amd64-build-manifest.json',
    f'Loom-node-linux-arm64-build-manifest.json',
    'node-channel.json',
    'loom-install.sh',
    'loom-install.sh.sha256',
]
manager_assets = [directory / name for name in manager_names]
missing = [path.name for path in manager_assets if not path.is_file()]
if missing:
    raise ValueError('Missing prebuilt Node Manager release assets: ' + ', '.join(missing))

notes = (release.ROOT / 'release/DRAFT.md').read_text()
provenance = manifest.get('provenance')
if provenance:
    client = provenance['client']
    node = provenance['node']
    validation = provenance['validation']
    notes = (
        '## Verified build provenance\n\n'
        + '- Client distributions: revision `' + client['revision'] + '` (Actions run `' + str(client['run_id']) + '`).\n'
        + '- Home Node and Node Manager: revision `' + node['revision'] + '` (Actions run `' + str(node['run_id']) + '`).\n'
        + '- Final validation: revision `' + validation['revision'] + '` (validate-only run `' + str(validation['run_id']) + '`).\n\n'
        + 'The publisher reused the verified platform artifacts; it did not rebuild Android, Windows, macOS, or Linux client packages. The client source changes after its recorded build revision are limited to non-behavioral analyzer cleanups.\n\n'
        + notes
    )
if not is_tag:
    notes = (
        'Alpha preview for revision `' + revision + '`.\n\n'
        'Android APK filenames and manifests identify whether each build uses the existing protected production keystore or unsigned-engineering mode; unsigned-engineering APKs are not installable as-is. '
        'Windows/Linux desktop artifacts are unsigned. macOS packages are ad-hoc signed, '
        'without Developer ID or notarization. The pipeline never creates a new production signing key.\n\n'
        + notes
    )
if not manager_only:
    publish_or_verify(tag, title, assets, notes, primary_extra, expected_revision=revision)

manager_component_version = release.version()['components']['terminalManager']
manager_notes = (
    'Loom Node Manager ' + manager_component_version + ' for Loom ' + version + ', built from source revision `' + manager_revision + '`.\n\n'
    'The release includes the verified Home Node installer bootstrap, Node Manager binaries and build manifests.\n'
    'The installer pulls prebuilt Node and MinIO images from GHCR; it does not compile Go or build Docker images on the target server.'
)
if manifest.get('reuse_node_manager_release', False):
    verify_existing_release(manager_tag, manager_revision, manager_names)
else:
    publish_or_verify(
        manager_tag,
        'Loom Node Manager ' + manager_component_version + ' — Loom ' + version + ' (' + manager_revision[:12] + ')',
        manager_assets,
        manager_notes,
        ['--target', manager_revision],
        expected_revision=manager_revision,
    )
