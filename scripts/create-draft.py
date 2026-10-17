"""Create a new draft only; never publish, replace a release or push a tag."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import release

REPOSITORY = '0800x/Loom'
if os.getenv('GITHUB_REPOSITORY') != REPOSITORY:
    raise ValueError('Draft assembly is restricted to ' + REPOSITORY)
directory = Path(sys.argv[1])
revision = release.git('rev-parse', 'HEAD')
if os.getenv('GITHUB_SHA') != revision:
    raise ValueError('Workflow and checked-out revision differ')
manifest = json.loads((directory / 'BUILD-MANIFEST.json').read_text())
if manifest['revision'] != revision:
    raise ValueError('Release assets are stale')

def gh(*arguments):
    return subprocess.check_output(['gh', *arguments], text=True).strip()

is_tag = os.getenv('GITHUB_REF_TYPE') == 'tag'
if is_tag:
    release.preflight()
    tag = os.environ['GITHUB_REF_NAME']
    title = 'Loom ' + release.version()['version']
    extra = ['--verify-tag']
else:
    if os.getenv('GITHUB_REF_NAME') != 'main':
        raise ValueError('Preview drafts require main')
    current = gh('api', 'repos/' + REPOSITORY + '/git/ref/heads/main', '--jq', '.object.sha')
    if current != revision:
        raise ValueError('Main advanced; refusing a stale preview draft')
    tag = 'preview-' + release.version()['version'] + '-' + revision[:12]
    title = 'Loom ' + release.version()['version'] + ' — alpha preview'
    extra = ['--target', revision]

existing = gh('api', '--paginate', 'repos/' + REPOSITORY + '/releases?per_page=100', '--jq', '.[].tag_name')
if tag in existing.splitlines():
    raise ValueError('A release or draft already exists; refusing replacement')
tags_before = gh('api', 'repos/' + REPOSITORY + '/git/matching-refs/tags/', '--jq', '.[].ref')
notes = (release.ROOT / 'release/DRAFT.md').read_text()
if not is_tag:
    notes = ('Alpha preview for revision `' + revision + '`.\n\n'
             'Android APKs labeled unsigned-engineering cannot be installed as-is. '
             'Windows/Linux artifacts are unsigned. macOS is ad-hoc signed, '
             'without Developer ID or notarization. No production signing key is generated.\n\n' + notes)
with tempfile.TemporaryDirectory() as folder:
    note_file = Path(folder) / 'release-notes.md'
    note_file.write_text(notes)
    assets = sorted(str(path) for path in directory.iterdir() if path.is_file())
    if not assets:
        raise ValueError('No release assets')
    subprocess.run(['gh', 'release', 'create', tag, *assets, '--repo', REPOSITORY,
                    '--draft', '--prerelease', '--title', title,
                    '--notes-file', str(note_file), *extra], check=True)
draft = json.loads(gh('api', '--paginate', 'repos/' + REPOSITORY + '/releases?per_page=100',
                     '--jq', '.[] | select(.tag_name == "' + tag + '")'))
if not draft['draft'] or not draft['prerelease']:
    raise ValueError('Release must remain a draft prerelease')
if not is_tag:
    tags_after = gh('api', 'repos/' + REPOSITORY + '/git/matching-refs/tags/', '--jq', '.[].ref')
    if tags_after != tags_before:
        raise ValueError('Unexpected tag change while creating an unpublished draft')
print('Draft prepared for owner review: ' + draft['html_url'])
