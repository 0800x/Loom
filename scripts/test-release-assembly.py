import hashlib
import json
import os
from pathlib import Path
import runpy
import tempfile
import unittest
from unittest.mock import patch
import release


class ReleaseAssembly(unittest.TestCase):
    def candidate(self, root):
        revision = release.git('rev-parse', 'HEAD')
        builds = []
        for platform in ('linux', 'windows'):
            directory = root / platform
            directory.mkdir(parents=True)
            files = []
            for name, body in [(platform + '.fixture', b'synthetic payload'),
                               ('identity-audit.json', b'{"blocked": []}')]:
                (directory / name).write_bytes(body)
                files.append({'name': name, 'size': len(body),
                              'sha256': hashlib.sha256(body).hexdigest()})
            manifest = {'revision': revision, 'platform': platform,
                        'architecture': 'x64', 'files': files}
            (directory / 'build-manifest.json').write_text(json.dumps(manifest))
            builds.append(manifest)
        (root / 'BUILD-MANIFEST.json').write_text(json.dumps(
            {'revision': revision, 'builds': builds}))

    def test_platform_audits_are_kept_without_filename_collisions(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / 'candidate'
            self.candidate(root)
            out = Path(temp) / 'assets'
            with patch('sys.argv', ['assemble-release.py', str(root), str(out)]):
                runpy.run_path(str(release.ROOT / 'scripts/assemble-release.py'))
            self.assertEqual(len(list(out.glob('*-identity-audit.json'))), 2)
            aggregate = json.loads((out / 'BUILD-MANIFEST.json').read_text())
            for build in aggregate['builds']:
                for item in build['files']:
                    self.assertEqual(release.sha(out / item['name']), item['sha256'])
            self.assertTrue((out / 'SHA256SUMS').is_file())

    def test_modified_asset_cannot_enter_the_release(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / 'candidate'
            self.candidate(root)
            (root / 'linux/linux.fixture').write_bytes(b'tampered')
            with patch('sys.argv', ['assemble-release.py', str(root), str(Path(temp) / 'out')]):
                with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
                    runpy.run_path(str(release.ROOT / 'scripts/assemble-release.py'))

    def test_successful_main_build_is_published_not_left_as_a_draft(self):
        publisher = (release.ROOT / 'scripts/create-draft.py').read_text()
        self.assertIn("'--prerelease'", publisher)
        self.assertIn("if info['tag_name'] != tag or info['draft'] or not info['prerelease']:", publisher)
        self.assertNotIn("'--draft'", publisher)
        workflow = (release.ROOT / '.github/workflows/loom-alpha.yml').read_text()
        self.assertIn('cancel-in-progress: false', workflow)

    def test_release_publication_can_resume_after_partial_success(self):
        publisher = (release.ROOT / 'scripts/create-draft.py').read_text()
        self.assertIn('def publish_or_verify(', publisher)
        self.assertIn('if existing is None:', publisher)
        self.assertIn("if info['tag_name'] != tag or info['draft'] or not info['prerelease']:", publisher)
        self.assertIn("actual[name] != digest", publisher)
        self.assertNotIn('refusing replacement', publisher)
        self.assertIn('require_revision_on_main(revision)', publisher)
        self.assertIn('/compare/', publisher)

    def test_composed_publisher_reuses_the_existing_node_manager_revision(self):
        publisher = (release.ROOT / 'scripts/create-draft.py').read_text()
        self.assertIn("manager_revision = manifest.get('node_manager_revision', revision)", publisher)
        self.assertIn("verify_existing_release(manager_tag, manager_revision, manager_names)", publisher)
        self.assertIn("'reuse_node_manager_release', False", publisher)

    def test_saved_build_publisher_reuses_existing_artifacts(self):
        workflow = (release.ROOT / '.github/workflows/publish-saved-build.yml').read_text()
        self.assertIn('workflow_dispatch:', workflow)
        self.assertIn('actions/download-artifact@v4', workflow)
        self.assertIn('run-id: ${{ inputs.source_run_id }}', workflow)
        self.assertIn('LOOM_BUILD_REVISION:', workflow)

    def test_draft_refuses_another_repository_before_any_api_call(self):
        with patch.dict(os.environ, {'GITHUB_REPOSITORY': 'example/fork'}, clear=True):
            with patch('subprocess.check_output', side_effect=AssertionError('Unexpected API call')):
                with self.assertRaisesRegex(ValueError, 'restricted'):
                    runpy.run_path(str(release.ROOT / 'scripts/create-draft.py'))


if __name__ == '__main__':
    unittest.main()
