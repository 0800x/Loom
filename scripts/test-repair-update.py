#!/usr/bin/env python3
"""Exercise recovery's actual offline verification against real Git objects."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / 'services/loom_server/scripts/linux/repair-update.sh'
SCRIPT = HELPER.read_text()
OFFLINE = SCRIPT.split('offline_git() {', 1)[1].split('/usr/bin/env -i PATH=/usr/sbin', 1)[0]
OFFLINE = 'offline_git() {' + OFFLINE


class RecoveryVerification(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.stage = Path(self.temp.name)
        self.repo = self.stage / 'repo'
        self.repo.mkdir()
        self.git('init', '-q')
        (self.repo / 'payload.txt').write_text('release payload\n')
        self.git('add', 'payload.txt')
        self.git('-c', 'user.name=Recovery Test', '-c', 'user.email=test@example.com', 'commit', '-qm', 'fixture')
        self.revision = self.git('rev-parse', 'HEAD').strip()

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.repo), *args], text=True)

    def verify(self, revision=None):
        env = dict(os.environ, stage=str(self.stage), revision=revision or self.revision)
        return subprocess.run(['bash', '-c', 'set -euo pipefail\n' + OFFLINE], env=env, capture_output=True, text=True)

    def test_valid_pin_extracts_private_marker(self):
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stderr)
        marker = self.stage / 'source/.loom-verified-source'
        self.assertEqual(marker.read_text().strip(), self.revision)
        self.assertEqual(marker.stat().st_mode & 0o777, 0o600)
        self.assertEqual((self.stage / 'source/payload.txt').read_text(), 'release payload\n')

    def test_wrong_pin_fails_before_extract(self):
        self.assertNotEqual(self.verify('a' * 40).returncode, 0)
        self.assertFalse((self.stage / 'source').exists())

    def test_corrupted_object_fails_before_extract(self):
        blob = self.git('rev-parse', 'HEAD:payload.txt').strip()
        object_file = self.repo / '.git/objects' / blob[:2] / blob[2:]
        object_file.chmod(0o600)
        object_file.write_bytes(b'corrupt object')
        self.assertNotEqual(self.verify().returncode, 0)
        self.assertFalse((self.stage / 'source').exists())

    def test_downloaded_hooks_and_fsmonitor_do_not_execute(self):
        sentinel = self.stage / 'unsafe-command-ran'
        self.git('config', 'core.fsmonitor', f'touch {sentinel}')
        self.git('config', 'core.hooksPath', str(self.stage / 'hooks'))
        self.assertEqual(self.verify().returncode, 0)
        self.assertFalse(sentinel.exists())

    def test_branch_argument_rejected_before_credentials(self):
        result = subprocess.run(['bash', str(HELPER), 'main'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn('TRUSTED_FULL_COMMIT_SHA', result.stderr)


if __name__ == '__main__':
    unittest.main()
