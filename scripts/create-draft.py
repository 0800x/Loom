"""Publish version tags and successful main builds as public prereleases."""
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
tags_before = set(gh('api', '--paginate', 'repos/' + REPOSITORY + '/git/matching-refs/tags/', '--jq', '.[].ref').splitlines())
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
                    '--prerelease', '--title', title,
                    '--notes-file', str(note_file), *extra], check=True)
release_info = json.loads(gh('api', '--paginate', 'repos/' + REPOSITORY + '/releases?per_page=100',
                             '--jq', '.[] | select(.tag_name == "' + tag + '")'))
if release_info['draft'] or not release_info['prerelease']:
    raise ValueError('Build release must be a published prerelease')
if not is_tag:
    tags_after_primary = set(gh('api', '--paginate', 'repos/' + REPOSITORY + '/git/matching-refs/tags/', '--jq', '.[].ref').splitlines())
    if tags_after_primary - tags_before != {'refs/tags/' + tag}:
        raise ValueError('Unexpected Git tag change while publishing the main-build prerelease')
print('Published build prerelease: ' + release_info['html_url'])
# Publish the host-side Node Manager separately so Home Node can fetch only
# the minimal verified Linux binaries and channel metadata by immutable revision.
version = release.version()["version"]
manager_tag = "node-manager-" + version + "-" + revision[:12]
manager_names = [
    f"Loom-{version}-manager-linux-amd64",
    f"Loom-{version}-manager-linux-arm64",
    "Loom-node-linux-amd64-build-manifest.json",
    "Loom-node-linux-arm64-build-manifest.json",
    "node-channel.json",
]
manager_assets = [directory / name for name in manager_names]
missing = [path.name for path in manager_assets if not path.is_file()]
if missing:
    raise ValueError("Missing prebuilt Node Manager release assets: " + ", ".join(missing))
manager_notes = (
    "Public prebuilt Loom Node Manager binaries for source revision `" + revision + "`.\\n\\n"
    "The Home Node installer downloads these verified binaries and pulls prebuilt Node and MinIO images from GHCR.\\n"
    "It does not compile Go or build Docker images on the target server."
)
subprocess.run([
    "gh", "release", "create", manager_tag, *map(str, manager_assets),
    "--repo", REPOSITORY, "--target", revision, "--prerelease",
    "--title", "Loom Node Manager " + version + " (" + revision[:12] + ")",
    "--notes", manager_notes,
], check=True)
manager_release = json.loads(gh(
    "api", "repos/" + REPOSITORY + "/releases/tags/" + manager_tag
))
if manager_release["draft"] or not manager_release["prerelease"]:
    raise ValueError("Node Manager distribution must be a public prerelease")
published_names = {asset["name"] for asset in manager_release["assets"]}
if set(manager_names) != published_names:
    raise ValueError("Node Manager prerelease is missing or has unexpected assets")
print("Published public Node Manager distribution: " + manager_release["html_url"])
manager_tags_after = set(gh("api", "--paginate", "repos/" + REPOSITORY + "/git/matching-refs/tags/", "--jq", ".[].ref").splitlines())
expected_added = {"refs/tags/" + manager_tag}
if not is_tag:
    expected_added.add("refs/tags/" + tag)
if manager_tags_after - tags_before != expected_added:
    raise ValueError("Unexpected Git tag changes during release publication")
